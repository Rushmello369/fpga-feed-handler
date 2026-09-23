# `tob_tracker`

Assembles the top-of-book snapshot the feature engine consumes. Source:
[`rtl/ITCH50_parser/tob_tracker.sv`](../../rtl/ITCH50_parser/tob_tracker.sv)

[← back to README](../../README.md#6-the-order-book)

---

## 1. The delay line

No FSM — a 4-bit shift register off `book_updated` with exactly two taps.

```mermaid
flowchart LR
    BU(["book_updated<br/>t+0"])
    S0["upd_shift[0]<br/>t+1"]
    S1["upd_shift[1]<br/><b>t+2 — TAP</b>"]
    S2["upd_shift[2]<br/>t+3"]
    S3["upd_shift[3]<br/><b>t+4 — TAP</b>"]

    BU --> S0 --> S1 --> S2 --> S3

    S1 --> LAUNCH["<b>launch reads + latch</b><br/>bid_rd_addr ← best_bid_addr<br/>lat_bid_addr ← best_bid_addr<br/>lat_bid_valid ← best_bid_valid"]
    S3 --> PUB["<b>publish</b><br/>tob.bid_idx ← lat_bid_addr<br/>tob.bid_qty ← bid_rd_data<br/>tob_valid ← both sides valid"]

    classDef tap fill:#fef2f2,stroke:#dc2626,stroke-width:2px
    class S1,S3 tap
```

The depth is **exactly 4 bits** because only those two taps are read. It was
`[4:0]`; bit 4 was written every cycle and never read, which synthesis dropped
but which misleads anyone counting pipeline stages from the source.

## 2. Where the 5 cycles go

```mermaid
sequenceDiagram
    autonumber
    participant B as book_update
    participant E as priority_encoder
    participant T as tob_tracker

    B->>T: book_updated (t+0)
    Note over E: +2 — the encoder's two-stage<br/>pipe flows the new mask through
    T->>B: bid_rd_addr / ask_rd_addr (t+2)
    Note over B: +1 — read address settles
    Note over B: +1 — registered read returns data
    B->>T: bid_rd_data / ask_rd_data (t+4)
    Note over T: +1 — output register
    T->>T: tob + tob_valid published
```

| Stage | Cycles |
|---|---:|
| encoder pipeline | 2 |
| read address settle | 1 |
| registered read data | 1 |
| output register | 1 |
| **`t_book2tob`** | **5** |

This is a fixed-latency chain with no data dependence, so the value was derived
from the RTL *before* measurement. It came back as 5 in simulation and again as 5
on hardware — which is why `latency_probe` doubles as an online correctness check
rather than merely an instrument. Anything other than 5 is a bug, not a
measurement.

## 3. The race this module is built around

`best_bid_addr` and friends are **live combinational wires** from the encoder, not
latched values. An earlier version waited t+2 to latch the read *address*, then at
t+4 re-read the live wires again to assemble `tob.bid_idx`.

```mermaid
sequenceDiagram
    participant D as dispatcher
    participant B as book_update
    participant E as encoder
    participant T as tob_tracker

    rect rgb(254, 242, 242)
    Note over D,T: BROKEN — re-sampling live wires at t+4
    D->>B: Replace, delete half
    B->>T: book_updated #1 (t=0)
    T->>B: read addr = level X (t=2)
    D->>B: Replace, insert half
    B->>T: book_updated #2 (t≈5)
    E->>E: best_bid_addr now = level Y
    B->>T: rd_data arrives — <b>quantity of X</b> (t=4)
    T->>T: publishes {idx: Y, qty: qty_of_X}
    Note over T: internally inconsistent snapshot
    end

    rect rgb(236, 253, 245)
    Note over D,T: FIXED — latch addr AND valid once at t+2
    B->>T: book_updated #1
    T->>T: lat_bid_addr ← X, lat_bid_valid ← v (t=2)
    B->>T: rd_data = qty_of_X (t=4)
    T->>T: publishes {idx: X, qty: qty_of_X}
    Note over T: reuses the latched copy —<br/>a later update cannot<br/>retroactively alter it
    end
```

**Why the window is exactly wide enough to hit.** `event_dispatcher` fires a
Replace's delete and insert roughly 4–5 cycles apart — right inside this 4-cycle
delay line. So the bug is not a rare race, it fires on *every* Replace, and it is
invisible on any capture that contains none.

Verified by `tb_tob_tracker_backtoback` (9 assertions), and validated by
**mutation testing**: removing the t+2 address latch makes that testbench fail
while the single-update `tb_tob_tracker` still passes.

## 4. Publish condition

```mermaid
flowchart TD
    T4["t+4 — read data returned"]
    T4 --> ASM["tob.bid_idx ← lat_bid_addr<br/>tob.bid_qty ← lat_bid_valid ? bid_rd_data : 0<br/>tob.ask_idx ← lat_ask_addr<br/>tob.ask_qty ← lat_ask_valid ? ask_rd_data : 0"]
    ASM --> Q{"lat_bid_valid<br/><b>and</b><br/>lat_ask_valid ?"}
    Q -->|yes| PUB(["<b>tob_valid = 1</b>"])
    Q -->|no| SUP["suppressed —<br/>a one-sided book has no<br/>spread and no mid"]

    classDef good fill:#ecfdf5,stroke:#059669
    classDef bad fill:#f3f4f6,stroke:#9ca3af
    class PUB good
    class SUP bad
```

Both sides must exist. Features derived from a one-sided book would be
meaningless, so the snapshot is simply not published — which is one of the two
reasons an accepted event can produce no feature at all (the other is an
`order_lookup` miss). `latency_probe` counts both in `lat_unmatched`.

## 5. Prices stay as tick indices

```mermaid
flowchart LR
    RAW["raw ITCH price<br/>Price(4) = dollars × 10,000"]
    RAW -->|"normalised once,<br/>in book_update"| IDX["window tick index<br/>0 .. WINDOW_SIZE-1"]
    IDX --> TOB["tob_t.bid_idx / ask_idx<br/><b>16-bit indices, not prices</b>"]
    TOB --> FEAT["feature_engine<br/>differences are <b>already in ticks</b><br/>→ no division anywhere"]

    classDef good fill:#ecfdf5,stroke:#059669
    class FEAT good
```

This is the single decision that makes `DSP = 0` achievable. Carrying indices
rather than prices means `ask_idx − bid_idx` *is* the spread in ticks, with no
scaling step to divide by.
