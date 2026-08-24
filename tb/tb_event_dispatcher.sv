/*
 * tb_event_dispatcher
 * -------------------
 * Subsystem test for event_dispatcher, wired to the REAL order_lookup and
 * book_update (the two units it choreographs), exactly as in top_v2. Driving
 * real neighbors keeps the busy/ready/res_valid handshakes honest instead of
 * hand-modeling their timing.
 *
 * The TB feeds itch_event_t events into the dispatcher and then reads back
 * the resulting book state through book_update's read ports.
 *
 * Covers the protocol logic that the smoke test does NOT exercise:
 *   - Add then Execute: book decremented, trade tap pulses (E only)
 *   - Replace 'U' two-step decomposition:
 *        (1) delete OLD id  -> old level drained to 0, mask clears
 *        (2) insert NEW id  -> new level = new qty, side INHERITED from step 1
 *   - Delete of an unknown id -> miss_count increments, book untouched
 *   - trade tap fires for Execute only, never for Cancel/Delete/Replace
 *
 * Book calibration: BASE_PRICE=1_550_000, TICK=100.
 *   price 1_600_000 -> level 500 ; 1_600_200 -> 502 ; 1_601_000 -> 510
 */
`timescale 1ns/1ps

module tb_event_dispatcher;
    import ITCH50_pkg::*;

    localparam int unsigned BASE_PRICE  = 1_550_000;
    localparam int unsigned WINDOW_SIZE = 2048;
    localparam int          TABLE_BITS  = 12;
    localparam int          ADDR_W      = $clog2(WINDOW_SIZE);

    logic clk = 0, arstn = 0;

    // dispatcher <- TB
    itch_event_t ev;
    logic        ev_valid = 0, ev_ready;

    // dispatcher <-> order_lookup
    logic        ins_valid; logic [63:0] ins_order_id;
    logic [31:0] ins_price, ins_qty; logic ins_side;
    logic        qry_valid; logic [63:0] qry_order_id;
    lookup_op_e  qry_op;    logic [31:0] qry_qty;
    logic        lk_busy, res_valid, res_hit, res_side, res_removed;
    logic [31:0] res_price, res_delta_qty;

    // dispatcher <-> book_update
    logic        bu_valid, bu_is_add, bu_side, bu_ready;
    logic [31:0] bu_price, bu_qty;

    // trade tap
    logic        trade_valid, trade_side;
    logic [31:0] trade_qty;
    logic [31:0] miss_count;

    // book read/observe
    logic [WINDOW_SIZE-1:0] bid_mask, ask_mask;
    logic [ADDR_W-1:0]      bid_rd_addr = 0, ask_rd_addr = 0;
    logic [31:0]            bid_rd_data, ask_rd_data;
    logic                   book_updated;
    logic [31:0]            oow_count;

    int pass_count = 0, fail_count = 0;

    // trade-tap monitor
    int          trade_events = 0;
    logic        last_trade_side;
    logic [31:0] last_trade_qty;

    // ---------------- DUT + real neighbors ----------------
    event_dispatcher u_disp (
        .clk(clk), .arstn(arstn),
        .ev(ev), .ev_valid(ev_valid), .ev_ready(ev_ready),
        .ins_valid(ins_valid), .ins_order_id(ins_order_id),
        .ins_price(ins_price), .ins_qty(ins_qty), .ins_side(ins_side),
        .qry_valid(qry_valid), .qry_order_id(qry_order_id),
        .qry_op(qry_op), .qry_qty(qry_qty),
        .lk_busy(lk_busy),
        .res_valid(res_valid), .res_hit(res_hit), .res_price(res_price),
        .res_side(res_side), .res_delta_qty(res_delta_qty),
        .res_removed(res_removed),
        .bu_valid(bu_valid), .bu_is_add(bu_is_add), .bu_price(bu_price),
        .bu_qty(bu_qty), .bu_side(bu_side), .bu_ready(bu_ready),
        .trade_valid(trade_valid), .trade_side(trade_side),
        .trade_qty(trade_qty),
        .miss_count(miss_count)
    );

    order_lookup #(.TABLE_BITS(TABLE_BITS)) u_lk (
        .clk(clk), .arstn(arstn),
        .ins_valid(ins_valid), .ins_order_id(ins_order_id),
        .ins_price(ins_price), .ins_qty(ins_qty), .ins_side(ins_side),
        .qry_valid(qry_valid), .qry_order_id(qry_order_id),
        .qry_op(qry_op), .qry_qty(qry_qty),
        .busy(lk_busy),
        .res_valid(res_valid), .res_hit(res_hit), .res_price(res_price),
        .res_side(res_side), .res_delta_qty(res_delta_qty),
        .res_removed(res_removed)
    );

    book_update #(.BASE_PRICE(BASE_PRICE), .WINDOW_SIZE(WINDOW_SIZE)) u_book (
        .clk(clk), .arstn(arstn),
        .bu_valid(bu_valid), .bu_is_add(bu_is_add), .bu_price(bu_price),
        .bu_qty(bu_qty), .bu_side(bu_side), .bu_ready(bu_ready),
        .bid_mask(bid_mask), .ask_mask(ask_mask),
        .bid_rd_addr(bid_rd_addr), .bid_rd_data(bid_rd_data),
        .ask_rd_addr(ask_rd_addr), .ask_rd_data(ask_rd_data),
        .book_updated(book_updated), .oow_count(oow_count)
    );

    always #5 clk = ~clk;
    initial begin #200000; $error("[TIMEOUT] sim stuck"); $finish; end

    // trade tap monitor
    always @(posedge clk) begin
        if (arstn && trade_valid) begin
            trade_events   <= trade_events + 1;
            last_trade_side <= trade_side;
            last_trade_qty  <= trade_qty;
        end
    end

    // ---------------- helpers ----------------
    task automatic check(input string desc, input logic cond);
        if (cond) begin pass_count++; $display("[PASS] %s", desc); end
        else      begin fail_count++; $error("[FAIL] %s", desc); end
    endtask

    // Wait for the WHOLE chain to be genuinely quiescent. The dispatcher can
    // return to IDLE (ev_ready=1) a cycle before a book/lookup strobe it just
    // issued has been accepted (the neighbor drops ready only on the next
    // posedge). Requiring several CONSECUTIVE fully-idle cycles - no strobes
    // in flight, both neighbors ready - closes that window.
    task automatic settle();
        int stable;
        stable = 0;
        while (stable < 6) begin
            @(negedge clk);
            if (ev_ready && !lk_busy && bu_ready &&
                !bu_valid && !ins_valid && !qry_valid)
                stable++;
            else
                stable = 0;
        end
    endtask

    task automatic send_event(input itch_event_t e);
        // inject only when dispatcher is in IDLE (ev_ready)
        while (!ev_ready) @(negedge clk);
        @(negedge clk);
        ev       = e;
        ev_valid = 1'b1;
        @(negedge clk);      // one posedge in between: dispatcher latches it
        ev_valid = 1'b0;
        ev       = '0;
        settle();            // let the whole op drain through lookup + book
    endtask

    function automatic itch_event_t mk(
        input logic [7:0] mt, input logic [63:0] oid, input logic [63:0] noid,
        input logic [31:0] price, input logic [31:0] shares, input logic side);
        itch_event_t e;
        e = '0;
        e.msg_type     = mt;
        e.stock_locate = 16'd1;
        e.order_id     = oid;
        e.new_order_id = noid;
        e.price        = price;
        e.shares       = shares;
        e.side         = side;
        return e;
    endfunction

    task automatic read_bid(input logic [ADDR_W-1:0] a, output logic [31:0] q);
        @(negedge clk); bid_rd_addr = a;
        @(negedge clk); q = bid_rd_data;
    endtask

    logic [31:0] q;
    int          tprev;

    initial begin
        repeat (4) @(posedge clk);
        arstn = 1;
        repeat (2) @(posedge clk);
        settle();

        // 1) ADD buy oid=100, 300 @ 1_600_000 (level 500)
        send_event(mk(MSG_TYPE_ADD, 64'd100, 64'd0, 32'd1_600_000, 32'd300, 1'b0));
        read_bid(11'd500, q);
        check("add: bid qty@500 = 300", q == 32'd300);
        check("add: bid_mask[500]=1",   bid_mask[500] == 1'b1);

        // 2) EXEC oid=100, 50 shares -> book 250, trade tap pulses (buy side)
        tprev = trade_events;
        send_event(mk(MSG_TYPE_EXEC, 64'd100, 64'd0, 32'd0, 32'd50, 1'b0));
        read_bid(11'd500, q);
        check("exec: bid qty@500 = 250",     q == 32'd250);
        check("exec: 1 trade event",         trade_events == tprev + 1);
        check("exec: trade_qty = 50",        last_trade_qty == 32'd50);
        check("exec: trade_side = buy(0)",   last_trade_side == 1'b0);

        // 3) ADD sell oid=200, 200 @ 1_600_200 (level 502)
        send_event(mk(MSG_TYPE_ADD, 64'd200, 64'd0, 32'd1_600_200, 32'd200, 1'b1));

        // 4) REPLACE: old=100 (250 left) -> new=300, 400 @ 1_601_000 (level 510)
        //    step1 deletes old @500 -> 0 ; step2 inserts new @510, side inherited=buy
        tprev = trade_events;
        send_event(mk(MSG_TYPE_REPLACE, 64'd100, 64'd300, 32'd1_601_000, 32'd400, 1'b0));
        read_bid(11'd500, q);
        check("replace: old level@500 drained to 0", q == 32'd0);
        check("replace: mask[500] cleared",          bid_mask[500] == 1'b0);
        read_bid(11'd510, q);
        check("replace: new level@510 = 400",        q == 32'd400);
        check("replace: mask[510]=1 (bid, inherited)", bid_mask[510] == 1'b1);
        check("replace: no trade tap (not an exec)", trade_events == tprev);

        // 5) DELETE unknown oid=9999 -> miss_count++, book untouched
        tprev = miss_count;
        send_event(mk(MSG_TYPE_DELETE, 64'd9999, 64'd0, 32'd0, 32'd0, 1'b0));
        check("unknown delete: miss_count++", miss_count == tprev + 1);
        read_bid(11'd510, q);
        check("unknown delete: book untouched@510", q == 32'd400);

        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display(fail_count == 0 ? "  ALL TESTS PASSED" : "  THERE ARE FAILURES");
        $display("========================================");
        $finish;
    end

    initial begin
        $dumpfile("tb_event_dispatcher.vcd");
        $dumpvars(0, tb_event_dispatcher);
    end

endmodule
