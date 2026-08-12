/*
 * eth_crc32
 * ---------
 * Byte-parallel CRC-32 engine for the Ethernet Frame Check Sequence (IEEE
 * 802.3 clause 3.2.9). One byte per clock, no multipliers, no tables in BRAM.
 *
 * PARAMETERS OF THE CRC (all fixed by the Ethernet standard):
 *   polynomial   0x04C11DB7, used here in REFLECTED form 0xEDB88320
 *   init         0xFFFFFFFF
 *   input        reflected (Ethernet transmits LSB-first within a byte)
 *   output       reflected
 *   final XOR    0xFFFFFFFF
 * These are exactly the parameters of zlib.crc32 / PKZIP, which is what makes
 * the software golden reference a one-liner.
 *
 * THE TWO OUTPUTS, AND WHY BOTH EXIST
 *
 *   fcs      = ~crc_raw. This is the value a TRANSMITTER appends to the frame.
 *
 *   crc_ok   = (crc_raw == 32'hDEBB20E3). This is how a RECEIVER checks a
 *              frame, and it is worth understanding rather than memorising:
 *              if you keep feeding the CRC through the frame's own 4 FCS
 *              bytes, the running register always lands on the same constant,
 *              regardless of payload content or length. That constant is the
 *              "residue". Verified in tb_eth_crc32 for payload lengths 1..100.
 *
 *              This matters for streaming: the receiver does NOT need to know
 *              where the frame ends in advance, nor buffer it, nor compare
 *              against a stored expected value. It just runs the CRC over
 *              everything and checks the residue when the PHY drops rx_dv.
 *
 * USAGE
 *   Assert `init` on the FIRST payload byte of the frame (i.e. the first byte
 *   after the SFD - preamble and SFD are NOT covered by the FCS). `init` may
 *   be asserted together with `data_valid`, in which case that byte is
 *   processed against a freshly seeded register, so no cycle is wasted at the
 *   start of every frame.
 *
 * TIMING
 *   The bit-serial LFSR is unrolled 8x combinationally. Each output bit
 *   collapses into a single wide XOR of input bits, so the path is a shallow
 *   XOR tree (a few LUT6 levels), not 8 sequential stages. Comfortable at the
 *   125 MHz an RGMII gigabit datapath needs.
 */

module eth_crc32 (
    input  logic        clk,
    input  logic        arstn,

    input  logic        init,        // seed the register (assert on 1st frame byte)
    input  logic        data_valid,
    input  logic [7:0]  data,

    output logic [31:0] crc_raw,     // running register, pre-final-XOR
    output logic [31:0] fcs,         // ~crc_raw : the 4 bytes a TX appends
    output logic        crc_ok       // RX: residue reached -> frame intact
);

    localparam logic [31:0] CRC_POLY    = 32'hEDB8_8320;  // reflected 0x04C11DB7
    localparam logic [31:0] CRC_INIT    = 32'hFFFF_FFFF;
    localparam logic [31:0] CRC_RESIDUE = 32'hDEBB_20E3;  // see header

    // One byte of CRC, as 8 unrolled bit-serial steps. Synthesis flattens this
    // into a combinational XOR network; the loop is elaboration-time only.
    function automatic logic [31:0] crc32_byte(input logic [31:0] crc_in,
                                               input logic [7:0]  d);
        logic [31:0] c;
        c = crc_in ^ {24'h00_0000, d};
        for (int i = 0; i < 8; i++)
            c = c[0] ? ((c >> 1) ^ CRC_POLY) : (c >> 1);
        return c;
    endfunction

    always_ff @(posedge clk) begin
        if (!arstn) begin
            crc_raw <= CRC_INIT;
        end else if (init) begin
            // init may coincide with the frame's first byte: seed and consume
            // it in the same cycle rather than burning a cycle per frame.
            crc_raw <= data_valid ? crc32_byte(CRC_INIT, data) : CRC_INIT;
        end else if (data_valid) begin
            crc_raw <= crc32_byte(crc_raw, data);
        end
    end

    assign fcs    = ~crc_raw;
    assign crc_ok = (crc_raw == CRC_RESIDUE);

endmodule
