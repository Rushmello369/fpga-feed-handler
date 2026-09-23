# `board_link_tx`

Packs one feature vector into a 15-byte frame and serialises it. Source:
[`rtl/ITCH50_parser/board_link-tx.sv`](../../rtl/ITCH50_parser/board_link-tx.sv)

[← back to README](../../README.md#8-the-board-link)

---

## 1. Frame layout

```mermaid
flowchart LR
    B0["<b>0</b><br/>SYNC<br/>0xA5"]
    B1["<b>1</b><br/>SEQ<br/>mod 256"]
    B2["<b>2-3</b><br/>spr"]
    B4["<b>4-5</b><br/>tobi"]
    B6["<b>6-7</b><br/>ofi"]
    B8["<b>8-9</b><br/>emadev"]
    B10["<b>10-11</b><br/>mom"]
    B12["<b>12-13</b><br/>tflow"]
    B14["<b>14</b><br/>CHK<br/>XOR 0-13"]

    B0 --- B1 --- B2 --- B4 --- B6 --- B8 --- B10 --- B12 --- B14

    classDef sync fill:#eff6ff,stroke:#2563eb
    classDef feat fill:#ecfdf5,stroke:#059669
    classDef chk fill:#fff4e5,stroke:#f59e0b
    class B0,B1 sync
    class B2,B4,B6,B8,B10,B12 feat
    class B14 chk
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
    IDLE --> IDLE : feat_valid<br/>latch into p_* registers<br/>pend_valid ← 1
    IDLE --> SENDING : not sending and pend_valid<br/><b>assemble all 15 bytes</b><br/>+ inline checksum<br/>seq++, pend_valid ← 0
    SENDING --> SENDING : tx_ready<br/>byte_idx++<br/>tx_data ← frame[byte_idx+1]
    SENDING --> IDLE : byte_idx == 14 and tx_ready<br/>tx_valid ← 0
    SENDING --> SENDING : feat_valid<br/>replace pending vector

    note right of SENDING
        tx_valid is held HIGH for the
        WHOLE frame, which is what makes
        the arbiter's grant frame-atomic
    end note
```

**The checksum is computed inline from the pending values**, not from the
registered frame bytes on the following cycle. Reading back `frame[]` one cycle
later to XOR it would race the writes that are still landing — a subtle bug that
would produce frames whose checksum is right most of the time.

## 3. Drop-oldest, and the counter bug this exposed

One pending vector, no queue.

```mermaid
flowchart TD
    FV["feat_valid arrives"]
    FV --> Q{"pend_valid<br/>already set ?"}
    Q -->|no| OK["latch it<br/><b>nothing lost</b>"]
    Q -->|yes| DROP["latch it<br/><b>drop_count++</b><br/>the waiting vector is overwritten"]

    subgraph WAS["the bug — condition was (sending OR pend_valid)"]
        direction TB
        W1["arriving while <i>sending</i><br/>counted as a drop"]
        W2["but the previous vector was already<br/>latched into the frame in flight —<br/>this one just becomes pending<br/>and goes out next"]
        W3["<b>nothing was actually lost</b>"]
        W1 --> W2 --> W3
    end

    classDef good fill:#ecfdf5,stroke:#059669
    classDef bad fill:#fef2f2,stroke:#dc2626
    class OK good
    class WAS bad
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
        F1["oldest vector<br/>sent first"]
        F2["under sustained back-pressure,<br/>the receiver acts on<br/><b>stale market state</b>"]
        F1 --> F2
    end

    subgraph DO["drop-oldest"]
        D1["newest vector wins"]
        D2["receiver always acts on<br/><b>the current book</b>"]
        D3["losses are counted and<br/>visible via SEQ gaps"]
        D1 --> D2 --> D3
    end

    classDef bad fill:#fef2f2,stroke:#dc2626
    classDef good fill:#ecfdf5,stroke:#059669
    class FIFO bad
    class DO good
```

For a decision engine the newest market state is strictly more valuable than a
stale snapshot, so there is nothing to gain from queueing. The requirement this
creates on the consumer side is that **`drop_count` must be recorded alongside any
ML replay or latency report** — a run with drops cannot be described as
per-event-complete inference.

## 5. Receiver obligations

```mermaid
flowchart TD
    R1["search for 0xA5<br/>frame sync"]
    R2["receive fixed 15 bytes"]
    R3["verify XOR checksum"]
    R4["check SEQ continuity"]
    R5["restore six big-endian<br/>signed int16"]
    R6["one valid <b>only</b> for<br/>complete, checksum-passing frames"]
    R7["count checksum errors,<br/>sequence gaps, valid frames"]

    R1 --> R2 --> R3 --> R4 --> R5 --> R6
    R3 -.-> R7
    R4 -.-> R7
```

Full definition in [`board_link_spec.md`](../board_link_spec.md). The frame format
is **frozen**; the physical layer — PMOD pin assignment, serial or parallel PHY,
and the CDC between the two boards' asynchronous clock domains — is not yet
defined. UART currently substitutes for the link.

Verified by `tb_board_link_tx` — **38 assertions**: frame layout, checksum,
sequence rollover, and drop-oldest under back-pressure.
