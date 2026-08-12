# Parameter Registry

Every parameter in the design, classified by **who owns it and what breaks when
it changes** — which is more useful than listing them per module, because the
question you actually have is never "what parameters does `book_update` take"
but "am I allowed to change this, and what else must change with it".

> **Single source of truth.** Values that reach the bitstream are the ones
> declared on **`top_board`**. Everything below it has its own defaults which
> are *different* and are used only by standalone module testbenches. See
> [§5](#5-hazard-the-same-parameter-has-three-different-defaults).

---

## 1. Class A — Calibration

**Re-derived per instrument and per trading day. Changing any of these
invalidates previously generated golden data.**

| Parameter | Bitstream value | Where it comes from | Symptom if wrong |
|---|---|---|---|
| `BASE_PRICE` | 1_610_800 | `itch_tools.py calibrate <file> --ticker AAPL` | `oow_count` climbs — the price window is not centred on where the instrument actually traded |
| `WINDOW_SIZE` | 1024 | same calibration run | Too small: out-of-window drops. Too large: wasted BRAM and a wider priority encoder. Also propagates into `ADDR_W`, mask width and `DIFF_W` |
| `FILTER_LOCATE` | 14 | that day's Stock Directory (`R`) message for the ticker | The wrong instrument is processed; `filtered_count` and `msg_count` look implausible relative to each other |
| `FILTER_EN` | 1 | — | 0 accepts every symbol; only correct if the feed is already single-stock |

`BASE_PRICE` is in ITCH `Price(4)` units, i.e. dollars × 10 000. With
`WINDOW_SIZE = 1024` penny ticks, the window covers
1_610_800 → 1_713_200, i.e. **$161.08 – $171.31**.

`stock_locate` is assigned per trading day by NASDAQ. **It must never be
hard-coded across days.**

### Recalibration procedure

```bash
python hardware/ax7a200b/src/itch_tools.py calibrate <itch-file> --ticker AAPL
# -> prints the locate id and a suggested BASE_PRICE / WINDOW_SIZE
```

Then update the defaults on `top_board`, re-synthesise, and regenerate golden
data with the *same* values:

```bash
python hardware/ax7a200b/src/itch_tools.py golden <itch-file> --locate <N> \
  --base <BASE_PRICE> --window <WINDOW_SIZE> --qty-shift <QTY_SHIFT> \
  --table-bits 14 --out frames.csv
```

---

## 2. Class B — Contract-frozen

**Changing any of these is an interface change.** Per
[`handler_contract.md`](handler_contract.md) §7 it requires a synchronised
update to: this document, the RTL, `itch_tools.py`, the feature and board-link
testbenches, and the ML dataset version. Do not change one in isolation.

| Parameter | Value | What depends on it |
|---|---|---|
| `QTY_SHIFT` | 0 | The scale of every quantity-derived feature (TOBI, OFI, TFLOW). Must be recorded in the bitstream config, the golden CSV metadata, and the model experiment metadata |
| `TABLE_BITS` | 14 | Order-table capacity (2¹⁴ = 16,384 entries) and therefore the collision rate visible as `miss_count`. **The Python golden model must reproduce the same direct-mapped eviction behaviour** — an unbounded dict is not an acceptable substitute |
| `MOM_DEPTH` | 8 | The MOM feature is `mid(t) − mid(t−8)` |
| `TFLOW_DEPTH` | 16 | TFLOW is the signed sum of the last 16 trades |

Also frozen by the same contract, though not expressed as parameters: the
feature order `[spr, tobi, ofi, emadev, mom, tflow]`, the `signed int16` output
width, the `sat16` clamping rule, and the fact that `mid2 = bid_idx + ask_idx`
is **not** right-shifted (so one integer unit of EMADEV/MOM is *half* a price
tick).

---

## 3. Class C — Platform

Determined by the board and the chosen transport. Independent of the algorithm.

| Parameter | Value | Constraint |
|---|---|---|
| `CLK_FREQ_HZ` | 100_000_000 | Must match what the MMCM actually produces |
| `BAUD` | 1_000_000 | **Must equal the host's baud** (`uart_feed.py --baud 1000000`). 1 Mbaud is the CP2102's maximum and divides 100 MHz exactly, giving `CLKS_PER_BIT = 100` with zero baud error |
| `STATUS_IDLE_CYCLES` | 1_000_000 (10 ms) | **Must exceed the host's inter-byte gap**, otherwise a pause mid-burst is mistaken for end-of-burst and extra status frames are emitted. Testbenches override it with a tiny value |
| `STABLE_CYCLES` | 1_000_000 (10 ms) | Button debounce interval; longer than mechanical bounce (~1–10 ms) |
| `FIFO_AW` | 6 (depth 64) | Only needs to absorb the parser's brief `EMIT` back-pressure. Under UART a byte arrives every ~1000 clocks, so the FIFO never approaches full |

MMCM configuration is fixed in `top_board`: input 200 MHz,
`CLKFBOUT_MULT_F = 5` → VCO 1000 MHz, `CLKOUT0_DIVIDE_F = 10` → 100 MHz. The
VCO value is not free — it must sit inside the Artix-7 −2 legal range
(roughly 600–1600 MHz).

---

## 4. Class D — Derived

`localparam`s computed from the above. **Never set these by hand**; they exist
so that changing a Class A/B parameter propagates correctly.

| Name | Expression | Value |
|---|---|---|
| `ADDR_W` | `$clog2(WINDOW_SIZE)` | 10 |
| `DIFF_W` | `$clog2(WINDOW_SIZE × TICK_SIZE)` | 17 |
| `TAG_BITS` | `64 − TABLE_BITS` | 50 |
| `TABLE_SIZE` | `1 << TABLE_BITS` | 16,384 |
| `NUM_GROUPS` | `WINDOW_SIZE / 32` | 32 |
| `GSEL_W` | `$clog2(NUM_GROUPS)` | 5 |
| `CLKS_PER_BIT` | `CLK_FREQ_HZ / BAUD` | 100 |
| Feature frame length | `1 + 1 + 6×2 + 1` | 15 bytes |
| Status frame length | `2 + 7×4 + 1` | 31 bytes |

Protocol constants from the ITCH 5.0 specification, in `ITCH50_pkg`:
`PRICE_SCALE = 10000` (Price(4) has four implied decimals) and
`TICK_SIZE = 100` (US equities quote in pennies, so consecutive real price
levels are 100 Price(4) units apart).

### Structural constraint

`WINDOW_SIZE` must be a **power-of-two multiple of 32**. The radix tree splits
the mask into 32-bit leaves, and the final address is formed as
`{grp_sel, local_addr}` — a concatenation that is only arithmetically equal to
`grp_sel × 32 + local_addr` when the width is a power of two. 1024, 2048 and
4096 all build unchanged.

---

## 5. Hazard: the same parameter has three different defaults

The calibration parameters are declared with **different default values at
three levels of the hierarchy**:

| Module | `BASE_PRICE` | `WINDOW_SIZE` | `FILTER_EN` | `FILTER_LOCATE` |
|---|---|---|---|---|
| **`top_board`** (synthesis top) | **1_610_800** | **1024** | **1** | **14** |
| `top_uart` | 1_550_000 | 2048 | 1 | 1 |
| `top_v2` | 1_550_000 | 2048 | 0 | 0 |
| `book_update`, `priority_encoder`, `tob_tracker` | 1_550_000 | 2048 | — | — |
| `radix_find_lowest` | — | 1024 | — | — |

**The bitstream is correct**: `top_board` overrides every one of these on the
way down, and the synthesis log confirms `BASE_PRICE` bound to 1_610_800 and
`WINDOW_SIZE` to 1024.

**But a standalone simulation is not the same design.** Elaborating `top_v2` or
`tb_top_v2` directly picks up a 2048-tick window centred on $155.00 with symbol
filtering *disabled* — a materially different configuration from the one on the
board. A discrepancy between simulation and hardware that originates here is
very hard to diagnose, because nothing is obviously wrong in either.

**Rule: only `top_board`'s values reach the bitstream.** Lower-level defaults
exist purely so single-module testbenches elaborate without an explicit
parameter list. When comparing simulation against hardware, always elaborate
from `top_board` or pass the Class A values explicitly.

A cleaner long-term fix is to give the lower levels no defaults at all, forcing
every instantiation to state its configuration — worth doing if this bites once
more.
