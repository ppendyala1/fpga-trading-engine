# Fast resource regression: the order store must actually infer block RAM.
set root [file normalize [file join [file dirname [info script]] ..]]
read_verilog -sv [list [file join $root rtl trading_types_pkg.sv] [file join $root rtl core order_store.sv]]
synth_design -top order_store -part xc7a100tcsg324-1
set blocks [get_cells -hier -filter {REF_NAME =~ RAMB*}]
file mkdir [file join $root build reports]
report_utilization -file [file join $root build reports order_store_utilization.rpt]
if {[llength $blocks] == 0} {error "Order store did not infer block RAM"}
puts "PASS: order store inferred [llength $blocks] block RAM primitives"
exit
