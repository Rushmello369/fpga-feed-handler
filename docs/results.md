# Measured Results

All numbers on this page come from the checked-in Vivado reports and from
actually running the testbenches. Nothing here is estimated unless it is
explicitly labelled **analytical**.

Reproduce everything with the commands in [§5](#5-reproducing-these-numbers).

---

## 1. Build under test

| | |
|---|---|
| Synthesis top | `top_board` |
| Device | `xc7a200tfbg484-2` (Artix-7 200T) |
| Toolchain | Vivado 2025.2 |
| Implementation completed | 2026-07-27 |
| Design state | Routed, bitstream written |

Parameters actually bound at elaboration (read back from the synthesis log, not
from source defaults — see [parameters.md](parameters.md) for why that
distinction matters):

| Parameter | Value |
|---|---|
| `BASE_PRICE` | 1_610_800 |
| `WINDOW_SIZE` | 1024 |
| `FILTER_EN` / `FILTER_LOCATE` | 1 / 14 |
| `QTY_SHIFT` | 0 |
| `TABLE_BITS` | 14 |
| `CLK_FREQ_HZ` / `BAUD` | 100_000_000 / 1_000_000 |

---

## 2. Timing closure — 100 MHz, met

Source: `hardware/ax7a200b/vivado/itch_uart.runs/impl_1/top_board_timing_summary_routed.rpt`

| Metric | Value |
|---|---|
| **WNS** (worst negative slack, setup) | **+0.333 ns** |
| TNS (total negative slack) | 0.000 ns |
| Setup endpoints failing | **0 of 38,013** |
| **WHS** (worst hold slack) | **+0.068 ns** |
| THS | 0.000 ns |
| Hold endpoints failing | **0 of 38,013** |
| WPWS (pulse width) | +3.870 ns, 0 failing |

Clock tree: 200 MHz differential input → `MMCME2_BASE` (VCO 1000 MHz,
÷10) → 100 MHz on a global buffer. The whole design is **one clock domain**;
`sys_clk` carries only a pulse-width check, and the sole asynchronous input
(the UART RX pin) is resynchronised inside `uart_rx`.

### The path that had to be fixed

The address computation in `book_update` was the critical path at
**WNS −0.055 ns**. A full 32-bit divide-by-`TICK_SIZE` did not fit in one
cycle. It was split into two pipeline stages (`ADDR1` = window bounds check +
subtract, `ADDR2` = the divide alone). Because `ADDR1` establishes
in-window-ness first, the difference fed to the divider is provably smaller
than `WINDOW_SIZE × TICK_SIZE`, so the divider narrowed from 32 bits to
`DIFF_W` = 17 bits as well as gaining its own cycle. Both effects together
produced the positive slack above. Commit `2738e85`.

---

## 3. Resource utilisation

Source: `.../impl_1/top_board_utilization_placed.rpt`

| Resource | Used | Available | Util % |
|---|---|---|---|
| Slice LUTs | 12,577 | 133,800 | 9.40 % |
|   — as logic | 9,750 | 133,800 | 7.29 % |
|   — as memory | 2,827 | 46,200 | 6.12 % |
| Slice Registers (all flip-flops, 0 latches) | 6,211 | 267,600 | 2.32 % |
| Block RAM tiles | 58 | 365 | 15.89 % |
| **DSP slices** | **0** | 740 | **0.00 %** |
| MMCM | 1 | 10 | 10.00 % |
| Global clock buffers | 2 | 32 | 6.25 % |

**DSP = 0 is the headline number.** All six features are computed with adds,
subtracts and shifts only — no multiplier, no divider anywhere in the feature
path. That is a design constraint the utilisation report proves objectively,
rather than something the documentation merely asserts. It is achieved by
carrying prices as **window tick indices** rather than raw ITCH price words
(so differences are already in ticks), by defining top-of-book imbalance as a
*difference* rather than a ratio, and by choosing an EMA coefficient of 1/16 so
the update is a pure arithmetic shift.

The 2,816 LUTs used as distributed RAM are the two 1024-bit occupancy masks
plus small structures; the 58 BRAMs hold the per-level quantity arrays and the
16,384-entry order table.

---

## 4. Functional verification

15 unit testbenches, **275 assertions, 0 failures**. Verified by running
`bash tb/run_all_tb.sh` (exit code 0).

| Testbench | Assertions | Covers |
|---|---|---|
| `tb_itch_parser` | 21 | field extraction per message type, framing length mismatch → `parse_error`, unknown types counted not fatal, back-pressure via `s_tready` |
| `tb_event_dispatcher` | 13 | Add / Execute / Cancel / Delete / Replace paths, lookup-miss handling |
| `tb_order_lookup` | 22 | insert/query/drain, Delete with no wire quantity, **collision eviction** (`TABLE_BITS` shrunk to 4 to force it), unknown-id miss |
| `tb_book_update` | 14 | add/remove, zero clamping, out-of-window drop counting, mask/quantity coherence |
| `tb_radix_find_lowest` | 14 | lowest-set-bit across group boundaries, all-zero vector, single-bit vectors |
| `tb_tob_tracker` | 11 | two-sided snapshot assembly, one-sided book suppressed |
| `tb_tob_tracker_backtoback` | 9 | **the Replace race**: two updates ~5 cycles apart must not pair update #2's address with update #1's quantity |
| `tb_feature_engine` | 42 | all six features, saturation boundaries, EMA seeding, OFI/MOM initialisation artefacts |
| `tb_board_link_tx` | 38 | 15-byte frame layout, XOR checksum, sequence rollover, drop-oldest under back-pressure |
| `tb_latency_probe` | 35 | stage arithmetic, Replace double-fire, abandoned events, **overlapping measurements** |
| `tb_uart_to_axis` | 7 | byte reception into the stream, FIFO decoupling |
| `tb_status_reporter` | 16 | idle-triggered frame emission, one frame per burst, checksum |
| `tb_button_debounce` | 9 | glitch rejection, stable-level acceptance |
| `tb_top_uart` | 10 | full pipeline end to end through the UART wrapper |
| `tb_eth_crc32` † | 14 | Ethernet FCS against `zlib.crc32` vectors, residue property, 1-bit corruption detection, back-to-back frames |

† `eth_crc32` is a foundation block for a future Ethernet ingress path. It is
verified but **not instantiated in the current bitstream**, so it contributes
nothing to the timing and resource figures above.

### Verification practice worth noting

Two testbenches were validated by **mutation testing** — deliberately breaking
the RTL and confirming the testbench fails:

- Removing the `t+2` address latch in `tob_tracker` makes
  `tb_tob_tracker_backtoback` fail while the single-update test still passes,
  which is exactly the bug the fix in commit `87edeab` addressed.
- Replacing `latency_probe`'s per-stage timestamp carriers with a naive single
  "armed" flag makes `tb_latency_probe` fail 5 assertions, all confined to the
  overlap scenario.

An assertion that has never been observed to fail is not evidence that it works.

---

## 5. Latency

### 5.1 Measurement definition

Quoting a latency number without stating what it spans is meaningless, so:

> **`t_total` = cycles from `ev_handoff` (the parser handing a validated event
> to the dispatcher) to the first `feat_valid` produced by that event.**

This deliberately **excludes** UART wire time and the parser's byte-shifting,
making it a property of the core pipeline rather than of whatever transport
happens to be feeding it. See [§5.3](#53-why-end-to-end-would-be-the-wrong-number).

### 5.2 Stage breakdown — **analytical**, pending hardware measurement

Derived by tracing the FSMs, **not yet measured on hardware**:

| Interval | Cycles | Determined by |
|---|---|---|
| `t_resolve` (Add) | ~7 | dispatcher `ADD_ISSUE`/`ADD_WAIT` + `book_update` (5) |
| `t_resolve` (Execute/Cancel/Delete) | ~12 | + `order_lookup` (3) round trip before the book can act |
| `t_book2tob` | **5** (constant) | encoder pipe (2) + address settle (1) + registered read (1) + output register (1) |
| `t_tob2feat` | **1** (constant) | `feature_engine`, all six features in parallel |
| **`t_total`** (Execute) | **~18 cycles ≈ 180 ns** @ 100 MHz | |

If the parser were fed at one byte per cycle instead of being UART-starved, a
33-byte Execute would add 33 cycles of shift-in, giving ~51 cycles ≈ **510 ns**
message-to-feature.

**Status:** `latency_probe` (`rtl/ITCH50_parser/latency_probe.sv`) implements
this measurement and is unit-verified (35 assertions), but is **not yet wired
into `top_v2`**, so no hardware-measured numbers exist yet. This section will be
replaced with measured min/max/mean once the probe is integrated and read back
over the status channel. Until then, treat the table above as arithmetic, not
evidence.

Note that `t_book2tob` and `t_tob2feat` are fixed-latency chains with no data
dependence. Once measured, any value other than 5 and 1 indicates a bug, so the
probe doubles as an online correctness check.

### 5.3 Why end-to-end would be the wrong number

The bring-up transport is a 1 Mbaud UART. At 8-N-1 that is 10 bits per byte,
so **10 µs per byte**, 100 KB/s.

| | Time |
|---|---|
| Computing all six features | 1 cycle = **10 ns** |
| Transmitting one 15-byte feature frame | **150 µs** |
| A 33-byte Execute arriving over the wire | **330 µs** |
| Core processing of that Execute (analytical) | **~0.18 µs** |

The transport is roughly **three orders of magnitude** slower than the core. Any
end-to-end figure measured on this bitstream would therefore be a measurement of
the UART, not of the feed handler. This is why the probe brackets the core only,
and why it also records the interval between consecutive events — so the
transport cost and the core cost can be reported from the same run, on the same
clock, both measured rather than one measured and one asserted.

UART was chosen for bring-up because it minimises time-to-first-observation and
debugging surface: two wires, an existing USB bridge, no MAC, no PHY
negotiation, no DMA descriptors, no host driver. It is the right transport for
verifying correctness and the wrong one for demonstrating throughput.

---

## 6. Reproducing these numbers

```bash
# Simulation — 14 testbenches, expect "261 assertions passed, 0 failed"
cd hardware/ax7a200b
bash tb/run_all_tb.sh
```

```bash
# Synthesis + implementation from source (no project files are committed)
cd hardware/ax7a200b
vivado -mode batch -source create_vivado_project.tcl
# then, in the Vivado Tcl console:
#   launch_runs synth_1 -jobs 8 ; wait_on_run synth_1
#   launch_runs impl_1  -jobs 8 ; wait_on_run impl_1
```

The Vivado simulator is located automatically by `tb/run_tb.sh`; override with
`export VIVADO_BIN=/path/to/Vivado/bin` if it is installed somewhere unusual.

---

## 7. Scope of these results

These numbers describe **feed → parse → order book → six features → framed byte
stream**, plus a diagnostic read-back channel, running on real silicon against
real NASDAQ ITCH 5.0 capture data.

They do **not** cover: Ethernet MAC/PHY, PCIe/XDMA, a risk core, an order-entry
encoder, the board-to-board link to the Pynq Z1 (UART currently substitutes for
it), or any ML inference in hardware. The design processes a single instrument
(`FILTER_LOCATE = 14`) within a 1024-tick price window.
