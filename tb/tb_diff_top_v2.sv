/*
 * tb_diff_top_v2  --  RTL vs golden-model differential harness
 * ------------------------------------------------------------
 * Streams a real NASDAQ ITCH 5.0 capture through top_v2 and writes every
 * emitted feature frame to CSV, so the RTL output can be diffed byte-for-byte
 * against itch_tools.py's independent Python model.
 *
 * This is the test that unit testbenches cannot replace: each module is
 * verified against hand-written expectations, but only an end-to-end run on
 * real exchange data against an independent implementation can catch a shared
 * misunderstanding of the protocol.
 *
 * PARAMETERS MUST MATCH THE THING BEING COMPARED. The defaults below are the
 * values bound into the shipping bitstream (confirmed from the synthesis log),
 * NOT the source defaults of top_v2 - which differ. Passing a different
 * TABLE_BITS to the golden model makes order-table evictions diverge, and the
 * two outputs then disagree for reasons that have nothing to do with a bug.
 *
 * Usage:
 *   xelab ... tb_diff_top_v2
 *   xsim snap -R -testplusarg ...     (defaults are fine)
 *   +STREAM=<path to filtered .bin>   default aapl_small.bin
 *   +OUT=<path to csv>                default sim_frames.csv
 *
 * tx_ready is held high throughout: we want every frame the pipeline produces,
 * with no drop-oldest replacement, so the comparison against golden is 1:1.
 * drop_count is printed at the end to confirm that actually held.
 */
