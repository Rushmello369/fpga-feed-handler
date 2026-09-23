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
    IDLE --> ADDR1 : bu_valid<br/>latch is_add, price, qty, side
    ADDR1 --> ADDR2 : window bounds check<br/><b>+ subtract only</b>
    ADDR2 --> READ : in_window<br/><b>the divide, alone</b>
    ADDR2 --> IDLE : not in_window<br/><b>oow_count++</b>, drop
    READ --> WRITE : registered read of qty<br/>+ latch the mask bit
    WRITE --> IDLE : add or subtract, clamp at 0<br/>write qty + mask<br/><b>book_updated pulse</b>

    note right of ADDR1
        Splitting ADDR into two states
        is what closed 100 MHz —
        see section 3
    end note
```

## 2. Address computation

```mermaid
flowchart LR
    P["bu_price<br/>raw Price(4)<br/>dollars × 10,000"]
    P --> CHK{"price >= BASE_PRICE<br/>and price < BASE_PRICE<br/>+ WINDOW_SIZE × TICK_SIZE ?"}
    CHK -->|no| OOW["<b>oow_count++</b><br/>dropped silently"]
    CHK -->|yes| SUB["diff = price - BASE_PRICE<br/><i>narrowed to DIFF_W = 17 bits</i>"]
    SUB --> DIV["lvl = diff / TICK_SIZE<br/><i>TICK_SIZE = 100</i>"]
    DIV --> ADDR["level index<br/>ADDR_W = 10 bits"]

    classDef bad fill:#fef2f2,stroke:#dc2626
    class OOW bad
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
flowchart TB
    subgraph BEFORE["before — one ADDR state"]
        direction LR
        B1["32-bit compare<br/>window bounds"] --> B2["32-bit subtract"] --> B3["<b>32-bit divide</b><br/>by TICK_SIZE"]
    end

    subgraph AFTER["after — ADDR1 / ADDR2"]
        direction LR
        A1["ADDR1<br/>bounds check<br/>+ subtract"] -.->|"register"| A2["ADDR2<br/><b>17-bit divide</b><br/>alone"]
    end

    BEFORE -->|"WNS −0.055 ns<br/>✗ fails"| AFTER
    AFTER -->|"WNS +0.333 ns<br/>✓ met"| OK(["100 MHz closed"])

    classDef bad fill:#fef2f2,stroke:#dc2626
    classDef good fill:#ecfdf5,stroke:#059669
    class BEFORE bad
    class AFTER,OK good
```

**The fix worked twice over, and that is the interesting part.** Splitting the
state gave the divide its own cycle — but because `ADDR1` establishes
in-window-ness *first*, the difference handed to `ADDR2` is provably smaller than
`WINDOW_SIZE × TICK_SIZE`. So the divider narrowed from 32 bits to
`DIFF_W = $clog2(WINDOW_SIZE × TICK_SIZE)` = **17 bits** as well as gaining a
cycle. Both effects together produced the positive slack.

## 4. Storage, and why the mask is the source of truth

```mermaid
flowchart TB
    subgraph SIDE["per side — bid and ask"]
        direction TB
        QTY["<b>qty array</b><br/>WINDOW_SIZE × 32 bits<br/>BRAM<br/><i>never globally cleared</i>"]
        MASK["<b>occupancy mask</b><br/>WINDOW_SIZE × 1 bit<br/>distributed RAM<br/><b>IS reset</b>"]
    end

    RD["READ state"] --> QTY
    RD --> MASK
    QTY -->|old_qty| GATE{"old_valid ?<br/><i>the mask bit</i>"}
    MASK -->|old_valid| GATE
    GATE -->|yes| USE["eff_old = old_qty"]
    GATE -->|no| ZERO["eff_old = 0<br/><i>ignore stale BRAM</i>"]

    USE --> CALC
    ZERO --> CALC
    CALC["is_add ?<br/>eff_old + qty<br/>: max(eff_old - qty, 0)"]
    CALC --> WR["qty[lvl] ← new_qty<br/>mask[lvl] ← (new_qty != 0)"]
    WR --> STROBE(["<b>book_updated</b><br/>the timing anchor<br/>for everything downstream"])

    classDef anchor fill:#fef2f2,stroke:#dc2626,stroke-width:2px
    class STROBE anchor
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
    TT["<b>tob_tracker</b><br/>the requester"]
    BU["<b>book_update</b><br/>the storage"]

    TT -->|"bid_rd_addr →"| BU
    BU -->|"← bid_rd_data<br/>1-cycle registered"| TT
    TT -->|"ask_rd_addr →"| BU
    BU -->|"← ask_rd_data<br/>1-cycle registered"| TT
```

> **Read-port direction is the most commonly reversed thing in this design.**
> Address is an *input* to `book_update`; data is an *output*. These ports are
> driven unconditionally every cycle, independent of the FSM, which is the standard
> BRAM inference pattern.

Verified by `tb_book_update` — **14 assertions**: add and remove, zero clamping,
out-of-window drop counting, and mask/quantity coherence.
