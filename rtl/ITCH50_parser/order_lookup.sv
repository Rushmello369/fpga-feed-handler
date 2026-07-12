/*
 * order_lookup
 * ------------
 * Resolves price/side for ITCH Execute/Cancel/Delete events, which carry
 * only an order_id (no price/side on the wire). Also tracks each order's
 * remaining live quantity, because Delete ('D') carries no quantity - the
 * consumer must know how much was still resting to decrement the book.
 *
 * Structure: L1-only direct-indexed cache. Index = low TABLE_BITS of the
 * order_id (a zero-cost hash). Collisions (two live orders sharing low
 * bits) are resolved by silent overwrite on insert; a later query against
 * the evicted id reports res_hit=0. Deliberate simplification for a
 * single-stock replay where live order count stays well under 2^TABLE_BITS.
 * If the miss counter (kept at top level) shows this isn't holding,
 * either raise TABLE_BITS (AX7A200B has BRAM to spare) or add a DDR L2.
 *
 * Timing: IDLE -> READ -> WRITE, 3 cycles per operation, one op in flight.
 * The registered read in READ is the standard BRAM-inference pattern.
 */

module order_lookup
    import ITCH50_pkg::*;
#(
    parameter int TABLE_BITS = 14                    // 2^14 entries
)
(
    input  logic          clk, arstn,

    // insert port - drive on Add Order ('A'/'F') and on the re-insert
    // half of a decomposed Replace ('U')
    input  logic          ins_valid,
    input  logic [63:0]   ins_order_id,
    input  logic [31:0]   ins_price,
    input  logic [31:0]   ins_qty,
    input  logic          ins_side,      // 0=buy, 1=sell

    // query port - drive on Execute/Cancel/Delete (and the delete half of U)
    input  logic          qry_valid,
    input  logic [63:0]   qry_order_id,
    input  lookup_op_e    qry_op,
    input  logic [31:0]   qry_qty,       // shares in E/X message; ignored for D

    output logic          busy,          // high outside IDLE; hold inputs while busy

    // resolved result - res_valid pulses exactly 1 cycle, queries only
    output logic          res_valid,
    output logic          res_hit,       // 0 = unknown id (never inserted / evicted)
    output logic [31:0]   res_price,
    output logic          res_side,
    output logic [31:0]   res_delta_qty, // amount to subtract from the book
    output logic          res_removed    // 1 = order fully drained / deleted
);

    localparam int TABLE_SIZE = (1 << TABLE_BITS);
    localparam int TAG_BITS   = 64 - TABLE_BITS;

    typedef struct packed {
        logic                 valid;
        logic [TAG_BITS-1:0]  tag;    // high bits of order_id disambiguate
        logic [31:0]          price;
        logic                 side;
        logic [31:0]          qty;    // remaining live quantity
    } entry_t;

    entry_t table_mem [TABLE_SIZE];

    typedef enum logic [1:0] { IDLE, READ, WRITE } state_e;
    state_e curr_state, next_state;

    // request latched in IDLE, used through READ/WRITE
    logic                  req_is_insert;
    logic [TABLE_BITS-1:0] req_index;
    logic [TAG_BITS-1:0]   req_tag;
    logic [31:0]           req_price;
    logic [31:0]           req_qty;
    logic                  req_side;
    lookup_op_e            req_op;

    entry_t entry_rd;   // registered read of table_mem[req_index]

    assign busy = (curr_state != IDLE);

    always_comb begin
        next_state = curr_state;
        case (curr_state)
            IDLE:  if (ins_valid || qry_valid) next_state = READ;
            READ:  next_state = WRITE;
            WRITE: next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!arstn) begin
            curr_state    <= IDLE;
            res_valid     <= 1'b0;
            res_hit       <= 1'b0;
            res_price     <= '0;
            res_side      <= 1'b0;
            res_delta_qty <= '0;
            res_removed   <= 1'b0;
        end else begin
            curr_state <= next_state;
            res_valid  <= 1'b0;   // default: result strobe is a 1-cycle pulse

            case (curr_state)
                IDLE: begin
                    if (ins_valid) begin
                        req_is_insert <= 1'b1;
                        req_index     <= ins_order_id[TABLE_BITS-1:0];
                        req_tag       <= ins_order_id[63:TABLE_BITS];
                        req_price     <= ins_price;
                        req_qty       <= ins_qty;
                        req_side      <= ins_side;
                    end else if (qry_valid) begin
                        req_is_insert <= 1'b0;
                        req_index     <= qry_order_id[TABLE_BITS-1:0];
                        req_tag       <= qry_order_id[63:TABLE_BITS];
                        req_qty       <= qry_qty;
                        req_op        <= qry_op;
                    end
                end

                READ: begin
                    entry_rd <= table_mem[req_index];
                end

                WRITE: begin
                    if (req_is_insert) begin
                        entry_t new_entry;
                        new_entry.valid = 1'b1;
                        new_entry.tag   = req_tag;
                        new_entry.price = req_price;
                        new_entry.side  = req_side;
                        new_entry.qty   = req_qty;
                        // Silent-overwrite collision policy: newest live
                        // order wins the slot. Evicted order becomes a miss.
                        table_mem[req_index] <= new_entry;
                    end else begin
                        logic        hit;
                        logic [31:0] new_qty;
                        logic        removed;
                        entry_t      updated_entry;

                        hit = entry_rd.valid && (entry_rd.tag == req_tag);

                        if (hit) begin
                            if (req_op == OP_DELETE) begin
                                new_qty = '0;
                                removed = 1'b1;
                                res_delta_qty <= entry_rd.qty;  // all that remained
                            end else begin
                                // OP_EXECUTE / OP_CANCEL: remove req_qty shares,
                                // clamping at zero for safety
                                new_qty = (entry_rd.qty > req_qty)
                                            ? (entry_rd.qty - req_qty) : '0;
                                removed = (new_qty == '0);
                                res_delta_qty <= req_qty;
                            end

                            updated_entry       = entry_rd;
                            updated_entry.qty   = new_qty;
                            updated_entry.valid = !removed;   // free the slot when drained
                            table_mem[req_index] <= updated_entry;

                            res_hit     <= 1'b1;
                            res_price   <= entry_rd.price;
                            res_side    <= entry_rd.side;
                            res_removed <= removed;
                        end else begin
                            res_hit       <= 1'b0;
                            res_price     <= '0;
                            res_side      <= 1'b0;
                            res_delta_qty <= '0;
                            res_removed   <= 1'b0;
                        end

                        res_valid <= 1'b1;
                    end
                end
            endcase
        end
    end

endmodule