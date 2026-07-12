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
export PATH="$PATH:/c/Xilinx/Vivado/2020.2/bin"

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
