/*
 * board_link_tx
 * -------------
 * Packs one feature vector into a 15-byte frame and serializes it as a
 * byte stream toward the Pynq Z1 board-link receiver:
 *
 *   byte 0      : SYNC   = 0xA5          (frame alignment marker)
 *   byte 1      : SEQ    = rolling count (lets RX detect dropped frames -
 *                 the improvement over Imperial's sequence-less UDP link)
 *   bytes 2-13  : six int16 features, BIG-endian, in spec packing order:
 *                 SPR, TOBI, OFI, EMADEV, MOM, TFLOW
 *   byte 14     : CHK    = XOR of bytes 0..13 (cheap integrity check)
 *
 * Big-endian to stay consistent with the ITCH convention used everywhere
 * else in this design (and with the Python golden model's struct.pack('>6h')).
 *
 * Flow control: tx_ready is the downstream's throttle. If a new feature
 * vector arrives while a frame is still being sent, the new one REPLACES
 * the pending one (drop-oldest policy): for a decision engine, the newest
 * market state is strictly more valuable than a stale snapshot, so we
 * never queue. Drops are counted for visibility.
 */

module board_link_tx
    import ITCH50_pkg::*;
(
    input  logic               clk,
    input  logic               arstn,

    // feature vector in
    input  logic               feat_valid,
    input  logic signed [15:0] f_spr,
    input  logic signed [15:0] f_tobi,
    input  logic signed [15:0] f_ofi,
    input  logic signed [15:0] f_emadev,
    input  logic signed [15:0] f_mom,
    input  logic signed [15:0] f_tflow,

    // byte stream out (to PMOD serializer / link PHY layer)
    output logic               tx_valid,
    output logic [7:0]         tx_data,
    input  logic               tx_ready,

    // diagnostics
    output logic [31:0]        drop_count   // vectors replaced mid-frame
);

    localparam int FRAME_LEN = 15;
    localparam logic [7:0] SYNC_BYTE = 8'hA5;

    logic [7:0]  frame [FRAME_LEN];
    logic [3:0]  byte_idx;
    logic        sending;
    logic [7:0]  seq;
    logic        pend_valid;             // a newer vector arrived mid-frame
    logic signed [15:0] p_spr, p_tobi, p_ofi, p_emadev, p_mom, p_tflow;

    always_ff @(posedge clk) begin
        if (!arstn) begin
            tx_valid   <= 1'b0;
            tx_data    <= '0;
            byte_idx   <= '0;
            sending    <= 1'b0;
            seq        <= '0;
            pend_valid <= 1'b0;
            drop_count <= '0;
        end else begin
            // latch an incoming vector; if one is already pending or being
            // sent, the newer one wins (drop-oldest) and we count the drop
            if (feat_valid) begin
                if (sending || pend_valid) drop_count <= drop_count + 1;
                p_spr    <= f_spr;
                p_tobi   <= f_tobi;
                p_ofi    <= f_ofi;
                p_emadev <= f_emadev;
                p_mom    <= f_mom;
                p_tflow  <= f_tflow;
                pend_valid <= 1'b1;
            end

            if (!sending) begin
                if (pend_valid) begin
                    // assemble the frame (big-endian per feature)
                    frame[0]  <= SYNC_BYTE;
                    frame[1]  <= seq;
                    frame[2]  <= p_spr[15:8];    frame[3]  <= p_spr[7:0];
                    frame[4]  <= p_tobi[15:8];   frame[5]  <= p_tobi[7:0];
                    frame[6]  <= p_ofi[15:8];    frame[7]  <= p_ofi[7:0];
                    frame[8]  <= p_emadev[15:8]; frame[9]  <= p_emadev[7:0];
                    frame[10] <= p_mom[15:8];    frame[11] <= p_mom[7:0];
                    frame[12] <= p_tflow[15:8];  frame[13] <= p_tflow[7:0];
                    // checksum computed next cycle from registered bytes is
                    // racy; compute inline from the pending values instead:
                    frame[14] <= SYNC_BYTE ^ seq
                               ^ p_spr[15:8]    ^ p_spr[7:0]
                               ^ p_tobi[15:8]   ^ p_tobi[7:0]
                               ^ p_ofi[15:8]    ^ p_ofi[7:0]
                               ^ p_emadev[15:8] ^ p_emadev[7:0]
                               ^ p_mom[15:8]    ^ p_mom[7:0]
                               ^ p_tflow[15:8]  ^ p_tflow[7:0];
                    seq        <= seq + 1;
                    pend_valid <= 1'b0;
                    byte_idx   <= '0;
                    sending    <= 1'b1;
                    tx_valid   <= 1'b0;
                end
            end else begin
                // byte-serial send with ready/valid handshake
                if (!tx_valid) begin
                    tx_data  <= frame[byte_idx];
                    tx_valid <= 1'b1;
                end else if (tx_ready) begin
                    if (byte_idx == FRAME_LEN-1) begin
                        tx_valid <= 1'b0;
                        sending  <= 1'b0;
                    end else begin
                        byte_idx <= byte_idx + 1;
                        tx_data  <= frame[byte_idx + 1];
                    end
                end
            end
        end
    end

endmodule