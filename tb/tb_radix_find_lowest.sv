/*
Testbench for radix_find_lowest

Test cases:
    all zeros        - valid must be 0; no phantom address on an empty book
    bit 0            - basic sanity, lowest possible address
    bit 5            - basic sanity, arbitrary address inside group 0
    bit 31           - last bit of group 0; group index still 0
    bit 32           - first bit of group 1; ONLY test that catches a swapped
                       {grp_sel, local_addr} concat (grp 0 tests hide it)
    bit 33           - group 1 with nonzero local offset
    bit 992          - first bit of group 31; top group boundary
    bit 1023         - last bit; catches off-by-one / narrow signal truncation
    bits 5,100       - must return 5: proves it picks the LOWEST, not just any
    bits 32,33       - must return 32: correct priority WITHIN a group
    bits 31,32       - must return 31: correct priority ACROSS a group boundary
    bits 0,1023      - must return 0: extreme spread
    all ones         - must return 0: every bit set, lowest still wins
    all zeros again  - valid must drop back to 0; catches a sticky valid flag
*/
`timescale 1ns/1ps

module tb_radix_find_lowest;

    // ---------------- signals ----------------
    logic          clk;
    logic          arstn;
    logic [1023:0] vec;
    logic [9:0]    addr;
    logic          valid;

    int            pass_count = 0;
    int            fail_count = 0;

    // ---------------- clock: 100 MHz (10ns period) ----------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- DUT ----------------
    radix_find_lowest dut (
        .clk   (clk),
        .arstn (arstn),
        .vec   (vec),
        .addr  (addr),
        .valid (valid)
    );

    // ---------------- self-checking task ----------------
    task automatic check (
        input logic [1023:0] stim,
        input logic [9:0]    exp_addr,
        input logic          exp_valid,
        input string         name
    );
        @(negedge clk);
        vec = stim;

        repeat (2) @(posedge clk);   // wait out the 2 pipeline stages
        #1;                          // let outputs settle

        if (valid !== exp_valid) begin
            $error("[FAIL] %s : valid = %0b, expected %0b", name, valid, exp_valid);
            fail_count++;
        end
        else if (exp_valid && (addr !== exp_addr)) begin
            $error("[FAIL] %s : addr = %0d, expected %0d", name, addr, exp_addr);
            fail_count++;
        end
        else begin
            $display("[PASS] %s : addr = %0d, valid = %0b", name, addr, valid);
            pass_count++;
        end
    endtask

    // ---------------- stimulus ----------------
    initial begin
        arstn = 1'b0;
        vec   = '0;
        repeat (3) @(posedge clk);
        arstn = 1'b1;
        @(posedge clk);

        // --- empty ---
        check(1024'b0,                    10'd0,    1'b0, "all zeros");

        // --- single bit, within group 0 ---
        check(1024'b1 << 0,               10'd0,    1'b1, "bit 0");
        check(1024'b1 << 5,               10'd5,    1'b1, "bit 5");
        check(1024'b1 << 31,              10'd31,   1'b1, "bit 31 (last of grp 0)");

        // --- group boundary: the highest-value test ---
        check(1024'b1 << 32,              10'd32,   1'b1, "bit 32 (first of grp 1)");
        check(1024'b1 << 33,              10'd33,   1'b1, "bit 33");

        // --- top of range ---
        check(1024'b1 << 992,             10'd992,  1'b1, "bit 992 (first of grp 31)");
        check(1024'b1 << 1023,            10'd1023, 1'b1, "bit 1023 (last bit)");

        // --- multiple bits: must pick the LOWEST ---
        check((1024'b1 << 5)  | (1024'b1 << 100),  10'd5,  1'b1, "bits 5,100 -> 5");
        check((1024'b1 << 32) | (1024'b1 << 33),   10'd32, 1'b1, "bits 32,33 -> 32 (within grp)");
        check((1024'b1 << 31) | (1024'b1 << 32),   10'd31, 1'b1, "bits 31,32 -> 31 (across grp)");
        check((1024'b1 << 0)  | (1024'b1 << 1023), 10'd0,  1'b1, "bits 0,1023 -> 0");
        check({1024{1'b1}},                        10'd0,  1'b1, "all ones -> 0");

        // --- back to empty, confirm valid drops ---
        check(1024'b0,                    10'd0,    1'b0, "all zeros again");

        // ---------------- summary ----------------
        $display("");
        $display("========================================");
        $display("  PASSED: %0d    FAILED: %0d", pass_count, fail_count);
        $display("========================================");

        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  THERE ARE FAILURES");

        $finish;
    end

    // ---------------- waveform dump ----------------
    initial begin
        $dumpfile("tb_radix_find_lowest.vcd");
        $dumpvars(0, tb_radix_find_lowest);
    end

endmodule