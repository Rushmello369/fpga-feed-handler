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

### Differential verification — RTL ≡ golden model ≡ hardware

The strongest evidence in the project, and the one thing unit tests structurally
cannot provide: they check each module against expectations *written by the same
person who wrote the module*, so a shared misunderstanding of the ITCH spec
would pass every one of them. An independent implementation, on real exchange
data, end to end, is what closes that hole.

Real NASDAQ ITCH 5.0 captures for one instrument (`stock_locate` 14) are pushed
through both implementations at identical calibration (`BASE_PRICE=1_610_800`,
`WINDOW_SIZE=1024`, `QTY_SHIFT=0`, `TABLE_BITS=14`):

```bash
cd hardware/ax7a200b && bash tb/run_diff.sh aapl_200000.bin
```

| Capture | Messages | Book-affecting | Frames | Feature values | Mismatches |
|---|---|---|---|---|---|
| `aapl_small` | 2,000 | 1,831 | 1,592 | 9,552 | **0** |
| `aapl_50000` | 50,000 | 47,879 | 31,994 | 191,964 | **0** |
| **`aapl_200000`** | **200,000** | **196,171** | **146,172** | **877,032** | **0** |

Diagnostic counters agree independently at every size — book-affecting message
count, out-of-window drops, lookup misses, parse errors, dropped frames, bad
checksums.

### Coverage matters more than volume

The three captures are not merely different sizes; they exercise different
code:

| Capture | Add | Execute | Delete | Cancel | **Exec-w-Price** | **Replace** |
|---|---|---|---|---|---|---|
| `aapl_small` | 914 | 523 | 389 | 5 | **0** | **0** |
| `aapl_50000` | 32,546 | 4,222 | 10,517 | 26 | 17 | 551 |
| `aapl_200000` | 110,504 | 12,503 | 62,296 | 550 | **122** | **10,196** |

**The two smallest captures contain no Replace messages at all.** Replace is
the most intricate path in the design — the dispatcher decomposes it into a
delete on the old id (which also recovers the side, absent from the wire)
followed by an insert, and it is where both the `RPL_WAIT` stale-`bu_ready`
bug and the `tob_tracker` back-to-back race lived. A differential test on
`aapl_small` passes without touching any of that.

The 200k capture also drives **14,060 order-table evictions**. That is the
number that matters most: `handler_contract.md` requires the Python model to
reproduce the direct-mapped table's silent-overwrite behaviour rather than
substitute an unbounded dictionary, and 14,060 agreeing evictions is what
demonstrates it does.

### Confirmed on silicon

The 50k capture was replayed into the AX7A200B over UART at 1 Mbaud and the
returned frames diffed against the same golden model. Every counter the FPGA
reports matches the simulation exactly:

| | RTL simulation | **Silicon** |
|---|---|---|
| messages | 50,000 | **50,000** |
| unknown message types | 2,120 | **2,120** |
| order-table misses | 746 | **746** |
| out-of-window drops | 15,401 | **15,401** |
| dropped frames | 0 | **0** |
| parse errors | 0 | **0** |
| frames emitted | 31,994 | **31,994** |
| **feature mismatches vs golden** | **0** | **0** |

191,964 feature values, produced identically by three independent things: the
RTL in simulation, a Python model written from the specification, and an FPGA.

Transfer rate: 1,716,664 bytes in 19.28 s = 89 KB/s against a theoretical
100 KB/s for 1 Mbaud 8-N-1; the shortfall is host-side inter-byte gaps.

### An operational trap worth documenting

The first attempt at this comparison failed with 87,647 field mismatches and a
first frame showing `spr = -195` — a crossed book, which cannot happen from an
empty book. It looked exactly like an order-book bug.

It was not. The FPGA had not been reset between replays. Four independent
counters came back at *precisely* 2× their expected values (`msg` 100,000,
`unknown` 4,240, `miss` 1,492, `oow` 30,802), which no logic error could produce
as a coincidence — the counters accumulate from reset, and more importantly the
order book still held the previous run's resting liquidity while the golden
model always starts empty.

Two lessons:

- **Simulation always starts from reset; real devices do not.** This class of
  failure is invisible to every testbench and appears only on hardware. It is a
  lifecycle bug, not a logic bug.
- **The diagnostic counters were what solved it.** Without them the natural move
  is to start debugging `book_update`. With them, the exact 2× pattern named the
  cause immediately. On a device with no processor and no debugger, the counters
  *are* the debugger.

`uart_feed.py` now counts the messages in the file it sends and compares that
against the FPGA's `msg` counter, reporting stale state explicitly rather than
printing thousands of diffs.

### Two small residuals, both explained by Replace

On the clean run, two probe cross-checks come out slightly under rather than
exactly equal:

