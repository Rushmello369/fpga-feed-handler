/*
 * tb_status_reporter
 * ------------------
 * Checks the diagnostic status frame: that it fires only after the RX line
 * goes quiet, exactly once per burst, and carries the counter values
 * big-endian with a correct XOR checksum.
 *
 * Covers:
 *   - no frame while bytes are still arriving (must not fire mid-burst)
 *   - one frame after IDLE_CYCLES of quiet, 31 bytes, sync 0x5A
 *   - all seven counters decoded big-endian
 *   - checksum valid
 *   - does NOT fire a second time while the line stays quiet (one per burst)
 *   - re-arms: new bytes -> another quiet period -> a second frame, seq+1
 */
`timescale 1ns/1ps

module tb_status_reporter;
    localparam int IDLE_CYCLES = 50;      // tiny for simulation
    localparam int FRAME_LEN   = 31;

    logic clk = 0, arstn = 0;
    logic rx_byte_seen = 0;
    logic [31:0] msg_count = 0, unknown_count = 0, filtered_count = 0;
    logic [31:0] miss_count = 0, oow_count = 0, drop_count = 0, parse_err_count = 0;
    logic [7:0] m_tdata;
    logic       m_tvalid;
    logic       m_tready = 1;

    int pass_count = 0, fail_count = 0;
    logic [7:0] rxq [$];

    status_reporter #(.IDLE_CYCLES(IDLE_CYCLES)) dut (
        .clk(clk), .arstn(arstn),
        .rx_byte_seen(rx_byte_seen),
        .msg_count(msg_count), .unknown_count(unknown_count),
        .filtered_count(filtered_count), .miss_count(miss_count),
        .oow_count(oow_count), .drop_count(drop_count),
        .parse_err_count(parse_err_count),
        .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready)
    );

    always #5 clk = ~clk;
    initial begin #200000; $error("[TIMEOUT]"); $finish; end

    always @(posedge clk)
        if (arstn && m_tvalid && m_tready) rxq.push_back(m_tdata);

    task automatic check(input string d, input logic c);
        if (c) begin pass_count++; $display("[PASS] %s", d); end
        else   begin fail_count++; $error("[FAIL] %s", d); end
    endtask

    function automatic logic [31:0] be32(input int o);
        return {rxq[o], rxq[o+1], rxq[o+2], rxq[o+3]};
    endfunction

    task automatic pulse_rx(input int n);
        for (int i = 0; i < n; i++) begin
            @(negedge clk); rx_byte_seen = 1'b1;
            @(negedge clk); rx_byte_seen = 1'b0;
            repeat (3) @(negedge clk);          // gap shorter than IDLE_CYCLES
        end
    endtask

    logic [7:0] chk;

    initial begin
        repeat (3) @(posedge clk);
        arstn = 1;
        repeat (2) @(posedge clk);

        // load distinctive counter values (all different, byte-pattern rich)
        msg_count       = 32'h0000_1234;
        unknown_count   = 32'h0000_0007;
        filtered_count  = 32'h00AB_CDEF;
        miss_count      = 32'h0000_0008;
        oow_count       = 32'h0000_00E5;
        drop_count      = 32'h0000_0000;
        parse_err_count = 32'h1234_5678;

        // ---- burst in progress: must NOT emit ----
        pulse_rx(5);
        check("no frame mid-burst", rxq.size() == 0);

        // ---- go quiet: one frame should appear ----
        repeat (IDLE_CYCLES + FRAME_LEN + 20) @(posedge clk);
        check("frame emitted after idle", rxq.size() == FRAME_LEN);

        if (rxq.size() >= FRAME_LEN) begin
            check("sync = 0x5A",        rxq[0] == 8'h5A);
            check("seq = 0",            rxq[1] == 8'd0);
            check("msg_count",          be32(2)  == 32'h0000_1234);
            check("unknown_count",      be32(6)  == 32'h0000_0007);
            check("filtered_count",     be32(10) == 32'h00AB_CDEF);
            check("miss_count",         be32(14) == 32'h0000_0008);
            check("oow_count",          be32(18) == 32'h0000_00E5);
            check("drop_count",         be32(22) == 32'h0000_0000);
            check("parse_err_count",    be32(26) == 32'h1234_5678);
            chk = 0;
            for (int i = 0; i < FRAME_LEN-1; i++) chk ^= rxq[i];
            check("checksum", rxq[FRAME_LEN-1] == chk);
        end

        // ---- still quiet: must NOT emit a second frame ----
        repeat (IDLE_CYCLES * 3) @(posedge clk);
        check("no repeat while still idle", rxq.size() == FRAME_LEN);

        // ---- new burst re-arms it ----
        rxq.delete();
        miss_count = 32'h0000_0009;          // counters moved on
        pulse_rx(3);
        repeat (IDLE_CYCLES + FRAME_LEN + 20) @(posedge clk);
        check("second frame after new burst", rxq.size() == FRAME_LEN);
        if (rxq.size() >= FRAME_LEN) begin
            check("seq incremented to 1", rxq[1] == 8'd1);
            check("updated miss_count",   be32(14) == 32'h0000_0009);
        end

        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display(fail_count == 0 ? "  ALL TESTS PASSED" : "  THERE ARE FAILURES");
        $display("========================================");
        $finish;
    end
endmodule
