/*
pipelined priority encoder (2-cycle latency)
ask: find lowest set bit directly
bid: find highest set bit by reversing input + complementing output,
     reusing the same find-lowest hardware
*/

module priority_encoder_v2 (
    input  logic          clk,
    input  logic          arstn,
    input  logic [1023:0] bid_mask,
    input  logic [1023:0] ask_mask,
    output logic [9:0]    best_bid_addr,
    output logic          best_bid_valid,
    output logic [9:0]    best_ask_addr,
    output logic          best_ask_valid
);

    //ask side: best ask = lowest price = lowest set bit
    radix_find_lowest u_ask (
        .clk   (clk),
        .arstn (arstn),
        .vec   (ask_mask),
        .addr  (best_ask_addr),
        .valid (best_ask_valid)
    );

    //bid side: best bid = highest price = highest set bit 
    logic [1023:0] bid_mask_rev;

    generate
        for (genvar i = 0; i < 1024; i++) begin : g_rev
            assign bid_mask_rev[i] = bid_mask[1023-i];
        end
    endgenerate

    logic [9:0] bid_idx_rev;

    radix_find_lowest u_bid (
        .clk   (clk),
        .arstn (arstn),
        .vec   (bid_mask_rev),
        .addr  (bid_idx_rev),
        .valid (best_bid_valid)
    );

    assign best_bid_addr = ~bid_idx_rev;   // 1023 - x == ~x for 10-bit x

endmodule