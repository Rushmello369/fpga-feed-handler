/*
 * tb_latency_probe
 * ----------------
 * Drives the probe's four taps directly with KNOWN cycle spacings, so every
 * expected latency is an exact integer rather than something read off a
 * waveform. Covers:
 *
 *   T1 basic          : one clean event, all three stage deltas + total
 *   T2 aggregation    : a second, slower event -> min/max/sum/count, and the
 *                       interarrival between the two ev_handoff pulses
 *   T3 unmatched      : an event that never reaches the book (lookup miss /
 *                       one-sided book) must be DISCARDED, not attributed to
 *                       the next event's feature
 *   T4 replace        : ONE event, TWO book/tob/feat triples -> exactly one
 *                       measurement ("first feature" semantics)
 *   T5 overlap        : the next ev_handoff arrives BEFORE the current
 *                       event's feature emerges. This is the case a naive
 *                       single-"armed"-flag probe gets wrong, and the reason
 *                       timestamps travel with the event.
 */
`timescale 1ns/1ps

module tb_latency_probe;

    logic clk = 0, arstn = 0;
    logic ev_handoff = 0, book_updated = 0, tob_valid = 0, feat_valid = 0;

    logic [31:0] lat_last, lat_min, lat_max, lat_sum, lat_count;
    logic [31:0] lat_resolve, lat_book2tob, lat_tob2feat;
    logic [31:0] lat_ia_last, lat_ia_min, lat_unmatched;

    int pass_count = 0, fail_count = 0;

    latency_probe dut (
        .clk(clk), .arstn(arstn),
        .ev_handoff(ev_handoff), .book_updated(book_updated),
        .tob_valid(tob_valid),   .feat_valid(feat_valid),
        .lat_last(lat_last), .lat_min(lat_min), .lat_max(lat_max),
        .lat_sum(lat_sum),   .lat_count(lat_count),
        .lat_resolve(lat_resolve), .lat_book2tob(lat_book2tob),
        .lat_tob2feat(lat_tob2feat),
        .lat_ia_last(lat_ia_last), .lat_ia_min(lat_ia_min),
        .lat_unmatched(lat_unmatched)
    );

    always #5 clk = ~clk;

    task automatic check(input string desc, input logic cond);
        if (cond) begin pass_count++; $display("[PASS] %s", desc); end
        else      begin fail_count++; $error("[FAIL] %s", desc); end
    endtask

    // Each pulse asserts its tap for exactly ONE sampling edge and returns
    // immediately after that edge, so "repeat(N) @(posedge clk)" between two
    // pulses puts them exactly N+1 cycles apart as the DUT sees them.
    task automatic p_ev();   ev_handoff   <= 1'b1; @(posedge clk); ev_handoff   <= 1'b0; endtask
    task automatic p_book(); book_updated <= 1'b1; @(posedge clk); book_updated <= 1'b0; endtask
    task automatic p_tob();  tob_valid    <= 1'b1; @(posedge clk); tob_valid    <= 1'b0; endtask
    task automatic p_feat(); feat_valid   <= 1'b1; @(posedge clk); feat_valid   <= 1'b0; endtask

    initial begin
        arstn = 1'b0;
        repeat (4) @(posedge clk);
        arstn <= 1'b1;
        @(posedge clk);

        //-------------------------------------------------------------------
        // T1: one clean event.  resolve=10, book2tob=4, tob2feat=1, total=15
        //-------------------------------------------------------------------
        p_ev();                          // E0
        repeat (9) @(posedge clk);
        p_book();                        // E0+10
        repeat (3) @(posedge clk);
        p_tob();                         // E0+14
        p_feat();                        // E0+15
        @(posedge clk);                  // let the NBA updates settle

        check("T1: resolve   = 10", lat_resolve   == 32'd10);
        check("T1: book2tob  = 4",  lat_book2tob  == 32'd4);
        check("T1: tob2feat  = 1",  lat_tob2feat  == 32'd1);
        check("T1: total     = 15", lat_last      == 32'd15);
        check("T1: min       = 15", lat_min       == 32'd15);
        check("T1: max       = 15", lat_max       == 32'd15);
        check("T1: sum       = 15", lat_sum       == 32'd15);
        check("T1: count     = 1",  lat_count     == 32'd1);
        check("T1: unmatched = 0",  lat_unmatched == 32'd0);

        //-------------------------------------------------------------------
        // T2: a slower event exactly 100 cycles after the first ev_handoff.
        //     resolve=20, total=25 -> min stays 15, max becomes 25, sum 40.
        //-------------------------------------------------------------------
        repeat (83) @(posedge clk);      // E0+16 (settle) + 83 -> E0+99
        p_ev();                          // E0+100  => interarrival = 100
        repeat (19) @(posedge clk);
        p_book();                        // +20
        repeat (3) @(posedge clk);
        p_tob();                         // +24
        p_feat();                        // +25
        @(posedge clk);

        check("T2: ia_last   = 100", lat_ia_last  == 32'd100);
        check("T2: ia_min    = 100", lat_ia_min   == 32'd100);
        check("T2: resolve   = 20",  lat_resolve  == 32'd20);
        check("T2: total     = 25",  lat_last     == 32'd25);
        check("T2: min       = 15",  lat_min      == 32'd15);
        check("T2: max       = 25",  lat_max      == 32'd25);
        check("T2: sum       = 40",  lat_sum      == 32'd40);
        check("T2: count     = 2",   lat_count    == 32'd2);

        //-------------------------------------------------------------------
        // T3: an event that never reaches the book. The NEXT ev_handoff must
        //     discard it (unmatched++) instead of letting the next event's
        //     feature close the abandoned measurement.
        //-------------------------------------------------------------------
        repeat (10) @(posedge clk);
        p_ev();                          // armed, but no book_updated follows
        repeat (10) @(posedge clk);
        p_ev();                          // discards the previous one
        repeat (4) @(posedge clk);
        p_book();                        // +5
        repeat (3) @(posedge clk);
        p_tob();                         // +9
        p_feat();                        // +10
        @(posedge clk);

        check("T3: unmatched = 1",  lat_unmatched == 32'd1);
        check("T3: total     = 10", lat_last      == 32'd10);
        check("T3: count     = 3",  lat_count     == 32'd3);
        check("T3: min       = 10", lat_min       == 32'd10);
        check("T3: sum       = 50", lat_sum       == 32'd50);

        //-------------------------------------------------------------------
        // T4: Replace - ONE event, TWO book/tob/feat triples. Only the first
        //     is timed; the second must not add a second measurement, and
        //     must not be counted as unmatched either.
        //-------------------------------------------------------------------
        repeat (10) @(posedge clk);
        p_ev();
        repeat (4) @(posedge clk);
        p_book();                        // +5   <- delete half
        repeat (3) @(posedge clk);
        p_tob();                         // +9
        p_feat();                        // +10  -> measured, total = 10
        repeat (4) @(posedge clk);
        p_book();                        // insert half - no valid_a left
        repeat (3) @(posedge clk);
        p_tob();
        p_feat();                        // must NOT produce a measurement
        @(posedge clk);

        check("T4: count     = 4 (one per event, not per feature)",
                                    lat_count     == 32'd4);
        check("T4: total     = 10", lat_last      == 32'd10);
        check("T4: sum       = 60", lat_sum       == 32'd60);
        check("T4: unmatched = 1 (2nd half is not an abandoned event)",
                                    lat_unmatched == 32'd1);

        //-------------------------------------------------------------------
        // T5: OVERLAP. Event B is accepted while event A's feature is still
        //     in flight - exactly what event_dispatcher does at line rate,
        //     since it returns to IDLE ~5 cycles before the feature emerges.
        //     A must still be timed correctly, and B must be timed from its
        //     own ev_handoff, not A's.
        //-------------------------------------------------------------------
        // A's total is deliberately 11, NOT 10: T4 left lat_last = 10, so a
        // probe that fails to measure A at all would leave the stale 10 in
        // place and a "== 10" check would pass for entirely the wrong reason.
        repeat (10) @(posedge clk);
        p_ev();                          // A @ EA
        repeat (5) @(posedge clk);
        p_book();                        // A book @ EA+6
        repeat (1) @(posedge clk);
        p_ev();                          // B @ EA+8  <-- B arrives mid-flight
        repeat (1) @(posedge clk);
        p_tob();                         // A tob  @ EA+10
        p_feat();                        // A feat @ EA+11 -> A total = 11
        @(posedge clk);

        check("T5: A resolve = 6 (A's own, not B's)",  lat_resolve == 32'd6);
        check("T5: A total   = 11 (not clobbered by B)", lat_last  == 32'd11);
        check("T5: count     = 5",                       lat_count == 32'd5);
        check("T5: unmatched = 1 (B is still in flight)",
                                                     lat_unmatched == 32'd1);

        // now finish B: its ev_handoff was at EA+8, and we are at EA+12.
        repeat (8) @(posedge clk);
        p_book();                        // B book @ EA+21 -> B resolve = 13
        repeat (3) @(posedge clk);
        p_tob();                         // @ EA+25
        p_feat();                        // @ EA+26 -> B total = 26-8 = 18
        @(posedge clk);

        check("T5: B resolve = 13 (from B's own handoff)",
                                    lat_resolve == 32'd13);
        check("T5: B total   = 18 (from B's own handoff)",
                                    lat_last    == 32'd18);
        check("T5: count     = 6",  lat_count   == 32'd6);
        check("T5: sum       = 89", lat_sum     == 32'd89);
        check("T5: max       = 25 (unchanged)", lat_max == 32'd25);

        //-------------------------------------------------------------------
        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display("========================================");
        $finish;
    end

endmodule
