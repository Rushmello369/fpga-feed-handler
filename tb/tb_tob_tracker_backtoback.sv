/*
 * tb_tob_tracker_backtoback
 * -------------------------
 * Regression test for a suspected bug: tob_tracker's original implementation
 * samples best_bid_addr/best_ask_addr LIVE (combinationally) at publish time
 * (upd_shift[3]), not the value latched when that update's read was launched.
 * If a SECOND book_updated pulse arrives within the ~4-cycle pipeline depth of
 * the first (exactly what event_dispatcher's Replace does: delete then insert,
 * ~4-5 cycles apart), the second update's address can overwrite the live
 * signal before the first update's snapshot is published, corrupting it
 * (idx from update #2, qty from update #1's stale read) - this was NEVER
 * exercised by the original tb_tob_tracker.sv (which used generously spaced,
 * single, isolated pulses) or by tb_event_dispatcher (which checks book state
 * directly, bypassing tob_tracker entirely).
 *
 * Test: fire TWO book_updated pulses 4 cycles apart (book_update's minimum
 * possible spacing), each with DIFFERENT bid/ask addresses and DIFFERENT
 * memory contents, and check BOTH published snapshots are internally
 * self-consistent (idx and qty both belong to the SAME update).
 */
`timescale 1ns/1ps

module tb_tob_tracker_backtoback;
    import ITCH50_pkg::*;

    localparam int WINDOW_SIZE = 2048;
    localparam int ADDR_W      = $clog2(WINDOW_SIZE);

    logic                  clk = 0, arstn = 0;
    logic                  book_updated = 0;
    logic [ADDR_W-1:0]     best_bid_addr = 0, best_ask_addr = 0;
    logic                  best_bid_valid = 0, best_ask_valid = 0;
    logic [ADDR_W-1:0]     bid_rd_addr, ask_rd_addr;
    logic [31:0]           bid_rd_data, ask_rd_data;
    logic [31:0]           bid_rd_data_in;
    tob_t                  tob;
    logic                  tob_valid;

    int pass_count = 0, fail_count = 0;

    tob_tracker #(.WINDOW_SIZE(WINDOW_SIZE)) dut (
        .clk(clk), .arstn(arstn),
        .book_updated(book_updated),
        .best_bid_addr(best_bid_addr), .best_bid_valid(best_bid_valid),
        .best_ask_addr(best_ask_addr), .best_ask_valid(best_ask_valid),
        .bid_rd_addr(bid_rd_addr), .bid_rd_data_in(bid_rd_data_in),
        .bid_rd_data(bid_rd_data),
        .ask_rd_addr(ask_rd_addr), .ask_rd_data(ask_rd_data),
        .tob(tob), .tob_valid(tob_valid)
    );

    always #5 clk = ~clk;
    initial begin #100000; $error("[TIMEOUT] sim stuck"); $finish; end

    // model book_update's registered read port (1-cycle latency)
    logic [31:0] bid_mem [WINDOW_SIZE];
    logic [31:0] ask_mem [WINDOW_SIZE];
    always_ff @(posedge clk) begin
        bid_rd_data <= bid_mem[bid_rd_addr];
        ask_rd_data <= ask_mem[ask_rd_addr];
    end

    task automatic check(input string desc, input logic cond);
        if (cond) begin pass_count++; $display("[PASS] %s", desc); end
        else      begin fail_count++; $error("[FAIL] %s", desc); end
    endtask

    // captured snapshots (one per tob_valid pulse observed)
    tob_t captured [$];
    always @(posedge clk) if (arstn && tob_valid) captured.push_back(tob);

    initial begin
        for (int i = 0; i < WINDOW_SIZE; i++) begin
            bid_mem[i] = 0; ask_mem[i] = 0;
        end
        // update #1's level: bid=500 qty=300, ask=502 qty=200
        bid_mem[500] = 32'd300;  ask_mem[502] = 32'd200;
        // update #2's level: bid=510 qty=400, ask=505 qty=150 (all DIFFERENT
        // from update #1, so a mixed idx/qty snapshot is unambiguously wrong)
        bid_mem[510] = 32'd400;  ask_mem[505] = 32'd150;

        repeat (4) @(posedge clk);
        arstn = 1;
        repeat (2) @(posedge clk);

        // ---- fire update #1 ----
        @(negedge clk);
        best_bid_addr = 11'd500; best_bid_valid = 1'b1;
        best_ask_addr = 11'd502; best_ask_valid = 1'b1;
        book_updated  = 1'b1;
        @(negedge clk);
        book_updated  = 1'b0;

        // ---- 4 cycles later (book_update's minimum realistic spacing,
        //      matching a Replace's delete-then-insert), fire update #2 with
        //      DIFFERENT addresses/quantities ----
        repeat (3) @(negedge clk);
        best_bid_addr = 11'd510; best_bid_valid = 1'b1;
        best_ask_addr = 11'd505; best_ask_valid = 1'b1;
        book_updated  = 1'b1;
        @(negedge clk);
        book_updated  = 1'b0;

        // drain
        repeat (15) @(posedge clk);

        $display("captured %0d snapshots", captured.size());
        for (int i = 0; i < captured.size(); i++)
            $display("  snap %0d: bid_idx=%0d bid_qty=%0d ask_idx=%0d ask_qty=%0d",
                     i, captured[i].bid_idx, captured[i].bid_qty,
                     captured[i].ask_idx, captured[i].ask_qty);

        check("exactly 2 snapshots published", captured.size() == 2);

        if (captured.size() >= 1) begin
            check("snap0: bid_idx=500 (update #1's own address)",
                  captured[0].bid_idx == 16'd500);
            check("snap0: bid_qty=300 (matches bid_idx=500, NOT update #2's 400)",
                  captured[0].bid_qty == 32'd300);
            check("snap0: ask_idx=502", captured[0].ask_idx == 16'd502);
            check("snap0: ask_qty=200 (matches ask_idx=502, NOT update #2's 150)",
                  captured[0].ask_qty == 32'd200);
        end
        if (captured.size() >= 2) begin
            check("snap1: bid_idx=510 (update #2's own address)",
                  captured[1].bid_idx == 16'd510);
            check("snap1: bid_qty=400 (matches bid_idx=510, NOT update #1's 300)",
                  captured[1].bid_qty == 32'd400);
            check("snap1: ask_idx=505", captured[1].ask_idx == 16'd505);
            check("snap1: ask_qty=150 (matches ask_idx=505, NOT update #1's 200)",
                  captured[1].ask_qty == 32'd150);
        end

        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display(fail_count == 0 ? "  ALL TESTS PASSED" : "  THERE ARE FAILURES");
        $display("========================================");
        $finish;
    end
endmodule
