/*
 * priority_encoder (parameterized)
 * --------------------------------
 * The width-configurable priority encoder that top_v2 instantiates.
 * Wraps two radix_find_lowest pipelines (2-cycle latency):
 *
 *   ask : best ask = lowest  price = lowest  set bit  -> direct
 *   bid : best bid = highest price = highest set bit  -> reverse the mask so
 *         the highest set bit becomes the lowest, find it, then map back with
 *         (WINDOW_SIZE-1) - idx  (exact for any power-of-two width; the old
 *         v2 used ~idx which only held for the fixed 10-bit / 1024 case).
 *
 * WINDOW_SIZE is the single knob for price coverage (penny ticks). It flows
 * straight from top_v2, so 1024 / 2048 / 4096 all build with no other edits.
 * Must be a power-of-two multiple of 32.
 */

module priority_encoder #(
    parameter int WINDOW_SIZE = 2048,
    parameter int ADDR_W      = $clog2(WINDOW_SIZE)
)(
    input  logic                   clk,
    input  logic                   arstn,
    input  logic [WINDOW_SIZE-1:0] bid_mask,
    input  logic [WINDOW_SIZE-1:0] ask_mask,
    output logic [ADDR_W-1:0]      best_bid_addr,
    output logic                   best_bid_valid,
    output logic [ADDR_W-1:0]      best_ask_addr,
    output logic                   best_ask_valid
);

    // ---- ask side: lowest set bit directly ----
    radix_find_lowest #(.WINDOW_SIZE(WINDOW_SIZE)) u_ask (
        .clk   (clk),
        .arstn (arstn),
        .vec   (ask_mask),
        .addr  (best_ask_addr),
        .valid (best_ask_valid)
    );

    // ---- bid side: highest set bit via reversal ----
    logic [WINDOW_SIZE-1:0] bid_mask_rev;
    generate
        for (genvar i = 0; i < WINDOW_SIZE; i++) begin : g_rev
            assign bid_mask_rev[i] = bid_mask[WINDOW_SIZE-1-i];
        end
    endgenerate

    logic [ADDR_W-1:0] bid_idx_rev;

    radix_find_lowest #(.WINDOW_SIZE(WINDOW_SIZE)) u_bid (
        .clk   (clk),
        .arstn (arstn),
        .vec   (bid_mask_rev),
        .addr  (bid_idx_rev),
        .valid (best_bid_valid)
    );

    // map the reversed index back to a real address
    assign best_bid_addr = (WINDOW_SIZE-1) - bid_idx_rev;

endmodule
