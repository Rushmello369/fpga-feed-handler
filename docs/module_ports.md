# Module & Port Reference

A lookup table, not a narrative. For *why* the design is shaped this way see
[`architecture.md`](architecture.md); for what must not drift see
[`handler_contract.md`](handler_contract.md).

**Every module has `clk` and `arstn` (active-low reset) unless noted.** Two
modules deliberately do not — they are called out where they appear.

---

## 1. Five interface patterns

There are only five. Recognising which one a port group belongs to is faster
than memorising signal names.

| Pattern | Shape | Rule | Used for |
|---|---|---|---|
| **① Stream with back-pressure** | `tdata` + `tvalid` / `tready` | Transfer occurs on the cycle where `tvalid && tready` | All byte streams |
| **② Command** | `X_valid` + payload / `X_ready` or `busy` | `X_valid` is a **1-cycle strobe**; check ready/busy *before* asserting | dispatcher → book, dispatcher → lookup |
| **③ Result pulse** | `X_valid` + payload, **no handshake** | 1-cycle pulse. The consumer must catch it that cycle — there is no retry | `res_valid`, `book_updated`, `tob_valid`, `feat_valid`, `trade_valid` |
| **④ Continuous** | Bare wires, no handshake | Always reflect current state; readable any cycle | Occupancy masks, best-level addresses, BRAM read ports |
| **⑤ Counter** | `*_count[31:0]` output | Monotonic, cleared only by reset | The seven diagnostics |

**The distinction that matters most:** a `*_valid` with a matching `*_ready`
will wait for you; a `*_valid` without one will not.

Naming conventions: `s_` = slave/input side, `m_` = master/output side (AXI
convention); `ins_` = insert port, `qry_` = query port, `res_` = result;
`bu_` = book update; `f_` = feature.

---

## 2. Board layer

### `top_board` — bitstream top
Parameters: `BASE_PRICE`, `WINDOW_SIZE`, `FILTER_EN`, `FILTER_LOCATE`,
`QTY_SHIFT`, `TABLE_BITS` — see [parameters.md](parameters.md).

| Dir | Signal | Purpose |
|---|---|---|
| in | `sys_clk_p` / `sys_clk_n` | 200 MHz differential clock (pins R4 / T4) |
| in | `rst_btn_n` | Reset push-button (F15), active-low |
| in | `uart_rx_pin` | From the CP2102 bridge (L14) |
| out | `uart_tx_pin` | To the CP2102 bridge (L15) |
| out | `rx_overflow` | LED1 — FIFO overrun, should stay 0 |
| out | `heartbeat_led` | LED2 — blinks iff the clock runs and reset is released |
| out | `rx_activity_led` | LED3 — flashes ~0.25 s per received byte |

**No `clk` / `arstn` inputs** — this module generates both. It is the only
module with physical pins; pin *assignment* lives in
`constraints/ax7a200_uart.xdc`.

### `button_debounce`
| Dir | Signal | Purpose |
|---|---|---|
| in | `clk` | |
| in | `btn_raw_n` | Asynchronous, active-low |
| out | `pressed` | Debounced, active-high |

**No `arstn` by design** — it produces the reset, so it cannot depend on one.
It relies on register initial values loaded at FPGA configuration.

---

## 3. IO layer

### `top_uart` — IO-layer top
| Dir | Signal | Purpose |
|---|---|---|
| in | `uart_rx_pin` | |
| out | `uart_tx_pin` | |
| out | `rx_overflow` | |
| out | `rx_byte_seen` | 1-cycle pulse per raw byte, **before** the FIFO |

### `uart_rx`  (param `CLKS_PER_BIT`)
| Dir | Signal | Purpose |
|---|---|---|
| in | `rx` | Asynchronous serial line |
| out | `o_data[7:0]` / `o_valid` | Pattern ③ |

