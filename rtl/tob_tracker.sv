module tob_tracker
    import fm24_pkg::*;
(
    input logic                       clk, arstn,
    input logic [ADDR_WIDTH-1:0]      best_bid_addr,
    input logic                       best_bid_valid,   
    input logic [ADDR_WIDTH-1:0]      best_ask_addr,
    input logic                       best_ask_valid,
    input logic [31:0]                read_bid_qty,
    input logic [31:0]                read_ask_qty,
    output fm24_tob_t                 tob
);

    logic [ADDR_WIDTH-1:0] reg_bid_addr;
    logic                  reg_bid_valid;
    logic [ADDR_WIDTH-1:0] reg_ask_addr;
    logic                  reg_ask_valid;

    always_ff @(posedge clk) begin
        if(!arstn) begin
            tob <= '0;
            reg_bid_addr  <= '0;
            reg_bid_valid <= '0;
            reg_ask_addr  <= '0;
            reg_ask_valid <= '0;
        end else begin
            reg_bid_addr  <= best_bid_addr;
            reg_bid_valid <= best_bid_valid;
            reg_ask_addr  <= best_ask_addr;
            reg_ask_valid <= best_ask_valid;

            tob.best_bid_price <= reg_bid_addr + BASE_PRICE;
            tob.best_bid_qty   <= read_bid_qty;
            tob.bid_valid      <= reg_bid_valid;
            tob.best_ask_price <= reg_ask_addr + BASE_PRICE;
            tob.best_ask_qty   <= read_ask_qty;
            tob.ask_valid      <= reg_ask_valid;
        end
    end


endmodule