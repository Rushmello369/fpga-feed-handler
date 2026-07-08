import struct
from enum import IntEnum
from dataclasses import dataclass
from typing import List

# constants
MSG_LEN     = 24
PRICE_SCALE = 100
FORMAT      = ">BBHIIIII"

class MsgType(IntEnum):
    ADD     = 0x01
    CANCEL  = 0x02
    EXECUTE = 0x03

class Side(IntEnum):
    BID = 0x00
    ASK = 0x01

@dataclass
class Message:
    msg_type:  MsgType
    side:      Side
    symbol_id: int
    order_id:  int
    price:     int
    qty:       int
    exec_qty:  int
    seq:       int

    @classmethod
    def add(cls, *, symbol_id: int, order_id: int,
            side: Side, price_cents: int,
            qty: int, seq: int) -> "Message":
        return cls(
            msg_type  = MsgType.ADD,
            side      = side,
            symbol_id = symbol_id,
            order_id  = order_id,
            price     = price_cents,
            qty       = qty,
            exec_qty  = 0,
            seq       = seq,
        )

    def encode(self) -> bytes:
        raw = struct.pack(
            FORMAT,
            int(self.msg_type),
            int(self.side),
            self.symbol_id,
            self.order_id,
            self.price,
            self.qty,
            self.exec_qty,
            self.seq,
        )
        assert len(raw) == MSG_LEN
        return raw

    @classmethod
    def decode(cls, raw: bytes) -> "Message":
        if len(raw) != MSG_LEN:
            raise ValueError(f"Expected {MSG_LEN} bytes, got {len(raw)}")
        fields = struct.unpack(FORMAT, raw)
        msg_type_val, side_val, symbol_id, \
            order_id, price, qty, exec_qty, seq = fields
        try:
            msg_type = MsgType(msg_type_val)
        except ValueError:
            raise ValueError(f"Unknown msg_type: 0x{msg_type_val:02X}")
        return cls(
            msg_type  = msg_type,
            side      = Side(side_val),
            symbol_id = symbol_id,
            order_id  = order_id,
            price     = price,
            qty       = qty,
            exec_qty  = exec_qty,
            seq       = seq,
        )

    @property
    def price_float(self) -> float:
        return self.price / PRICE_SCALE

    def validate(self) -> List[str]:
        errors = []
        if self.msg_type == MsgType.ADD and self.exec_qty != 0:
            errors.append("ADD must have exec_qty == 0")
        if self.seq < 1:
            errors.append(f"seq {self.seq} must be >= 1")
        return errors

    def __str__(self) -> str:
        return (
            f"[{self.msg_type.name}] seq={self.seq} "
            f"sym={self.symbol_id} px={self.price_float:.2f} "
            f"qty={self.qty}"
        )

    def hex_dump(self) -> str:
        raw = self.encode()
        return " ".join(f"{b:02X}" for b in raw)