package fm24_pkg;
    //Customized 24-Byte feed message type(Designed based on ITCH)
    //Message constants 
    localparam int unsigned MSG_BYTES = 24;             //Message Bytes number
    localparam int unsigned MSG_BITS  = MSG_BYTES * 8;  //Message Bits number
    localparam int unsigned PRICE_SCALE = 100;          //fixed-point price convertion: Actual Price * PRICE_SCALE = Price word in fm24
    
    /*LOB Price window constants
    Constraints: This design only contains a fixed range of price range, rather than a full market depth LOB
    Price Range = [BASE_PRICE, BASE_PRICE + WINDOW_SIZE)
    Any order exceeding this window will be abandoned (details in book_update.sv)
    */

    localparam int unsigned BASE_PRICE   = 14500;   
    localparam int unsigned WINDOW_SIZE  = 1024;   
    localparam int unsigned ADDR_WIDTH   = $clog2(WINDOW_SIZE);  // address width, update automatically with WINDOW_SIZE
                                                                 //note that the address width in other code(book_update/priority_encoder) will not automatically updated

    //byte 0 : message type
    typedef enum logic [7:0] {
        MSG_ADD = 8'h01,
        MSG_CANCEL = 8'h02,
        MSG_EXECUTE = 8'h03
    } msg_type_e;
    //byte 1: order side
    typedef enum logic [7:0] {
        BUYER = 8'h00,
        SELLER = 8'h01
    } msg_side_e;
    //Full 24-byte (192-bit) wire message layout
    typedef struct packed {
        logic [7:0] msg_type;
        logic [7:0] side;
        logic [15:0] symbol_id;
        logic [31:0] order_id;
        logic [31:0] price;
        logic [31:0] qty;
        logic [31:0] exec_qty;
        logic [31:0] seq;
    } fm24_t;

    //field-valid flags, one bit per fm24_t field(pulses)
    typedef struct packed {
        logic msg_type_valid;
        logic side_valid;
        logic symbol_id_valid;
        logic order_id_valid;
        logic price_valid;
        logic qty_valid;
        logic exec_qty_valid;
        logic seq_valid;
    } fm24_valid_t;

    //[159:0] cmd input for book_update, remove order_id&exec_qty
    typedef struct packed {
        logic [7:0]  msg_type;
        logic [7:0]  side;
        logic [15:0] symbol_id;
        logic [31:0] price;
        logic [31:0] qty;
        logic [31:0] seq;
    } fm24_cmd_t;

    //top of book output from book_update, index_array mapping in BRAM
    typedef struct packed {
        logic [31:0] best_bid_price;
        logic [31:0] best_bid_qty;
        logic bid_valid;
        logic [31:0] best_ask_price;
        logic [31:0] best_ask_qty;
        logic ask_valid;
    } fm24_tob_t;

    //error flags
    typedef struct packed {
        logic parse_error; //1 if the msg_type undefined
        logic seq_error; //1 if there are package lost
        logic length_error; //tlast arrives at wrong byte
    } fm24_err_t;

    //helper function 1: check msg type
    function automatic logic is_valid_msg_type(input logic [7:0] x);
        return (x == MSG_ADD) || (x == MSG_CANCEL) || (x == MSG_EXECUTE);
    endfunction
    //helper function 2: check side
    function automatic logic is_valid_side(input logic [7:0] x);
        return (x == BUYER) || (x == SELLER); 
    endfunction
    //helper function 3: check remove operation
    function automatic logic is_remove_op (input logic [7:0] x);
        return (x == MSG_CANCEL) || (x == MSG_EXECUTE);
    endfunction
endpackage