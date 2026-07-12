/*
this module split the 1024-bit address into 32 radix-32 blocks
and find their lowest address
Structure: radix-32, two levels.
    Level 0 (leaf) : 32 x find_lowest, one per 32-bit group, all in parallel
    Level 1 (group): 1 x find_lowest over the 32 group-hit flags
    Final addr = {grp_sel, local_addr} -- concat IS grp_sel*32 + local_addr,
                 since 32 is a power of two, so it costs zero gates.

    LATENCY: 2 clock cycles (leaf->group register, and output register).
    Replaces the old O(N)-depth priority-if chain that capped Fmax at ~10MHz.
 
If !valid, addr is meaningless 
*/

module radix_find_lowest(
    input  logic          clk,
    input  logic          arstn,
    input  logic [1023:0] vec,
    output logic [9:0]    addr,
    output logic          valid
);

//unpacked arrays, stores the binary lowest address for each block
logic [4:0] leaf_addr [32];
//flag for each block
logic       leaf_hit  [32];

generate 
    for(genvar g = 0; g < 32; g++) begin : g_leaf //assign g_leaf as the name, good for debugging
        find_lowest u_leaf(
            .mask(vec[g*32 +: 32]), // vec[g*32 + 31 : g*32]
            .addr(leaf_addr[g]),
            .valid(leaf_hit[g])
        );
    end
endgenerate

//pipelined registers
logic [4:0] leaf_addr_q [32]; 
logic       leaf_hit_q  [32];

always_ff @(posedge clk or negedge arstn) begin
    if(!arstn) begin
        for(int g = 0; g < 32; g++) begin
            leaf_addr_q[g] <= '0;
            leaf_hit_q[g] <= '0;
        end
    end else begin
        for(int g = 0; g < 32; g++) begin
            leaf_addr_q[g] <= leaf_addr[g];
            leaf_hit_q[g] <= leaf_hit[g];
        end
    end
end

//stores the flag as one 32-bit vector
logic [31:0] grp_hit_vec;

generate
    for(genvar g = 0; g < 32; g++) begin : g_pack
        assign grp_hit_vec[g] = leaf_hit_q[g];
    end
endgenerate

//find the valid block with lowest index
logic [4:0] grp_sel;
logic       any_valid;

find_lowest u_group (
    .mask  (grp_hit_vec),
    .addr  (grp_sel),
    .valid (any_valid)
);

logic [4:0] sel_local_addr;
assign sel_local_addr = leaf_addr_q[grp_sel]; //32-to-1 multiplexer, get the 5-bit lowest address for the lowest indexed block

always_ff @(posedge clk or negedge arstn) begin
    if (!arstn) begin
        addr  <= '0;
        valid <= '0;
    end else begin
        addr  <= {grp_sel, sel_local_addr}; //grp_sel*32 + sel_local_addr
        valid <= any_valid;
    end
end



endmodule