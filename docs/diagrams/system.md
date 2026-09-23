# System-Level Architecture

Generated from the RTL in `rtl/ITCH50_parser/`. Three views: the module
hierarchy as it is actually instantiated, the datapath with its handshake
types, and the diagnostic paths that run alongside it.

[← back to README](../../README.md)

---

## 1. Module hierarchy

Exactly what `create_vivado_project.tcl` builds, rooted at the synthesis top.

```mermaid
flowchart TB
    subgraph BOARD["top_board &nbsp;—&nbsp; synthesis top, the only module with pins"]
        direction TB
        IBUF["IBUFDS<br/>200 MHz differential<br/>R4 / T4"]
        MMCM["MMCME2_BASE<br/>VCO 1000 MHz, div 10<br/>→ 100 MHz"]
        BUFG["BUFG ×2"]
        DEB["button_debounce<br/>STABLE_CYCLES = 10 ms<br/><i>no arstn by design</i>"]
        RSTSR["reset shift register<br/>sync release, async assert"]
        LEDS["LED logic<br/>heartbeat / rx-activity / sticky overflow<br/><i>active-low pins</i>"]

        subgraph UARTTOP["top_uart &nbsp;—&nbsp; IO layer"]
            direction TB
            U2A["uart_to_axis<br/>uart_rx + sync_fifo<br/>CLKS_PER_BIT = 100"]
            A2U["axis_to_uart<br/>uart_tx"]
            ARB["axis_arb2<br/>frame-atomic 2:1"]
            STAT["status_reporter<br/>18 counters, 75-byte frame"]
            PEC["parse_err_count<br/>accumulator"]

            subgraph CORE["top_v2 &nbsp;—&nbsp; engine, transport-agnostic"]
                direction TB
                PARSE["itch_parser"]
                DISP["event_dispatcher"]
                LOOK["order_lookup"]
                BOOK["book_update"]
                ENC["priority_encoder"]
                TOB["tob_tracker"]
                FEAT["feature_engine"]
                LINK["board_link_tx"]
                PROBE["latency_probe<br/><i>observation only</i>"]
            end
        end
    end

    IBUF --> MMCM --> BUFG --> UARTTOP
    DEB --> RSTSR --> UARTTOP
    MMCM -.->|locked| RSTSR

    U2A --> PARSE
    PARSE --> DISP
    DISP <--> LOOK
    DISP --> BOOK
    BOOK --> ENC --> TOB
    BOOK -.->|read ports| TOB
    TOB --> FEAT
    DISP -.->|trade tap| FEAT
    FEAT --> LINK
    LINK --> ARB
    STAT --> ARB
    ARB --> A2U
    PARSE -.-> PEC
    PEC -.-> STAT
    U2A -.->|rx_byte_seen| STAT
    U2A -.->|overflow| LEDS

    classDef core fill:#e8f0fe,stroke:#4285f4,stroke-width:1px
    classDef io fill:#fff4e5,stroke:#f59e0b,stroke-width:1px
    classDef diag fill:#f3f4f6,stroke:#9ca3af,stroke-dasharray:3 3
    class PARSE,DISP,LOOK,BOOK,ENC,TOB,FEAT,LINK core
    class U2A,A2U,ARB,STAT io
    class PROBE,PEC,LEDS diag
```

**Why the split is where it is.** `top_v2` has no UART in it — its output is a
plain byte stream with a ready/valid handshake. The transport is entirely a
`top_uart` concern, so replacing UART with a MAC or XDMA touches nothing inside
the engine. `top_board` exists only to own pins, the clock tree, reset and the
LEDs.

---

## 2. Datapath, with handshake types

One event is in flight end to end. `ev_ready` is high only when the dispatcher
is in `IDLE`, so the parser stalls the byte stream rather than queueing.

```mermaid
flowchart LR
    IN(["ITCH byte stream<br/>8-bit"]) 
    PARSE["<b>itch_parser</b><br/>framing + field extraction<br/>+ stock_locate filter"]
    DISP["<b>event_dispatcher</b><br/>8-state FSM<br/>owns all cross-module logic"]
    LOOK["<b>order_lookup</b><br/>direct-mapped, 2^14 entries<br/>3 cycles"]
    BOOK["<b>book_update</b><br/>qty arrays + occupancy masks<br/>5 cycles"]
    ENC["<b>priority_encoder</b><br/>radix-32 tree<br/>2 cycles, fixed"]
    TOB["<b>tob_tracker</b><br/>snapshot assembly<br/>t+2 latch, t+4 publish"]
    FEAT["<b>feature_engine</b><br/>6 features in parallel<br/>1 cycle"]
    LINK["<b>board_link_tx</b><br/>15-byte frame<br/>drop-oldest"]
    OUT(["feature frame<br/>byte stream"])

    IN -->|"① tvalid / tready"| PARSE
    PARSE -->|"① ev_valid / ev_ready"| DISP
    DISP -->|"② ins_valid / qry_valid<br/>guarded by lk_busy"| LOOK
    LOOK -->|"③ res_valid pulse<br/>price, side, delta_qty"| DISP
    DISP -->|"② bu_valid / bu_ready"| BOOK
    BOOK -->|"④ bid_mask, ask_mask<br/>continuous"| ENC
    ENC -->|"④ best addr + valid<br/>2 cycles stale"| TOB
    TOB <-->|"④ addr out, data in<br/>registered read"| BOOK
    BOOK -->|"③ book_updated<br/><b>the timing anchor</b>"| TOB
    TOB -->|"③ tob_valid + tob_t"| FEAT
    DISP -->|"③ trade_valid<br/><b>independent stream</b>"| FEAT
    FEAT -->|"③ feat_valid + 6×int16"| LINK
    LINK -->|"① tvalid / tready"| OUT

    classDef anchor stroke:#dc2626,stroke-width:2px
    class BOOK anchor
```

