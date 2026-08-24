/*
 * feature_engine
 * --------------
 * Computes the six frozen features (see FEATURE_VECTOR_SPEC.md) from each
 * top-of-book snapshot, entirely with adds/subtracts/shifts - zero
 * multipliers, zero dividers. All six run in PARALLEL: total latency is
 * one cycle from tob_valid to feat_valid regardless of feature count,
 * because the pipeline depth is set by the deepest single feature, not
 * the sum.
 *
 * Feature definitions (all saturate to signed 16 bits via sat16, which
 * the Python golden model must replicate bit-exactly):
 *
 *   SPR    = ask_idx - bid_idx            spread in penny ticks (indices
 *                                         are already tick-denominated)
 *   TOBI   = (bid_qty - ask_qty) >>> QTY_SHIFT
 *                                         top-of-book imbalance, difference
 *                                         form - deliberately NOT a ratio,
 *                                         to avoid a divider
 *   OFI    = (Δbid_qty - Δask_qty) >>> QTY_SHIFT
 *                                         order-flow imbalance vs previous
 *                                         snapshot
 *   EMADEV = mid - EMA(mid)               EMA alpha = 1/16 -> update is
 *                                         ema += (mid - ema) >>> 4, a pure
 *                                         shift. EMA state carries 4 extra
 *                                         fraction bits so repeated shifts
 *                                         don't bleed precision.
 *   MOM    = mid(t) - mid(t-8)            8-snapshot momentum via a shift
 *                                         register of mids
 *   TFLOW  = signed sum of the last 16 trades (+qty buys hitting the book's
 *            sell side? see note) via ring buffer: add newest, subtract
 *            oldest each trade event.
 *
 * TFLOW sign convention: trade_side is the RESTING order's side from
 * order_lookup (0=resting buy got hit -> aggressive SELL; 1=resting sell
 * got lifted -> aggressive BUY). We define TFLOW positive for aggressive
 * buying: contribution = resting_side ? +qty : -qty.
 *
 * QTY_SHIFT is the placeholder quantity scaling from the spec (awaiting
 * the CS-side distribution calibration). Default 0 = raw shares.
 */

module feature_engine
    import ITCH50_pkg::*;
