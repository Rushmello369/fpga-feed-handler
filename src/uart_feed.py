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


class FrameDecoder:
    """Resynchronizing 15-byte frame decoder with XOR checksum validation."""

    def __init__(self):
        self.buf = bytearray()
        self.bad = 0

    def feed(self, data):
        """Append bytes; yield dict per valid frame."""
        self.buf.extend(data)
        while True:
            # drop bytes until a sync marker is at the head
            i = self.buf.find(SYNC)
            if i < 0:
                self.buf.clear()
                return
            if i > 0:
                del self.buf[:i]
            if len(self.buf) < FRAME_LEN:
                return
            frame = bytes(self.buf[:FRAME_LEN])
            chk = 0
            for b in frame[:14]:
                chk ^= b
            if chk != frame[14]:
                # bad checksum: not a real frame boundary, skip this sync byte
                self.bad += 1
                del self.buf[0]
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


def cmd_selftest(_args):
    frames = [
        dict(seq=0, spr=2, tobi=100, ofi=100, emadev=0, mom=1002, tflow=0),
        dict(seq=1, spr=2, tobi=50,  ofi=-50, emadev=0, mom=1002, tflow=-50),
    ]
    stream = b"\x00\xffnoise"        # junk before sync to test resync
    for f in frames:
        stream += _make_frame(f["seq"], f["spr"], f["tobi"], f["ofi"],
                              f["emadev"], f["mom"], f["tflow"])
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
    t0 = time.time()
    ser.write(payload)
    ser.flush()
    print(f"sent {len(payload)} bytes; waiting for frames...")

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
