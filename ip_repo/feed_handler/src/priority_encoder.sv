module priority_encoder 
    import fm24_pkg::*;
(
    // port widths hardcoded for IP Packager compatibility
    // WINDOW_SIZE=1024, ADDR_WIDTH=10
    input  logic [1023:0] bid_mask,
    input  logic [1023:0] ask_mask,
    output logic [9:0]    best_bid_addr,
    output logic          best_bid_valid,
    output logic [9:0]    best_ask_addr,
    output logic          best_ask_valid
);

    always_comb begin
        best_bid_addr  = '0;
        best_bid_valid = '0;
        best_ask_addr  = '0;
        best_ask_valid = '0;

        // bid: find highest set bit (best bid = highest price)
        for(int i = WINDOW_SIZE-1; i >= 0; i--) begin
            if(bid_mask[i] && !best_bid_valid) begin
                best_bid_addr  = i;
                best_bid_valid = 1;
            end
        end

        // ask: find lowest set bit (best ask = lowest price)
        for(int i = 0; i <= WINDOW_SIZE-1; i++) begin
            if(ask_mask[i] && !best_ask_valid) begin
                best_ask_addr  = i;
                best_ask_valid = 1;
            end
        end
    end

endmodule
