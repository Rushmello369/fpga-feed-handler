/*
 * tb_top_v2_smoke
 * ---------------
 * End-to-end smoke test: feeds spec-accurate framed ITCH messages (2-byte
 * big-endian length prefix + body) into the byte-stream input and checks
 * feature frames emerge from the board link.
 *
 * Scenario (BASE_PRICE=1,550,000, so $160.00 -> level index 500):
 *   1. Add BUY  oid=100, 300 shares @ $160.00  (bid side only -> no frame,
 *      tob_tracker requires both sides valid)
 *   2. Add SELL oid=200, 200 shares @ $160.02  (both sides now live ->
 *      FRAME 1: spr=2 ticks, tobi=300-200=+100, mid seeded)
 *   3. Exec 'E' oid=100, 50 shares             (resting buy hit ->
 *      FRAME 2: tobi=250-200=+50, ofi=-50, tflow=-50 aggressive sell)
 *
 * This is an INTEGRATION smoke test - it proves the plumbing (parser ->
 * dispatcher -> lookup -> book -> encoder -> tob -> features -> link)
 * carries a message end to end with sane values. It is NOT a substitute
 * for per-module testbenches with edge-case coverage.
 */

`timescale 1ns/1ps

module tb_top_v2_smoke;
    import ITCH50_pkg::*;

    localparam int CLK_PERIOD = 10;

    logic        clk = 0, arstn = 0;
    logic        s_tvalid = 0;
    logic [7:0]  s_tdata  = 0;
    logic        s_tready;
    logic        tx_valid;
    logic [7:0]  tx_data;
    logic        tx_ready = 1;
    logic        parse_error;
    logic [31:0] unknown_count, msg_count, miss_count, oow_count, drop_count;

    int frames_seen = 0;
    int byte_in_frame = 0;
    logic [7:0] rx_frame [15];
    int pass_count = 0, fail_count = 0;

    // shared message-build buffer (declared before the tasks that use it;
    // xsim requires declaration-before-use for module-scope variables)
    logic [7:0] msg_buf [0:63];

    top_v2 #(
        .BASE_PRICE (1_550_000),
        .WINDOW_SIZE(2048),
        .QTY_SHIFT  (0),
        .TABLE_BITS (8)
    ) dut (
        .clk(clk), .arstn(arstn),
        .s_tvalid(s_tvalid), .s_tdata(s_tdata), .s_tready(s_tready),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .parse_error(parse_error),
        .unknown_count(unknown_count), .msg_count(msg_count),
        .miss_count(miss_count), .oow_count(oow_count),
        .drop_count(drop_count)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- byte-stream driver: sends one byte respecting s_tready ----
    task automatic send_byte(input logic [7:0] b);
        @(posedge clk);
        while (!s_tready) @(posedge clk);
        s_tvalid <= 1'b1;
        s_tdata  <= b;
        @(posedge clk);
        s_tvalid <= 1'b0;
    endtask

    // sends msg_buf[0..n-1] as a framed message: 2-byte BE length prefix + body
    task automatic send_msg(input int unsigned n);
        send_byte(n[15:8]);
        send_byte(n[7:0]);
        for (int i = 0; i < n; i++) send_byte(msg_buf[i]);
    endtask

    // ---- message builders (spec-accurate field offsets) ----
    // iverilog does not allow output ports on functions, so builders are
    // tasks writing into the shared module-scope buffer declared above.

    // Add Order 'A' (36B): type,locate(2),track(2),ts(6),oid(8),side(1),
    //                      shares(4),stock(8),price(4)
    task automatic build_add(
        input logic [63:0] oid, input logic [7:0] side,
        input logic [31:0] shares, input logic [31:0] price);
        msg_buf[0] = MSG_TYPE_ADD;
        msg_buf[1] = 8'h00; msg_buf[2] = 8'h01;               // stock_locate = 1
        for (int i = 3;  i <= 10; i++) msg_buf[i] = 8'h00;    // tracking + ts
        for (int i = 0;  i <  8;  i++) msg_buf[11+i] = oid[8*(7-i) +: 8];  // BE
        msg_buf[19] = side;
        for (int i = 0;  i <  4;  i++) msg_buf[20+i] = shares[8*(3-i) +: 8];
        for (int i = 24; i <= 31; i++) msg_buf[i] = " ";      // stock symbol
        for (int i = 0;  i <  4;  i++) msg_buf[32+i] = price[8*(3-i) +: 8];
    endtask

    // Order Executed 'E' (31B): type,locate(2),track(2),ts(6),oid(8),
    //                           exec_shares(4),match(8)
    task automatic build_exec(
        input logic [63:0] oid, input logic [31:0] shares);
        msg_buf[0] = MSG_TYPE_EXEC;
        msg_buf[1] = 8'h00; msg_buf[2] = 8'h01;
        for (int i = 3; i <= 10; i++) msg_buf[i] = 8'h00;
        for (int i = 0; i <  8;  i++) msg_buf[11+i] = oid[8*(7-i) +: 8];
        for (int i = 0; i <  4;  i++) msg_buf[19+i] = shares[8*(3-i) +: 8];
        for (int i = 23; i <= 30; i++) msg_buf[i] = 8'h00;    // match number
    endtask

    // ---- frame collector: reassembles 15-byte link frames ----
    function automatic logic signed [15:0] f16(input int hi);
        return $signed({rx_frame[hi], rx_frame[hi+1]});
    endfunction

    task automatic check(input string desc, input logic cond);
        if (cond) begin pass_count++; $display("[PASS] %s", desc); end
        else      begin fail_count++; $display("[FAIL] %s", desc); end
    endtask

    always @(posedge clk) begin
        if (tx_valid && tx_ready) begin
            rx_frame[byte_in_frame] = tx_data;
            if (byte_in_frame == 14) begin
                byte_in_frame = 0;
                frames_seen++;
                $display("FRAME %0d: sync=%02h seq=%0d spr=%0d tobi=%0d ofi=%0d emadev=%0d mom=%0d tflow=%0d",
                    frames_seen, rx_frame[0], rx_frame[1],
                    f16(2), f16(4), f16(6), f16(8), f16(10), f16(12));

                if (frames_seen == 1) begin
                    check("frame1 sync byte",        rx_frame[0] == 8'hA5);
                    check("frame1 spread = 2 ticks", f16(2) == 16'sd2);
                    check("frame1 tobi = +100",      f16(4) == 16'sd100);
                    check("frame1 tflow = 0",        f16(12) == 16'sd0);
                end
                if (frames_seen == 2) begin
                    check("frame2 tobi = +50 (bid 250 vs ask 200)", f16(4) == 16'sd50);
                    check("frame2 ofi = -50",                       f16(6) == -16'sd50);
                    check("frame2 tflow = -50 (aggr sell)",         f16(12) == -16'sd50);
                    check("no parser errors",   unknown_count == 0);
                    check("no lookup misses",   miss_count == 0);
                    check("no OOW drops",       oow_count == 0);
                end
            end else begin
                byte_in_frame++;
            end
        end
    end

    // ---- stimulus ----
    initial begin
        repeat (5) @(posedge clk);
        arstn = 1;
        repeat (2) @(posedge clk);

        // 1) Add BUY 300 @ $160.00 (price word 1,600,000)
        build_add(64'd100, MSG_SIDE_BUY, 32'd300, 32'd1_600_000);
        send_msg(36);

        // 2) Add SELL 200 @ $160.02 (price word 1,600,200) -> FRAME 1
        build_add(64'd200, MSG_SIDE_SELL, 32'd200, 32'd1_600_200);
        send_msg(36);

        // 3) Execute 50 shares of oid=100 -> FRAME 2
        build_exec(64'd100, 32'd50);
        send_msg(31);

        // drain
        repeat (200) @(posedge clk);

        $display("========================================");
        $display("  FRAMES: %0d   PASSED: %0d   FAILED: %0d",
                 frames_seen, pass_count, fail_count);
        if (frames_seen == 2 && fail_count == 0)
            $display("  SMOKE TEST PASSED");
        else
            $display("  SMOKE TEST FAILED");
        $display("========================================");
        $finish;
    end

endmodule