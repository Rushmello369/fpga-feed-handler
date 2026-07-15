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
    input  logic uart_rx_pin,   // from CP2102 TXD (PC -> FPGA)
    output logic uart_tx_pin,   // to   CP2102 RXD (FPGA -> PC)
    output logic rx_overflow    // LED: FIFO overrun (should stay 0)
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

    // ---- reset: hold low until the clock is stable ----
    logic [3:0] rst_sr;
    logic       arstn;
    always_ff @(posedge clk100 or negedge locked) begin
        if (!locked) rst_sr <= 4'b0000;
        else         rst_sr <= {rst_sr[2:0], 1'b1};
    end
    assign arstn = rst_sr[3];

    // ---- pipeline + UART ----
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
        .rx_overflow(rx_overflow)
    );

endmodule