**Interface patterns** (numbering follows [`module_ports.md`](../module_ports.md)):

| | Shape | Rule |
|---|---|---|
| ① | `tdata` + `tvalid` / `tready` | transfer when both high; **will wait for you** |
| ② | `X_valid` + payload, gated by `ready`/`busy` | 1-cycle strobe; check the guard *first* |
| ③ | `X_valid` pulse, no handshake | catch it that cycle; **no retry** |
| ④ | bare wires | always reflect current state |

The distinction that causes the most bugs: a `*_valid` with a matching `*_ready`
will wait; a `*_valid` without one will not.

---

## 3. Per-message routing

Which blocks each ITCH message type actually touches.

```mermaid
flowchart TD
    MSG{"msg_type"}
    MSG -->|"A / F<br/>Add"| ADD["price, side, qty all on the wire"]
    MSG -->|"E / C<br/>Execute"| QRY["only order_id on the wire"]
    MSG -->|"X<br/>Cancel"| QRY
    MSG -->|"D<br/>Delete"| QRY
    MSG -->|"U<br/>Replace"| RPL["new id, price, qty on the wire<br/><b>side is not</b>"]
    MSG -->|"S / R<br/>admin"| SKIP(["parsed, book untouched"])
    MSG -->|unknown| CNT(["unknown_count++, skipped"])

    ADD --> P1["insert into order_lookup<br/><b>+</b> book add, same cycle"]
    QRY --> P2["query order_lookup<br/>→ resolve price / side / qty"]
    P2 --> P3["book remove at resolved level"]
    P2 -.->|"E / C only"| TT(["trade tap → TFLOW"])
    RPL --> P4["step 1: OP_DELETE on old id<br/><i>this is what recovers the side</i>"]
    P4 --> P5["step 2: insert new id,<br/>side inherited from step 1"]
    P4 -.->|miss| ABORT(["abort step 2, miss_count++"])

    P1 --> BOOK(["book_updated"])
    P3 --> BOOK
    P5 --> BOOK

    classDef warn fill:#fef2f2,stroke:#dc2626
    class RPL,P4,P5 warn
```

Replace produces **two** book updates for one message, and therefore up to two
feature vectors. It is the most intricate path in the design and the one the two
smaller test captures never exercise.

---

## 4. Diagnostics

Nothing here is in the datapath. Every counter is monotonic from reset.

```mermaid
flowchart LR
    subgraph SRC["counters, by owner"]
        direction TB
        C1["itch_parser<br/>msg_count, unknown_count<br/>filtered_count, parse_error"]
        C2["event_dispatcher<br/>miss_count"]
        C3["book_update<br/>oow_count"]
        C4["board_link_tx<br/>drop_count"]
        C5["latency_probe<br/>11 latency results"]
    end

    TAPS["<b>latency_probe</b> taps<br/>ev_handoff → book_updated<br/>→ tob_valid → feat_valid"]
    BUS["stat_bus<br/>18 × uint32, packed MSB-first<br/><i>this order is the wire format</i>"]
    SR["status_reporter<br/>triggered by RX going quiet<br/>for IDLE_CYCLES"]
    HOST(["host: uart_feed.py<br/>STATUS_FIELDS must match"])

    C1 --> BUS
    C2 --> BUS
    C3 --> BUS
    C4 --> BUS
    TAPS --> C5 --> BUS
    BUS --> SR --> HOST

    classDef diag fill:#f3f4f6,stroke:#9ca3af
    class C1,C2,C3,C4,C5,TAPS,BUS,SR diag
```

**The trigger is not a command byte, deliberately.** The inbound ITCH stream can
contain any byte value inside a price, order id or timestamp field, so an in-band
magic byte would eventually collide with real data and desynchronise the framing.
Watching for the RX line to go quiet is unambiguous and cannot corrupt the
datapath — and it fires at exactly the moment the host wants the counters, the
end of a replay burst.

On a board with no processor and no debugger, these counters *are* the debugger.
They are what identified a stale-device bug that looked exactly like an order-book
error — see §9.4 of the README.
