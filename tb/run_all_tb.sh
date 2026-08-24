#!/usr/bin/env bash
# run_all_tb.sh — run every unit testbench and print a one-line summary each.
#
# Usage (from hardware/ax7a200b):
#   bash tb/run_all_tb.sh
#
# Exit code is 0 only if every testbench reported FAILED: 0. Intended to be the
# single command a reviewer runs, and the basis for the CI job.
#
# Vivado is located by tb/run_tb.sh (detected, not hardcoded — see that file).

set -u
cd "$(dirname "$0")/.."          # hardware/ax7a200b

P="rtl/ITCH50_parser"
IO="$P/io"
PKG="$P/ITCH50_pkg.sv"
ENC_LEAF="$P/priority_encoder_v2/onehot2bin.sv \
          $P/priority_encoder_v2/onehot2bin_gen.sv \
          $P/priority_encoder_v2/find_lowest.sv \
          $P/priority_encoder_v2/radix_find_lowest.sv"
ENC="$ENC_LEAF $P/priority_encoder_v2/priority_encoder.sv"

total_pass=0
total_fail=0
n_tb=0
failed_list=""

run() {
    local name=$1; shift
    local out pass fail
    out=$(bash tb/run_tb.sh "$name" "$@" 2>&1)
    pass=$(echo "$out" | grep -oE "PASSED: +[0-9]+" | tail -1 | grep -oE "[0-9]+")
    fail=$(echo "$out" | grep -oE "FAILED: +[0-9]+" | tail -1 | grep -oE "[0-9]+")

    n_tb=$((n_tb + 1))
    if [ -z "$pass" ]; then
        printf "  %-32s  \033[31mNO SUMMARY (compile/elab error)\033[0m\n" "$name"
        failed_list="$failed_list $name"
        total_fail=$((total_fail + 1))
        return
    fi
    total_pass=$((total_pass + pass))
    total_fail=$((total_fail + fail))
    if [ "$fail" = "0" ]; then
        printf "  %-32s  \033[32mok\033[0m    %3d assertions\n" "$name" "$pass"
    else
        printf "  %-32s  \033[31mFAIL\033[0m  %3d passed, %d FAILED\n" "$name" "$pass" "$fail"
        failed_list="$failed_list $name"
    fi
}

echo "=== ITCH50 pipeline unit testbenches ==========================="

# ---- core datapath ----
run tb_itch_parser            "$PKG" "$P/Itch_parser.sv"      tb/tb_itch_parser.sv
run tb_event_dispatcher       "$PKG" "$P/Event_dispatcher.sv" tb/tb_event_dispatcher.sv
run tb_order_lookup           "$PKG" "$P/order_lookup.sv"     tb/tb_order_lookup.sv
run tb_book_update            "$PKG" "$P/book_update.sv"      tb/tb_book_update.sv
run tb_radix_find_lowest      $ENC_LEAF                       tb/tb_radix_find_lowest.sv
run tb_tob_tracker            "$PKG" "$P/tob_tracker.sv"      tb/tb_tob_tracker.sv
run tb_tob_tracker_backtoback "$PKG" "$P/tob_tracker.sv"      tb/tb_tob_tracker_backtoback.sv
run tb_feature_engine         "$PKG" "$P/feature_engine.sv"   tb/tb_feature_engine.sv
run tb_board_link_tx          "$PKG" "$P/board_link-tx.sv"    tb/tb_board_link_tx.sv
run tb_latency_probe                 "$P/latency_probe.sv"    tb/tb_latency_probe.sv

# ---- io / bring-up ----
run tb_uart_to_axis    "$IO/uart_rx.sv" "$IO/sync_fifo.sv" "$IO/uart_to_axis.sv" \
                       tb/tb_uart_to_axis.sv
run tb_eth_crc32       rtl/eth/eth_crc32.sv             tb/tb_eth_crc32.sv
run tb_status_reporter "$IO/status_reporter.sv"  tb/tb_status_reporter.sv
run tb_button_debounce "$IO/button_debounce.sv"  tb/tb_button_debounce.sv

# ---- full pipeline through the UART bring-up wrapper ----
run tb_top_uart "$PKG" $ENC \
    "$P/Itch_parser.sv" "$P/Event_dispatcher.sv" "$P/order_lookup.sv" \
    "$P/book_update.sv" "$P/tob_tracker.sv" "$P/feature_engine.sv" \
    "$P/board_link-tx.sv" "$P/top_v2.sv" \
    "$IO/uart_rx.sv" "$IO/uart_tx.sv" "$IO/sync_fifo.sv" "$IO/uart_to_axis.sv" \
    "$IO/axis_to_uart.sv" "$IO/axis_arb2.sv" "$IO/status_reporter.sv" "$IO/top_uart.sv" \
    tb/tb_top_uart.sv

echo "================================================================"
printf "  %d testbenches, %d assertions passed, %d failed\n" \
       "$n_tb" "$total_pass" "$total_fail"
if [ "$total_fail" -ne 0 ]; then
    echo "  FAILING:$failed_list"
    echo "================================================================"
    exit 1
fi
echo "================================================================"
exit 0
