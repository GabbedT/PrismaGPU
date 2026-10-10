# Source after Open Synthesized Design, or from synth_geometry_engine.tcl.
set ge_report_dir [file join [file dirname [file normalize [info script]]] reports]
file mkdir $ge_report_dir
report_utilization -file [file join $ge_report_dir utilization.rpt]
report_utilization -hierarchical -file [file join $ge_report_dir utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -max_paths 10 -report_unconstrained \
    -file [file join $ge_report_dir timing_summary.rpt]
report_timing -delay_type max -from [all_registers -clock ge_clk] \
    -to [all_registers -clock ge_clk] -max_paths 10 \
    -file [file join $ge_report_dir timing_registers.rpt]
check_timing -verbose -file [file join $ge_report_dir check_timing.rpt]
puts "Geometry Engine reports: $ge_report_dir"
