/*
 * tb_top_uart
 * -----------
 * End-to-end board-top test: drives framed ITCH messages into top_uart over a
 * real bit-level UART RX line, decodes the UART TX line back into 15-byte
 * feature frames, and checks the same values the tb_top_v2 smoke test proved.
 *
 * This exercises the COMPLETE PC-facing path:
 *   uart_rx -> fifo -> top_v2 (parser..features) -> board_link_tx -> uart_tx
 * plus the stock_locate filter (FILTER_EN=1, locate 1 matches the messages).
 */
`timescale 1ns/1ps

module tb_top_uart;
    localparam int CPB = 8;                 // clocks per bit (fast sim)

    logic clk = 0, arstn = 0;
    logic uart_rx_pin = 1'b1;               // PC -> FPGA (idle high)
    logic uart_tx_pin;                      // FPGA -> PC
    logic rx_overflow;

    int pass_count = 0, fail_count = 0;
    logic [7:0] outbytes [$];               // decoded UART TX bytes

    top_uart #(
        .CLK_FREQ_HZ (CPB),                 // with BAUD=1 -> CLKS_PER_BIT=CPB
        .BAUD        (1),
        .BASE_PRICE  (1_550_000),
        .WINDOW_SIZE (2048),
        .FILTER_EN   (1'b1),
        .FILTER_LOCATE (16'd1),
        .QTY_SHIFT   (0),
        .TABLE_BITS  (8)
    ) dut (
        .clk(clk), .arstn(arstn),
        .uart_rx_pin(uart_rx_pin), .uart_tx_pin(uart_tx_pin),
        .rx_overflow(rx_overflow)
    );

    always #5 clk = ~clk;
    initial begin #3000000; $error("[TIMEOUT]"); $finish; end

    // ---- UART TX line decoder (mirrors uart_rx), pushes bytes ----
    initial begin
        logic [7:0] b;
        @(posedge arstn);
        forever begin
            @(negedge uart_tx_pin);              // start bit
            repeat (CPB/2) @(posedge clk);       // center on start
            for (int i = 0; i < 8; i++) begin
                repeat (CPB) @(posedge clk);
                b[i] = uart_tx_pin;
            end
            repeat (CPB) @(posedge clk);         // stop
            outbytes.push_back(b);
        end
    end

    // ---- UART RX driver (PC side) ----
    task automatic uart_send_byte(input logic [7:0] b);
        uart_rx_pin = 1'b0;                      // start
        repeat (CPB) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            uart_rx_pin = b[i];
            repeat (CPB) @(posedge clk);
        end
        uart_rx_pin = 1'b1;                      // stop
        repeat (CPB*2) @(posedge clk);
    endtask

    logic [7:0] msg_buf [0:63];

    task automatic send_msg(input int unsigned n);
        uart_send_byte(n[15:8]);
        uart_send_byte(n[7:0]);
        for (int i = 0; i < n; i++) uart_send_byte(msg_buf[i]);
    endtask

    task automatic build_add(input logic [63:0] oid, input logic [7:0] side,
                             input logic [31:0] shares, input logic [31:0] price);
        for (int i = 0; i < 36; i++) msg_buf[i] = 8'h00;
        msg_buf[0] = "A";
        msg_buf[1] = 8'h00; msg_buf[2] = 8'h01;              // stock_locate = 1
        for (int i = 0; i < 8; i++) msg_buf[11+i] = oid[8*(7-i) +: 8];
        msg_buf[19] = side;
        for (int i = 0; i < 4; i++) msg_buf[20+i] = shares[8*(3-i) +: 8];
        for (int i = 24; i <= 31; i++) msg_buf[i] = " ";
        for (int i = 0; i < 4; i++) msg_buf[32+i] = price[8*(3-i) +: 8];
    endtask

    task automatic build_exec(input logic [63:0] oid, input logic [31:0] shares);
        for (int i = 0; i < 31; i++) msg_buf[i] = 8'h00;
        msg_buf[0] = "E";
        msg_buf[1] = 8'h00; msg_buf[2] = 8'h01;
        for (int i = 0; i < 8; i++) msg_buf[11+i] = oid[8*(7-i) +: 8];
        for (int i = 0; i < 4; i++) msg_buf[19+i] = shares[8*(3-i) +: 8];
    endtask

    task automatic check(input string d, input logic c);
        if (c) begin pass_count++; $display("[PASS] %s", d); end
        else   begin fail_count++; $error("[FAIL] %s", d); end
    endtask

    function automatic logic signed [15:0] f16(input int base_i);
        return $signed({outbytes[base_i], outbytes[base_i+1]});
    endfunction

    // find the index of the n-th 0xA5 sync byte that has a full 15-byte frame
    function automatic int frame_start(input int which);
        int seen = 0;
        for (int i = 0; i + 15 <= outbytes.size(); i++) begin
            if (outbytes[i] == 8'hA5) begin
                if (seen == which) return i;
                seen++;
            end
        end
        return -1;
    endfunction

    int f0, f1;

    initial begin
        repeat (4) @(posedge clk);
        arstn = 1;
        repeat (4) @(posedge clk);

        build_add(64'd100, "B", 32'd300, 32'd1_600_000); send_msg(36); // bid @160.00
        build_add(64'd200, "S", 32'd200, 32'd1_600_200); send_msg(36); // ask -> frame1
        build_exec(64'd100, 32'd50);                      send_msg(31); // exec -> frame2

        repeat (CPB*10*40) @(posedge clk);   // let frames flush out the UART TX

        $display("decoded %0d UART TX bytes", outbytes.size());
        f0 = frame_start(0);
        f1 = frame_start(1);
        check("frame 1 present", f0 >= 0);
        check("frame 2 present", f1 > f0);

        if (f0 >= 0) begin
            check("f1 sync=A5",       outbytes[f0]   == 8'hA5);
            check("f1 spr = 2 ticks", f16(f0+2) == 16'sd2);
            check("f1 tobi = +100",   f16(f0+4) == 16'sd100);
            check("f1 tflow = 0",     f16(f0+12) == 16'sd0);
        end
        if (f1 > f0 && f1 >= 0) begin
            check("f2 tobi = +50",    f16(f1+4)  == 16'sd50);
            check("f2 ofi  = -50",    f16(f1+6)  == -16'sd50);
            check("f2 tflow = -50",   f16(f1+12) == -16'sd50);
        end
        check("no FIFO overflow", rx_overflow == 1'b0);

        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display(fail_count == 0 ? "  ALL TESTS PASSED" : "  THERE ARE FAILURES");
        $display("========================================");
        $finish;
    end
endmodule
