/*
 * latency_probe
 * -------------
 * Non-invasive cycle-accurate latency instrumentation for the ITCH pipeline.
 * It only OBSERVES existing strobes - no back-pressure, no handshake, no
 * effect whatsoever on the datapath. Removing it cannot change behaviour.
 *
 * MEASUREMENT DEFINITION (口径) - state this whenever quoting a number:
 *
 *   t_total = cycles from `ev_handoff` (itch_parser hands a validated event
 *             to event_dispatcher) to the FIRST `feat_valid` produced by
 *             that event.
 *
 *   It EXCLUDES the UART wire time and the parser's byte-shifting, so it is
 *   a pure core-processing number, independent of whatever transport is
 *   feeding the design. That is the entire point: the current bring-up
 *   transport (1 Mbaud UART, 10 us per byte) is ~3 orders of magnitude
 *   slower than the core, so any end-to-end number would be a measurement
 *   of the UART, not of this pipeline.
 *
 *   It decomposes exactly:
 *
 *     ev_handoff --t_resolve--> book_updated --t_book2tob--> tob_valid
 *                --t_tob2feat--> feat_valid
 *     |<---------------------- t_total ------------------------------>|
 *
 *     t_resolve   : event_dispatcher FSM + order_lookup + book_update
 *                   (data dependent: ~7 for Add, ~12 for Execute/Cancel)
 *     t_book2tob  : priority_encoder + tob_tracker    (expect a CONSTANT 5)
 *     t_tob2feat  : feature_engine                    (expect a CONSTANT 1)
 *
 *   The 5 is tob_tracker's own published budget: +2 for the encoder's
 *   two-stage pipe, +1 for the read address to settle, +1 for the registered
 *   read data to return, +1 for the output register. Both of these stages are
 *   fixed-latency chains with no data dependence, so anything other than 5
 *   and 1 is a BUG, not a measurement - the probe doubles as a live assertion.
 *
 *   lat_ia_* = interarrival, i.e. cycles between consecutive ev_handoff
 *   pulses. Under UART this IS the transport cost, measured on the same
 *   clock and the same run as t_total, which turns "the transport dominates
 *   the core by ~800x" from a calculation into evidence with both halves
 *   measured rather than one measured and one asserted.
 *
 * WHY TIMESTAMPS TRAVEL WITH THE EVENT
 *   event_dispatcher returns to IDLE (and can therefore accept the NEXT
 *   event) roughly 5 cycles BEFORE the current event's feature emerges -
 *   ADD_WAIT only waits for book_update to drain, while tob_tracker still
 *   owes 4 cycles and feature_engine 1 more. A naive single "armed" flag
 *   would be clobbered by the next event whenever the feed runs near line
 *   rate. So each stage latches its own copy of the originating timestamp
 *   (ts_a -> ts_b -> ts_c) and its own stage-entry time, and every subtract
 *   uses only registers owned by that stage.
 *
 *   Replace ('U') emits TWO book updates for ONE event. The first consumes
 *   valid_a; the second finds it already cleared and propagates nothing.
 *   Hence the "FIRST feature" wording above - a U is timed on its delete
 *   half.
 *
 *   lat_unmatched counts events that were accepted but never reached the
 *   book at all (order_lookup miss, or a one-sided book suppressing
 *   tob_valid). Without this the probe would silently attribute the NEXT
 *   event's feature to the abandoned one - a wrong number that looks
 *   perfectly plausible.
 *
 * All counters are free-running and saturating-free (32-bit wrap). `cycle`
 * wraps every ~43 s at 100 MHz; every subtract is modulo-2^32, so a
 * measurement spanning a wrap is still correct as long as the interval
 * itself is < 2^32 cycles.
 */

