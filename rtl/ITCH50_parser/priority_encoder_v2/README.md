# Pipelined Radix-32 Priority Encoder

A parameterised priority encoder that finds the **lowest** and **highest** set
bit of two wide bitmasks, at 2-cycle latency, closing well above 100 MHz on a
mid-range Artix-7.

Written for an FPGA LOB engine, where the two masks are per-price-
level occupancy vectors and the answers are the best ask and the best bid(find highest for bids and find lowest for asks). w

| | |
|---|---|
| Latency | 2 clock cycles, fixed, no back-pressure |
| Throughput | 1 result per cycle (fully pipelined) |
| Fmax | 161 MHz @ 1024 bits, 126 MHz @ 2048 bits (`xc7a200tfbg484-2`, OOC synthesis) |
| Resources @ 1024 bits, both sides | 4,546 LUT , 406 FF , 528 CARRY4 , 0 DSP , 0 BRAM |
| Widths supported | Any power-of-two multiple of 32; 1024 and 2048 both built and timed |

---

## 1. The problem

Given a `WINDOW_SIZE`-bit occupancy mask, return the index of the lowest set
bit (and, on the other port, the highest), plus a flag saying whether any bit
was set at all. Every cycle. Inside a 10 ns budget.

The naive description of this is a priority encoder, and the naive *implementation*
is what makes it hard.

## 2. Why the obvious implementation cannot work

```systemverilog
for (int i = WINDOW_SIZE-1; i >= 0; i--)
    if (mask[i] && !found) begin addr = i; found = 1; end
```

The first implementation is correct and readable, but is poor at the speed. `for` inside `always_comb` is
not a loop - there is no counter in hardware. Synthesis unrolls it into
`WINDOW_SIZE` physical copies wired **in series**, because iteration *i* reads
the `found` flag that iteration *i+1* writes. That serial dependency is a carry
rippling through 1024 stages: **logic depth O(N)**, roughly 100 ns, about
10 MHz.

This is a structural limit, not a synthesis-effort problem. No amount of
optimisation directives shortens a 1024-deep dependency chain.

## 3. How this block works

### 3.1 Two primitives

**Isolate the lowest set bit** - `mask & (~mask + 1)`

`~mask + 1` is two's-complement negation. `x & (-x)` leaves exactly one bit
set: the lowest. Adding 1 to `~x` ripples a carry through the trailing ones of
`~x` (the trailing zeros of `x`) and stops at `x`'s lowest set bit, so `-x`
agrees with `x` there and disagrees above it. One incrementer (a dedicated
carry chain) plus a bitwise AND - **constant depth**.

**One-hot to binary** - five OR-reductions over fixed masks

```
bin[0] = |(oh & 32'hAAAAAAAA);   bin[3] = |(oh & 32'hFF00FF00);
bin[1] = |(oh & 32'hCCCCCCCC);   bin[4] = |(oh & 32'hFFFF0000);
bin[2] = |(oh & 32'hF0F0F0F0);
```

Bit *k* of the index is 1 exactly when the set bit lies at a position whose
index has bit *k* set; each mask enumerates those positions. Every output bit
is an independent 16-input OR - about two LUT6 levels, no priority logic.

### 3.2 The tree

Finding the lowest set bit is decomposable: split the vector into 32-bit
groups, let every group solve its own sub-problem **in parallel**, then pick
the lowest group that reported a hit.

![Ripple chain versus radix-32 tree: 1024 serial stages at 63.7 ns become two
parallel levels at 12.4 ns](img/radix_tree.svg)

**Depth O(N) → O(log N).** 1024 serial stages become two shallow levels.

**The final concatenation is free.** `{grp_sel, local}` *is*
`grp_sel × 32 + local`, because `local` is exactly 5 bits and 32 = 2⁵ — no
adder, no gates. This is why the radix must be a power of two, and why
`WINDOW_SIZE` must be a power-of-two multiple of 32.

### 3.3 Highest set bit

The bid port needs the *highest* set bit. The mask is reversed, the same tree
finds the lowest, and the index is mapped back:

```systemverilog
mask_rev[i] = mask[WINDOW_SIZE-1-i];      // pure rewiring, zero gates
addr        = (WINDOW_SIZE-1) - idx_rev;
```

---

## 4. Module hierarchy

```
priority_encoder                 wrapper: both ports, handles the reversal
 ├── radix_find_lowest (u_ask)   the 2-cycle tree
 │    ├── find_lowest ×N         level 0, parallel, combinational
 │    │    └── onehot2bin        fixed 32→5
 │    └── onehot2bin_gen         level 1, width follows NUM_GROUPS
 └── radix_find_lowest (u_bid)   same tree, reversed mask
```

