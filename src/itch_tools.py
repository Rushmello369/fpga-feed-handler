#!/usr/bin/env python3
"""
itch_tools.py  --  host-side preprocessing / calibration / golden model for the
                   ITCH50_parser FPGA pipeline (top_v2).

A NASDAQ TotalView-ITCH 5.0 historical file is a flat concatenation of
    [2-byte big-endian length N][N-byte message body]  ...repeat...
The first body byte is the message type; every message carries a 2-byte
stock_locate at offset 1 (daily per-symbol index, from the 'R' Stock Directory).

Subcommands
-----------
  calibrate <file> --ticker AAPL
        Find the ticker's stock_locate for that day, scan its price range, and
        print the RTL parameters to synthesize with:  FILTER_LOCATE, BASE_PRICE,
        WINDOW_SIZE (plus a message-type histogram and out-of-window estimate).

  filter <file> --locate N --out stream.bin [--max-messages M]
        Write only messages for stock_locate N, framing preserved. This is the
        byte stream you feed into the FPGA's 8-bit AXI-Stream input.

  golden <file> --locate N --base BASE --window WIN [--out frames.csv] [--limit K]
        Software reference model of book_update + order_lookup + tob_tracker +
        feature_engine. Emits one row per feature frame the hardware should
        produce (bit-exact fixed-point). Diff this against the 15-byte frames
        board_link_tx sends back.

  selftest
        Runs the tb_top_v2 smoke scenario through the golden model and asserts
        it reproduces the RTL's known-good feature frames.

Only the Python standard library is used.
"""

import argparse
import mmap
import struct
import sys
from collections import Counter

# ---- protocol constants (ITCH 5.0 spec section 3 + ITCH50_pkg.sv) -----------
PRICE_SCALE = 10000          # Price(4): dollars * 10000
TICK_SIZE   = 100            # one penny tick = 100 Price(4) units

MT_ADD, MT_ADD_MPID = ord('A'), ord('F')
MT_EXEC, MT_EXEC_PR = ord('E'), ord('C')
MT_CANCEL, MT_DELETE = ord('X'), ord('D')
MT_REPLACE = ord('U')
MT_EVENT, MT_STOCK_DIR = ord('S'), ord('R')

BOOK_TYPES = {MT_ADD, MT_ADD_MPID, MT_EXEC, MT_EXEC_PR,
              MT_CANCEL, MT_DELETE, MT_REPLACE}

# per-type body length (spec section 4); used only for reporting/sanity
MSG_LEN = {MT_ADD: 36, MT_ADD_MPID: 40, MT_EXEC: 31, MT_EXEC_PR: 36,
           MT_CANCEL: 23, MT_DELETE: 19, MT_REPLACE: 35,
           MT_EVENT: 12, MT_STOCK_DIR: 39}

SIDE_BUY, SIDE_SELL = 0, 1   # internal (matches RTL: 0=buy,1=sell)


# ---- low-level framed-file iterator (mmap: fast + large-file safe) ----------
def iter_messages(path, limit=None):
    """Yield each message body (bytes, without the 2-byte length prefix)."""
    with open(path, 'rb') as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        off, end, count = 0, len(mm), 0
        while off + 2 <= end:
            n = (mm[off] << 8) | mm[off + 1]
            off += 2
            if n == 0 or off + n > end:
                break
            yield mm[off:off + n]
            off += n
            count += 1
            if limit is not None and count >= limit:
                break
        mm.close()


def be(body, o, n):
    """Unsigned big-endian integer from body[o:o+n]."""
    return int.from_bytes(body[o:o + n], 'big')


# ---- per-type field extraction (offsets straight from the spec / RTL) -------
def locate_of(body):
    return be(body, 1, 2)


def parse_event(body):
    """Return a normalized dict for a book-affecting message, else None.

    Keys: type, oid, side (A/F only), price (A/F/U/C), shares, new_oid (U).
    """
    mt = body[0]
    if mt in (MT_ADD, MT_ADD_MPID):
        return dict(type=mt, oid=be(body, 11, 8),
                    side=(SIDE_SELL if body[19] == ord('S') else SIDE_BUY),
                    shares=be(body, 20, 4), price=be(body, 32, 4))
    if mt in (MT_EXEC, MT_EXEC_PR):          # E/C: order_id + executed shares
        return dict(type=mt, oid=be(body, 11, 8), shares=be(body, 19, 4))
    if mt == MT_CANCEL:                       # X: order_id + cancelled shares
        return dict(type=mt, oid=be(body, 11, 8), shares=be(body, 19, 4))
    if mt == MT_DELETE:                       # D: order_id only
        return dict(type=mt, oid=be(body, 11, 8))
    if mt == MT_REPLACE:                       # U: old id, new id, new qty, new px
        return dict(type=mt, oid=be(body, 11, 8), new_oid=be(body, 19, 8),
                    shares=be(body, 27, 4), price=be(body, 31, 4))
    return None


