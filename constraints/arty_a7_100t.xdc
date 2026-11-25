# Pins checked against Digilent Arty-A7-100-Master.xdc (see docs/board.md).
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports reset_n]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports eth_ref_clk]
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS33} [get_ports eth_rstn]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports eth_mdc]
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33} [get_ports eth_mdio]
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports eth_rx_clk]
set_property -dict {PACKAGE_PIN G16 IOSTANDARD LVCMOS33} [get_ports eth_rx_dv]
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports eth_rxerr]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[0]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[1]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[2]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[3]}]
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports eth_tx_clk]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports eth_tx_en]
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33} [get_ports {eth_txd[0]}]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports {eth_txd[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {eth_txd[2]}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {eth_txd[3]}]
create_clock -name sys_clk -period 10.000 [get_ports CLK100MHZ]
create_clock -name phy_rx -period 40.000 [get_ports eth_rx_clk]
create_clock -name phy_tx -period 40.000 [get_ports eth_tx_clk]
create_generated_clock -name phy_reference -source [get_pins phy_ref/C] -divide_by 1 [get_ports eth_ref_clk]
# MDC runs in 64-bit bursts; this describes its maximum active clock rate.
# MDIO timing is separately bounded by the qualified-strobe constraints below.
create_generated_clock -name management_clock -source [get_ports CLK100MHZ] -divide_by 100 [get_ports eth_mdc]
# TI SNLS250E T2.5.2: rising RX_CLK -> RX data 10..30 ns.
# Budget +/-1 ns PCB skew. TX driven falling edge, PHY samples rising;
# T2.4.2/3 specify 10 ns setup / 0 hold, with 1 ns PCB skew margins.
set_input_delay -clock phy_rx -min 9.0 [get_ports {eth_rxd[*] eth_rx_dv eth_rxerr}]
set_input_delay -clock phy_rx -max 31.0 [get_ports {eth_rxd[*] eth_rx_dv eth_rxerr}]
set_output_delay -clock phy_tx -max 11.0 [get_ports {eth_txd[*] eth_tx_en}]
set_output_delay -clock phy_tx -min -1.0 [get_ports {eth_txd[*] eth_tx_en}]
set_false_path -from [get_ports reset_n]
set_false_path -to [get_ports eth_rstn]
# MDIO is sampled only at a 1 MHz strobe, 500 ns after the preceding MDC
# falling edge. Bound pin-to-register/driver flight to 20 ns; remaining time
# covers external PHY turnaround. These are protocol-qualified slow paths.
set_input_delay -clock [get_clocks -of_objects [get_pins clocks/CLKOUT0]] -max 0 [get_ports eth_mdio]
set_input_delay -clock [get_clocks -of_objects [get_pins clocks/CLKOUT0]] -min 0 [get_ports eth_mdio]
set_output_delay -clock [get_clocks -of_objects [get_pins clocks/CLKOUT0]] -max 0 [get_ports eth_mdio]
set_output_delay -clock [get_clocks -of_objects [get_pins clocks/CLKOUT0]] -min 0 [get_ports eth_mdio]
set_max_delay -datapath_only 20.0 -from [get_ports eth_mdio] -to [get_cells -hier -regexp {.*management/(read_value_reg.*|ack_ok_reg.*)}]
set_max_delay -datapath_only 20.0 -to [get_ports eth_mdio]
# Only the first synchronizer stage is exempted, rather than all clock paths.
set_false_path -to [get_cells -hier -regexp {.*(req1|ack1|bad1|drop1|rx_running1|reset_pipe_reg.*|rx_reset_reg.*|tx_reset_reg.*).*}]
set_bus_skew 40.0 -from [get_cells -hier -regexp {.*receiver/bad_gray_reg.*}] -to [get_cells -hier -regexp {.*receiver/bad1_reg.*}]
set_bus_skew 40.0 -from [get_cells -hier -regexp {.*receiver/drop_gray_reg.*}] -to [get_cells -hier -regexp {.*receiver/drop1_reg.*}]
# The frame mailboxes are bundled data: data is stable before request crosses
# two synchronizers and remains stable until acknowledgement crosses back.
# Bound physical data flight time; do not blanket-exempt unrelated CDC paths.
set_max_delay -datapath_only 10.0 -from [get_cells -hier -regexp {.*receiver/length_q_reg.*}] -to [get_cells -hier -regexp {.*parser/length_q_reg.*}]
set_max_delay -datapath_only 20.0 -from [get_cells -hier -regexp {.*transmitter/(length_q_reg.*|mem_reg.*)}] -to [get_cells -hier -regexp {.*transmitter/(txd_reg.*|crc_reg.*|fcs_reg.*|state_reg.*|index_reg.*)}]
# Frozen mailbox buses have protocol-qualified capture after a synchronized
# request, and remain frozen until a synchronized acknowledgement. Clock-phase
# hold analysis between independent PHY/core clocks is inapplicable to them.
set_false_path -hold -from [get_cells -hier -regexp {.*receiver/length_q_reg.*}] -to [get_cells -hier -regexp {.*parser/length_q_reg.*}]
set_false_path -hold -from [get_cells -hier -regexp {.*transmitter/(length_q_reg.*|mem_reg.*)}] -to [get_cells -hier -regexp {.*transmitter/(txd_reg.*|crc_reg.*|fcs_reg.*|state_reg.*|index_reg.*)}]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
