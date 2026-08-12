/*
 * top_board
 * ---------
 * AX7A200B board-level top. Turns the board's 200 MHz DIFFERENTIAL system clock
 * (SYS_CLK_P=R4 / SYS_CLK_N=T4, per AX7A200 user guide) into the 100 MHz the
 * pipeline runs at, and wires the CP2102 USB-UART (RX=L14, TX=L15) to top_uart.
 *
 *   sys_clk_p/n --IBUFDS--> 200MHz --MMCM--> 100MHz --> top_uart
 *
 * Baud = 1,000,000 (CP2102GM max). At 100 MHz that is CLKS_PER_BIT = 100 exactly
 * -> zero baud error. Match uart_feed.py:  --baud 1000000
 *
 * Reset is held asserted until the MMCM locks (no external reset pin needed).
 * Calibrate BASE_PRICE / WINDOW_SIZE / FILTER_LOCATE per instrument/day with
 * itch_tools.py before synthesis.
 */
module top_board #(
    parameter int unsigned BASE_PRICE    = 1_610_800,
    parameter int unsigned WINDOW_SIZE   = 1024,
    parameter bit          FILTER_EN     = 1'b1,
    parameter logic [15:0] FILTER_LOCATE = 16'd14,
    parameter int unsigned QTY_SHIFT     = 0,
    parameter int          TABLE_BITS    = 14
)(
    input  logic sys_clk_p,
    input  logic sys_clk_n,
    // Board RESET push-button (F15), active-low. Clears the whole pipeline -
    // order table, book, feature state and all diagnostic counters - giving a
    // clean slate between replay runs without re-programming the device.
    input  logic rst_btn_n,
    input  logic uart_rx_pin,   // from CP2102 TXD (PC -> FPGA)
    output logic uart_tx_pin,   // to   CP2102 RXD (FPGA -> PC)

    // ---- bring-up diagnostics, independent of the ITCH parsing logic ----
    //
    // THE LEDS ON THIS BOARD ARE ACTIVE-LOW: driving 0 lights the LED. Hence
    // the _n suffix, and hence the inversions where these are assigned below.
    // Determined empirically with bringup/led_test.sv, which drives the three
    // pins at three distinguishable rates - the pin-to-LED mapping is also
    // shifted by one from what the user guide suggests:
    //
    //     pin M13 -> physical LED2      (NOT LED1)
    //     pin K14 -> physical LED3      (NOT LED2)
    //     pin K13 -> physical LED4      (NOT LED3)
    //
    // rx_overflow_n    (LED2/M13): FIFO overrun. Active-low, so a LIT LED here
    //   is the healthy state - it means the counter is zero.
    // heartbeat_n      (LED3/K14): blinks at ~1.5 Hz (0.67 s period) iff clk100
    //   is running AND arstn is released, i.e. the MMCM actually locked. A
    //   steady LED is a clock/reset problem upstream of everything else - stop
    //   debugging further down until this blinks.
    // rx_activity_n    (LED4/K13): stretched ~0.25 s per raw UART byte the
    //   receiver decodes, BEFORE the FIFO/core - proves bytes are physically
    //   reaching this chip regardless of what the ITCH pipeline does with them.
    output logic rx_overflow_n,
    output logic heartbeat_n,
    output logic rx_activity_n
);

    // ---- 200 MHz differential input -> single-ended ----
    logic clk200;
    IBUFDS u_ibufds (.O(clk200), .I(sys_clk_p), .IB(sys_clk_n));

    // ---- MMCM: 200 MHz -> 100 MHz  (VCO = 200*5 = 1000 MHz, /10 = 100 MHz) ----
    logic clk100_pre, clk100, clkfb_pre, clkfb, locked;

    MMCME2_BASE #(
        .BANDWIDTH        ("OPTIMIZED"),
        .CLKIN1_PERIOD    (5.000),        // 200 MHz
        .DIVCLK_DIVIDE    (1),
        .CLKFBOUT_MULT_F  (5.000),        // VCO = 1000 MHz
        .CLKOUT0_DIVIDE_F (10.000),       // 100 MHz
        .CLKOUT0_DUTY_CYCLE(0.5),
        .STARTUP_WAIT     ("FALSE")
    ) u_mmcm (
        .CLKOUT0 (clk100_pre), .CLKOUT0B(),
        .CLKOUT1 (),           .CLKOUT1B(),
        .CLKOUT2 (),           .CLKOUT2B(),
        .CLKOUT3 (),           .CLKOUT3B(),
        .CLKOUT4 (),           .CLKOUT5 (), .CLKOUT6(),
        .CLKFBOUT(clkfb_pre),  .CLKFBOUTB(),
        .LOCKED  (locked),
        .CLKIN1  (clk200),
        .PWRDWN  (1'b0),
        .RST     (1'b0),
        .CLKFBIN (clkfb)
    );

    BUFG u_bufg_clk (.I(clk100_pre), .O(clk100));
    BUFG u_bufg_fb  (.I(clkfb_pre),  .O(clkfb));

    // ---- reset: released once the clock is stable, re-asserted by the button ----
    // Sources: (1) MMCM not yet locked - never run on an unstable clock;
    //          (2) the debounced RESET button - manual clean slate.
    // Release is synchronous (shift register) so every flop leaves reset on the
    // same edge; assertion is immediate.
    logic btn_reset;
    button_debounce #(.STABLE_CYCLES(1_000_000)) u_btn (   // 10 ms
        .clk(clk100), .btn_raw_n(rst_btn_n), .pressed(btn_reset)
    );

    logic [3:0] rst_sr;
    logic       arstn;
    always_ff @(posedge clk100 or negedge locked) begin
        if (!locked)        rst_sr <= 4'b0000;
        else if (btn_reset) rst_sr <= 4'b0000;   // held low while pressed
        else                rst_sr <= {rst_sr[2:0], 1'b1};
    end
    assign arstn = rst_sr[3];

    // ---- pipeline + UART ----
    logic rx_byte_seen;
    logic rx_overflow_i;      // active-high internally, inverted at the pin

    top_uart #(
        .CLK_FREQ_HZ  (100_000_000),
        .BAUD         (1_000_000),
        .BASE_PRICE   (BASE_PRICE),
        .WINDOW_SIZE  (WINDOW_SIZE),
        .FILTER_EN    (FILTER_EN),
        .FILTER_LOCATE(FILTER_LOCATE),
        .QTY_SHIFT    (QTY_SHIFT),
        .TABLE_BITS   (TABLE_BITS)
    ) u_top (
        .clk(clk100), .arstn(arstn),
        .uart_rx_pin(uart_rx_pin),
        .uart_tx_pin(uart_tx_pin),
        .rx_overflow(rx_overflow_i),
        .rx_byte_seen(rx_byte_seen)
    );

    // ---- heartbeat: proves clk100 alive + arstn released (MMCM locked) ----
    logic [25:0] hb_cnt;
    always_ff @(posedge clk100) begin
        if (!arstn) hb_cnt <= '0;
        else        hb_cnt <= hb_cnt + 1'b1;
    end
    // hb_cnt[25] toggles every 2^25 cycles = 0.335 s at 100 MHz, so the LED
    // blinks with a 0.67 s period (~1.5 Hz) - unmistakably a blink by eye.
    assign heartbeat_n = ~hb_cnt[25];    // active-low pin

    // ---- rx activity: stretch each raw UART byte into a visible flash ----
    localparam int STRETCH = 100_000_000 / 4;   // ~0.25s at 100MHz
    logic [$clog2(STRETCH)-1:0] act_cnt;
    always_ff @(posedge clk100) begin
        if (!arstn)             act_cnt <= '0;
        else if (rx_byte_seen)  act_cnt <= STRETCH[$clog2(STRETCH)-1:0] - 1'b1;
        else if (act_cnt != 0)  act_cnt <= act_cnt - 1'b1;
    end
    assign rx_activity_n = ~(act_cnt != 0);   // active-low pin
    assign rx_overflow_n = ~rx_overflow_i;    // active-low pin: LIT = healthy

endmodule
