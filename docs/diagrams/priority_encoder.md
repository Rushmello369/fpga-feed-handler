# `priority_encoder`

Finds the lowest and highest set bit of two wide occupancy masks — the best ask
and the best bid — at fixed 2-cycle latency. Source:
[`rtl/ITCH50_parser/priority_encoder_v2/`](../../rtl/ITCH50_parser/priority_encoder_v2/)

[← back to README](../../README.md#finding-the-best-bid-and-ask) ·
[full write-up](../../rtl/ITCH50_parser/priority_encoder_v2/README.md)

---

## 1. Module hierarchy

```mermaid
flowchart TB
    PE["<b>priority_encoder</b><br/>both ports, handles the reversal<br/><i>clocked</i>"]
    RA["<b>radix_find_lowest</b> u_ask<br/>the 2-cycle tree<br/><i>clocked</i>"]
    RB["<b>radix_find_lowest</b> u_bid<br/>same tree, reversed mask<br/><i>clocked</i>"]
    FL["<b>find_lowest</b> × NUM_GROUPS<br/>32-bit leaf<br/><i>combinational</i>"]
    O2B["<b>onehot2bin</b><br/>fixed 32 → 5<br/><i>combinational</i>"]
    O2BG["<b>onehot2bin_gen</b><br/>generic W → log₂W<br/><i>combinational</i>"]

    PE --> RA
    PE --> RB
    RA --> FL
    RA --> O2BG
    RB --> FL
    RB --> O2BG
    FL --> O2B

    classDef comb fill:#f3f4f6,stroke:#9ca3af
    class FL,O2B,O2BG comb
```

`onehot2bin_gen` exists because the two tree levels are only the same width at
`WINDOW_SIZE = 1024`. At 2048 the group level is 64 wide, at 4096 it is 128. The
fixed 32-bit version stays the leaf primitive.

## 2. Why the obvious implementation cannot work

```mermaid
flowchart LR
    subgraph NAIVE["for-loop with a found flag"]
        direction LR
        N0["bit 0"] --> N1["bit 1"] --> N2["bit 2"] --> NDOTS["..."] --> N1023["bit 1023"]
    end
    NAIVE --> RES["<b>logic depth O(N)</b><br/>63.7 ns measured<br/>≈ 15.7 MHz"]

    classDef bad fill:#fef2f2,stroke:#dc2626
    class NAIVE,RES bad
```

A `for` inside `always_comb` is not a loop — there is no counter in hardware.
Synthesis unrolls it into 1024 physical copies wired **in series**, because
iteration *i* reads the `found` flag that iteration *i+1* writes. That serial
dependency is a carry rippling through 1024 stages. It is a structural limit, not
a synthesis-effort problem: no directive shortens a 1024-deep dependency chain.

## 3. The radix-32 tree

```mermaid
flowchart TB
    VEC["vec — 1024 bits"]

    subgraph L0["level 0 — 32 leaves, all in parallel, combinational"]
        direction LR
        G0["find_lowest<br/>bits 0-31"]
        G1["find_lowest<br/>bits 32-63"]
        GD["..."]
        G31["find_lowest<br/>bits 992-1023"]
    end

    REG1["<b>pipeline register 1</b><br/>leaf_addr_q[32], leaf_hit_q[32]"]

    subgraph L1["level 1 — group stage"]
        direction TB
        ISO["grp_oh = hit & (~hit + 1)<br/>isolate lowest group"]
        O2B["onehot2bin_gen<br/>→ grp_sel, 5 bits"]
        MUX["mux: leaf_addr_q[grp_sel]<br/>→ local_addr, 5 bits"]
    end

    CONCAT["addr = {grp_sel, local_addr}<br/><b>zero gates</b>"]
    REG2["<b>pipeline register 2</b><br/>addr, valid"]
    OUT(["addr + valid<br/>2 cycles after vec"])

    VEC --> L0 --> REG1 --> L1
    ISO --> O2B --> MUX
    L1 --> CONCAT --> REG2 --> OUT

    classDef free fill:#ecfdf5,stroke:#059669
    class CONCAT free
```

**Depth O(N) → O(log N).** 1024 serial stages become two shallow parallel levels.

**The concatenation is free.** `{grp_sel, local_addr}` *is*
`grp_sel × 32 + local_addr`, because `local_addr` is exactly 5 bits and 32 = 2⁵ —
no adder, no gates. This is why the radix must be a power of two, and why
`WINDOW_SIZE` must be a power-of-two multiple of 32.

## 4. The two primitives

```mermaid
flowchart LR
    subgraph P1["isolate the lowest set bit"]
        direction TB
        I1["mask"]
        I2["~mask + 1<br/><i>two's complement negation</i><br/>one carry chain"]
        I3["mask & (~mask + 1)<br/><b>exactly one bit set</b>"]
        I1 --> I2 --> I3
    end

    subgraph P2["one-hot → binary, 5 OR-reductions"]
        direction TB
        B0["bin[0] = OR-reduce of oh AND 0xAAAAAAAA"]
        B1["bin[1] = OR-reduce of oh AND 0xCCCCCCCC"]
        B2["bin[2] = OR-reduce of oh AND 0xF0F0F0F0"]
        B3["bin[3] = OR-reduce of oh AND 0xFF00FF00"]
        B4["bin[4] = OR-reduce of oh AND 0xFFFF0000"]
    end

    P1 --> P2
```

`~x + 1` ripples a carry through the trailing ones of `~x` — the trailing *zeros*
of `x` — and stops at `x`'s lowest set bit, so `−x` agrees with `x` there and
disagrees above it. Constant depth.

For the encoder: bit *k* of the index is 1 exactly when the set bit lies at a
position whose index has bit *k* set, and each constant mask enumerates those
positions. Every output bit is an independent 16-input OR, about two LUT6 levels,
with no priority logic at all.

## 5. Highest set bit, for the bid side

```mermaid
flowchart LR
    BM["bid_mask"] --> REV["mask_rev[i] = mask[N-1-i]<br/><b>pure rewiring, zero gates</b>"]
    REV --> TREE["the same radix tree<br/>finds the lowest"]
    TREE --> MAP["addr = (N-1) - idx_rev"]
    MAP --> OUT(["best_bid_addr"])

    classDef free fill:#ecfdf5,stroke:#059669
    class REV free
```

Best ask is the lowest price with liquidity; best bid is the highest. One tree
serves both — reverse the mask, find the lowest, map the index back. The
subtraction form is exact for any power-of-two width, unlike the `~idx` trick the
superseded fixed-1024 ancestor used.

## 6. Results

Out-of-context synthesis, `xc7a200tfbg484-2`, both ports, 10 ns constraint.

| | **Tree, 1024** | **Tree, 2048** | **Ripple chain, 1024** |
|---|---|---|---|
| Latency | 2 cycles | 2 cycles | combinational |
| Slack @ 10 ns | **+3.795 ns** | **+2.055 ns** | — |
| Longest path | — | — | **63.692 ns** |
| **Fmax** | **161 MHz** | **126 MHz** | **15.7 MHz** |
| LUTs | 4,546 | 8,851 | 3,875 |
| Flip-flops | 406 | 792 | 0 |
| DSP / BRAM | 0 / 0 | 0 / 0 | 0 / 0 |

**Adding pipeline stages reduced wall-clock latency by 3.2×.** Two cycles of a
10 ns clock beat one pass through 63.7 ns of combinational logic outright — and at
this block's own 161 MHz, two cycles is 12.4 ns, a 5.1× improvement. Cycles only
mean something multiplied by a clock period you can actually achieve.

The area price is **17 % more LUTs** plus 406 flip-flops, in exchange for roughly
4× the achievable clock and removing a hard ceiling on every other module.
