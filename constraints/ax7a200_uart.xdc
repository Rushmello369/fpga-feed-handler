## =============================================================================
## AX7A200B constraints for top_board (ITCH UART bring-up)
## Pins taken from the AX7A200 user guide:
##   200 MHz differential system clock : SYS_CLK_P = R4 , SYS_CLK_N = T4 (BANK34)
##   USB-UART (CP2102GM)               : UART1_RXD = L14, UART1_TXD  = L15
##   User LED1 / LED2 / LED3            : M13 / K14 / K13
## NOTE: BANK34 is shared with DDR3 (VCCO = 1.5 V) -> clock uses DIFF_SSTL15.
##       Cross-check IOSTANDARD/VCCO against ALINX's official XDC for your board.
## =============================================================================

## ---- 200 MHz differential system clock ----
set_property -dict {PACKAGE_PIN R4 IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN T4 IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_n]
create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

## ---- RESET push-button (F15), active-low, pulled up to 3.3 V on board ----
## Clears the pipeline + all diagnostic counters between replay runs.
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports rst_btn_n]

## ---- USB-UART (CP2102), 3.3 V LVCMOS ----
## FPGA RX  <- CP2102 TXD  (data from PC)
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33} [get_ports uart_rx_pin]
## FPGA TX  -> CP2102 RXD  (frames to PC)
set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33} [get_ports uart_tx_pin]

## ---- user LEDs: ACTIVE-LOW, and the pin-to-label mapping is shifted by one ----
## Both facts were established empirically with bringup/led_test.sv rather than
## taken from the user guide, which is what the note at the top of this file
## warned about. Driving 0 lights the LED, so every one of these nets is
## inverted inside top_board and carries an _n suffix.
##
##   M13 -> physical LED2 : FIFO overrun, sticky (DARK = healthy, lit = it
##                          happened at least once since reset)
##   K14 -> physical LED3 : heartbeat, ~1.5 Hz iff clk100 alive + MMCM locked
##   K13 -> physical LED4 : ~0.25 s flash per raw UART byte received
set_property -dict {PACKAGE_PIN M13 IOSTANDARD LVCMOS33} [get_ports rx_overflow_n]
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33} [get_ports heartbeat_n]
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33} [get_ports rx_activity_n]

## ---- async inputs: don't time them against the core clock ----
## (the button is double-registered + debounced inside button_debounce)
set_false_path -from [get_ports rst_btn_n]
set_false_path -from [get_ports uart_rx_pin]
set_false_path -to [get_ports uart_tx_pin]
set_false_path -to [get_ports rx_overflow_n]
set_false_path -to [get_ports heartbeat_n]
set_false_path -to [get_ports rx_activity_n]

## ---- bitstream / config bank (ALINX A7 boards: 3.3 V config) ----
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

