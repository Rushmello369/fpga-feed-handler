/*
 * button_debounce
 * ---------------
 * Synchronises and debounces a mechanical push-button.
 *
 * A raw button contacts bounce for ~1-10 ms, so a naive edge detector would
 * see dozens of presses. This accepts a new level only after it has been held
 * continuously for STABLE_CYCLES; any glitch shorter than that restarts the
 * timer and is ignored.
 *
 * The input is asynchronous to clk, so it is double-registered first
 * (metastability). btn_raw_n is ACTIVE-LOW: the AX7A200B buttons pull the pin
 * to GND when pressed and are pulled up to 3.3 V otherwise.
 *
 * No reset input by design: this block generates the reset, so it cannot
 * depend on one. Registers carry initial values, which FPGA configuration
 * loads at power-up (and simulation honours), and the filter is self-correcting
 * regardless of its starting state.
 */
module button_debounce #(
    parameter int STABLE_CYCLES = 1_000_000   // 10 ms at 100 MHz
)(
    input  logic clk,
    input  logic btn_raw_n,     // asynchronous, active-low
    output logic pressed        // debounced, active-high
);

    localparam int CW = $clog2(STABLE_CYCLES + 1);

    logic [1:0]    sync  = 2'b00;   // 2-FF synchroniser (already inverted)
    logic          level = 1'b0;    // currently accepted state
    logic [CW-1:0] cnt   = '0;

    always_ff @(posedge clk) begin
        sync <= {sync[0], ~btn_raw_n};      // invert once: 1 = pressed

        if (sync[1] == level) begin
            cnt <= '0;                       // agrees with accepted state
        end else if (cnt == CW'(STABLE_CYCLES - 1)) begin
            level <= sync[1];                // held long enough: accept it
            cnt   <= '0;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end

    assign pressed = level;

endmodule