# =============================================================================
#  calibrate
# =============================================================================
def cmd_calibrate(args):
    target = args.ticker.upper().encode('ascii')
    locate = args.locate
    # 1) resolve ticker -> stock_locate via Stock Directory ('R')
    if locate is None:
        for body in iter_messages(args.file):
            if body[0] == MT_STOCK_DIR:
                sym = body[11:19].rstrip(b' ')
                if sym == target:
                    locate = locate_of(body)
                    break
        if locate is None:
            print(f"ERROR: ticker {args.ticker} not found in any 'R' message.")
            print("       (check spelling; locate codes are per-day)")
            return 1
    print(f"stock_locate({args.ticker}) = {locate}")

    # 2) scan that symbol's Add prices for the day's range
    lo, hi, adds, book_msgs, total = None, None, 0, 0, 0
    hist = Counter()
    for body in iter_messages(args.file):
        total += 1
        if locate_of(body) != locate:
            continue
        mt = body[0]
        hist[chr(mt)] += 1
        if mt in BOOK_TYPES:
            book_msgs += 1
        if mt in (MT_ADD, MT_ADD_MPID):
            px = be(body, 32, 4)
            adds += 1
            lo = px if lo is None else min(lo, px)
            hi = px if hi is None else max(hi, px)

    if adds == 0:
        print("ERROR: no Add messages for this locate; cannot calibrate price.")
        return 1

    print(f"messages for this locate: {sum(hist.values())} "
          f"(book-affecting: {book_msgs})")
    print("  type histogram:", dict(sorted(hist.items())))
    print(f"price range: ${lo/PRICE_SCALE:.4f} .. ${hi/PRICE_SCALE:.4f} "
          f"(raw {lo}..{hi})")

    # 3) recommend BASE_PRICE / WINDOW_SIZE with ~5% headroom each side
    span_ticks = (hi - lo) // TICK_SIZE + 1
    margin = max(span_ticks // 20, 16)          # ~5%, at least 16 ticks
    base = (lo // TICK_SIZE - margin) * TICK_SIZE
    if base < 0:
        base = 0
    need = (hi - base) // TICK_SIZE + 1 + margin
    win = 1024
    while win < need:
        win *= 2                                 # power-of-two (radix encoder)
    coverage_lo = base / PRICE_SCALE
    coverage_hi = (base + win * TICK_SIZE) / PRICE_SCALE

    print()
    print("=== synthesize top_v2 with these parameters ===")
    print(f"  .FILTER_EN     (1'b1)")
    print(f"  .FILTER_LOCATE (16'd{locate})")
    print(f"  .BASE_PRICE    ({base})")
    print(f"  .WINDOW_SIZE   ({win})      // covers ${coverage_lo:.2f}..${coverage_hi:.2f}")
    print(f"  // price span this day = {span_ticks} ticks; window = {win} ticks")
    if win > 8192:
        print("  NOTE: window is large; consider a tighter time slice or "
              "splitting the day.")
    return 0


# =============================================================================
#  filter
# =============================================================================
def cmd_filter(args):
    kept, total = 0, 0
    with open(args.out, 'wb') as out:
        for body in iter_messages(args.file):
            total += 1
            if locate_of(body) == args.locate:
                out.write(struct.pack('>H', len(body)))
                out.write(body)
                kept += 1
                if args.max_messages and kept >= args.max_messages:
                    break
    print(f"wrote {kept} messages ({args.out}) out of {total} scanned")
    return 0


# =============================================================================
#  golden model  (book_update + order_lookup + tob_tracker + feature_engine)
# =============================================================================
def sat16(x):
    if x > 32767:
        return 32767
    if x < -32768:
        return -32768
    return x


class Golden:
    """Bit-exact software mirror of the v2 feature pipeline for one instrument."""

    def __init__(self, base, window, qty_shift=0, mom_depth=8, tflow_depth=16):
        self.BASE, self.WIN, self.QS = base, window, qty_shift
        self.MOM_DEPTH, self.TFLOW_DEPTH = mom_depth, tflow_depth
        # book: level -> qty, per side
        self.bid, self.ask = {}, {}
        # order table: oid -> [price, side, qty]
        self.table = {}
        # feature_engine persistent state
        self.prev_bid_q = 0
        self.prev_ask_q = 0
        self.ema_frac = 0
        self.ema_init = False
        self.mid_hist = [0] * mom_depth
        self.tflow_acc = 0
        self.tflow_ring = [0] * tflow_depth
        self.tflow_wr = 0
        # diagnostics
        self.oow = 0
        self.miss = 0
        self.frames = []            # list of dicts, one per emitted frame

    # -- book helpers ------------------------------------------------------
    def _level(self, price):
        return (price - self.BASE) // TICK_SIZE

    def _book(self, side):
        return self.bid if side == SIDE_BUY else self.ask

    def _commit(self, side, price, signed_delta):
        """Apply a qty delta at a price level; emit a snapshot (book_updated)."""
        lvl = self._level(price)
        if not (0 <= lvl < self.WIN):
            self.oow += 1
            return
        b = self._book(side)
        new = max(0, b.get(lvl, 0) + signed_delta)
        if new == 0:
            b.pop(lvl, None)
        else:
            b[lvl] = new
        self._snapshot()

    def _snapshot(self):
        """Mirror tob_tracker + feature_engine: publish a frame iff 2-sided."""
        if not self.bid or not self.ask:
            return
        bi = max(self.bid)                     # best bid = highest occupied level
        ai = min(self.ask)                     # best ask = lowest occupied level
        bq, aq = self.bid[bi], self.ask[ai]

        bidq_s = bq >> self.QS
        askq_s = aq >> self.QS
        mid = bi + ai                          # half-tick mid (no >>1), per RTL

        spr = sat16(ai - bi)
        tobi = sat16(bidq_s - askq_s)
        ofi = sat16((bidq_s - self.prev_bid_q) - (askq_s - self.prev_ask_q))
        self.prev_bid_q, self.prev_ask_q = bidq_s, askq_s

        if not self.ema_init:
            self.ema_frac = mid << 4
            self.ema_init = True
            emadev = 0
        else:
            ema_int = self.ema_frac >> 4
            emadev = sat16(mid - ema_int)
            self.ema_frac = self.ema_frac + (((mid << 4) - self.ema_frac) >> 4)

        mom = sat16(mid - self.mid_hist[self.MOM_DEPTH - 1])
        self.mid_hist = [mid] + self.mid_hist[:self.MOM_DEPTH - 1]

        tflow = sat16(self.tflow_acc >> self.QS)

        self.frames.append(dict(bid_idx=bi, bid_qty=bq, ask_idx=ai, ask_qty=aq,
                                spr=spr, tobi=tobi, ofi=ofi, emadev=emadev,
                                mom=mom, tflow=tflow))

    def _trade(self, resting_side, qty):
        """Rolling signed 16-trade flow (E/C only). +buy-aggressor."""
        contrib = qty if resting_side == SIDE_SELL else -qty
        self.tflow_acc += contrib - self.tflow_ring[self.tflow_wr]
        self.tflow_ring[self.tflow_wr] = contrib
        self.tflow_wr = (self.tflow_wr + 1) % self.TFLOW_DEPTH

    # -- event application (mirrors event_dispatcher) ----------------------
    def apply(self, ev):
        mt = ev['type']
        if mt in (MT_ADD, MT_ADD_MPID):
            self.table[ev['oid']] = [ev['price'], ev['side'], ev['shares']]
            self._commit(ev['side'], ev['price'], +ev['shares'])

        elif mt in (MT_EXEC, MT_EXEC_PR, MT_CANCEL):
            e = self.table.get(ev['oid'])
            if e is None:
                self.miss += 1
                return
            price, side, qty = e
            delta = ev['shares']               # res_delta_qty = message shares
            if mt in (MT_EXEC, MT_EXEC_PR):     # trade tap: executions only
                self._trade(side, delta)
            e[2] = max(0, qty - delta)
            if e[2] == 0:
                del self.table[ev['oid']]
            self._commit(side, price, -delta)

        elif mt == MT_DELETE:
            e = self.table.get(ev['oid'])
            if e is None:
                self.miss += 1
                return
            price, side, qty = e
            del self.table[ev['oid']]
            self._commit(side, price, -qty)     # remove all remaining

        elif mt == MT_REPLACE:
            e = self.table.get(ev['oid'])       # step 1: delete OLD id
            if e is None:
                self.miss += 1
                return
            price, side, qty = e
            del self.table[ev['oid']]
            self._commit(side, price, -qty)     # remove all remaining (frame A)
            # step 2: insert NEW id at new price/qty, side inherited
            self.table[ev['new_oid']] = [ev['price'], side, ev['shares']]
            self._commit(side, ev['price'], +ev['shares'])   # add (frame B)


def cmd_golden(args):
    g = Golden(args.base, args.window, qty_shift=args.qty_shift)
    n = 0
    for body in iter_messages(args.file, limit=args.limit):
        if args.locate is not None and locate_of(body) != args.locate:
            continue
        if body[0] not in BOOK_TYPES:
            continue
        ev = parse_event(body)
        if ev:
            g.apply(ev)
            n += 1

    print(f"processed {n} book-affecting messages -> {len(g.frames)} frames")
    print(f"  out-of-window drops: {g.oow}   lookup misses: {g.miss}")
    if g.oow > n // 20 and n > 0:
        print("  WARNING: high OOW rate -> BASE_PRICE/WINDOW_SIZE likely "
              "mis-calibrated.")

    if args.out:
        with open(args.out, 'w') as f:
            f.write("frame,bid_idx,bid_qty,ask_idx,ask_qty,"
                    "spr,tobi,ofi,emadev,mom,tflow\n")
            for i, fr in enumerate(g.frames):
                f.write(f"{i},{fr['bid_idx']},{fr['bid_qty']},{fr['ask_idx']},"
                        f"{fr['ask_qty']},{fr['spr']},{fr['tobi']},{fr['ofi']},"
                        f"{fr['emadev']},{fr['mom']},{fr['tflow']}\n")
        print(f"  wrote golden frames -> {args.out}")
    else:
        for i, fr in enumerate(g.frames[:10]):
            print(f"  frame {i}: spr={fr['spr']} tobi={fr['tobi']} "
                  f"ofi={fr['ofi']} emadev={fr['emadev']} mom={fr['mom']} "
                  f"tflow={fr['tflow']}")
    return 0


# =============================================================================
#  selftest  (reproduce the tb_top_v2 smoke scenario)
# =============================================================================
def _build_add(oid, side_char, shares, price, locate=1):
    b = bytearray(36)
    b[0] = MT_ADD
    b[1:3] = struct.pack('>H', locate)
    b[11:19] = struct.pack('>Q', oid)
    b[19] = ord(side_char)
    b[20:24] = struct.pack('>I', shares)
    b[24:32] = b'        '
    b[32:36] = struct.pack('>I', price)
    return bytes(b)


def _build_exec(oid, shares, locate=1):
    b = bytearray(31)
    b[0] = MT_EXEC
    b[1:3] = struct.pack('>H', locate)
    b[11:19] = struct.pack('>Q', oid)
    b[19:23] = struct.pack('>I', shares)
    return bytes(b)


def cmd_selftest(args):
    # tb_top_v2 smoke: BASE=1,550,000  WINDOW=2048  ($160.00 -> level 500)
    g = Golden(1_550_000, 2048)
    for body in (_build_add(100, 'B', 300, 1_600_000),   # bid @500  (1-sided)
                 _build_add(200, 'S', 200, 1_600_200),   # ask @502  -> frame 1
                 _build_exec(100, 50)):                   # exec buy  -> frame 2
        g.apply(parse_event(body))

    expect = [
        dict(spr=2, tobi=100, ofi=100, emadev=0, mom=1002, tflow=0),
        dict(spr=2, tobi=50,  ofi=-50, emadev=0, mom=1002, tflow=-50),
    ]
    ok = (len(g.frames) == 2)
    for got, exp in zip(g.frames, expect):
        for k, v in exp.items():
            if got[k] != v:
                ok = False
                print(f"  MISMATCH frame field {k}: got {got[k]} exp {v}")
    for i, fr in enumerate(g.frames):
        print(f"  frame {i}: spr={fr['spr']} tobi={fr['tobi']} ofi={fr['ofi']} "
              f"emadev={fr['emadev']} mom={fr['mom']} tflow={fr['tflow']}")
    print("SELFTEST:", "PASS" if ok else "FAIL",
          "(golden model matches RTL smoke frames)")
    return 0 if ok else 1


# =============================================================================
def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)

    c = sub.add_parser('calibrate', help='resolve locate + recommend BASE/WINDOW')
    c.add_argument('file')
    c.add_argument('--ticker', required=True)
    c.add_argument('--locate', type=int, default=None,
                   help='skip ticker lookup, use this locate directly')
    c.set_defaults(func=cmd_calibrate)

    c = sub.add_parser('filter', help='write single-locate framed byte stream')
    c.add_argument('file')
    c.add_argument('--locate', type=int, required=True)
    c.add_argument('--out', required=True)
    c.add_argument('--max-messages', type=int, default=0)
    c.set_defaults(func=cmd_filter)

    c = sub.add_parser('golden', help='software reference feature frames')
    c.add_argument('file')
    c.add_argument('--locate', type=int, default=None)
    c.add_argument('--base', type=int, required=True)
    c.add_argument('--window', type=int, required=True)
    c.add_argument('--qty-shift', type=int, default=0)
    c.add_argument('--out', default=None, help='CSV output path')
    c.add_argument('--limit', type=int, default=None,
                   help='stop after N raw messages')
    c.set_defaults(func=cmd_golden)

    c = sub.add_parser('selftest', help='validate golden model vs RTL smoke')
    c.set_defaults(func=cmd_selftest)

    args = p.parse_args()
    sys.exit(args.func(args))


if __name__ == '__main__':
    main()