`timescale 1ns/1ps

module tb_diff_top_v2;

    // ---- shipping-bitstream calibration ----
    localparam int unsigned BASE_PRICE    = 1_610_800;
    localparam int unsigned WINDOW_SIZE   = 1024;
    localparam bit          FILTER_EN     = 1'b1;
    localparam logic [15:0] FILTER_LOCATE = 16'd14;
    localparam int unsigned QTY_SHIFT     = 0;
    localparam int          TABLE_BITS    = 14;

    localparam int MAXB = 8_000_000;   // max capture size in bytes (fits aapl_200000.bin)

    logic clk = 1'b0, arstn = 1'b0;
    always #5 clk = ~clk;              // 100 MHz

    // ---- stimulus source ----
    byte unsigned data [0:MAXB-1];
    int  nbytes = 0;
    int  idx    = 0;
    bit  streaming = 1'b0;

    logic [7:0] s_tdata;
    logic       s_tvalid, s_tready;

    assign s_tdata  = data[idx];
    assign s_tvalid = streaming && (idx < nbytes);

    always_ff @(posedge clk) begin
        if (!arstn)                          idx <= 0;
        else if (s_tvalid && s_tready)       idx <= idx + 1;
    end

    // ---- DUT ----
    logic       tx_valid;
    logic [7:0] tx_data;
    logic       tx_ready = 1'b1;      // never back-pressure: capture every frame

    logic        parse_error;
    logic [31:0] unknown_count, msg_count, filtered_count,
                 miss_count, oow_count, drop_count;
    logic [31:0] lat_last, lat_min, lat_max, lat_sum, lat_count,
                 lat_resolve, lat_book2tob, lat_tob2feat,
                 lat_ia_last, lat_ia_min, lat_unmatched;

    top_v2 #(
        .BASE_PRICE   (BASE_PRICE),
        .WINDOW_SIZE  (WINDOW_SIZE),
        .QTY_SHIFT    (QTY_SHIFT),
        .TABLE_BITS   (TABLE_BITS),
        .FILTER_EN    (FILTER_EN),
        .FILTER_LOCATE(FILTER_LOCATE)
    ) dut (
        .clk(clk), .arstn(arstn),
        .s_tvalid(s_tvalid), .s_tdata(s_tdata), .s_tready(s_tready),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .parse_error(parse_error),
        .unknown_count(unknown_count), .msg_count(msg_count),
        .filtered_count(filtered_count), .miss_count(miss_count),
        .oow_count(oow_count), .drop_count(drop_count),
        .lat_last(lat_last), .lat_min(lat_min), .lat_max(lat_max),
        .lat_sum(lat_sum), .lat_count(lat_count),
        .lat_resolve(lat_resolve), .lat_book2tob(lat_book2tob),
        .lat_tob2feat(lat_tob2feat),
        .lat_ia_last(lat_ia_last), .lat_ia_min(lat_ia_min),
        .lat_unmatched(lat_unmatched)
    );

    // parse_error is a pulse; accumulate it the way top_uart does
    int parse_err_count = 0;
    always_ff @(posedge clk)
        if (arstn && parse_error) parse_err_count <= parse_err_count + 1;

    // ---- frame capture: 15-byte frames off the board-link stream ----
    byte unsigned fbuf [0:14];
    int  fidx    = 0;
    int  nframes = 0;
    int  bad_sync = 0, bad_chk = 0;
    int  fd_out;

    logic signed [15:0] f_spr, f_tobi, f_ofi, f_emadev, f_mom, f_tflow;
    byte unsigned chk;

    always @(posedge clk) begin
        if (arstn && tx_valid && tx_ready) begin
            fbuf[fidx] = tx_data;                 // blocking: TB monitor
            if (fidx == 14) begin
                fidx = 0;

                if (fbuf[0] !== 8'hA5) bad_sync = bad_sync + 1;

                chk = 8'h00;
                for (int b = 0; b < 14; b++) chk = chk ^ fbuf[b];
                if (chk !== fbuf[14]) bad_chk = bad_chk + 1;

                f_spr    = {fbuf[2],  fbuf[3]};
                f_tobi   = {fbuf[4],  fbuf[5]};
                f_ofi    = {fbuf[6],  fbuf[7]};
                f_emadev = {fbuf[8],  fbuf[9]};
                f_mom    = {fbuf[10], fbuf[11]};
                f_tflow  = {fbuf[12], fbuf[13]};

                $fwrite(fd_out, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                        nframes, fbuf[1],
                        f_spr, f_tobi, f_ofi, f_emadev, f_mom, f_tflow);
                nframes = nframes + 1;
            end else begin
                fidx = fidx + 1;
            end
        end
    end

    // ---- run ----
    // Fixed filenames by design. Vivado 2025.2's xsim splits -testplusarg on
    // '=', so "name=value" plusargs cannot be passed on the command line; the
    // $value$plusargs calls below still work on simulators that support them,
    // but the supported path is tb/run_diff.sh, which stages the chosen
    // capture to diff_input.bin before invoking xsim.
    string fname = "diff_input.bin";
    string oname = "sim_frames.csv";
    int    fd_in;
    int    drain;

    initial begin
        void'($value$plusargs("STREAM=%s", fname));
        void'($value$plusargs("OUT=%s",    oname));

        fd_in = $fopen(fname, "rb");
        if (fd_in == 0) begin
            $display("ERROR: cannot open stream file '%s'", fname);
            $finish;
        end
        nbytes = $fread(data, fd_in);
        $fclose(fd_in);

        fd_out = $fopen(oname, "w");
        if (fd_out == 0) begin
            $display("ERROR: cannot open output '%s'", oname);
            $finish;
        end
        $fwrite(fd_out, "frame,seq,spr,tobi,ofi,emadev,mom,tflow\n");

        $display("=== tb_diff_top_v2 ===");
        $display("  stream    : %s  (%0d bytes)", fname, nbytes);
        $display("  out       : %s", oname);
        $display("  params    : BASE_PRICE=%0d WINDOW=%0d LOCATE=%0d QTY_SHIFT=%0d TABLE_BITS=%0d",
                 BASE_PRICE, WINDOW_SIZE, FILTER_LOCATE, QTY_SHIFT, TABLE_BITS);

        repeat (8) @(posedge clk);
        arstn <= 1'b1;
        repeat (4) @(posedge clk);
        streaming <= 1'b1;

        // wait for the last byte to be consumed
        wait (idx == nbytes);

        // then let the pipeline drain: an event needs ~20 cycles end to end and
        // the final frame needs 15 more to serialise. 5000 is generous.
        drain = 0;
        while (drain < 5000) begin
            @(posedge clk);
            drain = drain + 1;
        end

        $fclose(fd_out);

        $display("--- pipeline counters ---");
        $display("  msg_count      = %0d", msg_count);
        $display("  filtered_count = %0d", filtered_count);
        $display("  unknown_count  = %0d", unknown_count);
        $display("  parse_errors   = %0d", parse_err_count);
        $display("  miss_count     = %0d   (order-table evictions / unknown ids)", miss_count);
        $display("  oow_count      = %0d   (price outside the window)", oow_count);
        $display("  drop_count     = %0d   (MUST be 0 for a 1:1 golden compare)", drop_count);
        $display("--- frames ---");
        $display("  frames written = %0d", nframes);
        $display("  bad sync bytes = %0d", bad_sync);
        $display("  bad checksums  = %0d", bad_chk);

        // ---- MEASURED latency, straight from the on-chip probe -------------
        // Core-only: ev_handoff (parser -> dispatcher) to the first feat_valid
        // that event produces. Excludes the transport entirely. 1 cycle = 10 ns.
        $display("--- latency (measured, cycles @100MHz) ---");
        $display("  samples        = %0d", lat_count);
        if (lat_count != 0) begin
            $display("  t_total  min   = %0d  (%0.1f ns)", lat_min, lat_min * 10.0);
            $display("  t_total  max   = %0d  (%0.1f ns)", lat_max, lat_max * 10.0);
            $display("  t_total  mean  = %0d  (%0.1f ns)",
                     lat_sum / lat_count, (lat_sum / lat_count) * 10.0);
            $display("  t_total  last  = %0d", lat_last);
            $display("  stage: resolve = %0d   book2tob = %0d (expect 5)   tob2feat = %0d (expect 1)",
                     lat_resolve, lat_book2tob, lat_tob2feat);
            $display("  interarrival   = %0d last, %0d min  (fed at line rate here,",
                     lat_ia_last, lat_ia_min);
            $display("                   NOT the UART's ~1000 cycles/byte)");
            $display("  unmatched      = %0d  (events that produced no feature)", lat_unmatched);
            if (lat_book2tob != 5 || lat_tob2feat != 1)
                $display("  WARNING: fixed-latency stages are off - this is a BUG, not a measurement");
        end

        if (drop_count != 0)
            $display("WARNING: drop_count nonzero - frames were replaced, comparison will misalign");
        if (bad_sync != 0 || bad_chk != 0)
            $display("WARNING: frame integrity errors - the link layer itself is wrong");

        $display("=== done ===");
        $finish;
    end

    // hard timeout so a hang cannot run forever
    initial begin
        #2_000_000_000;   // 2 s of sim time - enough for a 200k-message capture
        $display("ERROR: timeout");
        $finish;
    end

endmodule
