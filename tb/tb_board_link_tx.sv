/*
 * tb_board_link_tx
 * ----------------
 * Unit test for board_link_tx: packs a feature vector into a 15-byte frame
 *   [A5][seq][spr..tflow big-endian, 6x int16][XOR checksum]
 * and serializes it with a tx_valid/tx_ready handshake.
 *
 * Covers:
 *   - frame 0: sync/seq/all six BE fields/checksum exact
 *   - frame 1: seq increments, negative fields packed correctly
 *   - drop-oldest: two vectors arriving mid-send bump drop_count and the
 *     LATEST one wins the next frame
 *   - backpressure: dropping tx_ready mid-frame loses no bytes
 */
`timescale 1ns/1ps

module tb_board_link_tx;
    logic clk = 0, arstn = 0;
    logic               feat_valid = 0;
    logic signed [15:0] f_spr=0, f_tobi=0, f_ofi=0, f_emadev=0, f_mom=0, f_tflow=0;
    logic               tx_valid;
    logic [7:0]         tx_data;
    logic               tx_ready = 1;
    logic [31:0]        drop_count;

    int pass_count = 0, fail_count = 0;
    logic [7:0] rxq [$];

    board_link_tx dut (
        .clk(clk), .arstn(arstn),
        .feat_valid(feat_valid),
        .f_spr(f_spr), .f_tobi(f_tobi), .f_ofi(f_ofi),
        .f_emadev(f_emadev), .f_mom(f_mom), .f_tflow(f_tflow),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .drop_count(drop_count)
    );

    always #5 clk = ~clk;
    initial begin #200000; $error("[TIMEOUT]"); $finish; end

    // collect accepted bytes
    always @(posedge clk)
        if (arstn && tx_valid && tx_ready) rxq.push_back(tx_data);

    task automatic drive_feat(input logic signed [15:0] spr, tobi, ofi,
                              emadev, mom, tflow);
        @(negedge clk);
        f_spr=spr; f_tobi=tobi; f_ofi=ofi; f_emadev=emadev; f_mom=mom; f_tflow=tflow;
        feat_valid = 1'b1;
        @(negedge clk);
        feat_valid = 1'b0;
    endtask

    task automatic check(input string d, input logic c);
        if (c) begin pass_count++; $display("[PASS] %s", d); end
        else   begin fail_count++; $error("[FAIL] %s", d); end
    endtask

    function automatic logic signed [15:0] g16(input int base_i);
        return $signed({rxq[base_i], rxq[base_i+1]});
    endfunction

    // verify a 15-byte frame beginning at index `o`
    task automatic verify_frame(input int o, input logic [7:0] exp_seq,
                                input logic signed [15:0] spr, tobi, ofi,
                                emadev, mom, tflow, input string nm);
        logic [7:0] chk;
        chk = 0;
        for (int i = 0; i < 14; i++) chk ^= rxq[o+i];
        check({nm, " sync=A5"}, rxq[o]   == 8'hA5);
        check({nm, " seq"},     rxq[o+1] == exp_seq);
        check({nm, " spr"},     g16(o+2)  == spr);
        check({nm, " tobi"},    g16(o+4)  == tobi);
        check({nm, " ofi"},     g16(o+6)  == ofi);
        check({nm, " emadev"},  g16(o+8)  == emadev);
        check({nm, " mom"},     g16(o+10) == mom);
        check({nm, " tflow"},   g16(o+12) == tflow);
        check({nm, " checksum"},rxq[o+14] == chk);
    endtask

    initial begin
        arstn = 0; repeat (3) @(posedge clk); arstn = 1; repeat (2) @(posedge clk);

        // ---- frame 0 ----
        drive_feat(16'sd2, 16'sd100, -16'sd50, 16'sd7, -16'sd1000, 16'sd300);
        wait (rxq.size() >= 15);
        verify_frame(0, 8'd0, 16'sd2, 16'sd100, -16'sd50, 16'sd7, -16'sd1000,
                     16'sd300, "f0");

        // ---- frame 1: new values, seq must increment ----
        drive_feat(-16'sd3, 16'sd0, 16'sd12345, -16'sd8, 16'sd1, -16'sd32768);
        wait (rxq.size() >= 30);
        verify_frame(15, 8'd1, -16'sd3, 16'sd0, 16'sd12345, -16'sd8, 16'sd1,
                     -16'sd32768, "f1");

        // ---- drop-oldest: two vectors arrive while a frame is in flight ----
        rxq.delete();
        drive_feat(16'sd10, 16'sd10, 16'sd10, 16'sd10, 16'sd10, 16'sd10); // starts sending
        repeat (4) @(posedge clk);                     // mid-frame
        drive_feat(16'sd20, 16'sd20, 16'sd20, 16'sd20, 16'sd20, 16'sd20); // dropped
        drive_feat(16'sd33, 16'sd33, 16'sd33, 16'sd33, 16'sd33, 16'sd33); // latest wins
        wait (rxq.size() >= 30);                        // first frame + replacement
        check("drop-oldest: drop_count=2", drop_count == 32'd2);
        // second frame carries the LATEST vector (33s), seq=3
        verify_frame(15, 8'd3, 16'sd33, 16'sd33, 16'sd33, 16'sd33, 16'sd33,
                     16'sd33, "drop");

        // ---- backpressure: stall tx_ready mid-frame, no byte lost ----
        rxq.delete();
        drive_feat(16'sd1, 16'sd2, 16'sd3, 16'sd4, 16'sd5, 16'sd6);
        repeat (6) @(posedge clk);
        tx_ready = 0; repeat (20) @(posedge clk);       // stall
        check("backpressure: paused (<15 bytes)", rxq.size() < 15);
        tx_ready = 1;
        wait (rxq.size() >= 15);
        verify_frame(0, 8'd4, 16'sd1, 16'sd2, 16'sd3, 16'sd4, 16'sd5, 16'sd6, "bp");

        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display(fail_count == 0 ? "  ALL TESTS PASSED" : "  THERE ARE FAILURES");
        $display("========================================");
        $finish;
    end

    initial begin
        $dumpfile("tb_board_link_tx.vcd");
        $dumpvars(0, tb_board_link_tx);
    end
endmodule
