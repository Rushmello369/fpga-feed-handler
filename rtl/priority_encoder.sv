module priority_encoder 
    import fm24_pkg::*;
(
    input  logic [WINDOW_SIZE-1:0]     bid_mask,
    input  logic [WINDOW_SIZE-1:0]     ask_mask,
    output logic [ADDR_WIDTH-1:0]      best_bid_addr,
    output logic                       bid_valid,   
    output logic [ADDR_WIDTH-1:0]      best_ask_addr,
    output logic                       ask_valid
);

    always_comb begin
        logic bid_found;
        logic ask_found;
        bid_found = '0;
        ask_found = '0;

        best_bid_addr = '0;
        bid_valid = '0;
        best_ask_addr = '0;
        ask_valid = '0;

        for(int i = WINDOW_SIZE - 1; i >= 0; i--) begin
            if(bid_mask[i] && !bid_found) begin
                best_bid_addr = i;
                bid_found = 1;
                bid_valid = 1;
            end
        end
        for(int i = 0; i <= WINDOW_SIZE - 1; i++) begin
            if(ask_mask[i] && !ask_found) begin
                best_ask_addr = i;
                ask_found = 1;
                ask_valid = 1;
            end
        end
    end

endmodule