/*
 * onehot2bin_gen
 * --------------
 * Parameterized one-hot -> binary encoder for ANY power-of-two width.
 *
 * The fixed 32-bit onehot2bin.sv (truth-table masks 0xAAAA..., 0xCCCC...)
 * stays the fast leaf primitive. This generic version is only used at the
 * GROUP level of radix_find_lowest, where the group count follows
 * WINDOW_SIZE (32 groups for a 1024 window, 64 for 2048, ...).
 *
 * Input is guaranteed one-hot (isolated lowest set bit) or all-zero; on
 * all-zero it returns 0 and the caller's separate `valid` flag gates it.
 * Synthesizes to a shallow OR-of-masks network (depth = log2(W)).
 */

module onehot2bin_gen #(
    parameter int W  = 32,
    parameter int BW = (W > 1) ? $clog2(W) : 1
)(
    input  logic [W-1:0]  oh,
    output logic [BW-1:0] bin
);

    always_comb begin
        bin = '0;
        for (int i = 0; i < W; i++)
            if (oh[i]) bin = i[BW-1:0];   // one-hot: at most one iteration fires
    end

endmodule
