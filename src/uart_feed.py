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

# diagnostic status frame (status_reporter.sv): distinct sync, 31 bytes,
# emitted once the FPGA sees the RX line go quiet at the end of a burst
STATUS_SYNC = 0x5A
STATUS_LEN = 31
STATUS_FIELDS = ["msg", "unknown", "filtered", "miss", "oow", "drop", "parse_err"]


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
                vals = struct.unpack(">7I", frame[2:30])
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
    body = bytes([STATUS_SYNC, seq & 0xFF]) + struct.pack(">7I", *counters)
    return body + bytes([_xor(body)])


def cmd_selftest(_args):
    frames = [
        dict(seq=0, spr=2, tobi=100, ofi=100, emadev=0, mom=1002, tflow=0),
        dict(seq=1, spr=2, tobi=50,  ofi=-50, emadev=0, mom=1002, tflow=-50),
    ]
    exp_status = (0x1234, 7, 0xABCDEF, 8, 0xE5, 0, 0x5678)

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
