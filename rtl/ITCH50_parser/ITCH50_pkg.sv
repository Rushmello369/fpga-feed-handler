/*
 * ITCH50_pkg
 * ----------
 * Shared "vocabulary" for the v2 ITCH pipeline. This package contains ONLY:
 *   - protocol constants (message type bytes, side indicators, price scale)
 *   - lookup tables derived directly from the NASDAQ ITCH 5.0 spec
 *   - shared data shapes (structs / enums) passed between modules
 *   - small pure functions (no state, no timing)
 * No FSMs or per-module business logic belongs here.
*/

package ITCH50_pkg;

    // Fixed-point price convention per ITCH 5.0 spec section 3 (Data Types):
    // a "Price (4)" field has 4 implied decimal places, i.e.
    //   integer_on_wire = actual_price_in_dollars * 10000
    localparam int unsigned PRICE_SCALE = 10000;

    // NASDAQ quotes US equities in penny ticks. One tick = $0.01 = 100 units
    // of the Price(4) integer. Used to convert a raw price word into a
    // book-window index (constant division; synthesizes to multiply-shift).
    localparam int unsigned TICK_SIZE = 100;

    // ------------------------------------------------------------------
    // Message type bytes (ASCII, straight from spec section 4 tables)
    // ------------------------------------------------------------------
    localparam logic [7:0]  MSG_TYPE_ADD          = "A";
    localparam logic [7:0]  MSG_TYPE_ADD_MPID     = "F";
    localparam logic [7:0]  MSG_TYPE_EXEC         = "E";
    localparam logic [7:0]  MSG_TYPE_EXEC_PRICE   = "C";
    localparam logic [7:0]  MSG_TYPE_CANCEL       = "X";
    localparam logic [7:0]  MSG_TYPE_DELETE       = "D";
    localparam logic [7:0]  MSG_TYPE_REPLACE      = "U";
    localparam logic [7:0]  MSG_TYPE_EVENT        = "S";
    localparam logic [7:0]  MSG_TYPE_STOCK_DIRECT = "R";

    // Buy/Sell Indicator values inside Add Order messages (spec 4.3.1)
    localparam logic [7:0]  MSG_SIDE_BUY          = "B";
    localparam logic [7:0]  MSG_SIDE_SELL         = "S";

    // ------------------------------------------------------------------
    // order_lookup operation code. Note there is deliberately NO OP_REPLACE:
    // Replace ('U') is decomposed by the event dispatcher into an OP_DELETE
    // query on the old order_id followed by a fresh insert of the new one,
    // so order_lookup never needs to know Replace exists.
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {
        OP_EXECUTE = 2'b00,   // E/C: qty field = shares removed this event
        OP_CANCEL  = 2'b01,   // X:   qty field = shares cancelled
        OP_DELETE  = 2'b10    // D:   no qty on wire; remove all remaining
    } lookup_op_e;

    // ------------------------------------------------------------------
    // Per-type total message length in bytes (spec section 4, computed as
    // last field offset + length). Unknown types return 0.
    // Used by itch_parser as a self-check: the 2-byte length prefix in the
    // capture file must equal msg_length(type) for every known type.
    //
    // NOTE ON FORM: originally written as a 256-entry localparam array with
    // keyed assignment-pattern initialization (index = ASCII byte). Vivado
    // UG901 lists array assignment patterns as supported, but Icarus
    // Verilog rejects that construct for localparam arrays - so to keep ONE
    // codebase compiling in both simulator and synthesis, both LUTs are
    // expressed as constant functions with case statements. Synthesis
    // still reduces a constant-input case to the same LUT/ROM logic.
    // ------------------------------------------------------------------
    function automatic int unsigned msg_length(input logic [7:0] msg_type);
        case (msg_type)
            MSG_TYPE_ADD:          return 36;
            MSG_TYPE_ADD_MPID:     return 40;
            MSG_TYPE_EXEC:         return 31;
            MSG_TYPE_EXEC_PRICE:   return 36;
            MSG_TYPE_CANCEL:       return 23;
            MSG_TYPE_DELETE:       return 19;
            MSG_TYPE_REPLACE:      return 35;
            MSG_TYPE_EVENT:        return 12;
            MSG_TYPE_STOCK_DIRECT: return 39;
            default:               return 0;
        endcase
    endfunction

    // Does this message type change the order book? Admin messages (S, R)
    // and unknown types return 0 and are skipped without field extraction.
    function automatic logic is_book_affecting(input logic [7:0] msg_type);
        case (msg_type)
            MSG_TYPE_ADD, MSG_TYPE_ADD_MPID,
            MSG_TYPE_EXEC, MSG_TYPE_EXEC_PRICE,
            MSG_TYPE_CANCEL, MSG_TYPE_DELETE,
            MSG_TYPE_REPLACE: return 1'b1;
            default:          return 1'b0;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Unified parsed-event record emitted by itch_parser.
    // One shape for all message types; fields that a given type does not
    // carry are left zero. Packed so it can be flattened onto a bus later.
    //
    // Field semantics per type:
    //   A/F : order_id, side, shares, price all valid
    //   E   : order_id, shares(=executed shares)
    //   C   : order_id, shares(=executed shares), price(=execution price,
    //         informational only - the resting book level does not move)
    //   X   : order_id, shares(=cancelled shares)
    //   D   : order_id only
    //   U   : order_id(=OLD id), new_order_id, shares(=new qty),
    //         price(=new price); side is NOT on the wire (inherited from
    //         the original order, recovered via order_lookup)
    // ------------------------------------------------------------------
    typedef struct packed {
        logic [7:0]   msg_type;
        logic [15:0]  stock_locate;
        logic [63:0]  order_id;      // for U this is the OLD reference number
        logic [63:0]  new_order_id;  // only meaningful for U
        logic [31:0]  price;         // Price(4) integer, i.e. dollars*10000
        logic [31:0]  shares;
        logic         side;          // 0 = buy, 1 = sell (only valid for A/F)
    } itch_event_t;

    // ------------------------------------------------------------------
    // Top-of-book snapshot passed from tob_tracker to feature_engine.
    // Prices are carried as WINDOW TICK INDICES (address within the book
    // window), not raw Price(4) words. This is deliberate: differences of
    // indices are already in units of ticks, so spread / mid / momentum
    // computations need no division anywhere downstream.
    // ------------------------------------------------------------------
    typedef struct packed {
        logic [15:0]  bid_idx;   // window index of best bid
        logic [31:0]  bid_qty;   // aggregate shares resting at best bid
        logic [15:0]  ask_idx;   // window index of best ask
        logic [31:0]  ask_qty;   // aggregate shares resting at best ask
    } tob_t;

    // ------------------------------------------------------------------
    // Saturate a signed 32-bit value into signed 16 bits (clamp, no wrap).
    // Shared by feature_engine; the Python golden model MUST implement the
    // exact same clamp so training data matches hardware bit-for-bit.
    // ------------------------------------------------------------------
    function automatic logic signed [15:0] sat16(input logic signed [31:0] x);
        if (x > 32'sd32767)       return 16'sd32767;
        else if (x < -32'sd32768) return -16'sd32768;
        else                      return x[15:0];
    endfunction

endpackage