| | Value | Expected | Δ |
|---|---|---|---|
| latency samples | 31,756 | 31,994 frames | −238 |
| events with no feature | 16,120 | `oow + miss` = 16,147 | −27 |

Both follow from Replace being decomposed into two book updates for one event:

- The probe times an event to its **first** feature, so the second feature a
  Replace produces is not a separate measurement — hence fewer samples than
  frames.
- A Replace whose one half is out-of-window while the other half succeeds
  increments `oow` but still reaches the book, so it is not an "event that
  produced no feature".

Both gaps are small relative to the 551 Replace messages in this capture, and
both shrink to zero on data without Replace.

### A diagnostic bug this exercise found

At 200k messages the run reported `drop_count = 2160` while emitting exactly
146,172 frames — the same count as the golden model, with zero mismatches. A
frame-for-frame match is impossible if 2,160 vectors had genuinely been lost,
so the counter, not the datapath, was wrong.

`board_link_tx` incremented `drop_count` on `sending || pend_valid`. Arriving
while `sending` is not a drop: the previous vector has already been latched
into the frame in flight, so the new one simply becomes pending and goes out
next. Only overwriting a still-`pend_valid` vector loses anything. The
condition is now `pend_valid` alone.

`tb_board_link_tx` had encoded the old behaviour, asserting `drop_count == 2`
for a sequence that drives three vectors and emits two frames — while its
*own* frame assertions in the same block verified that the second frame
carries the third vector, proving exactly one was lost. The two assertions
contradicted each other and the frame assertions were right.

After the fix: `drop_count` 433 → **0** on the 50k capture, with frame count
and every feature value unchanged. Unit tests 38/38.

#### A caution this exercise produced

An older `golden_small.csv` in the working tree disagrees with hardware from
frame 138 onward, which initially looked like a correctness bug. It was not:
that file has 1,599 rows against the correct 1,592 and was generated at
different parameters, with **no metadata recorded**. The golden model's own
help warns that `--table-bits` "must match, or collisions/evictions will
differ", and `handler_contract.md` §6 requires a metadata JSON beside every
golden CSV — which had not been written for that file.

The lesson is procedural, not technical: **a golden CSV without its parameter
metadata is not evidence, it is a rumour.** Regenerate rather than trust an
undated artefact, and never "fix" a reference model to agree with the DUT —
that destroys the only independent check there is.

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

### 5.2 Measured on silicon

`latency_probe.sv` timestamps every event through the pipeline and the results
are read back over the status channel. Measured on the AX7A200B over 31,756
events of real ITCH data:

| | Cycles | Time @100 MHz |
|---|---|---|
| min | 13 | **130 ns** |
| mean | 15.3 | **153 ns** |
| max | 18 | **180 ns** |

| Stage | Cycles | Determined by |
|---|---|---|
| `t_resolve` | 7 | dispatcher FSM + `order_lookup` + `book_update` |
| `t_book2tob` | **5** | encoder pipe (2) + address settle (1) + registered read (1) + output register (1) |
| `t_tob2feat` | **1** | `feature_engine`, all six features in parallel |

**The two fixed stages were predicted before measurement.** `t_book2tob` and
`t_tob2feat` are fixed-latency chains with no data dependence, so their values
were derived from the RTL first — 5 and 1 — and any other result would have been
a bug rather than a measurement. They came back as 5 and 1 in simulation, and
again as 5 and 1 on hardware. The probe therefore doubles as an online
correctness check, not merely an instrument.

Simulation and silicon agree on the extremes exactly (13 and 18 cycles), which
is expected — the pipeline is fully synchronous with no data-dependent stalls
outside `t_resolve`.

An earlier analytical estimate of "~18 cycles for an Execute" turned out to be
the correct *upper* bound; the mean is lower because Add messages resolve
without the `order_lookup` round trip.

### 5.3 Why end-to-end would be the wrong number

The bring-up transport is a 1 Mbaud UART. At 8-N-1 that is 10 bits per byte,
so **10 µs per byte**, 100 KB/s.

Both sides of this comparison are now **measured on the same chip, in the same
run, on the same clock** — the probe records the interval between consecutive
events, which under UART is the transport cost:

| | Measured |
|---|---|
| core, event → feature | **153 ns** |
| transport, minimum interarrival | **20,791 cycles = 207.9 µs** |
| **ratio** | **~1,363×** |

For reference, the arithmetic that predicted this: 1 Mbaud 8-N-1 is 10 bits per
byte, so 10 µs per byte and 100 KB/s; a 33-byte Execute takes 330 µs on the
wire while the core needs 0.15 µs to process it.

Any end-to-end figure from this bitstream would therefore be a measurement of
the UART, not of the feed handler — which is exactly why the probe brackets the
core only, and why the transport is reported separately rather than folded in.

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
