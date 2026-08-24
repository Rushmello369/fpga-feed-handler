/*
 * tb_itch_parser
 * --------------
 * Unit test for itch_parser (byte-serial ITCH 5.0 framing decoder).
 *
 * Covers:
 *   - Add 'A'  : full field extraction (order_id/side/shares/price/stock_locate)
 *   - Delete 'D': order_id-only extraction, is_book_affecting -> event emitted
 *   - System 'S': known but NOT book-affecting -> NO event, msg_count++ only
 *   - Unknown 'H': msg_length()==0 -> skipped, unknown_count++, no desync
 *   - Length mismatch: framing prefix != msg_length(type) -> parse_error pulse,
 *                      event NOT emitted (guards against upstream misalignment)
 *   - back-to-back Adds: parser re-arms, second event still correct
 *
 * Driver respects s_tready (parser deasserts it while holding an event in EMIT).
 * A background consumer raises ev_ready for one cycle whenever ev_valid, and
 * latches the emitted event so the checker can inspect it.
 */
`timescale 1ns/1ps

module tb_itch_parser;
    import ITCH50_pkg::*;

    logic        clk = 0, arstn = 0;
    logic        s_tvalid = 0;
    logic [7:0]  s_tdata  = 0;
    logic        s_tready;
    itch_event_t ev;
    logic        ev_valid;
    logic        ev_ready = 0;
    logic        parse_error;
    logic [31:0] unknown_count, msg_count;

    int pass_count = 0, fail_count = 0;

    // captured event bookkeeping
    itch_event_t last_ev;
    int          events_seen   = 0;
    int          parse_err_cnt = 0;

    itch_parser dut (
        .clk(clk), .arstn(arstn),
        .s_tvalid(s_tvalid), .s_tdata(s_tdata), .s_tready(s_tready),
        .ev(ev), .ev_valid(ev_valid), .ev_ready(ev_ready),
        .parse_error(parse_error),
        .unknown_count(unknown_count), .msg_count(msg_count)
    );

    always #5 clk = ~clk;

    // ---- consumer: accept every emitted event, latch it ----
    always @(posedge clk) begin
        if (!arstn) begin
            events_seen   <= 0;
            parse_err_cnt <= 0;
            ev_ready      <= 0;
        end else begin
            ev_ready <= 0;
            if (ev_valid && !ev_ready) begin
                last_ev     <= ev;
                events_seen <= events_seen + 1;
                ev_ready    <= 1'b1;    // take it next cycle
            end
            if (parse_error) parse_err_cnt <= parse_err_cnt + 1;
        end
    end

    // ---- byte driver (respects backpressure) ----
    task automatic send_byte(input logic [7:0] b);
        @(posedge clk);
        while (!s_tready) @(posedge clk);
        s_tvalid <= 1'b1;
        s_tdata  <= b;
        @(posedge clk);
        s_tvalid <= 1'b0;
    endtask

    logic [7:0] mb [0:63];

    task automatic send_frame(input int unsigned n);
        send_byte(n[15:8]);
        send_byte(n[7:0]);
        for (int i = 0; i < n; i++) send_byte(mb[i]);
    endtask

    // Add 'A' (36B)
    task automatic build_add(input logic [63:0] oid, input logic [7:0] side,
                             input logic [31:0] shares, input logic [31:0] price);
        for (int i = 0; i < 36; i++) mb[i] = 8'h00;
        mb[0] = MSG_TYPE_ADD;
        mb[1] = 8'h00; mb[2] = 8'h07;                      // stock_locate = 7
        for (int i = 0; i < 8; i++) mb[11+i] = oid[8*(7-i) +: 8];
        mb[19] = side;
        for (int i = 0; i < 4; i++) mb[20+i] = shares[8*(3-i) +: 8];
        for (int i = 0; i < 4; i++) mb[32+i] = price[8*(3-i) +: 8];
    endtask

    // Delete 'D' (19B)
    task automatic build_delete(input logic [63:0] oid);
        for (int i = 0; i < 19; i++) mb[i] = 8'h00;
        mb[0] = MSG_TYPE_DELETE;
        mb[1] = 8'h00; mb[2] = 8'h07;
        for (int i = 0; i < 8; i++) mb[11+i] = oid[8*(7-i) +: 8];
    endtask

    task automatic build_system();   // 'S' (12B) known, not book-affecting
        for (int i = 0; i < 12; i++) mb[i] = 8'h00;
        mb[0] = MSG_TYPE_EVENT;
    endtask

    task automatic build_unknown(input int unsigned n);   // 'H' unknown type
        for (int i = 0; i < n; i++) mb[i] = 8'h00;
        mb[0] = "H";
    endtask

    task automatic check(input string desc, input logic cond);
        if (cond) begin pass_count++; $display("[PASS] %s", desc); end
        else      begin fail_count++; $error("[FAIL] %s", desc); end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        arstn = 1;
        repeat (2) @(posedge clk);

        // 1) well-formed Add
        build_add(64'hDEAD_BEEF_0000_0064, MSG_SIDE_BUY, 32'd300, 32'd1_600_000);
        send_frame(36);
        repeat (6) @(posedge clk);
        check("Add: 1 event emitted",        events_seen == 1);
        check("Add: order_id",   last_ev.order_id   == 64'hDEAD_BEEF_0000_0064);
        check("Add: side=buy(0)",last_ev.side       == 1'b0);
        check("Add: shares=300", last_ev.shares     == 32'd300);
        check("Add: price",      last_ev.price      == 32'd1_600_000);
        check("Add: stock_locate=7", last_ev.stock_locate == 16'd7);
        check("Add: no parse_error", parse_err_cnt == 0);
        check("Add: msg_count=1", msg_count == 32'd1);

        // 2) Delete (order_id only, book-affecting)
        build_delete(64'h0000_0000_0000_0064);
        send_frame(19);
        repeat (6) @(posedge clk);
        check("Delete: 2 events total",  events_seen == 2);
        check("Delete: order_id",        last_ev.order_id == 64'd100);
        check("Delete: msg_type=D",      last_ev.msg_type == MSG_TYPE_DELETE);

        // 3) System event: known, NOT book-affecting -> no new event
        build_system();
        send_frame(12);
        repeat (6) @(posedge clk);
        check("System: still 2 events (no emit)", events_seen == 2);
        check("System: msg_count=3",              msg_count == 32'd3);
        check("System: unknown_count still 0",    unknown_count == 32'd0);

        // 4) Unknown type -> skipped, counted, no desync
        build_unknown(20);
        send_frame(20);
        repeat (6) @(posedge clk);
        check("Unknown: still 2 events",     events_seen == 2);
        check("Unknown: unknown_count=1",    unknown_count == 32'd1);

        // 5) Length mismatch: Add body but framing says 35 (should be 36)
        build_add(64'd200, MSG_SIDE_SELL, 32'd50, 32'd1_600_100);
        send_frame(35);
        repeat (6) @(posedge clk);
        check("LenMismatch: parse_error pulsed", parse_err_cnt == 1);
        check("LenMismatch: no event emitted",   events_seen == 2);

        // 6) back-to-back Adds prove the parser re-arms cleanly
        build_add(64'd300, MSG_SIDE_SELL, 32'd77, 32'd1_600_500);
        send_frame(36);
        build_add(64'd301, MSG_SIDE_BUY,  32'd88, 32'd1_600_600);
        send_frame(36);
        repeat (8) @(posedge clk);
        check("B2B: 4 events total",  events_seen == 4);
        check("B2B: last shares=88",  last_ev.shares == 32'd88);
        check("B2B: last side=buy",   last_ev.side   == 1'b0);

        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display(fail_count == 0 ? "  ALL TESTS PASSED" : "  THERE ARE FAILURES");
        $display("========================================");
        $finish;
    end

    initial begin
        $dumpfile("tb_itch_parser.vcd");
        $dumpvars(0, tb_itch_parser);
    end

endmodule
