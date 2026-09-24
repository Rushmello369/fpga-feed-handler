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
    EV([ev_handoff]) -->|t_resolve| BK([book_updated])
    BK -->|t_book2tob = 5| TB([tob_valid])
    TB -->|t_tob2feat = 1| FT([feat_valid])
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
    participant F as feature_engine

    D->>P: event N accepted
    D->>P: book_updated for N
    D->>P: event N+1 accepted
    Note over P: a single armed flag would be<br/>overwritten here, before N finishes
    F->>P: feat_valid for N
    Note over P: correct only because each stage<br/>latches its own timestamp
```

So the probe carries three independent timestamp pairs, and every subtract uses
only registers owned by that stage:

```mermaid
flowchart LR
    S0[stage 0<br/>ts_a, valid_a] -->|book_updated| S1[stage 1<br/>carries origin ts]
    S1 -->|tob_valid| S2[stage 2<br/>carries origin ts]
    S2 -->|feat_valid| S3[stage 3<br/>closes the measurement]
    S1 -.-> R1([lat_resolve])
    S2 -.-> R2([lat_book2tob])
    S3 -.-> R3([lat_tob2feat, lat_last])
```

Each stage clears its predecessor's valid flag as it takes ownership, so exactly
one measurement occupies each stage.

## 3. Two edge cases the probe handles explicitly

```mermaid
flowchart TD
    subgraph RPL["Replace fires book_updated twice"]
        direction TB
        R1[first consumes valid_a] --> R2[second finds it low, ignored] --> R3[a U is timed on its delete half]
    end
    subgraph ABD["events that never reach the book"]
        direction TB
        A1[new handoff while valid_a set] --> A2[previous was abandoned] --> A3[lat_unmatched++]
    end
```

**Why `lat_unmatched` has to exist.** Without it the probe would silently attribute
the *next* event's feature to the abandoned one — a wrong number that looks
perfectly plausible. Counting the abandonment is what makes the remaining samples
trustworthy.

## 4. Interarrival — measuring the transport on the same clock

```mermaid
flowchart LR
    E1([ev_handoff, event N]) -->|interarrival| E2([ev_handoff, event N+1])
    E2 --> MIN([lat_ia_min])
    E2 --> LAST([lat_ia_last])
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
    RTL[derived from the RTL<br/>before measurement] --> PRED[t_book2tob = 5<br/>t_tob2feat = 1]
    PRED --> SIM([simulation: 5 and 1])
    PRED --> HW([silicon: 5 and 1])
    PRED --> BUG([anything else is a bug,<br/>not a measurement])
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
