/*
 * axis_to_uart
 * ------------
 * Drains an 8-bit AXI4-Stream (board_link_tx's tx_valid/tx_data/tx_ready) out
 * a UART TX line. s_tready is high whenever the transmitter can take a byte.
 */
module axis_to_uart #(
    parameter int CLKS_PER_BIT = 868
)(
    input  logic       clk,
    input  logic       arstn,

    input  logic [7:0] s_tdata,
    input  logic       s_tvalid,
    output logic       s_tready,

    output logic       tx
);
    logic tx_busy;
    logic load;

    // accept a byte when the stream offers one and the UART is free
    assign s_tready = ~tx_busy;
    assign load     = s_tvalid & s_tready;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .arstn(arstn),
        .i_data(s_tdata), .i_valid(load), .o_busy(tx_busy), .tx(tx)
    );
endmodule
