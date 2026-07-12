/*
 * uart_rx
 * -------
 * Plain 8-N-1 UART receiver. Samples the RX line at the middle of each bit.
 * One clock domain; CLKS_PER_BIT = clk_freq / baud (e.g. 100 MHz / 115200 = 868).
 *
 *   o_valid pulses high for 1 cycle when o_data holds a freshly received byte.
 *
 * No parity, one stop bit. The incoming line is double-registered first to
 * remove metastability (rx is asynchronous to clk).
 */
module uart_rx #(
    parameter int CLKS_PER_BIT = 868
)(
    input  logic       clk,
    input  logic       arstn,       // active-low async reset
    input  logic       rx,          // asynchronous serial input
    output logic [7:0]  o_data,
    output logic        o_valid
);

    localparam int CW = (CLKS_PER_BIT > 1) ? $clog2(CLKS_PER_BIT) : 1;

    typedef enum logic [2:0] {IDLE, START, DATA, STOP, CLEAN} state_e;
    state_e        state;

    logic [1:0]    rx_sync;          // 2-FF synchronizer
    logic          rx_q;
    logic [CW-1:0] clk_cnt;
    logic [2:0]    bit_idx;
    logic [7:0]    shreg;

    always_ff @(posedge clk or negedge arstn) begin
        if (!arstn) begin
            rx_sync <= 2'b11;        // idle line is high
            rx_q    <= 1'b1;
        end else begin
            rx_sync <= {rx_sync[0], rx};
            rx_q    <= rx_sync[1];
        end
    end

    always_ff @(posedge clk or negedge arstn) begin
        if (!arstn) begin
            state   <= IDLE;
            clk_cnt <= '0;
            bit_idx <= '0;
            shreg   <= '0;
            o_data  <= '0;
            o_valid <= 1'b0;
        end else begin
            o_valid <= 1'b0;         // default: 1-cycle strobe

            case (state)
                IDLE: begin
                    clk_cnt <= '0;
                    bit_idx <= '0;
                    if (rx_q == 1'b0)          // start bit detected
                        state <= START;
                end

                // confirm start bit still low at its midpoint
                START: begin
                    if (clk_cnt == (CLKS_PER_BIT-1)/2) begin
                        if (rx_q == 1'b0) begin
                            clk_cnt <= '0;
                            state   <= DATA;
                        end else begin
                            state <= IDLE;      // false start
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // sample 8 data bits at their midpoints, LSB first
                DATA: begin
                    if (clk_cnt < CLKS_PER_BIT-1) begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        clk_cnt        <= '0;
                        shreg[bit_idx] <= rx_q;
                        if (bit_idx == 3'd7) begin
                            bit_idx <= '0;
                            state   <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end
                end

                // one stop bit; publish the byte at its midpoint
                STOP: begin
                    if (clk_cnt < CLKS_PER_BIT-1) begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        o_data  <= shreg;
                        o_valid <= 1'b1;
                        clk_cnt <= '0;
                        state   <= CLEAN;
                    end
                end

                CLEAN: state <= IDLE;

                default: state <= IDLE;
            endcase
        end
    end

endmodule
