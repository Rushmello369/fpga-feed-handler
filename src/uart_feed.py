#!/usr/bin/env python3
"""
uart_feed.py  --  stream an ITCH byte file into the AX7A200B over USB-UART and
                  collect the 15-byte feature frames it sends back.

Matches top_uart.sv:
  * feed IN  : the framed ITCH stream produced by  itch_tools.py filter
  * frames OUT (15 bytes each, big-endian):
        [0]  sync = 0xA5
        [1]  seq  (rolling)
        [2:14] six int16: spr, tobi, ofi, emadev, mom, tflow
        [14] chk  = XOR of bytes[0..13]

Usage:
    pip install pyserial
    python uart_feed.py --port COM5 --baud 921600 \
           --send aapl.bin --recv-csv frames_hw.csv [--golden golden.csv]

    python uart_feed.py --selftest        # validate the frame decoder offline

Notes:
  * Baud must equal top_uart's BAUD parameter (CLKS_PER_BIT = CLK_FREQ/BAUD).
  * No hardware flow control: the FPGA consumer is ~1000x faster than the UART,
    so bytes are simply streamed; the on-chip FIFO absorbs parser backpressure.
"""

import argparse
import struct
import sys
import threading
import time

SYNC = 0xA5
FRAME_LEN = 15
FIELDS = ["spr", "tobi", "ofi", "emadev", "mom", "tflow"]

# Diagnostic status frame (status_reporter.sv): distinct sync, emitted once the
# FPGA sees the RX line go quiet at the end of a burst.
#
# STATUS_FIELDS MUST match top_uart.sv's `stat_bus` concatenation exactly,
# element for element - that assignment is the wire format. Adding a counter
# means editing both, in the same commit.
STATUS_SYNC = 0x5A
STATUS_FIELDS = [
    # 7 pipeline counters
    "msg", "unknown", "filtered", "miss", "oow", "drop", "parse_err",
    # 11 latency-probe results (cycles at 100 MHz -> 10 ns each)
    "lat_last", "lat_min", "lat_max", "lat_sum", "lat_count",
    "lat_resolve", "lat_book2tob", "lat_tob2feat",
    "lat_ia_last", "lat_ia_min", "lat_unmatched",
]
STATUS_LEN = 2 + len(STATUS_FIELDS) * 4 + 1     # sync + seq + counters + xor

# lat_min / lat_ia_min power up to 0xFFFFFFFF so the first sample always wins;
# that value means "no measurement yet", not a real 4.29-billion-cycle latency.
NO_SAMPLE = 0xFFFF_FFFF


def _xor(bs):
    c = 0
    for b in bs:
        c ^= b
    return c


class FrameDecoder:
    """Resynchronizing decoder for both frame types, XOR-checksum validated.

    Feature frames (0xA5, 15B) are yielded from feed(); status frames
    (0x5A, 31B) are collected into .status. Both syncs are scanned for, and a
    bad checksum just advances one byte, so a frame type appearing inside the
    other's payload cannot desynchronise the stream.
    """

    def __init__(self):
        self.buf = bytearray()
        self.bad = 0
        self.status = []          # decoded status frames, in arrival order

    def feed(self, data):
        """Append bytes; yield dict per valid FEATURE frame."""
        self.buf.extend(data)
        while True:
            # find the earliest candidate of either frame type
            i_f = self.buf.find(SYNC)
            i_s = self.buf.find(STATUS_SYNC)
            cands = [x for x in (i_f, i_s) if x >= 0]
            if not cands:
                self.buf.clear()
                return
            i = min(cands)
            if i > 0:
                del self.buf[:i]

            kind_status = (self.buf[0] == STATUS_SYNC)
            need = STATUS_LEN if kind_status else FRAME_LEN
            if len(self.buf) < need:
                return

            frame = bytes(self.buf[:need])
            if _xor(frame[:need-1]) != frame[need-1]:
                # not a real frame boundary here: skip this sync byte and rescan
                self.bad += 1
                del self.buf[0]
                continue

            if kind_status:
                n = len(STATUS_FIELDS)
                vals = struct.unpack(f">{n}I", frame[2:2 + n * 4])
                self.status.append(dict(seq=frame[1],
                                        **dict(zip(STATUS_FIELDS, vals))))
                del self.buf[:need]
                continue

            vals = struct.unpack(">6h", frame[2:14])
            del self.buf[:FRAME_LEN]
            yield dict(seq=frame[1], **dict(zip(FIELDS, vals)))


def _make_frame(seq, spr, tobi, ofi, emadev, mom, tflow):
    body = bytes([SYNC, seq & 0xFF]) + struct.pack(">6h", spr, tobi, ofi,
                                                    emadev, mom, tflow)
    chk = 0
    for b in body:
        chk ^= b
    return body + bytes([chk])


