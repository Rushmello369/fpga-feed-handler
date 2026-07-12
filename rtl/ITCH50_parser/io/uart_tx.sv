/*
 * uart_tx
 * -------
 * Plain 8-N-1 UART transmitter. Assert i_valid with i_data while !o_busy to
 * queue a byte; o_busy stays high until the stop bit completes.
 */
module uart_tx #(
    parameter int CLKS_PER_BIT = 868
)(
    input  logic       clk,
    input  logic       arstn,
    input  logic [7:0] i_data,
    input  logic       i_valid,
    output logic       o_busy,
    output logic       tx
);
    localparam int CW = (CLKS_PER_BIT > 1) ? $clog2(CLKS_PER_BIT) : 1;

    typedef enum logic [2:0] {IDLE, START, DATA, STOP} state_e;
    state_e        state;
    logic [CW-1:0] clk_cnt;
    logic [2:0]    bit_idx;
    logic [7:0]    shreg;

    assign o_busy = (state != IDLE);

    always_ff @(posedge clk or negedge arstn) begin
        if (!arstn) begin
            state   <= IDLE;
            tx      <= 1'b1;         // idle high
            clk_cnt <= '0;
            bit_idx <= '0;
            shreg   <= '0;
        end else begin
            case (state)
                IDLE: begin
                    tx      <= 1'b1;
                    clk_cnt <= '0;
                    bit_idx <= '0;
                    if (i_valid) begin
                        shreg <= i_data;
                        state <= START;
                    end
                end
                START: begin
                    tx <= 1'b0;                     // start bit
                    if (clk_cnt < CLKS_PER_BIT-1) clk_cnt <= clk_cnt + 1'b1;
                    else begin clk_cnt <= '0; state <= DATA; end
                end
                DATA: begin
                    tx <= shreg[bit_idx];           // LSB first
                    if (clk_cnt < CLKS_PER_BIT-1) clk_cnt <= clk_cnt + 1'b1;
                    else begin
                        clk_cnt <= '0;
                        if (bit_idx == 3'd7) begin bit_idx <= '0; state <= STOP; end
                        else bit_idx <= bit_idx + 1'b1;
                    end
                end
                STOP: begin
                    tx <= 1'b1;                     // stop bit
                    if (clk_cnt < CLKS_PER_BIT-1) clk_cnt <= clk_cnt + 1'b1;
                    else begin clk_cnt <= '0; state <= IDLE; end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
