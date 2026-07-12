/*
 * itch_parser
 * -----------
 * Byte-serial decoder for the NASDAQ sample-file framing:
 *
 *     [2-byte big-endian length N][N-byte ITCH message body] [repeat...]
 *
 * The first byte of every body is the message type. Fields are extracted
 * at fixed offsets per type (spec section 4). Big-endian means the first
 * byte received is the MOST significant, so multi-byte fields are built
 * by left-shifting bytes in as they arrive - no byte reversal needed.
 *
 * Output is one itch_event_t per book-affecting message, held stable with
 * ev_valid asserted until the consumer (event_dispatcher) raises ev_ready.
 * While waiting, s_tready is deasserted (backpressure to the DMA/link).
 *
 * Self-check: for every known type, the framing length prefix must equal
 * MSG_LENGTH[type]; a mismatch pulses parse_error and the event is NOT
 * emitted (a length mismatch means upstream framing is misaligned and the
 * field offsets cannot be trusted). Unknown types are skipped silently
 * and counted in unknown_count.
 */

module itch_parser
    import ITCH50_pkg::*;
#(
    // ------------------------------------------------------------------
    // Single-instrument filter. A full-day ITCH capture interleaves every
    // NASDAQ symbol; this book is single-stock, so unless upstream is
    // pre-filtered, drop every book-affecting message whose stock_locate
    // does not match FILTER_LOCATE. FILTER_LOCATE must be calibrated to the
    // same instrument/day as book_update's BASE_PRICE (both come from that
    // day's Stock Directory 'R' message for the target ticker).
    // FILTER_EN=0 disables filtering (accept all symbols) for the smoke test
    // or when the feed is already single-stock.
    // ------------------------------------------------------------------
    parameter bit          FILTER_EN     = 1'b0,
    parameter logic [15:0] FILTER_LOCATE = 16'd0
)(
    input  logic          clk,
    input  logic          arstn,

    // upstream byte stream (from XDMA H2C AXI-Stream, 8-bit tdata)
    input  logic          s_tvalid,
    input  logic  [7:0]   s_tdata,
    output logic          s_tready,

    // parsed event, valid/ready handshake to event_dispatcher
    output itch_event_t   ev,
    output logic          ev_valid,
    input  logic          ev_ready,

    // diagnostics (wire to AXI-Lite status registers at top level)
    output logic          parse_error,     // 1-cycle pulse on length mismatch
    output logic [31:0]   unknown_count,   // messages of unrecognized type
    output logic [31:0]   msg_count,       // total messages seen (any type)
    output logic [31:0]   filtered_count   // book msgs dropped by stock filter
);

    typedef enum logic [2:0] {
        RD_LEN_HI,   // first byte of the 2-byte big-endian length prefix
        RD_LEN_LO,   // second byte of the length prefix
        RD_BODY,     // consuming msg_len body bytes, extracting fields
        EMIT         // holding ev_valid until dispatcher takes it
    } state_e;

    state_e       state;
    logic [15:0]  msg_len;    // from the framing prefix
    logic [15:0]  idx;        // byte position within the current body (0-based)
    logic [7:0]   mtype;      // body byte 0, latched for fast branching

    // Ready for a new byte in every state except EMIT (backpressure while
    // the dispatcher is still working on the previous event).
    assign s_tready = (state != EMIT);

    always_ff @(posedge clk) begin
        if (!arstn) begin
            state         <= RD_LEN_HI;
            msg_len       <= '0;
            idx           <= '0;
            mtype         <= '0;
            ev            <= '0;
            ev_valid      <= 1'b0;
            parse_error   <= 1'b0;
            unknown_count <= '0;
            msg_count     <= '0;
            filtered_count<= '0;
        end else begin
            parse_error <= 1'b0;   // default: error is a 1-cycle pulse

            case (state)
                // ----------------------------------------------------------
                RD_LEN_HI: begin
                    if (s_tvalid) begin
                        msg_len[15:8] <= s_tdata;   // big-endian: high byte first
                        state         <= RD_LEN_LO;
                    end
                end

                // ----------------------------------------------------------
                RD_LEN_LO: begin
                    if (s_tvalid) begin
                        msg_len[7:0] <= s_tdata;
                        idx          <= '0;
                        ev           <= '0;        // clear all fields; unused ones stay 0
                        state        <= RD_BODY;
                    end
                end

                // ----------------------------------------------------------
                RD_BODY: begin
                    if (s_tvalid) begin
                        // Byte 0 of every message is its type; latch it so the
                        // per-type field extraction below can branch on it.
                        if (idx == 0) begin
                            mtype       <= s_tdata;
                            ev.msg_type <= s_tdata;
                        end

                        // stock_locate occupies bytes 1-2 in EVERY message type
                        // (spec guarantees same position for cheap filtering)
                        if (idx == 1) ev.stock_locate[15:8] <= s_tdata;
                        if (idx == 2) ev.stock_locate[7:0]  <= s_tdata;

                        // ---- per-type field extraction --------------------
                        // Multi-byte big-endian fields: shift each new byte
                        // into the low end; after the last byte the value is
                        // complete and correctly ordered.
                        case (mtype)
                            MSG_TYPE_ADD, MSG_TYPE_ADD_MPID: begin
                                // A: order_id 11-18, side 19, shares 20-23,
                                //    stock 24-31 (ignored), price 32-35
                                // F adds attribution 36-39 (ignored)
                                if (idx >= 11 && idx <= 18)
                                    ev.order_id <= {ev.order_id[55:0], s_tdata};
                                if (idx == 19)
                                    ev.side <= (s_tdata == MSG_SIDE_SELL);
                                if (idx >= 20 && idx <= 23)
                                    ev.shares <= {ev.shares[23:0], s_tdata};
                                if (idx >= 32 && idx <= 35)
                                    ev.price <= {ev.price[23:0], s_tdata};
                            end

                            MSG_TYPE_EXEC, MSG_TYPE_EXEC_PRICE, MSG_TYPE_CANCEL: begin
                                // E: order_id 11-18, executed shares 19-22
                                // C: same + printable 31 (ignored) + price 32-35
                                // X: order_id 11-18, cancelled shares 19-22
                                if (idx >= 11 && idx <= 18)
                                    ev.order_id <= {ev.order_id[55:0], s_tdata};
                                if (idx >= 19 && idx <= 22)
                                    ev.shares <= {ev.shares[23:0], s_tdata};
                                // C's execution price is informational only (the
                                // resting level doesn't move) but capture it for
                                // completeness / future trade-tape use:
                                if (mtype == MSG_TYPE_EXEC_PRICE &&
                                    idx >= 32 && idx <= 35)
                                    ev.price <= {ev.price[23:0], s_tdata};
                            end

                            MSG_TYPE_DELETE: begin
                                // D: order_id 11-18, nothing else
                                if (idx >= 11 && idx <= 18)
                                    ev.order_id <= {ev.order_id[55:0], s_tdata};
                            end

                            MSG_TYPE_REPLACE: begin
                                // U: old order_id 11-18, new order_id 19-26,
                                //    new shares 27-30, new price 31-34.
                                // Side is NOT on the wire - dispatcher recovers
                                // it from order_lookup via the delete step.
                                if (idx >= 11 && idx <= 18)
                                    ev.order_id <= {ev.order_id[55:0], s_tdata};
                                if (idx >= 19 && idx <= 26)
                                    ev.new_order_id <= {ev.new_order_id[55:0], s_tdata};
                                if (idx >= 27 && idx <= 30)
                                    ev.shares <= {ev.shares[23:0], s_tdata};
                                if (idx >= 31 && idx <= 34)
                                    ev.price <= {ev.price[23:0], s_tdata};
                            end

                            default: ;  // admin/unknown: consume bytes, extract nothing
                        endcase

                        // ---- end-of-message bookkeeping --------------------
                        if (idx == msg_len - 1) begin
                            msg_count <= msg_count + 1;
                            state     <= RD_LEN_HI;   // default next state

                            if (msg_length(mtype) == 0 && idx != 0) begin
                                // recognized nothing: not one of our types
                                unknown_count <= unknown_count + 1;
                            end else if (msg_length(mtype) != msg_len) begin
                                // known type but framing length disagrees with
                                // the spec: upstream is misaligned. Do NOT emit.
                                parse_error <= 1'b1;
                            end else if (is_book_affecting(mtype)) begin
                                // single-instrument filter: only emit events
                                // for the target symbol. stock_locate was
                                // latched at idx 1-2, stable by end-of-message.
                                if (!FILTER_EN || ev.stock_locate == FILTER_LOCATE) begin
                                    ev_valid <= 1'b1;
                                    state    <= EMIT;
                                end else begin
                                    filtered_count <= filtered_count + 1;
                                    // wrong symbol: drop, stay in RD_LEN_HI
                                end
                            end
                            // book-irrelevant known types (S, R) fall through
                            // to RD_LEN_HI with no event.
                        end else begin
                            idx <= idx + 1;
                        end
                    end
                end

                // ----------------------------------------------------------
                EMIT: begin
                    if (ev_ready) begin
                        ev_valid <= 1'b0;
                        state    <= RD_LEN_HI;
                    end
                end

                default: state <= RD_LEN_HI;
            endcase
        end
    end

endmodule