/*
 * top_uart
 * --------
 * Board-level top for a PC<->AX7A200B UART bring-up of the ITCH pipeline:
 *
 *     PC ==UART RX==> uart_to_axis ==> top_v2 ==> axis_to_uart ==UART TX==> PC
 *
 * A single full-duplex USB-UART carries the ITCH feed IN and the 15-byte
 * feature frames OUT. No PS, no DMA, no Ethernet - the simplest path to see
 * the whole datapath run on real silicon with historical data.
 *
 * Calibrate per instrument/day (from itch_tools.py calibrate):
 *   BASE_PRICE, WINDOW_SIZE, FILTER_LOCATE   (see below)
 *
 * Set CLK_FREQ_HZ / BAUD to your board's clock and the baud your PC sender uses.
 * Pin-assign clk / arstn / uart_rx_pin / uart_tx_pin in the board XDC.
 */
module top_uart #(
    parameter int          CLK_FREQ_HZ   = 100_000_000,
    parameter int          BAUD          = 921_600,
    // ---- instrument/day calibration (from itch_tools.py) ----
    parameter int unsigned BASE_PRICE    = 1_550_000,
    parameter int unsigned WINDOW_SIZE   = 2048,
    parameter bit          FILTER_EN     = 1'b1,
    parameter logic [15:0] FILTER_LOCATE = 16'd1,
    parameter int unsigned QTY_SHIFT     = 0,
    parameter int          TABLE_BITS    = 14
)(
    input  logic clk,
    input  logic arstn,        // active-low reset (tie to a button / power-on)
    input  logic uart_rx_pin,  // from PC (FPGA input)
    output logic uart_tx_pin,  // to   PC (FPGA output)

    // optional bring-up diagnostics (LEDs)
    output logic rx_overflow
);
    localparam int CPB = CLK_FREQ_HZ / BAUD;

    // ---- UART in -> stream ----
    logic [7:0] s_tdata;
    logic       s_tvalid, s_tready;

    uart_to_axis #(.CLKS_PER_BIT(CPB)) u_in (
        .clk(clk), .arstn(arstn), .rx(uart_rx_pin),
        .m_tdata(s_tdata), .m_tvalid(s_tvalid), .m_tready(s_tready),
        .overflow(rx_overflow)
    );

    // ---- core pipeline ----
    logic [7:0] tx_data;
    logic       tx_valid, tx_ready;
    logic       parse_error;
    logic [31:0] unknown_count, msg_count, filtered_count,
                 miss_count, oow_count, drop_count;

    top_v2 #(
        .BASE_PRICE(BASE_PRICE), .WINDOW_SIZE(WINDOW_SIZE),
        .QTY_SHIFT(QTY_SHIFT), .TABLE_BITS(TABLE_BITS),
        .FILTER_EN(FILTER_EN), .FILTER_LOCATE(FILTER_LOCATE)
    ) u_core (
        .clk(clk), .arstn(arstn),
        .s_tvalid(s_tvalid), .s_tdata(s_tdata), .s_tready(s_tready),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .parse_error(parse_error),
        .unknown_count(unknown_count), .msg_count(msg_count),
        .filtered_count(filtered_count),
        .miss_count(miss_count), .oow_count(oow_count), .drop_count(drop_count)
    );

    // ---- stream -> UART out ----
    axis_to_uart #(.CLKS_PER_BIT(CPB)) u_out (
        .clk(clk), .arstn(arstn),
        .s_tdata(tx_data), .s_tvalid(tx_valid), .s_tready(tx_ready),
        .tx(uart_tx_pin)
    );

endmodule
