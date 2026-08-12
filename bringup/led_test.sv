/*
 * led_test  --  minimal bring-up design to resolve LED pin mapping and polarity
 * ---------------------------------------------------------------------------
 * Drives the three user-LED pins at three obviously different rates so you can
 * tell by eye which physical LED is wired to which package pin, and whether the
 * LEDs are active-high or active-low.
 *
 * DELIBERATELY MINIMAL. No MMCM, no reset, no UART, no pipeline. It runs
 * straight off the 200 MHz differential input through IBUFDS + BUFG, so if the
 * LEDs move at all it proves the differential clock is arriving and the board
 * is configured. That isolates "is the clock there" from "does the MMCM lock",
 * which the full design cannot distinguish.
 *
 * No reset either: the counter starts from its configuration-time initial
 * value, so there is nothing to hold it off.
 *
 * WHAT TO OBSERVE (at 200 MHz):
 *
 *   pin M13 (led1) : ~3 Hz     fast, even on/off        (2^25 / 200e6 = 168 ms)
 *   pin K14 (led2) : ~0.37 Hz  slow, even on/off        (2^28 / 200e6 = 1.34 s)
 *   pin K13 (led3) : brief blip once every ~2.7 s       (1/16 duty cycle)
 *
 * MAPPING  : whichever physical LED blinks fast is M13, the slow even one is
 *            K14, the one that blips briefly is K13. If that does not match
 *            what you expect, the pin assignments in ax7a200_uart.xdc are wrong
 *            and that is why the heartbeat looked dead.
 *
 * POLARITY : watch the K13 LED. It is driven high for only 1/16 of its period.
 *              - a SHORT FLASH on a dark LED  -> LEDs are ACTIVE-HIGH (as the
 *                main design assumes; nothing to change)
 *              - a SHORT DARK GAP on a lit LED -> LEDs are ACTIVE-LOW, so every
 *                LED output in top_board must be inverted
 */

module led_test (
    input  logic sys_clk_p,
    input  logic sys_clk_n,
    output logic led1,      // M13
    output logic led2,      // K14
    output logic led3       // K13
);

    // ---- 200 MHz differential input -> global clock, no MMCM in the way ----
    logic clk200_i, clk200;
    IBUFDS u_ibufds (.O(clk200_i), .I(sys_clk_p), .IB(sys_clk_n));
    BUFG   u_bufg   (.I(clk200_i), .O(clk200));

    // free-running, starts from its configuration-time initial value
    logic [29:0] cnt = '0;
    always_ff @(posedge clk200) cnt <= cnt + 1'b1;

    assign led1 = cnt[25];                  // ~3 Hz,    50%  duty
    assign led2 = cnt[28];                  // ~0.37 Hz, 50%  duty
    assign led3 = (cnt[28:25] == 4'd0);     // ~0.37 Hz, 6.25% duty -> polarity tell

endmodule
