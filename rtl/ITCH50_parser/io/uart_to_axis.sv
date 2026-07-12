/*
 * uart_to_axis
 * ------------
 * Adapts a UART RX line into the 8-bit AXI4-Stream that top_v2 consumes:
 *
 *     rx --> uart_rx --> sync_fifo --> {m_tdata, m_tvalid, m_tready}
 *
 * The FIFO absorbs the parser's brief backpressure (s_tready low during EMIT);
 * because a UART byte arrives only every CLKS_PER_BIT*10 clocks (~thousands),
 * the FIFO stays nearly empty, but it makes the crossing correct regardless.
 *
 * Wire m_tdata/m_tvalid/m_tready straight to top_v2's s_tdata/s_tvalid/s_tready.
 */
module uart_to_axis #(
    parameter int CLKS_PER_BIT = 868,   // clk_freq / baud
    parameter int FIFO_AW      = 6
)(
    input  logic       clk,
    input  logic       arstn,
    input  logic       rx,           // UART serial in

    output logic [7:0] m_tdata,
    output logic       m_tvalid,
    input  logic       m_tready,

    output logic       overflow      // FIFO overrun (diagnostic; expect 0)
);

    logic [7:0] rx_data;
    logic       rx_valid;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .arstn(arstn), .rx(rx),
        .o_data(rx_data), .o_valid(rx_valid)
    );

    logic empty;
    assign m_tvalid = ~empty;

    sync_fifo #(.DW(8), .AW(FIFO_AW)) u_fifo (
        .clk(clk), .arstn(arstn),
        .wr_en(rx_valid), .wr_data(rx_data), .full(), .overflow(overflow),
        .rd_en(m_tvalid & m_tready), .rd_data(m_tdata), .empty(empty)
    );

endmodule
