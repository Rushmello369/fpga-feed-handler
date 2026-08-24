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
    // status frame is emitted once the RX line has been quiet this long
    // (~10 ms at 100 MHz); the testbench overrides it with a tiny value
    parameter int          STATUS_IDLE_CYCLES = 1_000_000,
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
    output logic rx_overflow,
    output logic rx_byte_seen   // 1-cyc pulse per raw UART byte (pre-FIFO,
                                 // pre-core) - proves bytes reach the FPGA
                                 // regardless of downstream logic state
);
    localparam int CPB = CLK_FREQ_HZ / BAUD;

    // ---- UART in -> stream ----
    logic [7:0] s_tdata;
    logic       s_tvalid, s_tready;

    uart_to_axis #(.CLKS_PER_BIT(CPB)) u_in (
        .clk(clk), .arstn(arstn), .rx(uart_rx_pin),
        .m_tdata(s_tdata), .m_tvalid(s_tvalid), .m_tready(s_tready),
        .overflow(rx_overflow), .rx_byte_seen(rx_byte_seen)
    );

    // ---- core pipeline ----
    logic [7:0] tx_data;
    logic       tx_valid, tx_ready;
    logic       parse_error;
    logic [31:0] unknown_count, msg_count, filtered_count,
                 miss_count, oow_count, drop_count;
    logic [31:0] lat_last, lat_min, lat_max, lat_sum, lat_count,
                 lat_resolve, lat_book2tob, lat_tob2feat,
                 lat_ia_last, lat_ia_min, lat_unmatched;

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
        .miss_count(miss_count), .oow_count(oow_count), .drop_count(drop_count),
        .lat_last(lat_last), .lat_min(lat_min), .lat_max(lat_max),
        .lat_sum(lat_sum), .lat_count(lat_count),
        .lat_resolve(lat_resolve), .lat_book2tob(lat_book2tob),
        .lat_tob2feat(lat_tob2feat),
        .lat_ia_last(lat_ia_last), .lat_ia_min(lat_ia_min),
        .lat_unmatched(lat_unmatched)
    );

    // ---- diagnostic status frames -------------------------------------
    // parse_error is a 1-cycle pulse; accumulate it so the host sees a count
    logic [31:0] parse_err_count;
    always_ff @(posedge clk) begin
        if (!arstn)          parse_err_count <= '0;
        else if (parse_error) parse_err_count <= parse_err_count + 1'b1;
    end

    logic [7:0] st_data;
    logic       st_valid, st_ready;

    // Status-frame payload. THIS ORDER IS THE WIRE FORMAT - uart_feed.py's
    // STATUS_FIELDS list must match it exactly, element for element. Packed
    // MSB-first so status_reporter emits it big-endian.
    localparam int NSTAT = 18;
    logic [NSTAT*32-1:0] stat_bus;
    assign stat_bus = {
        // --- 7 pipeline counters (unchanged, first for backward readability) ---
        msg_count, unknown_count, filtered_count, miss_count,
        oow_count, drop_count, parse_err_count,
        // --- 11 latency probe results ---
        lat_last, lat_min, lat_max, lat_sum, lat_count,
        lat_resolve, lat_book2tob, lat_tob2feat,
        lat_ia_last, lat_ia_min, lat_unmatched
    };

    status_reporter #(
        .IDLE_CYCLES(STATUS_IDLE_CYCLES),
        .NCNT       (NSTAT)
    ) u_status (
        .clk(clk), .arstn(arstn),
        .rx_byte_seen(rx_byte_seen),
        .cnt_bus(stat_bus),
        .m_tdata(st_data), .m_tvalid(st_valid), .m_tready(st_ready)
    );

    // ---- arbitrate feature vs status frames onto the single UART TX ----
    logic [7:0] out_data;
    logic       out_valid, out_ready;

    axis_arb2 u_arb (
        .clk(clk), .arstn(arstn),
        .s0_tdata(tx_data), .s0_tvalid(tx_valid), .s0_tready(tx_ready),
        .s1_tdata(st_data), .s1_tvalid(st_valid), .s1_tready(st_ready),
        .m_tdata(out_data), .m_tvalid(out_valid), .m_tready(out_ready)
    );

    // ---- stream -> UART out ----
    axis_to_uart #(.CLKS_PER_BIT(CPB)) u_out (
        .clk(clk), .arstn(arstn),
        .s_tdata(out_data), .s_tvalid(out_valid), .s_tready(out_ready),
        .tx(uart_tx_pin)
    );

endmodule
