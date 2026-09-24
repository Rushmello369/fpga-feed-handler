# `event_dispatcher`

The traffic controller between `itch_parser`, `order_lookup` and `book_update`.
It owns **all** the protocol logic that spans modules. Source:
[`rtl/ITCH50_parser/Event_dispatcher.sv`](../../rtl/ITCH50_parser/Event_dispatcher.sv)

[← back to README](../../README.md#3-architecture)

---

## 1. State machine

Eight states, three paths. `ev_ready` is high **only in `IDLE`**, which is what
enforces one event in flight end to end.

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> ADD_ISSUE: A / F
    IDLE --> QRY_ISSUE: E C X D U
    ADD_ISSUE --> ADD_WAIT: fire both
    ADD_WAIT --> IDLE: drained
    QRY_ISSUE --> QRY_WAIT: query sent
    QRY_WAIT --> BOOK_REMOVE: hit
    QRY_WAIT --> IDLE: miss
    BOOK_REMOVE --> IDLE: not Replace
    BOOK_REMOVE --> RPL_WAIT: Replace
    RPL_WAIT --> RPL_INSERT: bu_ready fell
    RPL_INSERT --> ADD_WAIT: new order in
```

## 2. The three paths, side by side

```mermaid
flowchart TD
    EV([event from parser]) --> T{msg_type}

    T -->|A / F| A1[ADD_ISSUE<br/>insert + book add together]
    A1 --> A2[ADD_WAIT]
    A2 --> DONE([IDLE])

    T -->|E / C / X / D| B1[QRY_ISSUE]
    B1 --> B2[QRY_WAIT]
    B2 --> B3{res_hit?}
    B3 -->|no| B4([miss_count++])
    B4 --> DONE
    B3 -->|yes| B5[BOOK_REMOVE]
    B5 --> DONE
    B3 -.->|E / C only| TT([trade tap])

    T -->|U| C1[QRY_ISSUE<br/>OP_DELETE]
    C1 --> C2[QRY_WAIT<br/>capture side]
    C2 --> C3{res_hit?}
    C3 -->|no| C4([step 2 aborted])
    C4 --> DONE
    C3 -->|yes| C5[BOOK_REMOVE]
    C5 --> C6[RPL_WAIT]
    C6 --> C7[RPL_INSERT]
    C7 --> A2
```

**Why Cancel and Delete differ.** `X` carries the number of shares cancelled, so
the lookup subtracts that amount. `D` carries **no quantity at all** — the only
way to know how much to remove from the book is the remaining live quantity the
order table has been tracking, which is why `OP_DELETE` returns `rd_qty` rather
than a wire value.

**Why the trade tap is Execute-only.** `trade_valid` fires on `E` and `C` hits and
nothing else. A cancellation is not a trade, and neither is a replace. The side
comes from `res_side` because execution messages never carry one.

## 3. The `RPL_WAIT` state, and the bug it exists to prevent

`RPL_WAIT` looks redundant — it waits for `bu_ready` to go *low*. Removing it
breaks Replace silently.

```mermaid
sequenceDiagram
    participant D as event_dispatcher
    participant B as book_update

    Note over D,B: BOOK_REMOVE issues the remove
    D->>B: bu_valid (registered output)
    Note over B: still IDLE this cycle,<br/>bu_ready STILL HIGH
    B->>B: samples bu_valid, enters ADDR1
    Note over B: bu_ready falls here,<br/>two cycles after the strobe

    Note over D,B: Without RPL_WAIT the step-2 add fires<br/>on a stale bu_ready and is dropped
    Note over D,B: With RPL_WAIT we hold until bu_ready<br/>actually falls, then re-check
```

This is the class of bug that passes every module-level test written against the
module's own assumptions, because both the dispatcher and the book behave exactly
as documented in isolation. It shows up only when the two are composed and an
event produces two back-to-back book commands — which is to say, only on Replace,
which the two smaller test captures contain none of.

## 4. What `order_lookup` is deliberately not told

```mermaid
flowchart LR
    U[ITCH U<br/>Order Replace] --> DEC[event_dispatcher decomposes]
    DEC --> D1[OP_DELETE on old id]
    DEC --> D2[insert on new id]
    D1 --> OL[order_lookup<br/>EXECUTE, CANCEL, DELETE]
    D2 --> OL
    NO[no OP_REPLACE exists]
```

There is no `OP_REPLACE` in `lookup_op_e`. Replace is a composition of two
primitives the table already supports, so the table stays a table — and the one
piece of protocol subtlety, that the side has to be recovered from the delete half
before the insert half can be issued, lives in exactly one place.
