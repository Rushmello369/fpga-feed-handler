"""
test_feed.py -- PYNQ-Z1 board bring-up driver for the feed_handler overlay.

Usage on the board:
    cd /home/xilinx/jupyter_notebooks
    sudo -E python3 test_feed.py

MMIO register map (base = feed_handler_0), all 32-bit:
    0x00 best_bid_price   0x04 best_bid_qty
    0x08 best_ask_price   0x0C best_ask_qty
    0x10 status {bit0 bid_valid, bit1 ask_valid, bit2 latency_seen}
    0x14 latency (cycles) 0x1C ID = 0xFEED0001
"""
from pynq import Overlay, allocate
import numpy as np
import time
from fm24 import Message, Side

ol   = Overlay("feed_handler.bit")     # same-dir feed_handler.hwh auto-paired
dma  = ol.axi_dma_0
core = ol.feed_handler_0

# 1) confirm the IP is alive
idv = core.read(0x1C)
print("ID =", hex(idv), "(expected 0xfeed0001)")
assert idv == 0xFEED0001, "IP not responding -- check overlay / address"

# 2) build a few messages. BASE_PRICE=14500, window [14500, 15524)
msgs = [
    Message.add(symbol_id=1, order_id=1, side=Side.BID, price_cents=14550, qty=100, seq=1),
    Message.add(symbol_id=1, order_id=2, side=Side.BID, price_cents=14560, qty=200, seq=2),  # higher bid
    Message.add(symbol_id=1, order_id=3, side=Side.ASK, price_cents=14600, qty=300, seq=3),
    Message.add(symbol_id=1, order_id=4, side=Side.ASK, price_cents=14590, qty=150, seq=4),  # lower ask
]
stream = b"".join(m.encode() for m in msgs)

# 3) send via DMA (8-bit stream)
buf = allocate(shape=(len(stream),), dtype=np.uint8)
buf[:] = np.frombuffer(stream, dtype=np.uint8)
dma.sendchannel.transfer(buf)
dma.sendchannel.wait()

# 4) read top-of-book + latency
time.sleep(0.01)
status = core.read(0x10)
print("best_bid_price =", core.read(0x00), " qty =", core.read(0x04),
      " bid_valid =", status & 1)
print("best_ask_price =", core.read(0x08), " qty =", core.read(0x0C),
      " ask_valid =", (status >> 1) & 1)
print("latency(cycles) =", core.read(0x14), " latency_seen =", (status >> 2) & 1)

buf.freebuffer()
