## =============================================================================
## build_all.tcl
## -----------------------------------------------------------------------------
## Recreate the Vivado project from source, synthesize, implement, write the
## bitstream, and print the numbers that matter. One command, no GUI clicking.
##
## Run from the Vivado Tcl Console:
##     cd C:/LatencyGate_ML/hardware/ax7a200b
##     source build_all.tcl
##
## or headless (note: PowerShell 5.1 has no '&&', use two statements):
##     Set-Location C:\LatencyGate_ML\hardware\ax7a200b
##     vivado -mode batch -source build_all.tcl
##
## WARNING: create_vivado_project.tcl uses -force, so this DELETES the previous
## project directory including any earlier bitstream. That is intentional - the
## whole point is that the build is reproducible from source - but if you want
## to keep an old .bit for comparison, copy it out first.
## =============================================================================

set root  "C:/LatencyGate_ML/hardware/ax7a200b"
set jobs  8

cd $root

puts "\n### 1/4  recreating project from source ###"
source $root/create_vivado_project.tcl

puts "\n### 2/4  synthesis ###"
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "SYNTHESIS FAILED - see the log in vivado/itch_uart.runs/synth_1/runme.log"
}

puts "\n### 3/4  implementation + bitstream ###"
launch_runs impl_1 -jobs $jobs -to_step write_bitstream
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "IMPLEMENTATION FAILED - see the log in vivado/itch_uart.runs/impl_1/runme.log"
}

puts "\n### 4/4  results ###"
open_run impl_1

## ---- timing: the number that decides whether this build is usable ----
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "-----------------------------------------------------------"
puts [format "  WNS (setup) : %+0.3f ns" $wns]
puts [format "  WHS (hold)  : %+0.3f ns" $whs]

## ---- resources ----
set luts  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
set ffs   [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set dsps  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == DSP}]]
set brams [llength [get_cells -hier -filter {PRIMITIVE_GROUP == BLOCKRAM}]]
puts [format "  LUT / FF    : %d / %d" $luts $ffs]
puts [format "  BRAM / DSP  : %d / %d" $brams $dsps]
puts "-----------------------------------------------------------"

if {$wns < 0} {
    puts "  *** TIMING NOT MET - do NOT program this bitstream ***"
    puts "  The design will behave non-deterministically on silicon."
} else {
    puts "  timing met"
    puts "  bitstream: $root/vivado/itch_uart.runs/impl_1/top_board.bit"
}
puts ""
puts "  Next: program the device, then confirm LED2 (K14) blinks at ~3 Hz"
puts "  before doing anything else - that proves clock alive + MMCM locked."
puts ""