def _make_status(seq, counters):
    n = len(STATUS_FIELDS)
    if len(counters) != n:
        raise ValueError(f"expected {n} counters, got {len(counters)}")
    body = bytes([STATUS_SYNC, seq & 0xFF]) + struct.pack(f">{n}I", *counters)
    return body + bytes([_xor(body)])


def cmd_selftest(_args):
    frames = [
        dict(seq=0, spr=2, tobi=100, ofi=100, emadev=0, mom=1002, tflow=0),
        dict(seq=1, spr=2, tobi=50,  ofi=-50, emadev=0, mom=1002, tflow=-50),
    ]
    # 7 pipeline counters + 11 latency values, in STATUS_FIELDS order
    exp_status = (0x1234, 7, 0xABCDEF, 8, 0xE5, 0, 0x5678,
                  18, 17, 24, 0x4E20, 1000, 12, 5, 1, 38000, 21000, 0)

    stream = b"\x00\xffnoise"        # junk before sync to test resync
    stream += _make_frame(frames[0]["seq"], frames[0]["spr"], frames[0]["tobi"],
                          frames[0]["ofi"], frames[0]["emadev"],
                          frames[0]["mom"], frames[0]["tflow"])
    # a status frame interleaved between feature frames must not disturb them
    stream += _make_status(3, exp_status)
    stream += _make_frame(frames[1]["seq"], frames[1]["spr"], frames[1]["tobi"],
                          frames[1]["ofi"], frames[1]["emadev"],
                          frames[1]["mom"], frames[1]["tflow"])
    stream += b"\xa5\x01bad"          # false sync w/ wrong checksum

    dec = FrameDecoder()
    got = list(dec.feed(stream))
    ok = (len(got) == 2)
    for g, exp in zip(got, frames):
        if g != exp:
            ok = False
            print("  MISMATCH", g, "vs", exp)
    for g in got:
        print("  frame:", g)

    # status frame decoded correctly?
    if len(dec.status) != 1:
        ok = False
        print(f"  STATUS: expected 1 frame, got {len(dec.status)}")
    else:
        s = dec.status[0]
        got_tuple = tuple(s[k] for k in STATUS_FIELDS)
        if s["seq"] != 3 or got_tuple != exp_status:
            ok = False
            print(f"  STATUS MISMATCH: {s}")
        print("  status:", s)

    print("SELFTEST:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def cmd_run(args):
    try:
        import serial  # pyserial
    except ImportError:
        print("ERROR: pyserial not installed.  Run:  pip install pyserial")
        return 2

    ser = serial.Serial(args.port, args.baud, timeout=0.1)
    dec = FrameDecoder()
    frames = []
    stop = threading.Event()

    def reader():
        while not stop.is_set():
            data = ser.read(4096)
            if data:
                for fr in dec.feed(data):
                    frames.append(fr)
                    if not args.quiet:
                        print("  frame", fr["seq"], {k: fr[k] for k in FIELDS})

    rt = threading.Thread(target=reader, daemon=True)
    rt.start()

    with open(args.send, "rb") as f:
        payload = f.read()

    # Count the ITCH messages we are about to send, so the FPGA's msg_count can
    # be sanity-checked against it afterwards. The FPGA's counters accumulate
    # from reset, so replaying twice without pressing RESET silently doubles
    # them - and, far worse, leaves the previous run's orders resting in the
    # book, which makes every feature disagree with the golden model for
    # reasons that look like an RTL bug.
    n_sent = 0
    _i = 0
    while _i + 2 <= len(payload):
        _ln = int.from_bytes(payload[_i:_i + 2], "big")
        _i += 2 + _ln
        if _i <= len(payload):
            n_sent += 1

    t0 = time.time()
    ser.write(payload)
    ser.flush()
    print(f"sent {len(payload)} bytes ({n_sent} messages); waiting for frames...")

    # drain: wait until no new frames arrive for `settle` seconds
    settle, last_n, idle_start = args.settle, -1, time.time()
    while time.time() - idle_start < settle:
        if len(frames) != last_n:
            last_n = len(frames)
            idle_start = time.time()
        time.sleep(0.05)
    stop.set()
    rt.join(timeout=1)
    ser.close()

    dt = time.time() - t0
    print(f"received {len(frames)} frames in {dt:.2f}s  "
          f"(decoder rejected {dec.bad} bad-sync bytes)")

    # FPGA-reported counters (status_reporter fires once the RX line goes quiet)
    if dec.status:
        s = dec.status[-1]
        print(f"FPGA counters [status seq={s['seq']}]: "
              f"msg={s['msg']} unknown={s['unknown']} filtered={s['filtered']} "
              f"miss={s['miss']} oow={s['oow']} drop={s['drop']} "
              f"parse_err={s['parse_err']}")
        if s['drop']:
            print(f"  NOTE: {s['drop']} feature vectors dropped (link "
                  f"bandwidth) - expect fewer frames than the golden model")
        if s['parse_err']:
            print(f"  WARNING: {s['parse_err']} parse errors - upstream framing "
                  f"may be misaligned")

        # The single most common bring-up mistake: replaying without pressing
        # RESET first. Counters accumulate from reset, so msg_count comes back
        # as a multiple of what was sent - and the order book still holds the
        # previous run's liquidity, so the features diverge from golden in a way
        # that looks exactly like an RTL bug. Catch it here instead.
        if s['msg'] > n_sent:
            mult = s['msg'] / n_sent if n_sent else 0
            print()
            print(f"  *** STALE STATE: FPGA reports msg={s['msg']} but only "
                  f"{n_sent} messages were sent ({mult:.1f}x) ***")
            print( "  The device was not reset before this run. Its counters AND")
            print( "  its order book still hold the previous replay, so any")
            print( "  golden-model comparison below is meaningless.")
            print( "  Press the RESET button (F15) and run this again.")
            print()

        # ---- latency probe (present once the bitstream carries latency_probe) ----
        if "lat_count" in s and s["lat_count"]:
            n = s["lat_count"]
            mean = s["lat_sum"] / n
            def ns(c):
                return "n/a" if c == NO_SAMPLE else f"{c} cyc ({c*10.0:.0f} ns)"
            print(f"MEASURED LATENCY on silicon  [{n} events]")
            print(f"  core, event -> feature : min {ns(s['lat_min'])}"
                  f" | mean {mean:.1f} cyc ({mean*10.0:.0f} ns)"
                  f" | max {ns(s['lat_max'])}")
            print(f"  stage breakdown        : resolve={s['lat_resolve']}"
                  f"  book2tob={s['lat_book2tob']}  tob2feat={s['lat_tob2feat']}")
            # These two stages are fixed-latency chains with no data dependence,
            # so anything else is a bug rather than a measurement.
            if s['lat_book2tob'] != 5 or s['lat_tob2feat'] != 1:
                print("  *** WARNING: expected book2tob=5, tob2feat=1 -"
                      " a different value is a BUG, not a result ***")
            # Interarrival under UART is the transport cost, measured on the same
            # clock and the same run as the core number above.
            ia = s['lat_ia_min']
            if ia != NO_SAMPLE and ia:
                print(f"  transport (interarrival): min {ia} cyc"
                      f" ({ia*10.0/1000.0:.1f} us) -> UART is ~{ia/mean:.0f}x"
                      f" slower than the core")
            if s['lat_unmatched']:
                print(f"  events with no feature  : {s['lat_unmatched']}"
                      f"  (should equal oow + miss = {s['oow'] + s['miss']})")
    else:
        print("FPGA counters: none received "
              "(needs a bitstream with status_reporter)")

    if args.recv_csv:
        with open(args.recv_csv, "w") as f:
            f.write("frame,seq," + ",".join(FIELDS) + "\n")
            for i, fr in enumerate(frames):
                f.write(f"{i},{fr['seq']}," +
                        ",".join(str(fr[k]) for k in FIELDS) + "\n")
        print("wrote", args.recv_csv)

    if args.golden:
        _compare_golden(frames, args.golden)
    return 0


def _compare_golden(frames, golden_path):
    """Diff hardware frames against itch_tools.py golden CSV (feature columns)."""
    gold = []
    with open(golden_path) as f:
        header = f.readline().strip().split(",")
        idx = {name: header.index(name) for name in FIELDS}
        for line in f:
            c = line.strip().split(",")
            gold.append({k: int(c[idx[k]]) for k in FIELDS})

    n = min(len(frames), len(gold))
    mismatches = 0
    for i in range(n):
        for k in FIELDS:
            if frames[i][k] != gold[i][k]:
                mismatches += 1
                if mismatches <= 20:
                    print(f"  DIFF frame {i} {k}: hw={frames[i][k]} "
                          f"golden={gold[i][k]}")
    print(f"golden compare: {n} frames checked, {mismatches} field mismatches"
          + ("" if len(frames) == len(gold)
             else f"  (count differs: hw={len(frames)} golden={len(gold)})"))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--selftest", action="store_true",
                   help="validate the frame decoder offline (no hardware)")
    p.add_argument("--port", help="serial port, e.g. COM5 or /dev/ttyUSB0")
    p.add_argument("--baud", type=int, default=1000000)   # matches top_board
    p.add_argument("--send", help="framed ITCH byte file to stream in")
    p.add_argument("--recv-csv", help="write received frames to this CSV")
    p.add_argument("--golden", help="compare received frames to this golden CSV")
    p.add_argument("--settle", type=float, default=2.0,
                   help="seconds of no-new-frames before finishing")
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args()

    if args.selftest:
        sys.exit(cmd_selftest(args))
    if not (args.port and args.send):
        p.error("--port and --send are required (or use --selftest)")
    sys.exit(cmd_run(args))


if __name__ == "__main__":
    main()
