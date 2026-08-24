#!/usr/bin/env bash
# run_tb.sh — compile + elaborate + run one ITCH50 unit testbench with xsim.
#
# Usage (from hardware/ax7a200b):
#   bash tb/run_tb.sh <tb_module_name> <rtl_and_tb_files...>
#   bash tb/run_tb.sh -g <tb_module_name> <files...>   # -g = open waveform GUI
#
# Examples:
#   bash tb/run_tb.sh tb_itch_parser \
#       rtl/ITCH50_parser/ITCH50_pkg.sv rtl/ITCH50_parser/Itch_parser.sv tb/tb_itch_parser.sv
#
# Notes:
#   * The package file (ITCH50_pkg.sv) must come FIRST in the file list.
#   * A unique snapshot name (-s) per TB avoids "cannot open ... for writing"
#     lock errors from a previously crashed/hung run.
#
# Vivado toolchain location is DETECTED, not hardcoded - install paths differ
# per machine (Xilinx vs AMDDesignTools, and per version), and a stale hardcoded
# path is a silent "command not found" for everyone but its author. To force a
# specific install, export VIVADO_BIN=/path/to/Vivado/bin before running.

find_vivado_bin() {
    # 1. already on PATH (e.g. the user sourced settings64.sh) - nothing to do
    if command -v xvlog >/dev/null 2>&1; then
        return 0
    fi

    # 2. explicit override, then the standard var settings64.sh exports
    for d in "$VIVADO_BIN" "${XILINX_VIVADO:+$XILINX_VIVADO/bin}"; do
        if [ -n "$d" ] && [ -x "$d/xvlog" ]; then
            export PATH="$PATH:$d"
            return 0
        fi
    done

    # 3. search the usual install roots; if several versions exist take the
    #    newest (sort -V orders 2020.2 < 2025.2 correctly, unlike plain sort)
    local found
    found=$(ls -d /c/AMDDesignTools/*/Vivado/bin \
                  /c/Xilinx/Vivado/*/bin \
                  /opt/Xilinx/Vivado/*/bin \
                  /tools/Xilinx/Vivado/*/bin 2>/dev/null \
            | while read -r d; do [ -x "$d/xvlog" ] && echo "$d"; done \
            | sort -V | tail -1)

    if [ -n "$found" ]; then
        export PATH="$PATH:$found"
        return 0
    fi
    return 1
}

if ! find_vivado_bin; then
    echo "ERROR: could not find the Vivado simulator (xvlog/xelab/xsim)." >&2
    echo "  Searched PATH, \$VIVADO_BIN, \$XILINX_VIVADO, and the usual" >&2
    echo "  install roots (/c/AMDDesignTools, /c/Xilinx, /opt/Xilinx, /tools/Xilinx)." >&2
    echo "  Fix: export VIVADO_BIN=/path/to/Vivado/bin   (or source settings64.sh)" >&2
    exit 1
fi

echo "--- using $(command -v xvlog) ---"

GUI=0
if [ "$1" = "-g" ]; then GUI=1; shift; fi

NAME=$1; shift
SNAP="snap_${NAME}"

rm -rf "xsim.dir/${SNAP}" 2>/dev/null

echo "--- xvlog (compile) ---"
xvlog --sv "$@" || { echo "COMPILE FAILED"; exit 1; }

echo "--- xelab (elaborate) ---"
# -timescale needed because the RTL files declare none; -debug all for waves
xelab "$NAME" -s "$SNAP" -timescale 1ns/1ps -debug all || { echo "ELAB FAILED"; exit 1; }

echo "--- xsim (run) ---"
if [ "$GUI" = "1" ]; then
    xsim "$SNAP" -gui        # opens the GUI; then: add_wave /*; run all
else
    xsim "$SNAP" -R          # run to $finish, print PASS/FAIL to console
fi