| Module | Role | Clocked? |
|---|---|---|
| `onehot2bin` | 32-bit one-hot → 5-bit binary, explicit masks | no |
| `onehot2bin_gen` | W-bit one-hot → log₂W binary, any power-of-two W | no |
| `find_lowest` | 32-bit leaf: isolate + encode + hit flag | no |
| `radix_find_lowest` | Two-level tree, both pipeline registers | **yes** |
| `priority_encoder` | Top wrapper, bid reversal, width plumbing | **yes** |

`onehot2bin_gen` exists because the two levels are only the same width when
`WINDOW_SIZE = 1024`. At 2048 the group level is 64 wide, at 4096 it is 128.
The fixed 32-bit version remains the leaf primitive, instantiated 2×N times.

---

## 5. Interface

### `priority_encoder`

| Dir | Signal | Width | Description |
|---|---|---|---|
| in | `clk` | 1 | |
| in | `arstn` | 1 | Active-low asynchronous reset |
| in | `bid_mask` | `WINDOW_SIZE` | Occupancy; result is the **highest** set bit |
| in | `ask_mask` | `WINDOW_SIZE` | Occupancy; result is the **lowest** set bit |
| out | `best_bid_addr` | `ADDR_W` | Meaningless when `best_bid_valid` is low |
| out | `best_bid_valid` | 1 | Any bit set in `bid_mask` |
| out | `best_ask_addr` | `ADDR_W` | Meaningless when `best_ask_valid` is low |
| out | `best_ask_valid` | 1 | Any bit set in `ask_mask` |

No handshake on either side. Masks are sampled every cycle; outputs are simply
valid two cycles later. The consumer is responsible for knowing when a result
corresponds to an input of interest.

### `radix_find_lowest` (usable standalone)

| Dir | Signal | Width |
|---|---|---|
| in | `clk`, `arstn` | 1 |
| in | `vec` | `WINDOW_SIZE` |
| out | `addr` | `ADDR_W` |
| out | `valid` | 1 |

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `WINDOW_SIZE` | 2048 | **Must be a power-of-two multiple of 32** |
| `ADDR_W` | `$clog2(WINDOW_SIZE)` | Derived; do not override |
| `NUM_GROUPS` | `WINDOW_SIZE/32` | Derived |
| `GSEL_W` | `$clog2(NUM_GROUPS)` | Derived; `ADDR_W = GSEL_W + 5` |

---

## 6. Timing

![Waveform: vec accepts A, B, C, D on consecutive cycles; addr produces each
result exactly two cycles later](img/timing.svg)

Fixed 2-cycle latency, one result per cycle, no stall condition and no
back-pressure path. A new vector may be presented every cycle.

`arstn` is asynchronous-assert; both pipeline registers clear, so `valid` is
low for two cycles after release.

---

## 7. Results

Out-of-context synthesis, `xc7a200tfbg484-2`, both bid and ask ports, 10 ns
clock constraint. The ripple-chain original is included on the same part and
the same flow, so the comparison is like-for-like.

| | **This block, 1024** | **This block, 2048** | **Ripple chain, 1024** |
|---|---|---|---|
| Latency | 2 cycles | 2 cycles | combinational |
| Slack @ 10 ns | **+3.795 ns** | **+2.055 ns** | — |
| Longest path | — | — | **63.692 ns** |
| **Fmax** | **161 MHz** | **126 MHz** | **15.7 MHz** |
| LUTs | 4,546 | 8,851 | 3,875 |
| Flip-flops | 406 | 792 | 0 |
| CARRY4 | 528 | 1,056 | 0 |
| MUXF7 / MUXF8 | 20 / 10 | 80 / 40 | 27 / 0 |
| DSP / BRAM | 0 / 0 | 0 / 0 | 0 / 0 |

Post-synthesis out-of-context figures; in-context, post-route numbers will
differ. The stronger in-system evidence is that in the full routed design this
block is **not** on the critical path.

### The resource count is fully explained by the structure

Predicted from the RTL before looking at the report, and matching exactly at
both widths — a useful check that nothing unexpected was inferred:

| | Predicted | Reported |
|---|---|---|
| FF @ 1024 | 2 × (32×5 + 32 + 10 + 1) = 2 × 203 | **406** ✓ |
| FF @ 2048 | 2 × (64×5 + 64 + 11 + 1) = 2 × 396 | **792** ✓ |
| CARRY4 @ 1024 | 64 leaves × 8 + 2 group × 8 = 512 + 16 | **528** ✓ |
| CARRY4 @ 2048 | 128 leaves × 8 + 2 group × 16 = 1024 + 32 | **1,056** ✓ |

The 2ⁿ two's-complement incrementers are the dominant cost — that is the price
of the isolate primitive, and it is what the carry chains are doing.

### Scaling behaviour

Doubling the window doubles area almost exactly (LUT ×1.95, FF ×1.95, CARRY4
×2.00) while costing only **22 % of Fmax** (161 → 126 MHz). Area is linear in
`WINDOW_SIZE`; frequency degrades far more slowly, because widening the window
adds one OR level to the group-stage encoder and doubles the group mux, rather
than deepening the tree. Reaching 4096 would need a third level to keep this
up.

