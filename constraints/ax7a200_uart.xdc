## =============================================================================
## AX7A200B constraints for top_board (ITCH UART bring-up)
## Pins taken from the AX7A200 user guide:
##   200 MHz differential system clock : SYS_CLK_P = R4 , SYS_CLK_N = T4 (BANK34)
##   USB-UART (CP2102GM)               : UART1_RXD = L14, UART1_TXD  = L15
##   User LED1                         : M13
## NOTE: BANK34 is shared with DDR3 (VCCO = 1.5 V) -> clock uses DIFF_SSTL15.
##       Cross-check IOSTANDARD/VCCO against ALINX's official XDC for your board.
## =============================================================================

## ---- 200 MHz differential system clock ----
set_property -dict {PACKAGE_PIN R4 IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN T4 IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_n]
create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

## ---- USB-UART (CP2102), 3.3 V LVCMOS ----
## FPGA RX  <- CP2102 TXD  (data from PC)
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33} [get_ports uart_rx_pin]
## FPGA TX  -> CP2102 RXD  (frames to PC)
set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33} [get_ports uart_tx_pin]

## ---- FIFO-overflow indicator on user LED1 ----
set_property -dict {PACKAGE_PIN M13 IOSTANDARD LVCMOS33} [get_ports rx_overflow]

## ---- async UART inputs: don't time them against the core clock ----
set_false_path -from [get_ports uart_rx_pin]
set_false_path -to [get_ports uart_tx_pin]
set_false_path -to [get_ports rx_overflow]

## ---- bitstream / config bank (ALINX A7 boards: 3.3 V config) ----
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

