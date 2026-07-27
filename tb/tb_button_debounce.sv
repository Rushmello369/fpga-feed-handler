/*
 * tb_button_debounce
 * ------------------
 * Verifies the reset button filter: bouncing contacts must produce exactly ONE
 * clean press (not dozens of resets), and short glitches must be rejected
 * entirely.
 *
 * Covers:
 *   - idle high (not pressed) -> pressed = 0
 *   - bouncy press: rapid 0/1 chatter then settle low -> exactly one 0->1 edge
 *   - held press stays asserted
 *   - bouncy release -> exactly one 1->0 edge
 *   - glitch shorter than STABLE_CYCLES is completely ignored
 */
`timescale 1ns/1ps

module tb_button_debounce;
    localparam int STABLE = 20;        // tiny for simulation

    logic clk = 0;
    logic btn_raw_n = 1'b1;            // idle high = not pressed
    logic pressed;

    int pass_count = 0, fail_count = 0;
    int rise_edges = 0, fall_edges = 0;
    logic prev_pressed = 1'b0;

    button_debounce #(.STABLE_CYCLES(STABLE)) dut (
        .clk(clk), .btn_raw_n(btn_raw_n), .pressed(pressed)
    );

    always #5 clk = ~clk;
    initial begin #100000; $error("[TIMEOUT]"); $finish; end

    // count transitions of the debounced output
    always @(posedge clk) begin
        if (pressed && !prev_pressed) rise_edges++;
        if (!pressed && prev_pressed) fall_edges++;
        prev_pressed <= pressed;
    end

    task automatic check(input string d, input logic c);
        if (c) begin pass_count++; $display("[PASS] %s", d); end
        else   begin fail_count++; $error("[FAIL] %s", d); end
    endtask

    // chatter for `n` bounces, then settle to `final_lvl`
    task automatic bounce(input logic final_lvl, input int n);
        for (int i = 0; i < n; i++) begin
            btn_raw_n = ~final_lvl;
            repeat (3) @(posedge clk);
            btn_raw_n = final_lvl;
            repeat (2) @(posedge clk);
        end
        btn_raw_n = final_lvl;
    endtask

    initial begin
        repeat (5) @(posedge clk);
        check("idle: not pressed", pressed == 1'b0);

        // ---- bouncy press (settles LOW = pressed) ----
        bounce(1'b0, 6);
        repeat (STABLE + 10) @(posedge clk);
        check("after bouncy press: pressed=1", pressed == 1'b1);
        check("exactly one rising edge (no multi-reset)", rise_edges == 1);

        // ---- hold ----
        repeat (STABLE * 3) @(posedge clk);
        check("still pressed while held", pressed == 1'b1);
        check("no extra edges while held", rise_edges == 1 && fall_edges == 0);

        // ---- bouncy release (settles HIGH) ----
        bounce(1'b1, 6);
        repeat (STABLE + 10) @(posedge clk);
        check("after bouncy release: pressed=0", pressed == 1'b0);
        check("exactly one falling edge", fall_edges == 1);

        // ---- short glitch must be ignored entirely ----
        btn_raw_n = 1'b0;
        repeat (STABLE / 2) @(posedge clk);       // shorter than STABLE
        btn_raw_n = 1'b1;
        repeat (STABLE * 2) @(posedge clk);
        check("glitch ignored: still not pressed", pressed == 1'b0);
        check("glitch produced no edges", rise_edges == 1 && fall_edges == 1);

        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display(fail_count == 0 ? "  ALL TESTS PASSED" : "  THERE ARE FAILURES");
        $display("========================================");
        $finish;
    end
endmodule
