# `order_lookup`

Resolves price and side for messages that carry only an order reference number,
and tracks each order's remaining live quantity. Source:
[`rtl/ITCH50_parser/order_lookup.sv`](../../rtl/ITCH50_parser/order_lookup.sv)

[← back to README](../../README.md#6-the-order-book)

---

## 1. Why this module has to exist

```mermaid
flowchart LR
    W1[A / F Add<br/>id, price, side, qty] -->|direct| NEED[book needs<br/>price + side + qty]
    W2[E / C Execute<br/>id, qty only] --> OL[order_lookup<br/>per-order state]
    W3[X Cancel<br/>id, qty only] --> OL
    W4[D Delete<br/>id only] --> OL
    W5[U Replace<br/>no side] --> OL
    OL -->|resolved| NEED
```

ITCH is a *delta* protocol. Reconstructing a book from it is not optional state —
it is the whole problem.

## 2. State machine

Three states, 3 cycles per operation, one in flight. `busy` is high outside
`IDLE`; callers must hold their inputs while it is asserted.

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> READ: ins_valid or qry_valid
    READ --> WRITE: registered read
    WRITE --> IDLE: insert writes slot<br/>query emits res_valid
```

## 3. Storage layout

```mermaid
flowchart TD
    ID([order_id, 64 bits])
    ID -->|low 14 bits| IDX[index]
    ID -->|high 50 bits| TAG[tag]
    IDX --> MEM
    subgraph MEM["16,384 entries, five parallel arrays"]
        direction LR
        M1[valid]
        M2[tag]
        M3[price]
        M4[side]
        M5[qty]
    end
    MEM --> CMP{tag match?}
    TAG --> CMP
    CMP -->|yes| HIT([price, side, delta_qty])
    CMP -->|no| MISS([unknown or evicted])
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
    participant T as order_lookup

    D->>T: insert id A
    Note over T: slot[0x1234] holds A
    D->>T: insert id B, same low bits
    Note over T: slot[0x1234] holds B,<br/>A silently evicted
    D->>T: query id A
    T-->>D: res_hit = 0
    Note over D: miss_count++,<br/>book update skipped
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
    OP{req_op}
    OP -->|OP_DELETE| D1[new_qty = 0<br/>delta_qty = all remaining]
    OP -->|OP_EXECUTE / OP_CANCEL| D2[new_qty = old - req, clamped<br/>delta_qty = message amount]
    D1 --> W[write qty<br/>valid = not removed]
    D2 --> W
    W --> R([res_valid pulse])
```

The clamp on the subtract matters: a remove larger than what is resting indicates
an upstream inconsistency, but it must not wrap a 32-bit counter into a huge
positive quantity. The slot is freed the moment an order drains, which returns
capacity to the table without any garbage collection pass.

Verified by `tb_order_lookup` — **22 assertions**, including collision eviction
with `TABLE_BITS` shrunk to 4 to force it, Delete with no wire quantity, and
unknown-id misses.
