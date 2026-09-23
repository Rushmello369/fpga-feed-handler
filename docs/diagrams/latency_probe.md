# `latency_probe`

Cycle-accurate latency instrumentation. Observation only — no back-pressure, no
handshake, no side effects. Removing the instance cannot change behaviour. Source:
[`rtl/ITCH50_parser/latency_probe.sv`](../../rtl/ITCH50_parser/latency_probe.sv)

[← back to README](../../README.md#103-latency)

---

## 1. Measurement definition

Quoting a latency number without stating what it spans is meaningless.

```mermaid
flowchart LR
    EV(["ev_handoff<br/><i>parser hands a validated<br/>event to the dispatcher</i>"])
    BK(["book_updated"])
    TB(["tob_valid"])
    FT(["feat_valid"])

    EV -->|"<b>t_resolve</b><br/>data dependent"| BK
    BK -->|"<b>t_book2tob</b><br/>constant 5"| TB
    TB -->|"<b>t_tob2feat</b><br/>constant 1"| FT

    subgraph EXCL["deliberately EXCLUDED"]
        X1["UART wire time"]
        X2["the parser's byte-shifting"]
    end

    classDef excl fill:#f3f4f6,stroke:#9ca3af,stroke-dasharray:3 3
    class EXCL,X1,X2 excl
```

> **`t_total` = cycles from `ev_handoff` to the *first* `feat_valid` produced by
> that event.**

Excluding the transport is the entire point. The bring-up transport is ~1,363×
slower than the core, so any end-to-end number would be a measurement of the UART,
not of this pipeline.

## 2. Why timestamps travel with the event

A single "armed" flag would be clobbered constantly.

```mermaid
sequenceDiagram
    participant D as dispatcher
    participant P as probe
    participant T as tob_tracker
    participant F as feature_engine

    Note over D: ADD_WAIT returns to IDLE once<br/>book_update drains — but tob_tracker<br/>still owes 4 cycles and the<br/>feature engine 1 more
    D->>P: event N accepted (ev_handoff)
    D->>P: book_updated for N
    D->>P: <b>event N+1 accepted</b>
    Note over P: a naive single "armed" flag<br/>would be overwritten HERE,<br/>before N's feature emerges
    T->>P: tob_valid for N
    F->>P: feat_valid for N
    Note over P: correct only because each stage<br/>latches its OWN copy of the<br/>originating timestamp
```

So the probe carries three independent timestamp pairs, and every subtract uses
only registers owned by that stage:

```mermaid
flowchart LR
    S0["<b>stage 0</b><br/>ts_a, valid_a<br/><i>event accepted</i>"]
    S1["<b>stage 1</b><br/>ts_b = ts_a (origin)<br/>tsb_book = now<br/>valid_b"]
    S2["<b>stage 2</b><br/>ts_c = ts_b (origin)<br/>tsc_tob = now<br/>valid_c"]
    S3["<b>stage 3</b><br/>close the measurement"]

    S0 -->|"book_updated<br/>and valid_a"| S1
    S1 -->|"tob_valid<br/>and valid_b"| S2
    S2 -->|"feat_valid<br/>and valid_c"| S3

    S1 -.->|"lat_resolve = now - ts_a"| R1(["stage result"])
    S2 -.->|"lat_book2tob = now - tsb_book"| R2(["stage result"])
    S3 -.->|"lat_tob2feat = now - tsc_tob<br/>lat_last = now - ts_c"| R3(["stage + total"])
```

Each stage clears its predecessor's valid flag as it takes ownership, so exactly
one measurement occupies each stage.

## 3. Two edge cases the probe handles explicitly

```mermaid
flowchart TD
    subgraph RPL["Replace fires book_updated TWICE"]
        direction TB
        R1["first book_updated<br/>consumes valid_a"]
        R2["second finds valid_a already low<br/><b>propagates nothing</b>"]
        R3["hence 'FIRST feature' —<br/>a U is timed on its delete half"]
        R1 --> R2 --> R3
    end

    subgraph ABD["events that never reach the book"]
        direction TB
        A1["ev_handoff arrives while<br/>valid_a is still set"]
        A2["the previous event was abandoned —<br/>order_lookup miss, or a one-sided<br/>book suppressing tob_valid"]
        A3["<b>lat_unmatched++</b>"]
        A1 --> A2 --> A3
    end

    classDef note fill:#fff4e5,stroke:#f59e0b
    class R3,A3 note
```

**Why `lat_unmatched` has to exist.** Without it the probe would silently attribute
the *next* event's feature to the abandoned one — a wrong number that looks
perfectly plausible. Counting the abandonment is what makes the remaining samples
trustworthy.

## 4. Interarrival — measuring the transport on the same clock

```mermaid
flowchart LR
    E1(["ev_handoff<br/>event N"]) -->|"lat_ia = cycle - ts_prev_ev"| E2(["ev_handoff<br/>event N+1"])
    E2 --> MIN["lat_ia_min<br/><i>smallest seen</i>"]
    E2 --> LAST["lat_ia_last"]
```

Under UART, the interval between consecutive events **is** the transport cost. That
turns "the transport dominates the core by three orders of magnitude" from a
calculation into a measurement with both halves observed on the same chip, in the
same run, on the same clock:

| | Measured |
|---|---:|
| core, event → feature | **153 ns** |
| transport, minimum interarrival | **20,791 cycles = 207.9 µs** |
| ratio | **~1,363×** |

## 5. The probe as an assertion, not just an instrument

```mermaid
flowchart LR
    RTL["derived from the RTL<br/><b>before</b> measurement"] --> PRED["t_book2tob = 5<br/>t_tob2feat = 1"]
    PRED --> SIM["simulation<br/><b>5 and 1</b> ✓"]
    PRED --> HW["silicon<br/><b>5 and 1</b> ✓"]
    PRED --> BUG["<b>anything else would be a bug,<br/>not a measurement</b>"]

    classDef good fill:#ecfdf5,stroke:#059669
    classDef bad fill:#fef2f2,stroke:#dc2626
    class SIM,HW good
    class BUG bad
```

Both stages are fixed-latency chains with no data dependence, so their values were
predicted from the RTL first. They came back as 5 and 1 in simulation and again as
5 and 1 on hardware — which means the probe doubles as a live correctness check on
every run.

Simulation and silicon also agree on the extremes exactly (13 and 18 cycles), which
is expected: the pipeline is fully synchronous with no data-dependent stalls outside
`t_resolve`. An earlier analytical estimate of "~18 cycles for an Execute" turned
out to be the correct *upper* bound — the mean is lower because Add messages
resolve without the `order_lookup` round trip.

## 6. Results reported

11 free-running 32-bit outputs, wired into the status frame:

| Group | Outputs |
|---|---|
| Total | `lat_last`, `lat_min`, `lat_max`, `lat_sum`, `lat_count` |
| Per stage | `lat_resolve`, `lat_book2tob`, `lat_tob2feat` |
| Transport | `lat_ia_last`, `lat_ia_min` |
| Health | `lat_unmatched` |

The host computes the mean as `lat_sum / lat_count`. `cycle` wraps every ~43 s at
100 MHz; every subtract is modulo-2³², so a measurement spanning a wrap is still
correct as long as the interval itself is under 2³² cycles.

Verified by `tb_latency_probe` — **35 assertions**, and validated by **mutation
testing**: replacing the per-stage timestamp carriers with a naive single "armed"
flag fails 5 assertions, all confined to the overlap scenario.
