# Values are written into the project-local constraints file by build.tcl.
# Ports model synchronous connections to other logic on the SoC system clock.
create_clock -name gpu_clk -period $eval_period [get_ports clk_i]
# Representative existing SoC BUFG: enables OOC clock delay/skew estimation.
# This does not instantiate a buffer or reserve the final ZenithSoC clock site.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk_i]
set_clock_uncertainty -setup $eval_uncertainty [get_clocks gpu_clk]
set data_inputs [get_ports -filter {DIRECTION == IN && NAME != clk_i}]
set_input_delay -clock gpu_clk -max $eval_io_delay $data_inputs
set_input_delay -clock gpu_clk -min 0.000 $data_inputs
set_output_delay -clock gpu_clk -max $eval_io_delay [all_outputs]
set_output_delay -clock gpu_clk -min 0.000 [all_outputs]
# rst_n_i is timed too: the assumed integration provides synchronous deassertion.
# No blanket false paths, board pins, generated clocks, or SoC floorplan.
