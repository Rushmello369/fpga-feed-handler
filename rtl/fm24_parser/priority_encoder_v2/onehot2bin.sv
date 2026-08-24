/* 
32-bit one-hot number to binary number converter
use a truth table to determine the mapping
e.g bin[0] is 1 when one of these positions is 1: 32'b10101010101010101010101010101010 = 32'hAAAAAAAA
first oh & positions
then or them together (log2(32)=5 stages)
*/

module onehot2bin(
    input  logic [31:0] oh,
    output logic [4:0]  bin
);

always_comb begin
    bin[0] = |(oh & 32'hAAAAAAAA);
    bin[1] = |(oh & 32'hCCCCCCCC);
    bin[2] = |(oh & 32'hF0F0F0F0);
    bin[3] = |(oh & 32'hFF00FF00);
    bin[4] = |(oh & 32'hFFFF0000);
end

endmodule