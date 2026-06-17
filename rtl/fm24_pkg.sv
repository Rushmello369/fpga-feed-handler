package fm24_pkg;
    //costumized 24 bytes feed message
    //define constants
    localparam int unsigned MSG_BYTES = 24; //24 bytes msg
    localparam int unsigned MSG_BITS  = MSG_BYTES * 8; //192 bits 
    localparam int unsigned PRICE_SCALE = 100; //actual price * scale = stored price, depend on the precision
    //define top 2 bytes
    typedef enum logic [7:0] {
        MSG_ADD = 8'h01,
        MSG_CANCEL = 8'h02,
        MSG_EXECUTE = 8'h03
     } msg_type_e;

    typedef enum logic [7:0] {
        BUYER = 8'h00,
        SELLER = 8'h01
    } msg_side_e;
    //define the msg struct
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

    //flag input for feed parser
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

endpackage