### `uart_tx`  (param `CLKS_PER_BIT`)
| Dir | Signal | Purpose |
|---|---|---|
| in | `i_data[7:0]` / `i_valid` | Assert while `o_busy` is low |
| out | `o_busy` | High until the stop bit completes |
| out | `tx` | Serial line |

### `sync_fifo`  (params `DW = 8`, `AW = 6` → depth 64)
| Dir | Signal | Purpose |
|---|---|---|
| in | `wr_en` / `wr_data[DW-1:0]` | Write port |
| out | `full` / `overflow` | `overflow` pulses on write-while-full |
| in | `rd_en` | Read port |
| out | `rd_data[DW-1:0]` / `empty` | First-word-fall-through: data is already present, `rd_en` advances the pointer |

### `uart_to_axis`  (params `CLKS_PER_BIT`, `FIFO_AW`)
Contains `uart_rx` + `sync_fifo`.

| Dir | Signal | Purpose |
|---|---|---|
| in | `rx` | |
| out | `m_tdata[7:0]` / `m_tvalid`, in `m_tready` | Pattern ① — wires straight to `top_v2`'s `s_*` |
| out | `overflow` / `rx_byte_seen` | Diagnostics |

### `axis_to_uart`  (param `CLKS_PER_BIT`)
Contains `uart_tx`.

| Dir | Signal | Purpose |
|---|---|---|
| in | `s_tdata[7:0]` / `s_tvalid`, out `s_tready` | Pattern ①; `s_tready = ~tx_busy` |
| out | `tx` | |

### `axis_arb2` — frame-atomic 2:1 arbiter
| Dir | Signal | Purpose |
|---|---|---|
| in | `s0_tdata[7:0]` / `s0_tvalid`, out `s0_tready` | **Feature frames**, higher priority |
| in | `s1_tdata[7:0]` / `s1_tvalid`, out `s1_tready` | **Status frames** |
| out | `m_tdata[7:0]` / `m_tvalid`, in `m_tready` | Merged output |

All three groups are pattern ①. A source is granted until *its* `tvalid` falls,
which equals frame granularity because both producers hold `tvalid` high for a
whole frame.

### `status_reporter`  (param `IDLE_CYCLES`)
| Dir | Signal | Purpose |
|---|---|---|
| in | `rx_byte_seen` | Drives the RX-idle detector that triggers a frame |
| in | 7 × `[31:0]` | `msg_count`, `unknown_count`, `filtered_count`, `miss_count`, `oow_count`, `drop_count`, `parse_err_count` |
| out | `m_tdata[7:0]` / `m_tvalid`, in `m_tready` | 31-byte frame, pattern ① |

---

## 4. Core pipeline

### `top_v2` — engine top
| Dir | Signal | Purpose |
|---|---|---|
| in | `s_tvalid` / `s_tdata[7:0]`, out `s_tready` | Inbound ITCH byte stream |
| out | `tx_valid` / `tx_data[7:0]`, in `tx_ready` | Outbound feature frames — a **transport-agnostic byte stream**, not a UART port |
| out | `parse_error` | 1-cycle pulse (*not* a counter; `top_uart` accumulates it) |
| out | 6 × `[31:0]` | `unknown_count`, `msg_count`, `filtered_count`, `miss_count`, `oow_count`, `drop_count` |

### `itch_parser`  (params `FILTER_EN`, `FILTER_LOCATE`)
| Dir | Signal | Purpose |
|---|---|---|
| in | `s_tvalid` / `s_tdata[7:0]`, out `s_tready` | `s_tready = (state != EMIT)` |
| out | `ev` (`itch_event_t`) / `ev_valid`, in `ev_ready` | Pattern ① |
| out | `parse_error` | 1-cycle pulse on framing-length mismatch; the event is **not** emitted |
| out | `unknown_count` / `msg_count` / `filtered_count` | Pattern ⑤ |

### `event_dispatcher`
The widest port list in the design. Read it as six independent groups.

