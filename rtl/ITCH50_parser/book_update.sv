/*
 * book_update (v2)
 * ----------------
 * Aggregate price-level order book. For each side (bid/ask) it keeps:
 *   - a qty array: shares resting at each price level in the window
 *   - a 1-bit occupancy mask (level has any shares), consumed by
 *     priority_encoder to find the best bid/ask
 *
 * Addressing: raw ITCH prices are Price(4) integers (dollars*10000), but
 * US equities tick in pennies, so consecutive REAL price levels are 100
 * units apart. We therefore normalize:
 *
 *     level_index = (price - BASE_PRICE) / TICK_SIZE
 *
 * so the window covers WINDOW_SIZE penny ticks = $WINDOW_SIZE/100 around
 * BASE_PRICE. TICK_SIZE division is by a constant; Vivado implements it
 * as multiply-shift. It gets its own pipeline stage (ADDR) to keep the
 * 100 MHz budget comfortable.
 *
 * !! CALIBRATION REQUIRED !!  BASE_PRICE must be set per instrument/day
 * (e.g. AAPL on 2019-01-30 traded near $160 -> BASE_PRICE ~ 1_550_000
 * with WINDOW_SIZE=2048 covers $155.00-$175.47). Out-of-window prices
 * are dropped and counted in oow_count - watch that counter during bring-up;
 * a nonzero drift means your window is mis-centered.
 *
 * FSM: IDLE -> ADDR -> READ -> WRITE (4 cycles per update, one in flight).
 * Read ports for tob_tracker are registered (1-cycle latency), matching
 * the BRAM inference pattern.
 */

module book_update
    import ITCH50_pkg::*;
#(
    parameter int unsigned BASE_PRICE  = 1_550_000,  // Price(4) units; CALIBRATE!
    parameter int unsigned WINDOW_SIZE = 2048,       // penny ticks covered
    parameter int unsigned ADDR_W      = $clog2(WINDOW_SIZE)
)
(
    input  logic                   clk,
    input  logic                   arstn,

    // command port (from event_dispatcher)
    input  logic                   bu_valid,
    input  logic                   bu_is_add,   // 1 = add qty, 0 = remove qty
    input  logic [31:0]            bu_price,    // raw Price(4) integer
    input  logic [31:0]            bu_qty,
    input  logic                   bu_side,     // 0 = bid, 1 = ask
    output logic                   bu_ready,    // high in IDLE

    // occupancy masks for priority_encoder (registered, always current
    // as of the last completed WRITE)
    output logic [WINDOW_SIZE-1:0] bid_mask,
    output logic [WINDOW_SIZE-1:0] ask_mask,

    // qty read ports for tob_tracker (registered read, 1-cycle latency)
    input  logic [ADDR_W-1:0]      bid_rd_addr,
    output logic [31:0]            bid_rd_data,
    input  logic [ADDR_W-1:0]      ask_rd_addr,
    output logic [31:0]            ask_rd_data,

    // book-updated strobe: pulses 1 cycle when a WRITE completes, telling
    // downstream (tob refresh / feature engine) that state changed
    output logic                   book_updated,

    // diagnostics
    output logic [31:0]            oow_count    // out-of-window drops
);

    // per-level share quantities (BRAM)
    logic [31:0] bid_qty_mem [WINDOW_SIZE];
    logic [31:0] ask_qty_mem [WINDOW_SIZE];

    typedef enum logic [1:0] { IDLE, ADDR, READ, WRITE } state_e;
    state_e state;

    // latched command
    logic              c_is_add;
    logic [31:0]       c_price;
    logic [31:0]       c_qty;
    logic              c_side;

    // pipeline registers
    logic [31:0]       lvl_full;    // (price - BASE_PRICE) / TICK, full width
    logic [ADDR_W-1:0] lvl;         // truncated level index
    logic              in_window;
    logic [31:0]       old_qty;     // registered read of the target level
    logic              old_valid;   // mask bit at the target level (see READ)

    assign bu_ready = (state == IDLE);

    always_ff @(posedge clk) begin
        if (!arstn) begin
            state        <= IDLE;
            bid_mask     <= '0;
            ask_mask     <= '0;
            book_updated <= 1'b0;
            oow_count    <= '0;
            c_is_add     <= 1'b0;
            c_price      <= '0;
            c_qty        <= '0;
            c_side       <= 1'b0;
            lvl          <= '0;
            in_window    <= 1'b0;
            old_qty      <= '0;
            old_valid    <= 1'b0;
            bid_rd_data  <= '0;
            ask_rd_data  <= '0;
        end else begin
            book_updated <= 1'b0;   // 1-cycle strobe

            // independent registered read ports for tob_tracker
            bid_rd_data <= bid_qty_mem[bid_rd_addr];
            ask_rd_data <= ask_qty_mem[ask_rd_addr];

            case (state)
                // --------------------------------------------------------
                IDLE: begin
                    if (bu_valid) begin
                        c_is_add <= bu_is_add;
                        c_price  <= bu_price;
                        c_qty    <= bu_qty;
                        c_side   <= bu_side;
                        state    <= ADDR;
                    end
                end

                // --------------------------------------------------------
                // Dedicated stage for window check + constant division so
                // the divide's mult-shift logic has a full cycle to itself.
                ADDR: begin
                    if (c_price >= BASE_PRICE &&
                        c_price <  BASE_PRICE + WINDOW_SIZE * TICK_SIZE) begin
                        lvl_full  <= (c_price - BASE_PRICE) / TICK_SIZE;
                        in_window <= 1'b1;
                        state     <= READ;
                    end else begin
                        oow_count <= oow_count + 1;
                        in_window <= 1'b0;
                        state     <= IDLE;   // drop silently (counted)
                    end
                end

                // --------------------------------------------------------
                READ: begin
                    lvl <= lvl_full[ADDR_W-1:0];
                    if (c_side)
                        old_qty <= ask_qty_mem[lvl_full[ADDR_W-1:0]];
                    else
                        old_qty <= bid_qty_mem[lvl_full[ADDR_W-1:0]];
                    // The qty BRAMs are never globally cleared (no reset on
                    // BRAM contents). The occupancy mask IS reset, so it is
                    // the source of truth: if the level's mask bit is 0, its
                    // effective old quantity is 0 no matter what stale bits
                    // sit in the memory. Latch that validity here.
                    old_valid <= c_side ? ask_mask[lvl_full[ADDR_W-1:0]]
                                        : bid_mask[lvl_full[ADDR_W-1:0]];
                    state <= WRITE;
                end

                // --------------------------------------------------------
                WRITE: begin
                    logic [31:0] eff_old;
                    logic [31:0] new_qty;
                    // mask bit gates stale/uninitialized BRAM content
                    eff_old = old_valid ? old_qty : 32'd0;
                    // add or remove, clamping at zero (a remove larger than
                    // what's resting indicates an upstream inconsistency but
                    // must not wrap the counter)
                    if (c_is_add)
                        new_qty = eff_old + c_qty;
                    else
                        new_qty = (eff_old > c_qty) ? (eff_old - c_qty) : 32'd0;

                    if (c_side) begin
                        ask_qty_mem[lvl] <= new_qty;
                        ask_mask[lvl]    <= (new_qty != 0);
                    end else begin
                        bid_qty_mem[lvl] <= new_qty;
                        bid_mask[lvl]    <= (new_qty != 0);
                    end

                    book_updated <= 1'b1;
                    state        <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule