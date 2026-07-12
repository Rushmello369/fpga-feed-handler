/*
 * tb_uart_to_axis
 * ---------------
 * Bit-level test of the UART -> AXI-Stream input adapter. Drives the serial rx
 * line with 8-N-1 frames and checks the bytes appear, in order, on the stream.
 * Uses a tiny CLKS_PER_BIT so the sim is fast.
 *
 * Covers:
 *   - three bytes received in order, LSB-first framing correct
 *   - backpressure: a byte received while m_tready=0 is buffered in the FIFO
 *     and delivered once m_tready rises (no loss), overflow stays 0
 */
`timescale 1ns/1ps

module tb_uart_to_axis;
    localparam int CPB = 8;          // clocks per bit (fast for sim)

    logic       clk = 0, arstn = 0;
    logic       rx = 1'b1;           // idle high
    logic [7:0] m_tdata;
    logic       m_tvalid;
    logic       m_tready = 1'b1;
    logic       overflow;

    int pass_count = 0, fail_count = 0;

    // captured bytes
    logic [7:0] rxq [$];

    uart_to_axis #(.CLKS_PER_BIT(CPB), .FIFO_AW(4)) dut (
        .clk(clk), .arstn(arstn), .rx(rx),
        .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready),
        .overflow(overflow)
    );

    always #5 clk = ~clk;
    initial begin #100000; $error("[TIMEOUT]"); $finish; end

    // collect bytes off the stream
    always @(posedge clk)
        if (arstn && m_tvalid && m_tready)
            rxq.push_back(m_tdata);

    // drive one 8-N-1 byte on rx, LSB first
    task automatic uart_send(input logic [7:0] b);
        rx = 1'b0;                                 // start
        repeat (CPB) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            rx = b[i];
            repeat (CPB) @(posedge clk);
        end
        rx = 1'b1;                                 // stop
        repeat (CPB) @(posedge clk);
        repeat (2) @(posedge clk);                 // inter-byte idle
    endtask

    task automatic check(input string d, input logic c);
        if (c) begin pass_count++; $display("[PASS] %s", d); end
        else   begin fail_count++; $error("[FAIL] %s", d); end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        arstn = 1;
        repeat (2) @(posedge clk);

        // --- three bytes, ready held high ---
        uart_send(8'hA5);
        uart_send(8'h3C);
        uart_send(8'hFF);
        repeat (CPB*4) @(posedge clk);

        check("received 3 bytes", rxq.size() == 3);
        check("byte0 = A5", rxq.size() > 0 && rxq[0] == 8'hA5);
        check("byte1 = 3C", rxq.size() > 1 && rxq[1] == 8'h3C);
        check("byte2 = FF", rxq.size() > 2 && rxq[2] == 8'hFF);

        // --- backpressure: receive with ready LOW, then release ---
        rxq.delete();
        m_tready = 1'b0;
        uart_send(8'h5A);                          // arrives into FIFO, not drained
        repeat (CPB*2) @(posedge clk);
        check("held: nothing drained yet", rxq.size() == 0);
        m_tready = 1'b1;                           // release
        repeat (CPB*2) @(posedge clk);
        check("released: byte delivered", rxq.size() == 1 && rxq[0] == 8'h5A);
        check("no FIFO overflow", overflow == 1'b0);

        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display(fail_count == 0 ? "  ALL TESTS PASSED" : "  THERE ARE FAILURES");
        $display("========================================");
        $finish;
    end

    initial begin
        $dumpfile("tb_uart_to_axis.vcd");
        $dumpvars(0, tb_uart_to_axis);
    end
endmodule
