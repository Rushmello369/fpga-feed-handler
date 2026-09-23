# IO layer — `top_board`, `top_uart` and the UART bring-up

The transport and board wrapper around the engine. Source:
[`rtl/ITCH50_parser/io/`](../../rtl/ITCH50_parser/io/)

[← back to README](../../README.md#11-getting-started)

---

## 1. Full-duplex path

One USB-UART carries the ITCH feed in and both frame types out.

```mermaid
flowchart LR
    PC(["host<br/>uart_feed.py"])
    RX["uart_to_axis<br/><i>uart_rx + sync_fifo</i>"]
    CORE["<b>top_v2</b><br/>the engine"]
    LINK(["feature frames<br/>15 B, sync 0xA5"])
    STAT(["status frames<br/>75 B, sync 0x5A"])
    ARB["axis_arb2<br/>frame-atomic"]
    TX["axis_to_uart<br/><i>uart_tx</i>"]

    PC -->|"RX pin L14"| RX
    RX -->|"① m_tdata / tvalid / tready"| CORE
    CORE --> LINK
    CORE -.->|"counters"| SR["status_reporter"]
    SR --> STAT
    LINK -->|"s0 — priority"| ARB
    STAT -->|"s1"| ARB
    ARB --> TX
    TX -->|"TX pin L15"| PC

    classDef io fill:#fff4e5,stroke:#f59e0b
    class RX,TX,ARB,SR io
```

No PS, no DMA, no Ethernet — the shortest path to seeing the whole datapath run on
real silicon against historical data.

## 2. Clock and reset generation in `top_board`

```mermaid
flowchart TB
    PIN["sys_clk_p / sys_clk_n<br/>200 MHz differential<br/>pins R4 / T4"]
    IB["IBUFDS"]
    MM["MMCME2_BASE<br/>CLKIN1_PERIOD 5.000<br/>CLKFBOUT_MULT_F 5 → <b>VCO 1000 MHz</b><br/>CLKOUT0_DIVIDE_F 10 → <b>100 MHz</b>"]
    BG["BUFG ×2<br/>clk100 + feedback"]
    LK{"LOCKED"}
    BTN["rst_btn_n — F15<br/>→ button_debounce<br/>STABLE_CYCLES = 10 ms"]
    SR["rst_sr — 4-bit shift register<br/><b>sync release, async assert</b>"]
    ARSTN(["arstn → everything"])

    PIN --> IB --> MM --> BG --> ARSTN
    MM --> LK
    LK -->|"not locked → hold reset"| SR
    BTN -->|"pressed → hold reset"| SR
    SR --> ARSTN

    classDef clk fill:#eff6ff,stroke:#2563eb
    class PIN,IB,MM,BG clk
```

**The VCO value is not free** — it must sit inside the Artix-7 −2 legal range,
roughly 600–1600 MHz. **Reset release is synchronous** via the shift register so
every flop leaves reset on the same edge, while assertion is immediate. There is no
external reset pin needed: reset is held until the MMCM actually locks, because
running the pipeline on an unstable clock is never correct.

`button_debounce` has **no `arstn` by design** — it *produces* the reset, so it
cannot depend on one. It relies on register initial values loaded at FPGA
configuration.

## 3. Baud choice

```mermaid
flowchart LR
    B["BAUD = 1,000,000<br/><i>CP2102GM maximum</i>"]
    C["CLK_FREQ_HZ = 100,000,000"]
    B --> D["CLKS_PER_BIT = 100<br/><b>exactly</b> — zero baud error"]
    C --> D
    D --> E["8-N-1 → 10 bits/byte<br/>10 µs per byte<br/><b>100 KB/s</b>"]
```

Must equal the host's baud (`uart_feed.py --baud 1000000`). 1 Mbaud divides 100 MHz
exactly, which is why it was chosen over a faster non-integer divisor.

## 4. The three bring-up LEDs

```mermaid
flowchart LR
    subgraph L1["rx_overflow_n — LED2, pin M13"]
        direction TB
        O1["sync_fifo overflow<br/><i>1-cycle pulse, 10 ns</i>"]
        O2["<b>latched sticky</b><br/>cleared only by reset"]
        O3["dark = healthy<br/>lit = it happened at some point"]
        O1 --> O2 --> O3
    end

    subgraph L2["heartbeat_n — LED3, pin K14"]
        direction TB
        H1["hb_cnt[25] toggles<br/>every 2^25 cycles"]
        H2["~1.5 Hz blink"]
        H3["<b>steady = clock or reset problem</b><br/>stop debugging further down"]
        H1 --> H2 --> H3
    end

    subgraph L3["rx_activity_n — LED4, pin K13"]
        direction TB
        A1["rx_byte_seen<br/><i>pre-FIFO, pre-core</i>"]
        A2["stretched ~0.25 s"]
        A3["proves bytes physically reach<br/>the chip, regardless of what<br/>the pipeline does with them"]
        A1 --> A2 --> A3
    end

    classDef warn fill:#fef2f2,stroke:#dc2626
    class O3,H3 warn
```

> **These pins are active-low: driving 0 lights the LED.** Hence the `_n` suffixes
> and the inversions. The pin-to-LED mapping is also **shifted by one** from what the
> board user guide suggests — determined empirically with `bringup/led_test.sv`,
> which drives the three pins at three distinguishable rates.

**Why overflow is latched.** `sync_fifo`'s `overflow` is a 1-cycle pulse — 10 ns —
so wiring it straight to a pin produced an indicator that could never be seen by
eye and therefore *always looked healthy*. An error light has to report "this ever
happened", not "this is happening right now".

## 5. Status frames — triggered by silence, not a command byte

```mermaid
flowchart TD
    RX["rx_byte_seen"] --> TMR["idle_cnt<br/>reset on every byte"]
    TMR --> Q{"idle_cnt == IDLE_CYCLES-1<br/>and had_activity<br/>and not sending ?"}
    Q -->|no| TMR
    Q -->|yes| EMIT["assemble frame<br/>had_activity ← 0<br/><b>one frame per burst</b>"]
    EMIT --> FR["0x5A | seq | 18 × uint32 | XOR<br/><b>75 bytes, big-endian</b>"]

    classDef good fill:#ecfdf5,stroke:#059669
    class FR good
```

**Why not an in-band command byte.** The inbound ITCH stream is a continuous
`[length][body]` sequence in which **any** byte value can occur inside a price,
order id or timestamp field. A magic byte would eventually collide with real data
and desynchronise the framing permanently. Watching for the RX line to go quiet
cannot corrupt the datapath, and it fires at exactly the moment the host wants the
counters: the end of a replay burst.

`IDLE_CYCLES` must **exceed the host's inter-byte gap**, or a pause mid-burst is
mistaken for end-of-burst and extra frames are emitted. Testbenches override it
with a tiny value.

The counters arrive as one flattened `cnt_bus` rather than named ports, packed
MSB-first so the frame is big-endian by construction. That keeps `status_reporter`
agnostic about what is being reported — adding a counter is a change in `top_uart`
and the host decoder, not here.

> **`stat_bus`'s concatenation order *is* the wire format.** `uart_feed.py`'s
> `STATUS_FIELDS` list must match it element for element. Adding a counter means
> editing both, in the same commit.

## 6. Frame-atomic arbitration

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> GRANT0 : s0_tvalid<br/><b>features win ties</b>
    IDLE --> GRANT1 : s1_tvalid and not s0_tvalid
    GRANT0 --> IDLE : not s0_tvalid<br/><i>frame complete</i>
    GRANT1 --> IDLE : not s1_tvalid<br/><i>frame complete</i>
```

Both producers hold `tvalid` high for a whole frame and drop it only at the frame
boundary. So "grant a source until its `tvalid` falls" **is** frame granularity —
the two frame types can never interleave or tear on the wire. Without this the host
would see a `0xA5` feature frame with status bytes spliced into it.

Priority only decides who starts when both are waiting and the mux is idle.

## 7. FIFO sizing

`sync_fifo` is first-word-fall-through, `DW = 8`, `AW = 6` → **depth 64**.

It only needs to absorb the parser's brief `EMIT` back-pressure. Under UART a byte
arrives every ~1000 clocks, so the FIFO never approaches full — `rx_overflow` going
sticky would mean something structurally wrong, which is exactly why it is worth an
LED.

Verified by `tb_uart_to_axis` (7 assertions), `tb_status_reporter` (16),
`tb_button_debounce` (9), and `tb_top_uart` (10, full pipeline end to end).
