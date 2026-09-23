# `order_lookup`

Resolves price and side for messages that carry only an order reference number,
and tracks each order's remaining live quantity. Source:
[`rtl/ITCH50_parser/order_lookup.sv`](../../rtl/ITCH50_parser/order_lookup.sv)

[← back to README](../../README.md#6-the-order-book)

---

## 1. Why this module has to exist

```mermaid
flowchart LR
    subgraph WIRE["what ITCH actually puts on the wire"]
        direction TB
        W1["<b>A / F</b> Add<br/>id, price, side, qty ✓"]
        W2["<b>E / C</b> Execute<br/>id, qty — <b>no price, no side</b>"]
        W3["<b>X</b> Cancel<br/>id, qty — <b>no price, no side</b>"]
        W4["<b>D</b> Delete<br/>id only — <b>no qty either</b>"]
        W5["<b>U</b> Replace<br/>new id, price, qty — <b>no side</b>"]
    end

    NEED["the book needs<br/>price + side + qty<br/>for every update"]

    W1 -->|"direct"| NEED
    W2 --> OL["<b>order_lookup</b><br/>per-order state"]
    W3 --> OL
    W4 --> OL
    W5 --> OL
    OL -->|"resolved"| NEED

    classDef gap fill:#fef2f2,stroke:#dc2626
    class W2,W3,W4,W5 gap
```

ITCH is a *delta* protocol. Reconstructing a book from it is not optional state —
it is the whole problem.

## 2. State machine

Three states, 3 cycles per operation, one in flight. `busy` is high outside
`IDLE`; callers must hold their inputs while it is asserted.

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> READ : ins_valid or qry_valid<br/>latch index, tag, payload
    READ --> WRITE : registered read of all<br/>five field arrays
    WRITE --> IDLE : insert → overwrite slot<br/>query → compare tag, emit res_valid

    note right of IDLE
        index = order_id[TABLE_BITS-1:0]
        tag   = order_id[63:TABLE_BITS]
        a zero-cost hash
    end note

    note right of WRITE
        res_valid pulses for
        QUERIES ONLY — an insert
        produces no result
    end note
```

## 3. Storage layout

```mermaid
flowchart TB
    ID["order_id — 64 bits"]
    ID --> IDX["low 14 bits<br/><b>index</b>"]
    ID --> TAG["high 50 bits<br/><b>tag</b>"]

    IDX --> MEM

    subgraph MEM["five separate arrays, 2^14 = 16,384 entries each"]
        direction LR
        M1["mem_valid<br/>1 bit"]
        M2["mem_tag<br/>50 bits"]
        M3["mem_price<br/>32 bits"]
        M4["mem_side<br/>1 bit"]
        M5["mem_qty<br/>32 bits"]
    end

    TAG --> CMP{"rd_tag == req_tag<br/>and rd_valid ?"}
    MEM --> CMP
    CMP -->|yes| HIT["res_hit = 1<br/>price, side, delta_qty"]
    CMP -->|no| MISS["res_hit = 0<br/>unknown or evicted id"]

    classDef bad fill:#fef2f2,stroke:#dc2626
    class MISS bad
```

**Why five arrays and not one struct array.** A single packed table of 16,384
entries would be roughly 1.9 Mbit, which exceeds Vivado's 1,000,000-bit
per-variable elaboration limit (`[Synth 8-4556]`). Split, each array is under the
limit and infers its own BRAM — and BRAM powers up to zero, so `mem_valid` starts
all-invalid with no explicit reset loop.

## 4. Collision policy, and why the golden model must copy it

The index is the low bits of the order id with no rehashing. Two live orders can
share it.

```mermaid
sequenceDiagram
    participant D as dispatcher
    participant T as order_lookup table

    D->>T: insert id = 0x...1234, price 161.20
    Note over T: slot[0x1234] ← order A
    D->>T: insert id = 0x...1234 (different high bits)
    Note over T: slot[0x1234] ← order B<br/><b>order A silently evicted</b>
    D->>T: query id = order A
    T-->>D: res_hit = 0
    Note over D: miss_count++<br/>the book update is skipped
```

This is a **deliberate simplification**, valid because the live order count for a
single instrument stays well under 2¹⁴. If `miss_count` shows otherwise, the fix is
to raise `TABLE_BITS` (the AX7A200B has BRAM to spare) or add a DDR-backed L2.

> **The contract requires the Python model to reproduce this exactly.** An
> unbounded dictionary is not an acceptable substitute — it would never miss, so
> it would disagree with hardware on every evicted order and the differential test
> would be meaningless. The 200k capture drives **14,060 agreeing evictions**,
> which is the evidence that the model does reproduce it.

## 5. Per-operation semantics

```mermaid
flowchart TD
    OP{"req_op"}
    OP -->|"OP_DELETE"| D1["new_qty = 0<br/>removed = 1<br/><b>res_delta_qty = rd_qty</b><br/>all that remained"]
    OP -->|"OP_EXECUTE<br/>OP_CANCEL"| D2["new_qty = max(rd_qty - req_qty, 0)<br/>removed = (new_qty == 0)<br/><b>res_delta_qty = req_qty</b><br/>the message amount"]

    D1 --> W["mem_qty ← new_qty<br/>mem_valid ← not removed"]
    D2 --> W
    W --> R(["res_valid pulse"])
```

The clamp on the subtract matters: a remove larger than what is resting indicates
an upstream inconsistency, but it must not wrap a 32-bit counter into a huge
positive quantity. The slot is freed the moment an order drains, which returns
capacity to the table without any garbage collection pass.

Verified by `tb_order_lookup` — **22 assertions**, including collision eviction
with `TABLE_BITS` shrunk to 4 to force it, Delete with no wire quantity, and
unknown-id misses.
