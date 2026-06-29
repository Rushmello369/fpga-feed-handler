module top
    import fm24_pkg::*;
(
    input logic clk,
    input logic arstn,
    input  logic [7:0]  s_tdata,
    input  logic        s_tvalid,
    output logic        s_tready,
    input  logic        s_tlast,
    output fm24_tob_t   tob,
    output logic [31:0] latency,
    output logic        latency_valid
);

    // parser → book_update
    fm24_cmd_t              cmd;
    fm24_valid_t            valid;
    fm24_err_t              err;

    // book_update → priority_encoder（masks）
    logic [WINDOW_SIZE-1:0] bid_mask;
    logic [WINDOW_SIZE-1:0] ask_mask;

    // priority_encoder → book_update（）+ tob_tracker
    logic [ADDR_WIDTH-1:0]  best_bid_addr;
    logic                   best_bid_valid;
    logic [ADDR_WIDTH-1:0]  best_ask_addr;
    logic                   best_ask_valid;

    // book_update → tob_tracker
    logic [31:0]            read_bid_qty;
    logic [31:0]            read_ask_qty;

    msg_parser u_parser(
        .clk(clk),
        .arstn(arstn),
        .s_tdata(s_tdata),
        .s_tvalid(s_tvalid),
        .s_tready(s_tready),
        .s_tlast(s_tlast),
        .cmd(cmd),
        .valid(valid),
        .err(err)
    );

    book_update u_book(
        .clk(clk),
        .arstn(arstn),
        .cmd(cmd),
        .valid(valid),
        .bid_mask(bid_mask),
        .ask_mask(ask_mask),
        .read_bid_addr(best_bid_addr),
        .read_bid_qty(read_bid_qty),
        .read_ask_addr(best_ask_addr),
        .read_ask_qty(read_ask_qty)
    );

    priority_encoder u_encoder(
        .bid_mask(bid_mask),
        .ask_mask(ask_mask),
        .best_bid_addr(best_bid_addr),
        .best_bid_valid(best_bid_valid),
        .best_ask_addr(best_ask_addr),
        .best_ask_valid(best_ask_valid)
    );

    tob_tracker u_tob(
        .clk(clk),
        .arstn(arstn),
        .best_bid_addr(best_bid_addr),
        .best_bid_valid(best_bid_valid),
        .best_ask_addr(best_ask_addr),
        .best_ask_valid(best_ask_valid),
        .read_bid_qty(read_bid_qty),
        .read_ask_qty(read_ask_qty),
        .tob(tob)
    );

    latency_counter u_lat(
        .clk(clk),
        .arstn(arstn),
        .s_tready(s_tready),
        .s_tvalid(s_tvalid),
        .qty_valid(valid.qty_valid),
        .latency_valid(latency_valid),
        .latency(latency)
    );

endmodule
