# System-Level Architecture

Generated from the RTL in `rtl/ITCH50_parser/`. Three views: the module
hierarchy as it is actually instantiated, the datapath with its handshake
types, and the diagnostic paths that run alongside it.

[← back to README](../../README.md)

---

## 1. Module hierarchy

Exactly what `create_vivado_project.tcl` builds, rooted at the synthesis top.

```mermaid
flowchart TD
    subgraph BOARD["top_board — pins, clock, reset, LEDs"]
        IBUF[IBUFDS] --> MMCM[MMCME2_BASE] --> BUFG[BUFG x2]
        DEB[button_debounce] --> RSTSR[reset shift register]
        MMCM -.->|locked| RSTSR
        subgraph UARTTOP["top_uart — IO layer"]
            U2A[uart_to_axis]
            ARB[axis_arb2]
            STAT[status_reporter]
            A2U[axis_to_uart]
            subgraph CORE["top_v2 — engine"]
                PARSE[itch_parser]
                DISP[event_dispatcher]
                LOOK[order_lookup]
                BOOK[book_update]
                ENC[priority_encoder]
                TOB[tob_tracker]
                FEAT[feature_engine]
                LINK[board_link_tx]
                PROBE[latency_probe]
            end
        end
    end

    BUFG --> UARTTOP
    RSTSR --> UARTTOP
    U2A --> PARSE
    PARSE --> DISP
    DISP <--> LOOK
    DISP --> BOOK
    BOOK --> ENC --> TOB
    TOB -.-> BOOK
    TOB --> FEAT
    DISP -.-> FEAT
    FEAT --> LINK
    LINK --> ARB
    STAT --> ARB
    ARB --> A2U
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
flowchart TD
    IN([ITCH bytes in])
    PARSE[itch_parser]
    DISP[event_dispatcher]
    LOOK[order_lookup]
    BOOK[book_update]
    ENC[priority_encoder]
    TOB[tob_tracker]
    FEAT[feature_engine]
    LINK[board_link_tx]
    OUT([feature frames out])

    IN --> PARSE
    PARSE -->|event| DISP
    DISP <-->|resolve id| LOOK
    DISP -->|add / remove| BOOK
    BOOK -->|masks| ENC
    ENC -->|best levels| TOB
    BOOK -->|book_updated| TOB
    TOB -.->|read port| BOOK
    TOB -->|snapshot| FEAT
    DISP -->|trade tap| FEAT
    FEAT --> LINK
    LINK --> OUT
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
    MSG{msg_type}
    MSG -->|A / F| ADD[all fields on the wire]
    MSG -->|E / C| QRY[only order_id]
    MSG -->|X| QRY
    MSG -->|D| QRY
    MSG -->|U| RPL[no side on the wire]
    MSG -->|S / R| SKIP([book untouched])
    MSG -->|unknown| CNT([unknown_count++])

    ADD --> P1[insert + book add]
    QRY --> P2[query lookup]
    P2 --> P3[book remove at resolved level]
    P2 -.->|E / C only| TT([trade tap])
    RPL --> P4[step 1: delete old id]
    P4 --> P5[step 2: insert new id]
    P4 -.->|miss| ABORT([abort, miss_count++])

    P1 --> BOOK([book_updated])
    P3 --> BOOK
    P5 --> BOOK
```

Replace produces **two** book updates for one message, and therefore up to two
feature vectors. It is the most intricate path in the design and the one the two
smaller test captures never exercise.

---

## 4. Diagnostics

Nothing here is in the datapath. Every counter is monotonic from reset.

```mermaid
flowchart LR
    C1[itch_parser<br/>4 counters]
    C2[event_dispatcher<br/>miss_count]
    C3[book_update<br/>oow_count]
    C4[board_link_tx<br/>drop_count]
    C5[latency_probe<br/>11 results]

    C1 --> BUS[stat_bus<br/>18 x uint32]
    C2 --> BUS
    C3 --> BUS
    C4 --> BUS
    C5 --> BUS
    BUS --> SR[status_reporter]
    SR --> HOST([host decoder])
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
