/*
 * tb_feature_engine
 * -----------------
 * Unit test for feature_engine. Drives tob snapshots + trade-tap pulses and
 * checks all six features. Expected values were computed by an independent
 * Python reference (src/itch_tools.py Golden math) so a match cross-validates
 * RTL and the software model.
 *
 * Phase A: SPR / TOBI / OFI / EMADEV / MOM basics + a saturation snapshot
 *          (TOBI and OFI clamp to +32767, EMADEV to a large negative).
 * Phase B: (after reset) TFLOW 16-entry ring wraparound - 16 unit trades then
 *          a 17th large trade must EVICT the oldest, proving the ring buffer.
 *
 * Timing: feat_valid pulses the cycle after tob_valid; trade updates the flow
 * accumulator one cycle after trade_valid. Stimulus is spaced so each event
 * fully commits before the next (negedge driving/sampling).
 */
`timescale 1ns/1ps

module tb_feature_engine;
    import ITCH50_pkg::*;

    logic clk = 0, arstn = 0;
    logic tob_valid = 0;
    tob_t tob = '0;
    logic trade_valid = 0, trade_side = 0;
    logic [31:0] trade_qty = 0;
    logic feat_valid;
    logic signed [15:0] f_spr, f_tobi, f_ofi, f_emadev, f_mom, f_tflow;

    int pass_count = 0, fail_count = 0;

    feature_engine #(.QTY_SHIFT(0)) dut (
        .clk(clk), .arstn(arstn),
        .tob_valid(tob_valid), .tob(tob),
        .trade_valid(trade_valid), .trade_side(trade_side), .trade_qty(trade_qty),
        .feat_valid(feat_valid),
        .f_spr(f_spr), .f_tobi(f_tobi), .f_ofi(f_ofi),
        .f_emadev(f_emadev), .f_mom(f_mom), .f_tflow(f_tflow)
    );

    always #5 clk = ~clk;
    initial begin #100000; $error("[TIMEOUT]"); $finish; end

    // drive a tob snapshot, wait for the frame, check all six features
    task automatic snap_check(
        input logic [15:0] bi, input logic [31:0] bq,
        input logic [15:0] ai, input logic [31:0] aq,
        input logic signed [15:0] e_spr, e_tobi, e_ofi, e_emadev, e_mom, e_tflow,
        input string name);
        @(negedge clk);
        tob.bid_idx = bi; tob.bid_qty = bq; tob.ask_idx = ai; tob.ask_qty = aq;
        tob_valid = 1'b1;
        @(negedge clk);
        tob_valid = 1'b0;
        while (!feat_valid) @(negedge clk);
        check_eq(name, "spr",    f_spr,    e_spr);
        check_eq(name, "tobi",   f_tobi,   e_tobi);
        check_eq(name, "ofi",    f_ofi,    e_ofi);
        check_eq(name, "emadev", f_emadev, e_emadev);
        check_eq(name, "mom",    f_mom,    e_mom);
        check_eq(name, "tflow",  f_tflow,  e_tflow);
        @(negedge clk);
    endtask

    task automatic do_trade(input logic side, input logic [31:0] qty);
        @(negedge clk);
        trade_side = side; trade_qty = qty; trade_valid = 1'b1;
        @(negedge clk);
        trade_valid = 1'b0;
        @(negedge clk);            // let the accumulator commit
    endtask

    task automatic check_eq(input string nm, input string fld,
                            input logic signed [15:0] got, exp);
        if (got === exp) begin
            pass_count++;
        end else begin
            fail_count++;
            $error("[FAIL] %s.%s : got %0d, expected %0d", nm, fld, got, exp);
        end
    endtask

    task automatic reset_dut();
        arstn = 1'b0;
        tob_valid = 0; trade_valid = 0;
        repeat (3) @(posedge clk);
        arstn = 1'b1;
        repeat (2) @(posedge clk);
    endtask

    initial begin
        // ================= Phase A =================
        reset_dut();
        //          bid_idx bid_qty ask_idx ask_qty  spr  tobi   ofi emadev  mom tflow
        snap_check(16'd500, 32'd300, 16'd502, 32'd200,
                   16'sd2, 16'sd100, 16'sd100, 16'sd0, 16'sd1002, 16'sd0, "A0");
        do_trade(1'b1, 32'd40);                             // aggressive buy +40
        snap_check(16'd500, 32'd250, 16'd502, 32'd200,
                   16'sd2, 16'sd50, -16'sd50, 16'sd0, 16'sd1002, 16'sd40, "A1");
        snap_check(16'd501, 32'd100, 16'd504, 32'd150,
                   16'sd3, -16'sd50, -16'sd100, 16'sd3, 16'sd1005, 16'sd40, "A2");
        do_trade(1'b0, 32'd30);                             // aggressive sell -30
        snap_check(16'd501, 32'd100, 16'd504, 32'd150,
                   16'sd3, -16'sd50, 16'sd0, 16'sd3, 16'sd1005, 16'sd10, "A3");
        // saturation: bidq-askq = 100000 -> clamp 32767; emadev large negative
        snap_check(16'd0, 32'd100000, 16'd1, 32'd0,
                   16'sd1, 16'sd32767, 16'sd32767, -16'sd1001, 16'sd1, 16'sd10, "A4");

        // ================= Phase B: TFLOW ring wraparound =================
        reset_dut();
        for (int i = 0; i < 16; i++) do_trade(1'b1, 32'd1);  // fill ring with +1
        snap_check(16'd100, 32'd10, 16'd102, 32'd10,
                   16'sd2, 16'sd0, 16'sd0, 16'sd0, 16'sd202, 16'sd16, "B0");
        do_trade(1'b1, 32'd100);                             // 17th: evicts a +1
        snap_check(16'd100, 32'd10, 16'd102, 32'd10,
                   16'sd2, 16'sd0, 16'sd0, 16'sd0, 16'sd202, 16'sd115, "B1");

        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display(fail_count == 0 ? "  ALL TESTS PASSED" : "  THERE ARE FAILURES");
        $display("========================================");
        $finish;
    end

    initial begin
        $dumpfile("tb_feature_engine.vcd");
        $dumpvars(0, tb_feature_engine);
    end
endmodule
