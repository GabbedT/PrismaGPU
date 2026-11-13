proc write_reports {directory} {
    file mkdir $directory
    report_utilization -file [file join $directory utilization.rpt]
    report_utilization -hierarchical -file [file join $directory utilization_hierarchical.rpt]
    report_timing_summary -delay_type min_max -max_paths 20 -report_unconstrained \
        -file [file join $directory timing_summary.rpt]
    report_timing -delay_type max -from [all_registers -clock gpu_clk] \
        -to [all_registers -clock gpu_clk] -max_paths 20 \
        -file [file join $directory timing_registers.rpt]
    report_timing -delay_type min -from [all_registers -clock gpu_clk] \
        -to [all_registers -clock gpu_clk] -max_paths 20 \
        -file [file join $directory timing_registers_hold.rpt]
    report_timing -delay_type max -from [all_inputs] -max_paths 20 \
        -file [file join $directory timing_inputs.rpt]
    report_timing -delay_type max -to [all_outputs] -max_paths 20 \
        -file [file join $directory timing_outputs.rpt]
    check_timing -verbose -file [file join $directory check_timing.rpt]
    report_drc -file [file join $directory drc.rpt]
    report_clocks -file [file join $directory clocks.rpt]
    puts "Evaluation reports: $directory"
}
