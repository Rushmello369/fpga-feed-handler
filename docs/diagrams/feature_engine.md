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
    subgraph A["Stream A — snapshots"]
        direction TB
        TOB["tob_valid + tob_t<br/>from tob_tracker<br/><i>one per book update</i>"]
    end

    subgraph B["Stream B — trades"]
        direction TB
        TR["trade_valid + side + qty<br/><b>direct from the dispatcher</b><br/><i>E / C hits only</i>"]
    end

    A --> F1["SPR"]
    A --> F2["TOBI"]
    A --> F3["OFI"]
    A --> F4["EMADEV"]
    A --> F5["MOM"]
    B --> ACC["tflow_acc<br/>rolling 16-trade ring"]
    ACC -->|"sampled by stream A"| F6["TFLOW"]

    F1 --> OUT(["feat_valid<br/>6 × signed int16"])
    F2 --> OUT
    F3 --> OUT
    F4 --> OUT
    F5 --> OUT
    F6 --> OUT

    classDef sa fill:#eff6ff,stroke:#2563eb
    classDef sb fill:#fff4e5,stroke:#f59e0b
    class TOB,F1,F2,F3,F4,F5 sa
    class TR,ACC sb
```

The trade accumulator updates in its own `always_ff` block, on its own event
stream. TFLOW is whatever that accumulator happens to hold when a snapshot
arrives. Only Stream A produces `feat_valid`.

## 2. The six datapaths, all in parallel

One cycle from `tob_valid` to `feat_valid`, regardless of feature count — the
depth is set by the deepest single feature, not their sum.

```mermaid
flowchart TB
    IN["tob_valid<br/>bid_idx, ask_idx, bid_qty, ask_qty"]

    IN --> PRE["mid = bid_idx + ask_idx<br/><b>no >> 1</b><br/>bidq = bid_qty >>> QTY_SHIFT<br/>askq = ask_qty >>> QTY_SHIFT"]

    PRE --> D1["<b>SPR</b><br/>ask_idx - bid_idx"]
    PRE --> D2["<b>TOBI</b><br/>bidq - askq"]
    PRE --> D3["<b>OFI</b><br/>(bidq - prev_bidq)<br/>- (askq - prev_askq)"]
    PRE --> D4["<b>EMADEV</b><br/>mid - (ema_frac >>> 4)"]
    PRE --> D5["<b>MOM</b><br/>mid - mid_hist[7]"]
    ACC["tflow_acc"] --> D6["<b>TFLOW</b><br/>tflow_acc >>> QTY_SHIFT"]

    D1 --> S["<b>sat16</b><br/>clamp to signed 16 bits"]
    D2 --> S
    D3 --> S
    D4 --> S
    D5 --> S
    D6 --> S
    S --> OUT(["feat_valid + 6 × int16"])

    D3 -.->|"update"| ST1["prev_bidq, prev_askq"]
    D4 -.->|"update"| ST2["ema_frac"]
    D5 -.->|"shift in"| ST3["mid_hist[0..7]"]

    classDef state fill:#f3f4f6,stroke:#9ca3af,stroke-dasharray:3 3
    class ST1,ST2,ST3 state
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
    Q{"ema_init ?"}
    Q -->|"no — first sample"| SEED["ema_frac ← mid << 4<br/>ema_init ← 1<br/><b>emadev = 0</b>"]
    Q -->|yes| UPD["ema_int = ema_frac >>> 4<br/><b>emadev = sat16(mid - ema_int)</b><br/>ema_frac += ((mid << 4) - ema_frac) >>> 4"]

    SEED --> ST["ema_frac<br/><i>carries 4 extra fraction bits</i>"]
    UPD --> ST

    classDef seed fill:#fff4e5,stroke:#f59e0b
    class SEED seed
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
    subgraph MOM["MOM — mid shift register, depth 8"]
        direction LR
        M0["mid_hist[0]"] --> M1["[1]"] --> MD["..."] --> M7["<b>[7]</b>"]
    end
    NEW["mid(t)"] --> M0
    M7 --> DIFF["mom = sat16(mid(t) - mid_hist[7])"]

    subgraph TF["TFLOW — ring buffer, depth 16"]
        direction TB
        RING["tflow_ring[0..15]"]
        WR["tflow_wr pointer"]
        SUM["tflow_acc += contrib - tflow_ring[wr]<br/>tflow_ring[wr] ← contrib<br/>wr++"]
    end
    TRADE["trade event"] --> CON["contrib = side ? +qty : -qty"]
    CON --> SUM
    SUM --> RING
    WR --> SUM
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
        O1["prev_bidq = 0<br/>prev_askq = 0"]
        O2["so ofi = (bidq - 0) - (askq - 0)<br/>= bidq - askq<br/><b>= tobi, not 0</b>"]
        O1 --> O2
    end

    subgraph MOMI["MOM after reset"]
        M1["mid_hist[0..7] = 0"]
        M2["first 8 vectors compare<br/>against 0"]
        M3["from the <b>9th</b> onward it is a<br/>true t vs t-8 difference"]
        M1 --> M2 --> M3
    end

    classDef note fill:#fff4e5,stroke:#f59e0b
    class O2,M2 note
```

Both are written into [`handler_contract.md`](../handler_contract.md) precisely so
the RTL and the Python model cannot quietly disagree about them. An "obvious" fix
in either implementation — zeroing the first OFI, or suppressing the first eight
MOM values — would break the differential test, and the contract is what settles
which side is wrong.

## 6. Saturation

```mermaid
flowchart LR
    X["32-bit intermediate"] --> S{"sat16"}
    S -->|"x > 32767"| H["32767"]
    S -->|"x < -32768"| L["-32768"]
    S -->|otherwise| P["x"]
```

All intermediate arithmetic is 32-bit; only the output is narrowed. Every shift is
**arithmetic** (`>>>`), so negative values keep their sign.

`mid2 = bid_idx + ask_idx` is deliberately **not** halved, which keeps half-tick
precision for free. The consequence to remember: one integer unit of EMADEV or MOM
is **half a price tick**, not a whole one.

Verified by `tb_feature_engine` — **42 assertions**: all six features, saturation
boundaries, EMA seeding, and both initialisation artefacts above.
