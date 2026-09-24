# `board_link_tx`

Packs one feature vector into a 15-byte frame and serialises it. Source:
[`rtl/ITCH50_parser/board_link-tx.sv`](../../rtl/ITCH50_parser/board_link-tx.sv)

[← back to README](../../README.md#8-the-board-link)

---

## 1. Frame layout

```mermaid
flowchart LR
    B0[byte 0<br/>SYNC A5]
    B1[byte 1<br/>SEQ]
    B2[bytes 2-13<br/>six int16, big-endian]
    B14[byte 14<br/>XOR checksum]
    B0 --- B1 --- B2 --- B14
```

Six `signed int16`, **big-endian**, in frozen order. Big-endian to stay consistent
with the ITCH convention used everywhere else in the design, and with the golden
model's `struct.pack('>6h')`.

`SEQ` is the improvement over a sequence-less link: the receiver detects a lost
frame from a gap rather than never knowing.

## 2. Transmit flow

Not an enumerated FSM — two flags, `sending` and `pend_valid`.

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> IDLE: feat_valid, latch pending
    IDLE --> SENDING: assemble 15 bytes
    SENDING --> SENDING: tx_ready, next byte
    SENDING --> SENDING: feat_valid, replace pending
    SENDING --> IDLE: last byte accepted
```

**The checksum is computed inline from the pending values**, not from the
registered frame bytes on the following cycle. Reading back `frame[]` one cycle
later to XOR it would race the writes that are still landing — a subtle bug that
would produce frames whose checksum is right most of the time.

## 3. Drop-oldest, and the counter bug this exposed

One pending vector, no queue.

```mermaid
flowchart TD
    FV([feat_valid arrives]) --> Q{pend_valid already set?}
    Q -->|no| OK([latch it, nothing lost])
    Q -->|yes| DROP([latch it, drop_count++])
    WAS[old condition also counted<br/>arrivals while sending,<br/>which lose nothing]
```

**How the bug was caught.** A 200k-message replay reported `drop_count = 2160`
while emitting exactly **146,172 frames — the same count as the golden model, with
zero mismatches**. A frame-for-frame match is arithmetically impossible if 2,160
vectors had genuinely been lost. So the counter, not the datapath, was wrong.

Fixing the condition to `pend_valid` alone took `drop_count` from 433 → **0** on
the 50k capture, with frame count and every feature value unchanged.

**The testbench had encoded the bug.** `tb_board_link_tx` asserted
`drop_count == 2` for a sequence that drives three vectors and emits two frames —
while its *own* frame assertions in the same block verified that the second frame
carries the **third** vector, proving exactly one was lost. The two assertions
contradicted each other, and the frame assertions were right.

> A diagnostic counter that disagrees with the datapath is a bug in the counter
> until proven otherwise — but only if you notice the disagreement. Here the frame
> count was the independent check that made it visible.

## 4. Why drop-oldest rather than a FIFO

```mermaid
flowchart LR
    subgraph FIFO["a queue"]
        direction TB
        F1[oldest sent first] --> F2[receiver acts on stale state]
    end
    subgraph DO["drop-oldest"]
        direction TB
        D1[newest wins] --> D2[receiver acts on current book] --> D3[losses visible via SEQ]
    end
```

For a decision engine the newest market state is strictly more valuable than a
stale snapshot, so there is nothing to gain from queueing. The requirement this
creates on the consumer side is that **`drop_count` must be recorded alongside any
ML replay or latency report** — a run with drops cannot be described as
per-event-complete inference.

## 5. Receiver obligations

```mermaid
flowchart TD
    R1[search for 0xA5] --> R2[receive 15 bytes] --> R3[verify XOR] --> R4[check SEQ continuity] --> R5[restore six int16] --> R6[one valid per good frame]
    R3 -.-> R7[count errors and gaps]
    R4 -.-> R7
```

Full definition in [`board_link_spec.md`](../board_link_spec.md). The frame format
is **frozen**; the physical layer — PMOD pin assignment, serial or parallel PHY,
and the CDC between the two boards' asynchronous clock domains — is not yet
defined. UART currently substitutes for the link.

Verified by `tb_board_link_tx` — **38 assertions**: frame layout, checksum,
sequence rollover, and drop-oldest under back-pressure.