| Group | Dir | Signals |
|---|---|---|
| Event in | in | `ev` / `ev_valid`; out `ev_ready` (**high only in IDLE**) |
| Insert → lookup | out | `ins_valid`, `ins_order_id[63:0]`, `ins_price[31:0]`, `ins_qty[31:0]`, `ins_side` |
| Query → lookup | out | `qry_valid`, `qry_order_id[63:0]`, `qry_op` (`lookup_op_e`), `qry_qty[31:0]` |
| Result ← lookup | in | `lk_busy`, `res_valid`, `res_hit`, `res_price[31:0]`, `res_side`, `res_delta_qty[31:0]`, `res_removed` |
| Command → book | out | `bu_valid`, `bu_is_add`, `bu_price[31:0]`, `bu_qty[31:0]`, `bu_side`; in `bu_ready` |
| Trade tap → features | out | `trade_valid`, `trade_side`, `trade_qty[31:0]` |
| Diagnostic | out | `miss_count[31:0]` |

### `order_lookup`  (param `TABLE_BITS`)
| Dir | Signal | Purpose |
|---|---|---|
| in | `ins_valid`, `ins_order_id[63:0]`, `ins_price[31:0]`, `ins_qty[31:0]`, `ins_side` | Insert port |
| in | `qry_valid`, `qry_order_id[63:0]`, `qry_op`, `qry_qty[31:0]` | Query port |
| out | `busy` | High outside IDLE — hold inputs while asserted |
| out | `res_valid` | 1-cycle pulse, **queries only** (inserts produce no result) |
| out | `res_hit` | 0 = unknown or evicted id |
| out | `res_price[31:0]` / `res_side` | Resolved location in the book |
| out | `res_delta_qty[31:0]` | Shares to remove — all remaining for Delete, the message amount for Execute/Cancel |
| out | `res_removed` | Order fully drained |

### `book_update`  (params `BASE_PRICE`, `WINDOW_SIZE`, `ADDR_W`)
| Group | Dir | Signals |
|---|---|---|
| Command | in | `bu_valid`, `bu_is_add`, `bu_price[31:0]`, `bu_qty[31:0]`, `bu_side`; out `bu_ready` |
| Masks | out | `bid_mask[WINDOW_SIZE-1:0]`, `ask_mask[WINDOW_SIZE-1:0]` — pattern ④, 1024 bits each |
| Read port | in | `bid_rd_addr[ADDR_W-1:0]` → out `bid_rd_data[31:0]` (1-cycle registered read) |
| Read port | in | `ask_rd_addr[ADDR_W-1:0]` → out `ask_rd_data[31:0]` |
| Strobe | out | `book_updated` — 1-cycle pulse, **the timing anchor for everything downstream** |
| Diagnostic | out | `oow_count[31:0]` |

**Read-port direction is the most commonly reversed thing in this design:**
address is an *input*, data is an *output*. `book_update` is the storage;
`tob_tracker` is the requester.

### `priority_encoder`  (params `WINDOW_SIZE`, `ADDR_W`)
| Dir | Signal |
|---|---|
| in | `bid_mask[WINDOW_SIZE-1:0]`, `ask_mask[WINDOW_SIZE-1:0]` |
| out | `best_bid_addr[ADDR_W-1:0]`, `best_bid_valid` |
| out | `best_ask_addr[ADDR_W-1:0]`, `best_ask_valid` |

Pattern ④ with no handshake, but internally pipelined — outputs lag the masks
by **2 cycles**.

### `radix_find_lowest`  (params `WINDOW_SIZE`, `NUM_GROUPS`, `GSEL_W`, `ADDR_W`)
| Dir | Signal |
|---|---|
| in | `vec[WINDOW_SIZE-1:0]` |
| out | `addr[ADDR_W-1:0]`, `valid` |

### `find_lowest` / `onehot2bin` / `onehot2bin_gen`
**Purely combinational — no `clk`, no `arstn`.**

