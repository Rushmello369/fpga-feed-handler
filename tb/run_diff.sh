#!/usr/bin/env bash
# run_diff.sh — end-to-end differential test: RTL simulation vs Python golden.
#
#   bash tb/run_diff.sh [capture.bin]      default aapl_small.bin
#
# Streams a real ITCH capture through top_v2 in simulation, regenerates the
# golden model AT THE SAME PARAMETERS, and diffs the six feature columns.
#
# Why the parameters are duplicated here rather than read from somewhere:
# they must match what is bound in the bitstream (see docs/parameters.md), and
# the golden model's own help warns that a mismatched --table-bits makes
# order-table evictions differ. A golden CSV generated at different parameters
# is not evidence, it is a rumour — this script exists so the two sides can
# never drift apart.
#
# Exit code 0 only if every frame matches.

set -u
cd "$(dirname "$0")/.."          # hardware/ax7a200b

# ---- calibration: MUST match the synthesized bitstream ----
BASE_PRICE=1610800
WINDOW_SIZE=1024
LOCATE=14
QTY_SHIFT=0
TABLE_BITS=14

CAPTURE="${1:-aapl_small.bin}"
TAG="$(basename "$CAPTURE" .bin)"
SIM_CSV="sim_frames_${TAG}.csv"
GOLD_CSV="golden_${TAG}_fresh.csv"

if [ ! -f "$CAPTURE" ]; then
    echo "ERROR: capture '$CAPTURE' not found" >&2; exit 1
fi

PY=py; command -v py >/dev/null 2>&1 || PY=python

echo "=== differential test: $CAPTURE ==="
echo "    BASE_PRICE=$BASE_PRICE WINDOW=$WINDOW_SIZE LOCATE=$LOCATE QTY_SHIFT=$QTY_SHIFT TABLE_BITS=$TABLE_BITS"

# ---- 1. stage the capture under the fixed name the testbench reads ----
cp -f "$CAPTURE" diff_input.bin

# ---- 2. RTL simulation ----
P=rtl/ITCH50_parser; E=$P/priority_encoder_v2
echo "--- RTL simulation ---"
bash tb/run_tb.sh tb_diff_top_v2 \
    "$P/ITCH50_pkg.sv" "$E/onehot2bin.sv" "$E/onehot2bin_gen.sv" "$E/find_lowest.sv" \
    "$E/radix_find_lowest.sv" "$E/priority_encoder.sv" \
    "$P/Itch_parser.sv" "$P/Event_dispatcher.sv" "$P/order_lookup.sv" \
    "$P/book_update.sv" "$P/tob_tracker.sv" "$P/feature_engine.sv" \
    "$P/board_link-tx.sv" "$P/latency_probe.sv" "$P/top_v2.sv" \
    tb/tb_diff_top_v2.sv \
  | sed -n '/=== tb_diff_top_v2/,/=== done/p'

if [ ! -f sim_frames.csv ]; then
    echo "ERROR: simulation produced no output" >&2; exit 1
fi
mv -f sim_frames.csv "$SIM_CSV"

# ---- 3. golden model, same parameters ----
echo "--- golden model ---"
$PY src/itch_tools.py golden "$CAPTURE" --locate "$LOCATE" --base "$BASE_PRICE" \
    --window "$WINDOW_SIZE" --qty-shift "$QTY_SHIFT" --table-bits "$TABLE_BITS" \
    --out "$GOLD_CSV" | sed 's/^/    /'

# ---- 4. compare the six feature columns ----
echo "--- comparison ---"
$PY - "$SIM_CSV" "$GOLD_CSV" <<'EOF'
import csv, sys
F = ['spr','tobi','ofi','emadev','mom','tflow']
def load(p):
    with open(p, newline='') as f:
        return [tuple(int(r[k]) for k in F) for r in csv.DictReader(f)]
s, g = load(sys.argv[1]), load(sys.argv[2])
n = min(len(s), len(g))
mism = [i for i in range(n) if s[i] != g[i]]
print("    RTL frames    : %d" % len(s))
print("    golden frames : %d" % len(g))
print("    compared      : %d frames / %d feature values" % (n, n*6))
print("    MISMATCHES    : %d" % len(mism))
if len(s) != len(g):
    print("    FAIL: frame-count mismatch (%d vs %d)" % (len(s), len(g)))
    sys.exit(1)
if mism:
    for i in mism[:5]:
        print("      frame %d  rtl=%s  golden=%s" % (i, list(s[i]), list(g[i])))
    sys.exit(1)
print()
print("    PASS: RTL and the independent golden model agree bit-exactly")
EOF
rc=$?

rm -f diff_input.bin
if [ $rc -ne 0 ]; then echo "=== DIFFERENTIAL TEST FAILED ==="; exit 1; fi
echo "=== DIFFERENTIAL TEST PASSED ==="
exit 0
