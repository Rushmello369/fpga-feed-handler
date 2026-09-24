# `tob_tracker`

Assembles the top-of-book snapshot the feature engine consumes. Source:
[`rtl/ITCH50_parser/tob_tracker.sv`](../../rtl/ITCH50_parser/tob_tracker.sv)

[← back to README](../../README.md#6-the-order-book)

---

## 1. The delay line

No FSM — a 4-bit shift register off `book_updated` with exactly two taps.

```mermaid
flowchart LR
    BU([book_updated]) --> S0[t+1] --> S1[t+2] --> S2[t+3] --> S3[t+4]
    S1 --> LAUNCH[launch reads<br/>latch addr + valid]
    S3 --> PUB[publish snapshot]
```

The depth is **exactly 4 bits** because only those two taps are read. It was
`[4:0]`; bit 4 was written every cycle and never read, which synthesis dropped
but which misleads anyone counting pipeline stages from the source.

## 2. Where the 5 cycles go

```mermaid
sequenceDiagram
    participant B as book_update
    participant E as priority_encoder
    participant T as tob_tracker

    B->>T: book_updated, t+0
    Note over E: +2 encoder pipe flows through
    T->>B: read addresses, t+2
    Note over B: +1 address settles
    Note over B: +1 registered read returns
    B->>T: read data, t+4
    Note over T: +1 output register
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
    participant T as tob_tracker

    Note over D,T: BROKEN — re-sampling live wires at t+4
    D->>B: Replace, delete half
    B->>T: book_updated 1
    T->>B: read addr = level X
    D->>B: Replace, insert half
    B->>T: book_updated 2, live wires now level Y
    B->>T: read data returns qty of X
    Note over T: publishes idx Y with qty of X

    Note over D,T: FIXED — latch addr and valid once at t+2
    B->>T: book_updated 1
    T->>T: latch X
    B->>T: read data = qty of X
    Note over T: publishes idx X with qty of X
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
    T4[t+4, read data returned]
    T4 --> ASM[assemble idx and qty<br/>from the latched copy]
    ASM --> Q{both sides valid?}
    Q -->|yes| PUB([tob_valid = 1])
    Q -->|no| SUP([suppressed, one-sided book])
```

Both sides must exist. Features derived from a one-sided book would be
meaningless, so the snapshot is simply not published — which is one of the two
reasons an accepted event can produce no feature at all (the other is an
`order_lookup` miss). `latency_probe` counts both in `lat_unmatched`.

## 5. Prices stay as tick indices

```mermaid
flowchart LR
    RAW([raw ITCH price]) -->|normalised in book_update| IDX[window tick index]
    IDX --> TOB[tob_t holds indices, not prices]
    TOB --> FEAT([differences already in ticks<br/>no division needed])
```

This is the single decision that makes `DSP = 0` achievable. Carrying indices
rather than prices means `ask_idx − bid_idx` *is* the spread in ticks, with no
scaling step to divide by.
