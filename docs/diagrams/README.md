# Architecture Diagrams

Mermaid diagrams generated from the RTL in
[`rtl/ITCH50_parser/`](../../rtl/ITCH50_parser/). GitHub renders these inline — no
image files, no export step, and they diff as text when the RTL changes.

[← back to README](../../README.md)

| Diagram | Covers |
|---|---|
| [**System architecture**](system.md) | Module hierarchy, datapath with handshake types, per-message routing, diagnostics |
| [`itch_parser`](itch_parser.md) | 4-state FSM, end-of-message decision tree, per-type field offsets, cost per message |
| [`event_dispatcher`](event_dispatcher.md) | 8-state FSM, the three message paths, the `RPL_WAIT` race |
| [`order_lookup`](order_lookup.md) | Why it exists, 3-state FSM, table layout, collision eviction |
| [`book_update`](book_update.md) | 5-state FSM, address computation, the critical path fix, mask-as-source-of-truth |
| [`priority_encoder`](priority_encoder.md) | Radix-32 tree, the two primitives, why the naive loop fails |
| [`tob_tracker`](tob_tracker.md) | Delay line, the 5-cycle budget, the Replace race |
| [`feature_engine`](feature_engine.md) | Two input streams, six parallel datapaths, EMA precision, init artefacts |
| [`board_link_tx`](board_link_tx.md) | Frame layout, transmit flow, drop-oldest and the counter bug |
| [`latency_probe`](latency_probe.md) | Measurement definition, per-stage timestamp carriers, edge cases |
| [IO layer](io_uart.md) | `top_board` clock/reset, baud choice, the three LEDs, status frames, arbitration |

---

## Conventions

**Handshake patterns**, as numbered in [`module_ports.md`](../module_ports.md):

| | Shape | Rule |
|---|---|---|
| ① | `tdata` + `tvalid` / `tready` | transfer when both high — **will wait for you** |
| ② | `X_valid` + payload, gated by `ready` / `busy` | 1-cycle strobe; check the guard *first* |
| ③ | `X_valid` pulse, no handshake | catch it that cycle — **no retry** |
| ④ | bare wires | always reflect current state |
| ⑤ | `*_count[31:0]` | monotonic, cleared only by reset |

**Colour**, where it appears: blue for snapshot/clock paths, amber for the trade
stream and IO, green for a property that costs nothing or a result that passed, red
for a hazard or a path that failed. Dashed grey is observation-only — nothing in the
datapath depends on it.

**Scope.** These describe the design as committed. Where a diagram documents a bug,
it is one that was found and fixed; the arrangement shown is the fixed one, with the
broken version drawn alongside only where the fix is otherwise hard to motivate.
