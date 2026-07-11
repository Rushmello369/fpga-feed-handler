/* 
find the lowest bit of address (radix-32)
use two's complement arithmetic to isolate lowest bit
convert to binary address and update valid flag
*/

module find_lowest (
    input  logic [31:0] mask,
    output logic [4:0]  addr,
    output logic        valid
);

    logic [31:0] mask_oh;

    assign mask_oh = mask & (~mask + 1);   // isolate lowest set bit
    assign valid   = |mask;                // check mask != 0 

    onehot2bin u_onehot2bin (
        .oh  (mask_oh),
        .bin (addr)
    );

endmodule