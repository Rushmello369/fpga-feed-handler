# `itch_parser`

Byte-serial decoder for the NASDAQ historical-file framing. Source:
[`rtl/ITCH50_parser/Itch_parser.sv`](../../rtl/ITCH50_parser/Itch_parser.sv)

[← back to README](../../README.md#5-the-parser)

---

## 1. State machine

Four states. `s_tready = (state != EMIT)` — the single point of back-pressure in
the core.

```mermaid
stateDiagram-v2
    [*] --> RD_LEN_HI

    RD_LEN_HI --> RD_LEN_LO : s_tvalid<br/>msg_len[15:8] ← byte
    RD_LEN_LO --> RD_BODY : s_tvalid<br/>msg_len[7:0] ← byte<br/>idx ← 0, ev ← 0
    RD_BODY --> RD_BODY : s_tvalid and idx < msg_len-1<br/>extract field, idx++
    RD_BODY --> EMIT : last byte, known type,<br/>length matches, book-affecting,<br/>locate matches
    RD_BODY --> RD_LEN_HI : last byte and any of —<br/>unknown type, length mismatch,<br/>wrong symbol, admin type
    EMIT --> RD_LEN_HI : ev_ready

    note right of RD_BODY
        s_tready is HIGH here
        one byte per cycle
    end note

    note right of EMIT
        s_tready is LOW
        event held until the
        dispatcher accepts it
    end note
```

## 2. End-of-message decision

The four outcomes at `idx == msg_len - 1`, in the order the RTL tests them.

```mermaid
flowchart TD
    EOM["idx == msg_len - 1<br/>msg_count++"]
    Q1{"msg_length(mtype) == 0<br/>and idx != 0 ?"}
    Q2{"msg_length(mtype)<br/>!= msg_len ?"}
    Q3{"is_book_affecting(mtype) ?"}
    Q4{"FILTER_EN == 0<br/>or locate matches ?"}

    EOM --> Q1
    Q1 -->|yes| UNK["unknown_count++<br/><i>not fatal</i>"]
    Q1 -->|no| Q2
    Q2 -->|yes| ERR["<b>parse_error pulse</b><br/>event NOT emitted"]
    Q2 -->|no| Q3
    Q3 -->|no| ADM["admin type — S, R<br/>no event"]
    Q3 -->|yes| Q4
    Q4 -->|no| FIL["filtered_count++<br/>wrong instrument"]
    Q4 -->|yes| OK["<b>ev_valid ← 1</b><br/>→ EMIT"]

    UNK --> BACK(["RD_LEN_HI"])
    ERR --> BACK
    ADM --> BACK
    FIL --> BACK

    classDef good fill:#ecfdf5,stroke:#059669
    classDef bad fill:#fef2f2,stroke:#dc2626
    class OK good
    class ERR bad
```

**Why a length mismatch suppresses the event.** If the framing prefix disagrees
with the spec length for a recognised type, upstream framing is misaligned — which
means every field offset in this message is untrustworthy. Emitting a plausible
looking event from misaligned bytes is worse than emitting nothing.

## 3. Field extraction by type

Big-endian assembly: each arriving byte shifts into the low end, so the value is
complete and correctly ordered after the last byte. No buffering, no reversal.

```mermaid
flowchart LR
    subgraph COMMON["every message type"]
        B0["byte 0<br/>msg_type"]
        B12["bytes 1-2<br/><b>stock_locate</b>"]
    end

    subgraph AF["A / F — Add"]
        AF1["11-18 order_id"]
        AF2["19 side"]
        AF3["20-23 shares"]
        AF4["32-35 price"]
    end

    subgraph ECX["E / C / X"]
        E1["11-18 order_id"]
        E2["19-22 shares"]
        E3["32-35 price<br/><i>C only, informational</i>"]
    end

    subgraph D["D — Delete"]
        D1["11-18 order_id<br/><i>nothing else on the wire</i>"]
    end

    subgraph U["U — Replace"]
        U1["11-18 <b>old</b> order_id"]
        U2["19-26 <b>new</b> order_id"]
        U3["27-30 new shares"]
        U4["31-34 new price"]
        U5["<b>side absent</b><br/>recovered via order_lookup"]
    end

    COMMON --> AF
    COMMON --> ECX
    COMMON --> D
    COMMON --> U

    classDef warn fill:#fef2f2,stroke:#dc2626
    class U5 warn
```

`stock_locate` sits at the **same offset in every message type**. That is what
makes single-instrument filtering a two-byte comparison rather than a per-type
decode, and it is why the filter can be applied after field extraction without
costing anything.

## 4. Cost per message

Deterministic — one byte per cycle while `s_tvalid` holds, so the only variable
is time spent in `EMIT`.

| Type | Body | Cycles | @ 100 MHz |
|---|---:|---:|---:|
| `D` Delete | 19 B | 21 | 210 ns |
| `X` Cancel | 23 B | 25 | 250 ns |
| `E` Execute | 31 B | 33 | 330 ns |
| `U` Replace | 35 B | 37 | 370 ns |
| `A` Add | 36 B | 38 | 380 ns |
| `C` Exec w/ Price | 36 B | 38 | 380 ns |
| `F` Add + MPID | 40 B | 42 | 420 ns |

**This module is the core's bottleneck**, deliberately. One byte per cycle at
100 MHz is a 100 MB/s ingest ceiling; parsing one Execute costs 33 cycles against
roughly 18 for the entire rest of the pipeline. That is the right trade for a
1 Mbaud UART (1000× headroom) or 100 Mbps Ethernet (8× headroom), and it is the
first thing that breaks at gigabit line rate, where a 64-bit datapath and a
structurally different parser would be needed.

Synthesis, out of context, `xc7a200tfbg484-2`: **298 LUT, 360 FF, 0 BRAM, 0 DSP**,
WNS +4.953 ns against 10 ns. The register count is almost entirely `itch_event_t`
itself — 217 bits, two of them 64-bit order ids — which is the price of one event
shape covering every message type.