| Module | in | out |
|---|---|---|
| `find_lowest` | `mask[31:0]` | `addr[4:0]`, `valid` |
| `onehot2bin` | `oh[31:0]` | `bin[4:0]` |
| `onehot2bin_gen` (param `W`) | `oh[W-1:0]` | `bin[BW-1:0]` |

### `tob_tracker`  (params `WINDOW_SIZE`, `ADDR_W`)
| Dir | Signal | Purpose |
|---|---|---|
| in | `book_updated` | Timing anchor |
| in | `best_bid_addr` / `best_bid_valid` / `best_ask_addr` / `best_ask_valid` | From the encoder — **live wires**, latched internally at t+2 |
| out | `bid_rd_addr` / `ask_rd_addr` | Addresses issued to `book_update` |
| in | `bid_rd_data[31:0]` / `ask_rd_data[31:0]` | Quantities returned |
| out | `tob` (`tob_t`) / `tob_valid` | 1-cycle pulse; asserted only when **both** sides are valid |

### `feature_engine`  (params `QTY_SHIFT`, `MOM_DEPTH`, `TFLOW_DEPTH`)
| Dir | Signal | Purpose |
|---|---|---|
| in | `tob_valid` / `tob` | **Stream A** — snapshots; drives SPR, TOBI, OFI, EMADEV, MOM |
| in | `trade_valid` / `trade_side` / `trade_qty[31:0]` | **Stream B** — trades, direct from the dispatcher; drives TFLOW only |
| out | `feat_valid` | 1-cycle pulse |
| out | `f_spr`, `f_tobi`, `f_ofi`, `f_emadev`, `f_mom`, `f_tflow` | All `signed [15:0]` |

The two input streams are **independent and unsynchronised** — the structural
detail most often missed in this module.

### `board_link_tx`
| Dir | Signal | Purpose |
|---|---|---|
| in | `feat_valid` + 6 × `signed [15:0]` | |
| out | `tx_valid` / `tx_data[7:0]`, in `tx_ready` | Pattern ①, 15-byte frame |
| out | `drop_count[31:0]` | Vectors replaced mid-frame (drop-oldest) |

### `latency_probe`
| Dir | Signal | Purpose |
|---|---|---|
| in | `ev_handoff`, `book_updated`, `tob_valid`, `feat_valid` | Four taps — **observation only**, no back-pressure, no side effects |
| out | 11 × `[31:0]` | `lat_last/min/max/sum/count`, `lat_resolve/book2tob/tob2feat`, `lat_ia_last/ia_min`, `lat_unmatched` |

---

## 5. Data types (`ITCH50_pkg`)

### `itch_event_t` — parser output
| Field | Width | Notes |
|---|---|---|
| `msg_type` | 8 | ASCII, e.g. `"A"` |
| `stock_locate` | 16 | Same byte offset in *every* message type — that is what makes symbol filtering cheap |
| `order_id` | 64 | For Replace this is the **old** reference number |
| `new_order_id` | 64 | Replace only |
| `price` | 32 | `Price(4)` integer = dollars × 10 000 |
| `shares` | 32 | |
| `side` | 1 | 0 = buy, 1 = sell. Valid **only** for Add — Execute/Cancel/Delete/Replace do not carry it, which is precisely why `order_lookup` exists |

### `tob_t` — snapshot into the feature engine
| Field | Width | Notes |
|---|---|---|
| `bid_idx` / `ask_idx` | 16 | **Window tick indices, not prices.** Differences are already in ticks, which is what lets the feature engine avoid division entirely |
| `bid_qty` / `ask_qty` | 32 | Aggregate shares at that level |

### `lookup_op_e`
`OP_EXECUTE` (E/C), `OP_CANCEL` (X), `OP_DELETE` (D). **There is deliberately no
`OP_REPLACE`** — the dispatcher decomposes `U` into a delete plus an insert, so
`order_lookup` never needs to know Replace exists.
