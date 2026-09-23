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

    IDLE --> ADD_ISSUE : ev_valid and type is A or F
    IDLE --> QRY_ISSUE : ev_valid and type is<br/>E, C, X, D or U

    ADD_ISSUE --> ADD_WAIT : not lk_busy and bu_ready<br/>fire ins_valid + bu_valid<br/><b>same cycle</b>
    ADD_WAIT --> IDLE : not lk_busy and bu_ready<br/>both units drained

    QRY_ISSUE --> QRY_WAIT : not lk_busy<br/>fire qry_valid with op
    QRY_WAIT --> BOOK_REMOVE : res_valid and res_hit<br/>latch price, qty, side
    QRY_WAIT --> IDLE : res_valid and not res_hit<br/><b>miss_count++</b>

    BOOK_REMOVE --> IDLE : bu_ready, not a Replace
    BOOK_REMOVE --> RPL_WAIT : bu_ready, is_replace
    RPL_WAIT --> RPL_INSERT : <b>not bu_ready</b><br/>book has taken the remove
    RPL_INSERT --> ADD_WAIT : not lk_busy and bu_ready<br/>insert new id, side inherited

    note right of ADD_ISSUE
        Add: everything is on the
        wire, so lookup insert and
        book add fire in parallel
    end note

    note right of RPL_WAIT
        Waits for bu_ready to FALL,
        not rise. See section 3.
    end note
```

## 2. The three paths, side by side

```mermaid
flowchart TD
    EV(["event from parser"])
    EV --> T{"msg_type"}

    T -->|"A / F"| A1["ADD_ISSUE<br/>ins_valid + bu_valid, one cycle"]
    A1 --> A2["ADD_WAIT<br/>drain both units"]
    A2 --> DONE(["IDLE"])

    T -->|"E / C / X / D"| B1["QRY_ISSUE<br/>op ← EXECUTE / CANCEL / DELETE"]
    B1 --> B2["QRY_WAIT"]
    B2 --> B3{"res_hit ?"}
    B3 -->|no| B4["miss_count++<br/>abandon"]
    B4 --> DONE
    B3 -->|yes| B5["BOOK_REMOVE<br/>at resolved price / side"]
    B5 --> DONE
    B3 -.->|"E or C only"| TT(["trade_valid pulse<br/>side = res_side<br/>qty = res_delta_qty"])

    T -->|"U"| C1["QRY_ISSUE<br/>op ← <b>OP_DELETE</b><br/>removes ALL old qty"]
    C1 --> C2["QRY_WAIT<br/>res_side → rpl_side"]
    C2 --> C3{"res_hit ?"}
    C3 -->|no| C4["miss_count++<br/><b>step 2 aborted</b><br/>side unknown"]
    C4 --> DONE
    C3 -->|yes| C5["BOOK_REMOVE<br/>old level"]
    C5 --> C6["RPL_WAIT"]
    C6 --> C7["RPL_INSERT<br/>new id, new price, new qty<br/>side = rpl_side"]
    C7 --> A2

    classDef warn fill:#fef2f2,stroke:#dc2626
    classDef trade fill:#eff6ff,stroke:#2563eb
    class C1,C4,C6,C7 warn
    class TT trade
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
    D->>B: bu_valid ← 1 (registered output)
    Note right of D: strobe is REGISTERED,<br/>so it appears on the wire<br/>one cycle later
    Note over B: still in IDLE this cycle —<br/>bu_ready is STILL HIGH
    B->>B: samples bu_valid, enters ADDR1
    Note over B: bu_ready falls HERE,<br/>two cycles after the strobe

    rect rgb(254, 242, 242)
    Note over D,B: WITHOUT RPL_WAIT: RPL_INSERT samples the<br/>stale bu_ready = 1, fires the step-2 add while<br/>the book is busy with the remove.<br/>The add is silently dropped — the Replace's<br/>new order is LOST.
    end

    rect rgb(236, 253, 245)
    Note over D,B: WITH RPL_WAIT: hold until bu_ready actually<br/>falls, proving the book has taken the remove.<br/>RPL_INSERT then re-checks a fresh value.
    end
```

This is the class of bug that passes every module-level test written against the
module's own assumptions, because both the dispatcher and the book behave exactly
as documented in isolation. It shows up only when the two are composed and an
event produces two back-to-back book commands — which is to say, only on Replace,
which the two smaller test captures contain none of.

## 4. What `order_lookup` is deliberately not told

```mermaid
flowchart LR
    U["ITCH 'U'<br/>Order Replace"] --> DEC["event_dispatcher<br/>decomposes"]
    DEC --> D1["OP_DELETE on old id"]
    DEC --> D2["insert on new id"]
    D1 --> OL["<b>order_lookup</b><br/>ops it knows —<br/>OP_EXECUTE, OP_CANCEL, OP_DELETE"]
    D2 --> OL
    NO["<s>OP_REPLACE</s><br/>does not exist"]

    classDef gone fill:#f3f4f6,stroke:#9ca3af,stroke-dasharray:3 3
    class NO gone
```

There is no `OP_REPLACE` in `lookup_op_e`. Replace is a composition of two
primitives the table already supports, so the table stays a table — and the one
piece of protocol subtlety, that the side has to be recovered from the delete half
before the insert half can be issued, lives in exactly one place.
