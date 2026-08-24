/*
 * tb_book_update
 * --------------
 * Unit test for book_update (aggregate price-level book).
 *
 * BASE_PRICE=1_550_000, WINDOW_SIZE=2048, TICK_SIZE=100 (from pkg).
 *   level_index = (price - BASE_PRICE) / 100
 *   window covers price in [1_550_000, 1_550_000 + 2048*100) = [1.55M, 1.7548M)
 *
 * $160.00 -> price word 1_600_000 -> level (1_600_000-1_550_000)/100 = 500.
 *
 * Covers:
 *   - add liquidity: mask bit set, qty readable via read port
 *   - accumulate at same level
 *   - remove (partial): qty decremented, mask stays 1
 *   - remove to zero: mask bit CLEARS (critical - a stale mask bit makes the
 *     priority encoder point at an empty level)
 *   - bid vs ask independence
 *   - out-of-window price (too low / too high): dropped, oow_count++, no change
 *   - remove more than resting: clamps at 0, no wrap
 */
`timescale 1ns/1ps

module tb_book_update;
    import ITCH50_pkg::*;

    localparam int unsigned BASE_PRICE  = 1_550_000;
    localparam int unsigned WINDOW_SIZE = 2048;
    localparam int          ADDR_W      = $clog2(WINDOW_SIZE);

    logic                    clk = 0, arstn = 0;
    logic                    bu_valid = 0, bu_is_add = 0, bu_side = 0;
    logic [31:0]             bu_price = 0, bu_qty = 0;
    logic                    bu_ready;
    logic [WINDOW_SIZE-1:0]  bid_mask, ask_mask;
    logic [ADDR_W-1:0]       bid_rd_addr = 0, ask_rd_addr = 0;
    logic [31:0]             bid_rd_data, ask_rd_data;
    logic                    book_updated;
    logic [31:0]             oow_count;

    int pass_count = 0, fail_count = 0;

    book_update #(.BASE_PRICE(BASE_PRICE), .WINDOW_SIZE(WINDOW_SIZE)) dut (
        .clk(clk), .arstn(arstn),
        .bu_valid(bu_valid), .bu_is_add(bu_is_add), .bu_price(bu_price),
        .bu_qty(bu_qty), .bu_side(bu_side), .bu_ready(bu_ready),
        .bid_mask(bid_mask), .ask_mask(ask_mask),
        .bid_rd_addr(bid_rd_addr), .bid_rd_data(bid_rd_data),
        .ask_rd_addr(ask_rd_addr), .ask_rd_data(ask_rd_data),
        .book_updated(book_updated), .oow_count(oow_count)
    );

    always #5 clk = ~clk;

    // watchdog: self-terminate instead of hanging if a wait loop is stuck
    initial begin
        #100000;   // 100 us
        $error("[TIMEOUT] simulation did not finish - a wait loop is stuck");
        $finish;
    end

    // Sample bu_ready / drive commands on the NEGEDGE to dodge the posedge
    // nonblocking-update race (reading bu_ready at the posedge can return the
    // stale value and fire the next command a cycle early, while the DUT is
    // still busy). Stimulus driven with blocking = so it is stable before the
    // DUT's sampling posedge.
    task automatic wait_ready();
        do @(negedge clk); while (!bu_ready);
    endtask

    task automatic cmd(input logic is_add, input logic [31:0] price,
                       input logic [31:0] qty, input logic side);
        wait_ready();
        @(negedge clk);
        bu_valid  = 1'b1;
        bu_is_add = is_add;
        bu_price  = price;
        bu_qty    = qty;
        bu_side   = side;
        @(negedge clk);
        bu_valid  = 1'b0;
        wait_ready();     // returns once FSM is back in IDLE (WRITE committed)
    endtask

    // read a level's qty through book_update's registered read port
    // (set addr on a negedge, one posedge latches the data, read next negedge)
    task automatic read_bid(input logic [ADDR_W-1:0] a, output logic [31:0] q);
        @(negedge clk);
        bid_rd_addr = a;
        @(negedge clk);
        q = bid_rd_data;
    endtask

    task automatic read_ask(input logic [ADDR_W-1:0] a, output logic [31:0] q);
        @(negedge clk);
        ask_rd_addr = a;
        @(negedge clk);
        q = ask_rd_data;
    endtask

    task automatic check(input string desc, input logic cond);
        if (cond) begin pass_count++; $display("[PASS] %s", desc); end
        else      begin fail_count++; $error("[FAIL] %s", desc); end
    endtask

    logic [31:0] q;

    initial begin
        repeat (4) @(posedge clk);
        arstn = 1;
        repeat (2) @(posedge clk);

        // --- add BID 300 @ 1_600_000 -> level 500 ---
        cmd(1'b1, 32'd1_600_000, 32'd300, 1'b0);
        check("add: bid_mask[500]=1", bid_mask[500] == 1'b1);
        read_bid(10'd500, q);
        check("add: bid qty@500 = 300", q == 32'd300);

        // --- accumulate 200 more at same level ---
        cmd(1'b1, 32'd1_600_000, 32'd200, 1'b0);
        read_bid(10'd500, q);
        check("accumulate: bid qty@500 = 500", q == 32'd500);

        // --- partial remove 150 -> 350, mask still set ---
        cmd(1'b0, 32'd1_600_000, 32'd150, 1'b0);
        read_bid(10'd500, q);
        check("remove partial: qty@500 = 350", q == 32'd350);
        check("remove partial: mask still 1",  bid_mask[500] == 1'b1);

        // --- remove remaining 350 -> 0, mask MUST clear ---
        cmd(1'b0, 32'd1_600_000, 32'd350, 1'b0);
        read_bid(10'd500, q);
        check("remove all: qty@500 = 0",     q == 32'd0);
        check("remove all: mask CLEARED",    bid_mask[500] == 1'b0);

        // --- ask side independent: add 200 @ 1_600_200 -> level 502 ---
        cmd(1'b1, 32'd1_600_200, 32'd200, 1'b1);
        check("ask: ask_mask[502]=1", ask_mask[502] == 1'b1);
        check("ask: bid_mask[502]=0 (independent)", bid_mask[502] == 1'b0);
        read_ask(10'd502, q);
        check("ask: qty@502 = 200", q == 32'd200);

        // --- out-of-window: below base ---
        cmd(1'b1, 32'd1_540_000, 32'd10, 1'b0);
        check("oow low: count=1", oow_count == 32'd1);

        // --- out-of-window: at/above top (1_550_000 + 2048*100 = 1_754_800) ---
        cmd(1'b1, 32'd1_754_800, 32'd10, 1'b0);
        check("oow high: count=2", oow_count == 32'd2);

        // --- remove more than resting: clamp, no wrap ---
        cmd(1'b1, 32'd1_601_000, 32'd40, 1'b0);   // level 510 = 40
        cmd(1'b0, 32'd1_601_000, 32'd999, 1'b0);  // remove 999
        read_bid(10'd510, q);
        check("clamp: qty@510 = 0",     q == 32'd0);
        check("clamp: mask@510 cleared",bid_mask[510] == 1'b0);

        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display(fail_count == 0 ? "  ALL TESTS PASSED" : "  THERE ARE FAILURES");
        $display("========================================");
        $finish;
    end

    initial begin
        $dumpfile("tb_book_update.vcd");
        $dumpvars(0, tb_book_update);
    end

endmodule
