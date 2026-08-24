## =============================================================================
## led_test.xdc  --  same pin assumptions as ax7a200_uart.xdc, isolated so this
## bring-up build can be edited freely while testing alternatives.
##
## If the LED walk shows a different mapping than expected, change the pins HERE
## first, rebuild, confirm, and only then port the correction back into
## ax7a200_uart.xdc.
## =============================================================================

## ---- 200 MHz differential system clock (BANK34, shared with DDR3 -> 1.5 V) ----
set_property -dict {PACKAGE_PIN R4 IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN T4 IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_n]
create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

## ---- user LEDs ----
set_property -dict {PACKAGE_PIN M13 IOSTANDARD LVCMOS33} [get_ports led1]
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33} [get_ports led2]
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33} [get_ports led3]

set_false_path -to [get_ports led1]
set_false_path -to [get_ports led2]
set_false_path -to [get_ports led3]

## ---- bitstream / config bank ----
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
