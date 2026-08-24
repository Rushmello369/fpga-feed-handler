/*
 * radix_find_lowest (parameterized)
 * ---------------------------------
 * Finds the lowest set bit of a WINDOW_SIZE-bit vector as a binary address.
 *
 * Structure: radix-32, two levels.
 *   Level 0 (leaf)  : NUM_GROUPS x find_lowest, one per 32-bit group, parallel
 *   Level 1 (group) : find lowest among the NUM_GROUPS group-hit flags
 *   Final addr = {grp_sel, local_addr}  (concat == grp_sel*32 + local_addr,
 *                zero-gate because 32 is a power of two)
 *
 *   NUM_GROUPS = WINDOW_SIZE / 32 :
 *     WINDOW_SIZE=1024 -> 32 groups, addr 10 bits (original behavior)
 *     WINDOW_SIZE=2048 -> 64 groups, addr 11 bits
 *     WINDOW_SIZE=4096 -> 128 groups, addr 12 bits
 *   WINDOW_SIZE must be a power-of-two multiple of 32.
 *
 * LATENCY: 2 clock cycles (leaf->group register, then output register).
 * The 32-bit leaf (find_lowest + fixed onehot2bin) is reused UNCHANGED; only
 * the group stage widened via the generic onehot2bin_gen.
 *
 * If !valid, addr is meaningless.
 */

module radix_find_lowest #(
    parameter int WINDOW_SIZE = 1024,                 // default keeps v2 (1024) working
    parameter int NUM_GROUPS  = WINDOW_SIZE / 32,     // 32-bit leaves
    parameter int GSEL_W      = (NUM_GROUPS > 1) ? $clog2(NUM_GROUPS) : 1,
    parameter int ADDR_W      = $clog2(WINDOW_SIZE)   // = GSEL_W + 5
)(
    input  logic                   clk,
    input  logic                   arstn,
    input  logic [WINDOW_SIZE-1:0] vec,
    output logic [ADDR_W-1:0]      addr,
    output logic                   valid
);

    // ---- Level 0: per-32-bit-group leaves (reused fixed primitive) ----
    logic [4:0] leaf_addr [NUM_GROUPS];
    logic       leaf_hit  [NUM_GROUPS];

    generate
        for (genvar g = 0; g < NUM_GROUPS; g++) begin : g_leaf
            find_lowest u_leaf (
                .mask  (vec[g*32 +: 32]),
                .addr  (leaf_addr[g]),
                .valid (leaf_hit[g])
            );
        end
    endgenerate

    // ---- pipeline stage 1: register leaf results ----
    logic [4:0] leaf_addr_q [NUM_GROUPS];
    logic       leaf_hit_q  [NUM_GROUPS];

    always_ff @(posedge clk or negedge arstn) begin
        if (!arstn) begin
            for (int g = 0; g < NUM_GROUPS; g++) begin
                leaf_addr_q[g] <= '0;
                leaf_hit_q[g]  <= '0;
            end
        end else begin
            for (int g = 0; g < NUM_GROUPS; g++) begin
                leaf_addr_q[g] <= leaf_addr[g];
                leaf_hit_q[g]  <= leaf_hit[g];
            end
        end
    end

    // pack the registered hit flags into a vector for the group encoder
    logic [NUM_GROUPS-1:0] grp_hit_vec;
    generate
        for (genvar g = 0; g < NUM_GROUPS; g++) begin : g_pack
            assign grp_hit_vec[g] = leaf_hit_q[g];
        end
    endgenerate

    // ---- Level 1: find lowest set group (generic width) ----
    logic [NUM_GROUPS-1:0] grp_oh;
    logic [GSEL_W-1:0]     grp_sel;
    logic                  any_valid;

    assign grp_oh    = grp_hit_vec & (~grp_hit_vec + 1);   // isolate lowest group
    assign any_valid = |grp_hit_vec;

    onehot2bin_gen #(.W(NUM_GROUPS)) u_group_o2b (
        .oh  (grp_oh),
        .bin (grp_sel)
    );

    // 32-to-1 (or wider) mux: local offset of the selected group
    logic [4:0] sel_local_addr;
    assign sel_local_addr = leaf_addr_q[grp_sel];

    // ---- pipeline stage 2: register the final address ----
    always_ff @(posedge clk or negedge arstn) begin
        if (!arstn) begin
            addr  <= '0;
            valid <= '0;
        end else begin
            addr  <= {grp_sel, sel_local_addr};   // grp_sel*32 + sel_local_addr
            valid <= any_valid;
        end
    end

endmodule