### Versus the ripple chain — the result worth understanding

| | Cycles | Wall-clock latency | Ceiling imposed on the design |
|---|---|---|---|
| Ripple chain | 0 (combinational) | **63.7 ns** | ~15.7 MHz |
| This block | 2 | **20 ns** @ 100 MHz | none — not the critical path |

**Adding pipeline stages reduced latency by 3.2×.** Cycles only mean something
multiplied by a clock period you can actually achieve; two cycles of a 10 ns
clock beat one pass through 63.7 ns of combinational logic outright — and at
this block's own 161 MHz, two cycles is 12.4 ns, a 5.1× improvement.

The area price for that is remarkably small: **17 % more LUTs** (4,546 vs
3,875) plus 406 flip-flops, in exchange for roughly 4× the achievable clock and
removing a hard ceiling on every other module in the design.

*(The original RTL comment estimated the ripple chain at "~100 ns → about
10 MHz". The measured 63.7 ns / 15.7 MHz shows that estimate was the right
order of magnitude but pessimistic by about 1.6×. The conclusion is unchanged:
it cannot reach 100 MHz.)*

---

## 8. Verification

`tb_radix_find_lowest` - 14 directed tests, all passing.

| Case | What it catches |
|---|---|
| all zeros | phantom address / valid on an empty vector |
| bit 0, 5, 31 | basic addressing within group 0 |
| **bit 32** | **a swapped `{grp_sel, local_addr}` concatenation — every group-0 test hides this bug** |
| bit 33, 992, 1023 | group indexing, top-of-range, truncation |
| bits 5,100 → 5 | picks the lowest, not merely any |
| bits 32,33 → 32 | priority *within* a group |
| bits 31,32 → 31 | priority *across* a group boundary |
| bits 0,1023 → 0 | extreme spread |
| all ones → 0 | saturated input |
| all zeros again | a sticky `valid` flag |

```bash
bash tb/run_tb.sh tb_radix_find_lowest \
  priority_encoder_v2/onehot2bin.sv priority_encoder_v2/onehot2bin_gen.sv \
  priority_encoder_v2/find_lowest.sv priority_encoder_v2/radix_find_lowest.sv \
  tb/tb_radix_find_lowest.sv
```

### Known gaps

1. **Parameterisation is functionally untested.** Every test runs at
   `WINDOW_SIZE = 1024`. Synthesis confirms 2048 elaborates, infers the
   predicted structure, and meets 100 MHz with +2.055 ns to spare - but
   *building* is not *behaving*. The block's headline claim is width
   independence, and that is precisely the property nothing exercises. The
   testbench is already parameter-clean apart from hardcoded `1024'b1 << N`
   stimulus literals, so closing this is cheap.
2. **No randomised testing.** 14 directed vectors against a 2^1024 input space.
   A constrained-random test with a reference model, plus functional coverage on
   group-boundary bins, would close this cheaply.

---

## 9. Design notes

**Why not a comparator tree?** A comparator tree compares *values*. Here the
input is an occupancy bitmask - the value is implicit in the bit's position, so
the leaf operation reduces to two gates (`x & -x`) rather than a magnitude
comparator, and combining reduces to an OR of hit flags rather than a
compare-and-select carrying both value and index through every node. A
comparator tree would be right if you had 1024 price *values* to rank; it is
the wrong structure for a bitmask.

**Why radix 32?** It matches the natural width of the fixed one-hot encoder and
gives a two-level tree for 1024 bits. It also makes the final concatenation
free, since 32 is a power of two. Radix 8 or 64 would work with a
correspondingly deeper or shallower tree.

**Why two pipeline stages and not one?** The register between levels is what
breaks the combinational path; the output register keeps the block's outputs
driven directly by flip-flops, so a downstream consumer sees a clean
register-to-register path rather than inheriting this block's combinational
tail.

**A benign synthesis warning.** `Port oh[0] in module onehot2bin_gen is either
unconnected or has no load` is expected: `bin` defaults to zero and the `i = 0`
iteration assigns zero, so `oh[0]` cannot influence the output and is optimised
away. Nothing to fix.

---

## 10. Files

| File | Contents |
|---|---|
| `priority_encoder.sv` | Top wrapper  |
| `radix_find_lowest.sv` | The parameterised tree |
| `find_lowest.sv` | 32-bit leaf |
| `onehot2bin.sv` | Fixed 32→5 encoder |
| `onehot2bin_gen.sv` | Generic W→log₂W encoder |
| `priority_encoder_v2.sv` | **Superseded.** Hardcoded 1024-bit ancestor, kept for history and excluded from the build |

The ripple-chain original lives at `../../fm24_parser/priority_encoder_v1.sv`.
