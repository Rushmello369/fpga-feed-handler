## =============================================================================
## build_led_test.tcl  --  build the LED bring-up bitstream in one shot.
##
## Run from the Vivado Tcl Console:
##     cd C:/LatencyGate_ML/hardware/ax7a200b/bringup
##     source build_led_test.tcl
##
## Builds into its own project directory, so it does NOT touch the main
## itch_uart project or its bitstream. Takes about a minute - the design is
## three counters.
## =============================================================================

set here "C:/LatencyGate_ML/hardware/ax7a200b/bringup"
set part "xc7a200tfbg484-2"

create_project -force led_test $here/vivado_led -part $part
add_files -norecurse -fileset sources_1 $here/led_test.sv
set_property file_type SystemVerilog [get_files $here/led_test.sv]
add_files -norecurse -fileset constrs_1 $here/led_test.xdc
set_property top led_test [get_filesets sources_1]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -jobs 8 -to_step write_bitstream
wait_on_run impl_1

puts ""
puts "============================================================"
puts "  bitstream: $here/vivado_led/led_test.runs/impl_1/led_test.bit"
puts ""
puts "  Program it, then watch the three user LEDs:"
puts ""
puts "    fast even blink   (~3 Hz)          -> that LED is pin M13"
puts "    slow even blink   (~0.37 Hz)       -> that LED is pin K14"
puts "    brief blip every ~2.7 s            -> that LED is pin K13"
puts ""
puts "  POLARITY - watch the K13 one:"
puts "    short FLASH on a dark LED  -> active-HIGH (main design is correct)"
puts "    short DARK GAP on a lit LED-> active-LOW  (invert LED outputs)"
puts ""
puts "  If NO LED moves at all, the 200 MHz differential clock is not"
puts "  reaching the FPGA - check R4/T4 and the DIFF_SSTL15 standard."
puts "============================================================"
