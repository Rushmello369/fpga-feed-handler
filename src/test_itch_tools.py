"""Regression tests for ITCH timestamp propagation in the golden model."""

import csv
import struct
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from itch_tools import (
    Golden,
    MT_REPLACE,
    _build_add,
    _build_exec,
    cmd_golden,
    parse_event,
)


BASE_PRICE = 1_550_000
WINDOW_SIZE = 2048


def framed(*bodies):
    stream = bytearray()
    for body in bodies:
        stream += struct.pack(">H", len(body))
        stream += body
    return bytes(stream)


class TimestampTests(unittest.TestCase):
    def test_parse_event_reads_six_byte_timestamp(self):
        timestamp_ns = 0x010203040506
        event = parse_event(
            _build_add(
                100,
                "B",
                300,
                1_600_000,
                timestamp_ns=timestamp_ns,
            )
        )
        self.assertEqual(event["timestamp_ns"], timestamp_ns)

    def test_feature_frames_keep_triggering_event_timestamp(self):
        golden = Golden(BASE_PRICE, WINDOW_SIZE)
        bodies = (
            _build_add(100, "B", 300, 1_600_000, timestamp_ns=100),
            _build_add(200, "S", 200, 1_600_200, timestamp_ns=200),
            _build_exec(100, 50, timestamp_ns=300),
        )

        for body in bodies:
            golden.apply(parse_event(body))

        self.assertEqual(
            [frame["timestamp_ns"] for frame in golden.frames],
            [200, 300],
        )

    def test_replace_frames_share_one_timestamp(self):
        golden = Golden(BASE_PRICE, WINDOW_SIZE)
        for body in (
            _build_add(100, "B", 300, 1_600_000, timestamp_ns=100),
            _build_add(101, "B", 100, 1_599_900, timestamp_ns=110),
            _build_add(200, "S", 200, 1_600_200, timestamp_ns=120),
        ):
            golden.apply(parse_event(body))

        golden.apply(
            {
                "type": MT_REPLACE,
                "timestamp_ns": 130,
                "oid": 100,
                "new_oid": 300,
                "shares": 250,
                "price": 1_600_100,
            }
        )

        self.assertEqual(
            [frame["timestamp_ns"] for frame in golden.frames[-2:]],
            [130, 130],
        )

    def test_golden_csv_contains_timestamp_column(self):
        bodies = (
            _build_add(100, "B", 300, 1_600_000, timestamp_ns=100),
            _build_add(200, "S", 200, 1_600_200, timestamp_ns=200),
            _build_exec(100, 50, timestamp_ns=300),
        )

        with tempfile.TemporaryDirectory() as tmp:
            input_path = Path(tmp) / "sample.itch"
            output_path = Path(tmp) / "frames.csv"
            input_path.write_bytes(framed(*bodies))

            args = SimpleNamespace(
                file=str(input_path),
                locate=1,
                base=BASE_PRICE,
                window=WINDOW_SIZE,
                qty_shift=0,
                table_bits=14,
                out=str(output_path),
                limit=None,
            )
            self.assertEqual(cmd_golden(args), 0)

            with output_path.open(newline="") as file:
                rows = list(csv.DictReader(file))

        self.assertIn("timestamp_ns", rows[0])
        self.assertEqual(
            [int(row["timestamp_ns"]) for row in rows],
            [200, 300],
        )


if __name__ == "__main__":
    unittest.main()
