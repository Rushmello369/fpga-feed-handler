# `feature_engine`

Six features from each top-of-book snapshot, computed with adds, subtracts and
shifts only. Source:
[`rtl/ITCH50_parser/feature_engine.sv`](../../rtl/ITCH50_parser/feature_engine.sv)

[← back to README](../../README.md#7-the-feature-engine)

---

## 1. Two independent input streams

The structural detail most often missed in this module: the snapshot stream and
the trade stream are **unsynchronised**, and they drive different features.

```mermaid
flowchart LR
    A([Stream A<br/>tob_valid snapshots]) --> F1[SPR]
    A --> F2[TOBI]
    A --> F3[OFI]
    A --> F4[EMADEV]
    A --> F5[MOM]
    B([Stream B<br/>trade_valid, E and C only]) --> ACC[tflow_acc ring]
    ACC -->|sampled by Stream A| F6[TFLOW]
    F1 --> OUT([feat_valid])
    F2 --> OUT
    F3 --> OUT
    F4 --> OUT
    F5 --> OUT
    F6 --> OUT
```

The trade accumulator updates in its own `always_ff` block, on its own event
stream. TFLOW is whatever that accumulator happens to hold when a snapshot
arrives. Only Stream A produces `feat_valid`.

## 2. The six datapaths, all in parallel

One cycle from `tob_valid` to `feat_valid`, regardless of feature count — the
depth is set by the deepest single feature, not their sum.

```mermaid
flowchart LR
    TOB([tob_valid]) --> PRE[mid, bidq, askq]
    TRADE([trade_valid]) --> ACC[tflow_acc<br/>16-trade ring]

    PRE --> SPR
    PRE --> TOBI
    PRE --> OFI
    PRE --> EMADEV
    PRE --> MOM
    ACC --> TFLOW

    SPR --> SAT[sat16]
    TOBI --> SAT
    OFI --> SAT
    EMADEV --> SAT
    MOM --> SAT
    TFLOW --> SAT

    SAT --> OUT([feat_valid, 6 x int16])
```

**No multiplier, no divider, anywhere.** Three choices make that possible:

1. Prices arrive as **window tick indices**, so `ask_idx − bid_idx` is already the
   spread in ticks — nothing to scale.
2. Imbalance is defined as a **difference, not a ratio** — TOBI is `bidq − askq`,
   not `bidq / (bidq + askq)`.
3. The EMA coefficient is **1/16**, so the update is a pure arithmetic shift.

The utilisation report proves it: **0 of 740 DSP slices**.

## 3. EMADEV — the extended-precision EMA

```mermaid
flowchart TD
    Q{ema_init?}
    Q -->|no, first sample| SEED[seed ema_frac<br/>emadev = 0]
    Q -->|yes| UPD[emadev = mid - ema_int<br/>update ema_frac]
    SEED --> ST[ema_frac carries<br/>4 extra fraction bits]
    UPD --> ST
```

**Why the 4 extra fraction bits.** An EMA whose state is a plain integer loses the
fractional part on every `>>> 4`, and repeated truncation bleeds precision until
the average drifts. Keeping the state as `ema << 4` and doing the update in the
extended domain confines the rounding to one place.

**Why seeding matters.** Without it, the first sample would be compared against an
EMA of zero, producing a `mid`-sized spike that has nothing to do with market
behaviour. The first snapshot seeds instead and reports `emadev = 0`.

## 4. MOM and TFLOW — the two ring structures

```mermaid
flowchart LR
    subgraph MOM["MOM — shift register, depth 8"]
        direction LR
        M0[slot 0] --> M1[slot 1] --> MD[...] --> M7[slot 7]
    end
    NEW([mid at t]) --> M0
    M7 --> DIFF([mom = mid t minus mid t-8])

    subgraph TF["TFLOW — ring buffer, depth 16"]
        direction TB
        SUM[add newest, subtract oldest]
        RING[tflow_ring, 16 slots]
        SUM --> RING
    end
    TRADE([trade event]) --> CON[contrib = plus or minus qty] --> SUM
```

The TFLOW ring is what keeps the window rolling without a re-sum: add the newest
contribution, subtract the one leaving. Constant work per trade, no matter the
depth.

**TFLOW sign convention.** `trade_side` is the **resting** order's side, from
`order_lookup`. A resting sell being lifted means an aggressive *buy*; a resting
buy being hit means an aggressive *sell*. TFLOW is positive for aggressive buying,
so `contrib = resting_side ? +qty : −qty`.

## 5. Two initialisation artefacts — specified, not accidental

```mermaid
flowchart LR
    subgraph OFI["OFI after reset"]
        direction TB
        O1[prev_bidq = prev_askq = 0] --> O2[first ofi equals tobi<br/>not zero]
    end
    subgraph MOMI["MOM after reset"]
        direction TB
        M1[eight history slots = 0] --> M2[first 8 vectors compare against 0] --> M3[true t vs t-8 from the 9th]
    end
```

Both are written into [`handler_contract.md`](../handler_contract.md) precisely so
the RTL and the Python model cannot quietly disagree about them. An "obvious" fix
in either implementation — zeroing the first OFI, or suppressing the first eight
MOM values — would break the differential test, and the contract is what settles
which side is wrong.

## 6. Saturation

```mermaid
flowchart LR
    X([32-bit intermediate]) --> S{sat16}
    S -->|greater than 32767| H([32767])
    S -->|less than -32768| L([-32768])
    S -->|otherwise| P([x])
```

All intermediate arithmetic is 32-bit; only the output is narrowed. Every shift is
**arithmetic** (`>>>`), so negative values keep their sign.

`mid2 = bid_idx + ask_idx` is deliberately **not** halved, which keeps half-tick
precision for free. The consequence to remember: one integer unit of EMADEV or MOM
is **half a price tick**, not a whole one.

Verified by `tb_feature_engine` — **42 assertions**: all six features, saturation
boundaries, EMA seeding, and both initialisation artefacts above.
