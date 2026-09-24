# `book_update`

Aggregate price-level order book: per-level quantities plus the occupancy masks
the priority encoder consumes. Source:
[`rtl/ITCH50_parser/book_update.sv`](../../rtl/ITCH50_parser/book_update.sv)

[← back to README](../../README.md#6-the-order-book)

---

## 1. State machine

Five states, 5 cycles per update, one in flight. `bu_ready = (state == IDLE)`.

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> ADDR1: bu_valid
    ADDR1 --> ADDR2: bounds check + subtract
    ADDR2 --> READ: in window
    ADDR2 --> IDLE: out of window
    READ --> WRITE: read qty + mask bit
    WRITE --> IDLE: write back, strobe
```

## 2. Address computation

```mermaid
flowchart LR
    P([bu_price<br/>Price 4, dollars x 10000])
    P --> CHK{inside window?}
    CHK -->|no| OOW([oow_count++, dropped])
    CHK -->|yes| SUB[diff = price - BASE_PRICE<br/>narrowed to 17 bits]
    SUB --> DIV[lvl = diff / TICK_SIZE]
    DIV --> ADDR([level index, 10 bits])
```

ITCH `Price(4)` has four implied decimals, but US equities quote in pennies — so
consecutive *real* price levels are 100 units apart. Normalising once, here, means
every downstream difference is already denominated in ticks, which is what lets
the feature engine avoid division entirely.

At `BASE_PRICE = 1,610,800` and `WINDOW_SIZE = 1024`, the window covers
**\$161.08 – \$171.31**.

## 3. The critical path, and how it was fixed

This address computation was the design's critical path at **WNS −0.055 ns**.

```mermaid
flowchart TD
    subgraph BEFORE["before — one ADDR state"]
        direction LR
        B1[32-bit bounds check] --> B2[32-bit subtract] --> B3[32-bit divide]
    end
    subgraph AFTER["after — ADDR1 then ADDR2"]
        direction LR
        A1[bounds check + subtract] -.->|register| A2[17-bit divide]
    end
    BEFORE -->|WNS -0.055 ns, fails| AFTER
    AFTER -->|WNS +0.333 ns, met| OK([100 MHz closed])
```

**The fix worked twice over, and that is the interesting part.** Splitting the
state gave the divide its own cycle — but because `ADDR1` establishes
in-window-ness *first*, the difference handed to `ADDR2` is provably smaller than
`WINDOW_SIZE × TICK_SIZE`. So the divider narrowed from 32 bits to
`DIFF_W = $clog2(WINDOW_SIZE × TICK_SIZE)` = **17 bits** as well as gaining a
cycle. Both effects together produced the positive slack.

## 4. Storage, and why the mask is the source of truth

```mermaid
flowchart TD
    RD[READ state]
    RD --> QTY[qty array<br/>BRAM, never cleared]
    RD --> MASK[occupancy mask<br/>distributed RAM, reset]
    QTY -->|old_qty| GATE{mask bit set?}
    MASK -->|old_valid| GATE
    GATE -->|yes| USE[eff_old = old_qty]
    GATE -->|no| ZERO[eff_old = 0]
    USE --> CALC[add, or subtract clamped at 0]
    ZERO --> CALC
    CALC --> WR[write qty and mask]
    WR --> STROBE([book_updated])
```

**BRAM contents have no reset.** The quantity arrays power up holding whatever
they hold and are never cleared en masse — clearing 1024 levels would take 1024
cycles, and there is nothing to clear them *for*. The occupancy mask *is* reset, so
it is the authority: if a level's mask bit is 0, its effective old quantity is 0
regardless of what stale bits sit in the memory. `old_valid` is latched in `READ`
for exactly this purpose.

The clamp on the subtract exists because a remove larger than what is resting
signals an upstream inconsistency, and a wrapped 32-bit quantity would corrupt the
book permanently rather than transiently.

## 5. Two independent read ports

```mermaid
flowchart LR
    TT[tob_tracker<br/>the requester]
    BU[book_update<br/>the storage]
    TT -->|addr out| BU
    BU -->|data in, 1 cycle| TT
```

> **Read-port direction is the most commonly reversed thing in this design.**
> Address is an *input* to `book_update`; data is an *output*. These ports are
> driven unconditionally every cycle, independent of the FSM, which is the standard
> BRAM inference pattern.

Verified by `tb_book_update` — **14 assertions**: add and remove, zero clamping,
out-of-window drop counting, and mask/quantity coherence.
