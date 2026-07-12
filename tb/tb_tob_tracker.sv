/*
 * tb_tob_tracker
 * --------------
 * Unit test for tob_tracker's delay-and-sample pipeline.
 *
 * tob_tracker fires off a book_updated pulse, waits for the priority encoder
 * (2 cyc) + read address (1 cyc) + registered read data (1 cyc), then samples
 * the best bid/ask quantities and publishes a tob_t snapshot. This TB drives
 * the encoder-side inputs and models book_update's registered read port with
 * a matching 1-cycle memory, then checks the snapshot lands with the right
 * quantities and that tob_valid asserts ONLY when both sides are valid.
 *
 * Covers:
 *   - two-sided book: bid_idx/bid_qty/ask_idx/ask_qty all correct, tob_valid=1
 *   - one-sided book (ask invalid): tob_valid MUST stay 0 (no spread/mid)
 *   - a second update refreshes to new levels/quantities
 */
`timescale 1ns/1ps

module tb_tob_tracker;
    import ITCH50_pkg::*;

    localparam int WINDOW_SIZE = 2048;
    localparam int ADDR_W      = $clog2(WINDOW_SIZE);

    logic                  clk = 0, arstn = 0;
    logic                  book_updated = 0;
    logic [ADDR_W-1:0]     best_bid_addr = 0, best_ask_addr = 0;
    logic                  best_bid_valid = 0, best_ask_valid = 0;
    logic [ADDR_W-1:0]     bid_rd_addr, ask_rd_addr;   // from DUT
    logic [31:0]           bid_rd_data, ask_rd_data;   // to DUT
    logic [31:0]           bid_rd_data_in;             // unused DUT output
    tob_t                  tob;
    logic                  tob_valid;

    int pass_count = 0, fail_count = 0;

    tob_tracker #(.WINDOW_SIZE(WINDOW_SIZE)) dut (
        .clk(clk), .arstn(arstn),
        .book_updated(book_updated),
        .best_bid_addr(best_bid_addr), .best_bid_valid(best_bid_valid),
        .best_ask_addr(best_ask_addr), .best_ask_valid(best_ask_valid),
        .bid_rd_addr(bid_rd_addr), .bid_rd_data_in(bid_rd_data_in),
        .bid_rd_data(bid_rd_data),
        .ask_rd_addr(ask_rd_addr), .ask_rd_data(ask_rd_data),
        .tob(tob), .tob_valid(tob_valid)
    );

    always #5 clk = ~clk;

    initial begin
        #100000; $error("[TIMEOUT] sim stuck"); $finish;
    end

    // ---- model book_update's registered read port (1-cycle latency) ----
    logic [31:0] bid_mem [WINDOW_SIZE];
    logic [31:0] ask_mem [WINDOW_SIZE];
    always_ff @(posedge clk) begin
        bid_rd_data <= bid_mem[bid_rd_addr];
        ask_rd_data <= ask_mem[ask_rd_addr];
    end

    task automatic check(input string desc, input logic cond);
        if (cond) begin pass_count++; $display("[PASS] %s", desc); end
        else      begin fail_count++; $error("[FAIL] %s", desc); end
    endtask

    // pulse book_updated for 1 cycle, then wait (bounded) for the snapshot.
    // Returns the captured tob and whether tob_valid ever fired.
    task automatic run_update(output tob_t got, output logic gotv);
        int guard;
        gotv = 1'b0;
        @(negedge clk); book_updated = 1'b1;
        @(negedge clk); book_updated = 1'b0;
        guard = 0;
        while (!tob_valid && guard < 15) begin
            @(negedge clk); guard++;
        end
        got  = tob;          // registered; holds after the pulse
        gotv = tob_valid;
    endtask

    tob_t   t;
    logic   tv;

    initial begin
        // preload the modeled book: best bid 300@lvl500, best ask 200@lvl502
        for (int i = 0; i < WINDOW_SIZE; i++) begin
            bid_mem[i] = 0; ask_mem[i] = 0;
        end
        bid_mem[500] = 32'd300;
        ask_mem[502] = 32'd200;

        repeat (4) @(posedge clk);
        arstn = 1;
        repeat (2) @(posedge clk);

        // --- two-sided update ---
        best_bid_addr = 11'd500; best_bid_valid = 1'b1;
        best_ask_addr = 11'd502; best_ask_valid = 1'b1;
        run_update(t, tv);
        check("2-sided: tob_valid=1", tv == 1'b1);
        check("2-sided: bid_idx=500", t.bid_idx == 16'd500);
        check("2-sided: bid_qty=300", t.bid_qty == 32'd300);
        check("2-sided: ask_idx=502", t.ask_idx == 16'd502);
        check("2-sided: ask_qty=200", t.ask_qty == 32'd200);

        repeat (6) @(posedge clk);   // let the delay line drain

        // --- one-sided book: ask invalid -> no snapshot published ---
        best_bid_addr = 11'd500; best_bid_valid = 1'b1;
        best_ask_valid = 1'b0;
        run_update(t, tv);
        check("1-sided: tob_valid=0 (both sides required)", tv == 1'b0);

        repeat (6) @(posedge clk);

        // --- second two-sided update: new levels/quantities ---
        bid_mem[510] = 32'd400;
        ask_mem[505] = 32'd150;
        best_bid_addr = 11'd510; best_bid_valid = 1'b1;
        best_ask_addr = 11'd505; best_ask_valid = 1'b1;
        run_update(t, tv);
        check("refresh: tob_valid=1", tv == 1'b1);
        check("refresh: bid_idx=510", t.bid_idx == 16'd510);
        check("refresh: bid_qty=400", t.bid_qty == 32'd400);
        check("refresh: ask_idx=505", t.ask_idx == 16'd505);
        check("refresh: ask_qty=150", t.ask_qty == 32'd150);

        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display(fail_count == 0 ? "  ALL TESTS PASSED" : "  THERE ARE FAILURES");
        $display("========================================");
        $finish;
    end

    initial begin
        $dumpfile("tb_tob_tracker.vcd");
        $dumpvars(0, tb_tob_tracker);
    end

endmodule
