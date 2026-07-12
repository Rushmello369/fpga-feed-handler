/*
 * sync_fifo
 * ---------
 * Small single-clock FIFO (first-word-fall-through). Used to decouple the
 * slow UART byte producer from the parser's occasional 1-cycle backpressure.
 * Depth = 2**AW. `overflow` pulses if a write arrives while full (should never
 * happen given UART << clk, but flagged for bring-up visibility).
 */
module sync_fifo #(
    parameter int DW = 8,
    parameter int AW = 6            // depth 64
)(
    input  logic          clk,
    input  logic          arstn,

    input  logic          wr_en,
    input  logic [DW-1:0] wr_data,
    output logic          full,
    output logic          overflow,

    input  logic          rd_en,
    output logic [DW-1:0] rd_data,
    output logic          empty
);
    localparam int DEPTH = (1 << AW);

    logic [DW-1:0] mem [DEPTH];
    logic [AW:0]   wr_ptr, rd_ptr;    // extra MSB distinguishes full/empty

    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[AW] != rd_ptr[AW]) &&
                   (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
    assign rd_data = mem[rd_ptr[AW-1:0]];

    always_ff @(posedge clk or negedge arstn) begin
        if (!arstn) begin
            wr_ptr   <= '0;
            rd_ptr   <= '0;
            overflow <= 1'b0;
        end else begin
            overflow <= 1'b0;
            if (wr_en && !full) begin
                mem[wr_ptr[AW-1:0]] <= wr_data;
                wr_ptr <= wr_ptr + 1'b1;
            end else if (wr_en && full) begin
                overflow <= 1'b1;
            end
            if (rd_en && !empty)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end

endmodule
