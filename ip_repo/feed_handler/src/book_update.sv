//this module receive cmd from parser, and when qty_valid == 1:
//computes addr from cmd.price
//updates qty at that addr
//updates mask signal
module book_update 
    import fm24_pkg::*;
(
    //control signal from parser
    input fm24_valid_t   valid,
    input fm24_cmd_t     cmd,
    input logic          clk, arstn,
    //update masks — port widths hardcoded for IP Packager compatibility
    output logic [1023:0] bid_mask,
    output logic [1023:0] ask_mask,
    //access to qty of a given address (ADDR_WIDTH = $clog2(1024) = 10)
    input  logic [9:0]   read_bid_addr,
    output logic [31:0]  read_bid_qty,
    input  logic [9:0]   read_ask_addr,
    output logic [31:0]  read_ask_qty
);

    logic [31:0] bid_array [WINDOW_SIZE];
    logic [31:0] ask_array [WINDOW_SIZE];

    typedef enum logic [1:0] { 
        IDLE  = 2'b00,
        READ  = 2'b01,
        WRITE = 2'b10
    } state_e;

    state_e curr_state, next_state;

    logic [ADDR_WIDTH-1:0] addr;
    fm24_cmd_t             reg_cmd;
    logic [31:0]           old_qty;
    logic [31:0]           new_qty;

    always_comb begin
        next_state = curr_state;
    
        case(curr_state) 
            IDLE: begin
                if(valid.qty_valid && cmd.price >= BASE_PRICE && cmd.price < BASE_PRICE + WINDOW_SIZE) begin
                    next_state = READ;
                end
            end
            READ: begin
                next_state = WRITE;
            end
            WRITE: begin
                next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if(!arstn) begin
            curr_state <= IDLE;
            bid_mask   <= '0;
            ask_mask   <= '0;
            addr       <= '0;
            reg_cmd    <= '0;
            old_qty    <= '0;
        end else begin
            curr_state <= next_state;
            case(curr_state)
                IDLE: begin
                    if(valid.qty_valid && cmd.price >= BASE_PRICE && cmd.price < BASE_PRICE + WINDOW_SIZE) begin
                        addr    <= cmd.price - BASE_PRICE;
                        reg_cmd <= cmd;
                    end
                end
                READ: begin
                    if(reg_cmd.side == BUYER) begin
                        old_qty <= bid_array[addr];
                    end else begin
                        old_qty <= ask_array[addr];
                    end          
                end
                WRITE: begin
                    if (is_remove_op(reg_cmd.msg_type))
                        new_qty = (old_qty > reg_cmd.qty) ? old_qty - reg_cmd.qty : '0;
                    else
                        new_qty = old_qty + reg_cmd.qty;
                    if (reg_cmd.side == BUYER) begin
                        bid_array[addr] <= new_qty;
                        bid_mask[addr]  <= (new_qty > 0);
                    end else begin
                        ask_array[addr] <= new_qty;
                        ask_mask[addr]  <= (new_qty > 0);
                    end          
                end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if(!arstn) begin
            read_bid_qty <= '0;
            read_ask_qty <= '0;
        end else begin
            read_bid_qty <= bid_array[read_bid_addr];
            read_ask_qty <= ask_array[read_ask_addr];
        end
    end

endmodule
