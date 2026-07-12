/*
 * tob_tracker (v2)
 * ----------------
 * Assembles the top-of-book snapshot (tob_t) consumed by feature_engine.
 * Takes the best bid/ask WINDOW INDICES from priority_encoder, fetches
 * the resting quantity at those levels through book_update's registered
 * read ports, and emits one tob_t + tob_valid pulse per completed book
 * update (chained off book_updated so downstream sees exactly one
 * snapshot per book-changing event - the natural "event rate" for
 * feature computation).
 *
 * Note prices stay as window tick indices end-to-end (see tob_t comment
 * in the package): differences of indices are already in ticks, which is
 * what lets the whole feature engine avoid division.
 *
 * Latency budget (from book_updated pulse):
 *   +2 cycles  priority_encoder refresh flows through
 *   +1 cycle   read-port address settles
 *   +1 cycle   registered read data returns
 *   +1 cycle   output register
 * Implemented as a small delay-and-sample pipeline below.
 */

module tob_tracker
    import ITCH50_pkg::*;
#(
    parameter int WINDOW_SIZE = 2048,
    parameter int ADDR_W      = $clog2(WINDOW_SIZE)
)
(
    input  logic              clk,
    input  logic              arstn,

    // "book state changed" strobe from book_update
    input  logic              book_updated,

    // best-level addresses from priority_encoder (2-cycle-stale relative
    // to book_updated; the delay chain below accounts for it)
    input  logic [ADDR_W-1:0] best_bid_addr,
    input  logic              best_bid_valid,
    input  logic [ADDR_W-1:0] best_ask_addr,
    input  logic              best_ask_valid,

    // qty read ports into book_update
    output logic [ADDR_W-1:0] bid_rd_addr,
    output logic [31:0]       bid_rd_data_in,   // unused; kept for symmetry
    input  logic [31:0]       bid_rd_data,
    output logic [ADDR_W-1:0] ask_rd_addr,
    input  logic [31:0]       ask_rd_data,

    // snapshot out
    output tob_t              tob,
    output logic              tob_valid
);

    // delay line: wait for the encoder's 2-stage pipe to reflect the update,
    // then 1 cycle for the read address, 1 for read data, then sample.
    logic [4:0] upd_shift;

    always_ff @(posedge clk) begin
        if (!arstn) begin
            upd_shift   <= '0;
            bid_rd_addr <= '0;
            ask_rd_addr <= '0;
            tob         <= '0;
            tob_valid   <= 1'b0;
        end else begin
            upd_shift <= {upd_shift[3:0], book_updated};
            tob_valid <= 1'b0;

            // t+2 after update: encoder outputs are fresh; launch the reads
            if (upd_shift[1]) begin
                bid_rd_addr <= best_bid_addr;
                ask_rd_addr <= best_ask_addr;
            end

            // t+4: read data has returned (1 cycle addr settle + 1 cycle
            // registered read); assemble and publish the snapshot
            if (upd_shift[3]) begin
                tob.bid_idx <= 16'(best_bid_addr);
                tob.bid_qty <= best_bid_valid ? bid_rd_data : 32'd0;
                tob.ask_idx <= 16'(best_ask_addr);
                tob.ask_qty <= best_ask_valid ? ask_rd_data : 32'd0;
                // publish only when both sides exist; a one-sided book has
                // no spread/mid, so features would be meaningless
                tob_valid   <= best_bid_valid && best_ask_valid;
            end
        end
    end

    assign bid_rd_data_in = '0;  // placeholder, port kept for interface symmetry

endmodule