#(
    parameter int unsigned QTY_SHIFT  = 0,   // calibrate from data distribution!
    parameter int unsigned MOM_DEPTH  = 8,   // snapshots of mid-price history
    parameter int unsigned TFLOW_DEPTH = 16  // trades in the flow window
)
(
    input  logic                 clk,
    input  logic                 arstn,

    // top-of-book snapshot stream
    input  logic                 tob_valid,
    input  tob_t                 tob,

    // trade tap from event_dispatcher (E/C hits only)
    input  logic                 trade_valid,
    input  logic                 trade_side,   // resting order's side
    input  logic [31:0]          trade_qty,

    // feature vector out (order matches FEATURE_VECTOR_SPEC packing order)
    output logic                 feat_valid,
    output logic signed [15:0]   f_spr,
    output logic signed [15:0]   f_tobi,
    output logic signed [15:0]   f_ofi,
    output logic signed [15:0]   f_emadev,
    output logic signed [15:0]   f_mom,
    output logic signed [15:0]   f_tflow
);

    // ------------------------------------------------------------------
    // Persistent state
    // ------------------------------------------------------------------
    logic signed [31:0] prev_bid_qty, prev_ask_qty;   // for OFI deltas
    logic signed [31:0] ema_frac;                     // EMA(mid) << 4 (4 frac bits)
    logic               ema_init;                     // first-sample seeding flag
    logic signed [31:0] mid_hist [MOM_DEPTH];         // mid shift register
    logic signed [31:0] tflow_acc;                    // running signed sum
    logic signed [31:0] tflow_ring [TFLOW_DEPTH];     // per-trade contributions
    logic [$clog2(TFLOW_DEPTH)-1:0] tflow_wr;         // ring write pointer

    // ------------------------------------------------------------------
    // Trade-flow accumulator: updated on TRADE events (its own event
    // stream, independent of tob snapshots). Newest contribution enters,
    // oldest leaves - a rolling 16-trade signed sum with no division.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!arstn) begin
            tflow_acc <= '0;
            tflow_wr  <= '0;
            for (int i = 0; i < TFLOW_DEPTH; i++) tflow_ring[i] <= '0;
        end else if (trade_valid) begin
            logic signed [31:0] contrib;
            // resting sell lifted = aggressive buy = positive flow
            contrib = trade_side ? $signed(trade_qty) : -$signed(trade_qty);
            tflow_acc            <= tflow_acc + contrib - tflow_ring[tflow_wr];
            tflow_ring[tflow_wr] <= contrib;
            tflow_wr             <= tflow_wr + 1;
        end
    end

    // ------------------------------------------------------------------
    // Snapshot-driven features: one cycle, all six in parallel
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!arstn) begin
            feat_valid   <= 1'b0;
            f_spr        <= '0;
            f_tobi       <= '0;
            f_ofi        <= '0;
            f_emadev     <= '0;
            f_mom        <= '0;
            f_tflow      <= '0;
            prev_bid_qty <= '0;
            prev_ask_qty <= '0;
            ema_frac     <= '0;
            ema_init     <= 1'b0;
            for (int i = 0; i < MOM_DEPTH; i++) mid_hist[i] <= '0;
        end else begin
            feat_valid <= 1'b0;

            if (tob_valid) begin
                logic signed [31:0] mid;
                logic signed [31:0] bidq_s, askq_s;
                logic signed [31:0] ema_int;

                // mid in HALF-ticks: (bid_idx + ask_idx) without the >>1,
                // keeping the extra bit of precision for free (consistent
                // scale cancels out in EMADEV and MOM, which are both
                // differences of mids). Golden model must match this choice.
                mid    = $signed({16'd0, tob.bid_idx}) + $signed({16'd0, tob.ask_idx});
                bidq_s = $signed(tob.bid_qty) >>> QTY_SHIFT;
                askq_s = $signed(tob.ask_qty) >>> QTY_SHIFT;

                // --- SPR: spread in ticks ---
                f_spr <= sat16($signed({16'd0, tob.ask_idx})
                             - $signed({16'd0, tob.bid_idx}));

                // --- TOBI: difference-form imbalance ---
                f_tobi <= sat16(bidq_s - askq_s);

                // --- OFI: change-in-quantity imbalance vs last snapshot ---
                f_ofi <= sat16((bidq_s - prev_bid_qty) - (askq_s - prev_ask_qty));
                prev_bid_qty <= bidq_s;
                prev_ask_qty <= askq_s;

                // --- EMADEV: mid minus its EMA (alpha = 1/16) ---
                // EMA state has 4 extra fraction bits (ema_frac = ema << 4).
                // Update in the extended domain: ema_frac += (mid<<4 - ema_frac)>>4
                // First snapshot seeds the EMA to avoid a huge startup deviation.
                ema_int = ema_frac >>> 4;
                if (!ema_init) begin
                    ema_frac <= mid <<< 4;
                    ema_init <= 1'b1;
                    f_emadev <= '0;
                end else begin
                    f_emadev <= sat16(mid - ema_int);
                    ema_frac <= ema_frac + (((mid <<< 4) - ema_frac) >>> 4);
                end

                // --- MOM: mid(t) - mid(t-MOM_DEPTH) ---
                f_mom <= sat16(mid - mid_hist[MOM_DEPTH-1]);
                for (int i = MOM_DEPTH-1; i > 0; i--)
                    mid_hist[i] <= mid_hist[i-1];
                mid_hist[0] <= mid;

                // --- TFLOW: sample the rolling trade-flow sum ---
                f_tflow <= sat16(tflow_acc >>> QTY_SHIFT);

                feat_valid <= 1'b1;
            end
        end
    end

endmodule