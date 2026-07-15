## =============================================================================
## create_vivado_project.tcl
## -----------------------------------------------------------------------------
## Builds a Vivado project for the ITCH UART bring-up design (top = top_board),
## with sources correctly split into design / simulation / constraints filesets.
##
## Run from the Vivado Tcl Console:
##     cd C:/LatencyGate_ML/hardware/ax7a200b
##     source create_vivado_project.tcl
## or in batch:
##     vivado -mode batch -source create_vivado_project.tcl
##
## Edit the three variables below if your paths / part differ.
## =============================================================================

## ---- user settings ----------------------------------------------------------
set root      "C:/LatencyGate_ML/hardware/ax7a200b"
set proj_name "itch_uart"
set proj_dir  "$root/vivado"
## AX7A200B = XC7A200T, FBG484, speed -2. CONFIRM the exact suffix from the chip
## marking / user guide (could be -2FBG484I etc.).
set part      "xc7a200tfbg484-2"
## -----------------------------------------------------------------------------

## ---- design sources (SYNTHESIZABLE). Order does not matter; Vivado computes
## the compile order. NOTE deliberately EXCLUDED:
##   - tb_top_v2.sv                (testbench living in the rtl folder)
##   - priority_encoder_v2.sv      (old fixed-1024 encoder, unused)
##   - fm24_parser/*               (old design)
set design_files [list \
    "$root/rtl/ITCH50_parser/ITCH50_pkg.sv" \
    "$root/rtl/ITCH50_parser/priority_encoder_v2/onehot2bin.sv" \
    "$root/rtl/ITCH50_parser/priority_encoder_v2/onehot2bin_gen.sv" \
    "$root/rtl/ITCH50_parser/priority_encoder_v2/find_lowest.sv" \
    "$root/rtl/ITCH50_parser/priority_encoder_v2/radix_find_lowest.sv" \
    "$root/rtl/ITCH50_parser/priority_encoder_v2/priority_encoder.sv" \
    "$root/rtl/ITCH50_parser/Itch_parser.sv" \
    "$root/rtl/ITCH50_parser/Event_dispatcher.sv" \
    "$root/rtl/ITCH50_parser/order_lookup.sv" \
    "$root/rtl/ITCH50_parser/book_update.sv" \
    "$root/rtl/ITCH50_parser/tob_tracker.sv" \
    "$root/rtl/ITCH50_parser/feature_engine.sv" \
    "$root/rtl/ITCH50_parser/board_link-tx.sv" \
    "$root/rtl/ITCH50_parser/top_v2.sv" \
    "$root/rtl/ITCH50_parser/io/uart_rx.sv" \
    "$root/rtl/ITCH50_parser/io/uart_tx.sv" \
    "$root/rtl/ITCH50_parser/io/sync_fifo.sv" \
    "$root/rtl/ITCH50_parser/io/uart_to_axis.sv" \
    "$root/rtl/ITCH50_parser/io/axis_to_uart.sv" \
    "$root/rtl/ITCH50_parser/io/top_uart.sv" \
    "$root/rtl/ITCH50_parser/io/top_board.sv" \
]

## ---- constraints ------------------------------------------------------------
set constr_files [list \
    "$root/constraints/ax7a200_uart.xdc" \
]

## ---- simulation-only sources (optional; not used for synthesis) -------------
set sim_files [list \
    "$root/rtl/ITCH50_parser/tb_top_v2.sv" \
    "$root/tb/tb_itch_parser.sv" \
    "$root/tb/tb_order_lookup.sv" \
    "$root/tb/tb_book_update.sv" \
    "$root/tb/tb_tob_tracker.sv" \
    "$root/tb/tb_event_dispatcher.sv" \
    "$root/tb/tb_feature_engine.sv" \
    "$root/tb/tb_board_link_tx.sv" \
    "$root/tb/tb_radix_find_lowest.sv" \
    "$root/tb/tb_uart_to_axis.sv" \
    "$root/tb/tb_top_uart.sv" \
]

## =============================================================================
##  build the project
## =============================================================================
create_project -force $proj_name $proj_dir -part $part

## ---- design sources ----
add_files -norecurse -fileset sources_1 $design_files
set_property file_type SystemVerilog [get_files -of [get_filesets sources_1] *.sv]
set_property top top_board [get_filesets sources_1]

## ---- constraints ----
add_files -norecurse -fileset constrs_1 $constr_files

## ---- simulation sources ----
add_files -norecurse -fileset sim_1 $sim_files
set_property file_type SystemVerilog [get_files -of [get_filesets sim_1] *.sv]
## reasonable default sim top (change in the GUI to run a different testbench)
set_property top tb_top_uart [get_filesets sim_1]

## ---- resolve compile order for both filesets ----
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

## ---- report ----
puts "============================================================"
puts "  project   : $proj_name  ($proj_dir)"
puts "  part      : $part"
puts "  synth top : [get_property top [get_filesets sources_1]]"
puts "  design    : [llength $design_files] files"
puts "  sim       : [llength $sim_files] files (fileset sim_1)"
puts "  constrs   : [llength $constr_files] file(s)"
puts "  EXCLUDED  : tb_top_v2.sv(->sim), priority_encoder_v2.sv, fm24_parser/*"
puts "  next: launch_runs synth_1 -jobs 8 ; wait_on_run synth_1"
puts "        launch_runs impl_1 -jobs 8  ; wait_on_run impl_1"
puts "============================================================"
