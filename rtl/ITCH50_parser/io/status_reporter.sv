/*
 * status_reporter
 * ---------------
 * Emits a diagnostic STATUS FRAME on the outbound byte stream so the host can
 * actually read the pipeline's counters. Without this they are dangling
 * top-level signals that synthesis optimises away, and every bring-up problem
 * has to be inferred indirectly from the feature output.
 *
 * TRIGGER - deliberately NOT a command byte. The inbound ITCH stream is a
 * continuous [2-byte length][body] sequence in which ANY byte value can occur
 * inside a price / order_id / timestamp field, so an in-band magic byte would
 * eventually collide with real data and desynchronise the framing. Instead we
 * watch for the RX line going QUIET: once no byte has arrived for
 * IDLE_CYCLES, one status frame is emitted. That is exactly the moment the
 * host wants the counters (end of a replay burst), and it cannot corrupt the
 * data path. One frame per burst - had_activity re-arms only after new bytes.
 *
 * FRAME (31 bytes, big-endian, distinct sync from the 0xA5 feature frame):
 *   byte 0     : 0x5A  sync
 *   byte 1     : seq   (rolling, independent of the feature-frame seq)
 *   bytes 2-29 : 7 x uint32 : msg, unknown, filtered, miss, oow, drop, parse_err
 *   byte 30    : XOR of bytes 0..29
 */
module status_reporter #(
    // ~10 ms at 100 MHz. Must exceed the host's inter-byte gap so a burst is
    // not mistaken for its own end; small values are used by the testbench.
    parameter int IDLE_CYCLES = 1_000_000
)(
    input  logic        clk,
    input  logic        arstn,

    // 1-cycle pulse per raw UART byte received (from uart_to_axis)
    input  logic        rx_byte_seen,

    // pipeline diagnostic counters
    input  logic [31:0] msg_count,
    input  logic [31:0] unknown_count,
    input  logic [31:0] filtered_count,
    input  logic [31:0] miss_count,
    input  logic [31:0] oow_count,
    input  logic [31:0] drop_count,
    input  logic [31:0] parse_err_count,

    // outbound byte stream (into the TX arbiter)
    output logic [7:0]  m_tdata,
    output logic        m_tvalid,
    input  logic        m_tready
);

    localparam int NCNT      = 7;
    localparam int FRAME_LEN = 2 + NCNT*4 + 1;      // 31
    localparam int IW        = $clog2(FRAME_LEN+1);
    localparam logic [7:0] SYNC_BYTE = 8'h5A;

    // counters packed MSB-first so the frame is big-endian by construction
    logic [NCNT*32-1:0] cnt_bus;
    assign cnt_bus = {msg_count, unknown_count, filtered_count,
                      miss_count, oow_count, drop_count, parse_err_count};

    logic [7:0]         frame [FRAME_LEN];
    logic [IW-1:0]      byte_idx;
    logic               sending;
    logic [7:0]         seq;

    // idle detection
    logic [$clog2(IDLE_CYCLES+1)-1:0] idle_cnt;
    logic                             had_activity;
    logic                             trigger;

    assign trigger = had_activity && !sending && (idle_cnt == IDLE_CYCLES-1);

    always_ff @(posedge clk) begin
        if (!arstn) begin
            idle_cnt     <= '0;
            had_activity <= 1'b0;
            sending      <= 1'b0;
            byte_idx     <= '0;
            seq          <= '0;
            m_tvalid     <= 1'b0;
            m_tdata      <= '0;
        end else begin
            // ---- RX idle timer ----
            if (rx_byte_seen) begin
                idle_cnt     <= '0;
                had_activity <= 1'b1;      // arm: a burst is in progress
            end else if (idle_cnt != IDLE_CYCLES-1) begin
                idle_cnt <= idle_cnt + 1'b1;
            end

            // ---- launch a status frame at end of burst ----
            if (trigger) begin
                logic [7:0] chk;
                frame[0] = SYNC_BYTE;
                frame[1] = seq;
                chk      = SYNC_BYTE ^ seq;
                for (int j = 0; j < NCNT*4; j++) begin
                    frame[2+j] = cnt_bus[(NCNT*32-1) - 8*j -: 8];
                    chk        = chk ^ cnt_bus[(NCNT*32-1) - 8*j -: 8];
                end
                frame[FRAME_LEN-1] = chk;

                seq          <= seq + 1'b1;
                had_activity <= 1'b0;      // one frame per burst
                byte_idx     <= '0;
                sending      <= 1'b1;
                m_tdata      <= SYNC_BYTE;
                m_tvalid     <= 1'b1;
            end
            // ---- byte-serial send, valid held high for the whole frame so
            //      the arbiter's "grant until tvalid drops" is frame-atomic ----
            else if (sending && m_tvalid && m_tready) begin
                if (byte_idx == IW'(FRAME_LEN-1)) begin
                    m_tvalid <= 1'b0;
                    sending  <= 1'b0;
                end else begin
                    byte_idx <= byte_idx + 1'b1;
                    m_tdata  <= frame[byte_idx + 1];
                end
            end
        end
    end

endmodule
