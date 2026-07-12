/*
 * event_dispatcher
 * ----------------
 * The traffic controller between itch_parser, order_lookup and book_update.
 * This module owns ALL the protocol business logic that spans modules:
 *
 *   Add (A/F):   insert into order_lookup  +  book_update add
 *                (both fired in parallel; price/side/qty are on the wire)
 *
 *   Exec (E/C),
 *   Cancel (X),
 *   Delete (D):  query order_lookup first (only order_id is on the wire),
 *                then book_update remove at the RESOLVED price/side.
 *                On E/C hits, additionally pulse the trade tap for the
 *                feature engine's trade-flow feature (side comes from
 *                res_side - the messages themselves never carry side).
 *
 *   Replace (U): two-step decomposition so order_lookup stays ignorant of
 *                Replace: (1) OP_DELETE query on the OLD id -> resolves old
 *                price/side + remaining qty, book removes it; (2) insert
 *                the NEW id at the new price/qty with the side INHERITED
 *                from step 1, book adds it. A step-1 miss aborts step 2
 *                (side unknown) and bumps miss_count.
 *
 * Handshake: ev_ready is high only in IDLE; the parser holds each event
 * until we take it, so there is exactly one event in flight end-to-end.
 * Misses (evicted/unknown order_ids) are counted, not fatal - with the
 * L1-only lookup table they are expected at some small rate.
 */

module event_dispatcher
    import ITCH50_pkg::*;