module latency_probe (
    input  logic        clk,
    input  logic        arstn,

    // ---- taps: 1-cycle strobes observed from top_v2 ----
    input  logic        ev_handoff,     // ev_valid && ev_ready
    input  logic        book_updated,
    input  logic        tob_valid,
    input  logic        feat_valid,

    // ---- results: wired into the status frame ----
    output logic [31:0] lat_last,       // t_total, most recent
    output logic [31:0] lat_min,
    output logic [31:0] lat_max,
    output logic [31:0] lat_sum,        // host computes mean = sum / count
    output logic [31:0] lat_count,
    output logic [31:0] lat_resolve,    // stage 1, most recent
    output logic [31:0] lat_book2tob,   // stage 2, most recent (expect 4)
    output logic [31:0] lat_tob2feat,   // stage 3, most recent (expect 1)
    output logic [31:0] lat_ia_last,    // interarrival, most recent
    output logic [31:0] lat_ia_min,     // interarrival, smallest seen
    output logic [31:0] lat_unmatched   // events that produced no feature
);

    logic [31:0] cycle;                 // free-running cycle counter

    // per-stage timestamp carriers (the "event" travelling through the probe)
    logic [31:0] ts_a;                  // when the event was accepted
    logic [31:0] ts_b,  tsb_book;       // origin ts + when its book write landed
    logic [31:0] ts_c,  tsc_tob;        // origin ts + when its snapshot published
    logic        valid_a, valid_b, valid_c;

    // interarrival tracking
    logic [31:0] ts_prev_ev;
    logic        have_prev_ev;

    always_ff @(posedge clk) begin
        if (!arstn) begin
            cycle         <= '0;
            ts_a          <= '0;
            ts_b          <= '0;
            tsb_book      <= '0;
            ts_c          <= '0;
            tsc_tob       <= '0;
            valid_a       <= 1'b0;
            valid_b       <= 1'b0;
            valid_c       <= 1'b0;
            ts_prev_ev    <= '0;
            have_prev_ev  <= 1'b0;
            lat_last      <= '0;
            lat_min       <= 32'hFFFF_FFFF;   // so the first sample always wins
            lat_max       <= '0;
            lat_sum       <= '0;
            lat_count     <= '0;
            lat_resolve   <= '0;
            lat_book2tob  <= '0;
            lat_tob2feat  <= '0;
            lat_ia_last   <= '0;
            lat_ia_min    <= 32'hFFFF_FFFF;
            lat_unmatched <= '0;
        end else begin
            cycle <= cycle + 1'b1;

            // ---- stage 0: parser handed an event to the dispatcher --------
            if (ev_handoff) begin
                logic [31:0] ia;

                // previous event never reached the book: lookup miss, or a
                // one-sided book. Drop it rather than mis-attribute later.
                if (valid_a) lat_unmatched <= lat_unmatched + 1'b1;

                ts_a    <= cycle;
                valid_a <= 1'b1;

                if (have_prev_ev) begin
                    ia          = cycle - ts_prev_ev;
                    lat_ia_last <= ia;
                    if (ia < lat_ia_min) lat_ia_min <= ia;
                end
                ts_prev_ev   <= cycle;
                have_prev_ev <= 1'b1;
            end

            // ---- stage 1: this event's book write committed ---------------
            // Replace's SECOND book_updated finds valid_a already low and is
            // deliberately ignored (see header: "first feature" semantics).
            if (book_updated && valid_a) begin
                lat_resolve <= cycle - ts_a;
                ts_b        <= ts_a;      // carry the origin timestamp forward
                tsb_book    <= cycle;     // and stamp this stage's entry
                valid_b     <= 1'b1;
                valid_a     <= 1'b0;
            end

            // ---- stage 2: snapshot published ------------------------------
            if (tob_valid && valid_b) begin
                lat_book2tob <= cycle - tsb_book;
                ts_c         <= ts_b;
                tsc_tob      <= cycle;
                valid_c      <= 1'b1;
                valid_b      <= 1'b0;
            end

            // ---- stage 3: features ready -> close the measurement ---------
            if (feat_valid && valid_c) begin
                logic [31:0] tot;
                tot = cycle - ts_c;

                lat_tob2feat <= cycle - tsc_tob;
                lat_last     <= tot;
                if (tot < lat_min) lat_min <= tot;
                if (tot > lat_max) lat_max <= tot;
                lat_sum      <= lat_sum + tot;
                lat_count    <= lat_count + 1'b1;
                valid_c      <= 1'b0;
            end
        end
    end

endmodule