(
    input  logic          clk,
    input  logic          arstn,

    // event in from itch_parser
    input  itch_event_t   ev,
    input  logic          ev_valid,
    output logic          ev_ready,

    // order_lookup insert port
    output logic          ins_valid,
    output logic [63:0]   ins_order_id,
    output logic [31:0]   ins_price,
    output logic [31:0]   ins_qty,
    output logic          ins_side,

    // order_lookup query port
    output logic          qry_valid,
    output logic [63:0]   qry_order_id,
    output lookup_op_e    qry_op,
    output logic [31:0]   qry_qty,

    // order_lookup results
    input  logic          lk_busy,
    input  logic          res_valid,
    input  logic          res_hit,
    input  logic [31:0]   res_price,
    input  logic          res_side,
    input  logic [31:0]   res_delta_qty,
    input  logic          res_removed,

    // book_update command port
    output logic          bu_valid,
    output logic          bu_is_add,     // 1 = add liquidity, 0 = remove
    output logic [31:0]   bu_price,
    output logic [31:0]   bu_qty,
    output logic          bu_side,
    input  logic          bu_ready,      // book_update in IDLE

    // trade tap for feature_engine's TFLOW (pulses on E/C hits only)
    output logic          trade_valid,
    output logic          trade_side,
    output logic [31:0]   trade_qty,

    // diagnostics
    output logic [31:0]   miss_count     // lookup misses (evictions/unknown ids)
);

    typedef enum logic [2:0] {
        IDLE,          // waiting for an event from the parser
        ADD_ISSUE,     // firing insert + book add for A/F (parallel, 1 cycle)
        ADD_WAIT,      // waiting for book_update to accept / lookup to finish
        QRY_ISSUE,     // firing the lookup query for E/C/X/D (and U step 1)
        QRY_WAIT,      // waiting for res_valid
        BOOK_REMOVE,   // pushing the resolved removal into book_update
        RPL_WAIT,      // U: wait for book to actually accept the remove before
                       //    issuing the step-2 add (closes a back-to-back race)
        RPL_INSERT     // U step 2: insert new id + book add at new price
    } state_e;

    state_e       state;
    itch_event_t  cur;          // event being processed
    logic         is_replace;   // distinguishes U's remove from plain E/X/D
    logic         rpl_side;     // side inherited from U step-1 resolution
    logic [31:0]  rm_price;     // latched resolution for the remove step
    logic [31:0]  rm_qty;
    logic         rm_side;

    assign ev_ready = (state == IDLE);

    always_ff @(posedge clk) begin
        if (!arstn) begin
            state        <= IDLE;
            cur          <= '0;
            is_replace   <= 1'b0;
            rpl_side     <= 1'b0;
            rm_price     <= '0;
            rm_qty       <= '0;
            rm_side      <= 1'b0;
            ins_valid    <= 1'b0;
            ins_order_id <= '0;
            ins_price    <= '0;
            ins_qty      <= '0;
            ins_side     <= 1'b0;
            qry_valid    <= 1'b0;
            qry_order_id <= '0;
            qry_op       <= OP_EXECUTE;
            qry_qty      <= '0;
            bu_valid     <= 1'b0;
            bu_is_add    <= 1'b0;
            bu_price     <= '0;
            bu_qty       <= '0;
            bu_side      <= 1'b0;
            trade_valid  <= 1'b0;
            trade_side   <= 1'b0;
            trade_qty    <= '0;
            miss_count   <= '0;
        end else begin
            // strobes default low; each is asserted for exactly one cycle
            ins_valid   <= 1'b0;
            qry_valid   <= 1'b0;
            bu_valid    <= 1'b0;
            trade_valid <= 1'b0;

            case (state)
                // ------------------------------------------------------------
                IDLE: begin
                    if (ev_valid) begin
                        cur        <= ev;
                        is_replace <= (ev.msg_type == MSG_TYPE_REPLACE);
                        case (ev.msg_type)
                            MSG_TYPE_ADD, MSG_TYPE_ADD_MPID: state <= ADD_ISSUE;
                            MSG_TYPE_EXEC, MSG_TYPE_EXEC_PRICE,
                            MSG_TYPE_CANCEL, MSG_TYPE_DELETE,
                            MSG_TYPE_REPLACE:                state <= QRY_ISSUE;
                            default:                         state <= IDLE; // shouldn't happen
                        endcase
                    end
                end

                // ------------------------------------------------------------
                // Add path: everything is on the wire, so the lookup insert
                // and the book add can be fired in the same cycle. They run
                // independently (lookup takes 3 cycles, book takes its own);
                // ADD_WAIT holds until both are idle again.
                ADD_ISSUE: begin
                    if (!lk_busy && bu_ready) begin
                        ins_valid    <= 1'b1;
                        ins_order_id <= cur.order_id;
                        ins_price    <= cur.price;
                        ins_qty      <= cur.shares;
                        ins_side     <= cur.side;

                        bu_valid     <= 1'b1;
                        bu_is_add    <= 1'b1;
                        bu_price     <= cur.price;
                        bu_qty       <= cur.shares;
                        bu_side      <= cur.side;

                        state <= ADD_WAIT;
                    end
                end

                ADD_WAIT: begin
                    // one cycle after the strobes, busy/ready reflect the new op;
                    // return to IDLE once both units have drained
                    if (!lk_busy && bu_ready) state <= IDLE;
                end

                // ------------------------------------------------------------
                // Resolution path for E/C/X/D and U step 1
                QRY_ISSUE: begin
                    if (!lk_busy) begin
                        qry_valid    <= 1'b1;
                        qry_order_id <= cur.order_id;
                        qry_qty      <= cur.shares;
                        case (cur.msg_type)
                            MSG_TYPE_CANCEL:  qry_op <= OP_CANCEL;
                            MSG_TYPE_DELETE,
                            MSG_TYPE_REPLACE: qry_op <= OP_DELETE; // U removes ALL old qty
                            default:          qry_op <= OP_EXECUTE; // E and C
                        endcase
                        state <= QRY_WAIT;
                    end
                end

                QRY_WAIT: begin
                    if (res_valid) begin
                        if (res_hit) begin
                            // latch resolution; book command issued next state
                            rm_price <= res_price;
                            rm_qty   <= res_delta_qty;
                            rm_side  <= res_side;
                            rpl_side <= res_side;   // U step 2 inherits this
                            state    <= BOOK_REMOVE;

                            // trade tap: executions only (E/C), not X/D/U -
                            // cancellations are not trades
                            if (cur.msg_type == MSG_TYPE_EXEC ||
                                cur.msg_type == MSG_TYPE_EXEC_PRICE) begin
                                trade_valid <= 1'b1;
                                trade_side  <= res_side;
                                trade_qty   <= res_delta_qty;
                            end
                        end else begin
                            // evicted or never-seen order_id: count and move on;
                            // for U we must also skip step 2 (side unknown)
                            miss_count <= miss_count + 1;
                            state      <= IDLE;
                        end
                    end
                end

                BOOK_REMOVE: begin
                    if (bu_ready) begin
                        bu_valid  <= 1'b1;
                        bu_is_add <= 1'b0;
                        bu_price  <= rm_price;
                        bu_qty    <= rm_qty;
                        bu_side   <= rm_side;
                        state     <= is_replace ? RPL_WAIT : IDLE;
                    end
                end

                // ------------------------------------------------------------
                // U: the remove strobe above is registered, so book_update only
                // samples it on the NEXT cycle and drops bu_ready the cycle
                // after that. Wait for bu_ready to actually fall (book has taken
                // the remove) before RPL_INSERT re-checks it - otherwise
                // RPL_INSERT sees a STALE bu_ready=1 and fires the step-2 add
                // strobe while the book is still busy with the remove, and the
                // add is silently dropped (the Replace's new order is lost).
                RPL_WAIT: begin
                    if (!bu_ready) state <= RPL_INSERT;
                end

                // ------------------------------------------------------------
                // U step 2: new order at new price/qty, side inherited
                RPL_INSERT: begin
                    if (!lk_busy && bu_ready) begin
                        ins_valid    <= 1'b1;
                        ins_order_id <= cur.new_order_id;
                        ins_price    <= cur.price;      // NEW price from the U message
                        ins_qty      <= cur.shares;     // NEW quantity
                        ins_side     <= rpl_side;       // inherited from step 1

                        bu_valid     <= 1'b1;
                        bu_is_add    <= 1'b1;
                        bu_price     <= cur.price;
                        bu_qty       <= cur.shares;
                        bu_side      <= rpl_side;

                        state <= ADD_WAIT;   // same drain-wait as a plain Add
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule