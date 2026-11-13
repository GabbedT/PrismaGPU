# Usage: vivado -mode batch -source triangle_math_unit.tcl -tclargs <stages> <Use_Mults|Use_LUTs> <ip|sim|route>
# Run each candidate in a separate process/project. No pipeline depth is assumed optimal.
if {$argc != 3} { error "Expected: stages construction ip|sim|route" }
lassign $argv stages construction action
if {![string is integer -strict $stages] || $stages < 1 || $stages > 30} { error "Pipeline stages must be 1..30" }
if {$construction ni {Use_Mults Use_LUTs} || $action ni {ip sim route}} { error "Invalid construction or action" }
set script_dir [file dirname [file normalize [info script]]]
set root [file normalize [file join $script_dir ../../..]]
set work [file join $root out triangle_math_unit vivado ${construction}_${stages}]
set rtl [file join $root hw raster_engine triangle_setup math_unit]
file mkdir $work
create_project -force triangle_math_unit $work -part xc7a100tcsg324-1
set_param general.maxThreads 2
create_ip -name mult_gen -vendor xilinx.com -library ip -version 12.0 -module_name triangle_multiply_ip
# The installed component metadata supports signed operands through 64 bits each.
set_property -dict [list CONFIG.PortAWidth 54 CONFIG.PortBWidth 33 \
    CONFIG.PortAType Signed CONFIG.PortBType Signed CONFIG.MultType Parallel_Multiplier \
    CONFIG.Multiplier_Construction $construction CONFIG.PipeStages $stages \
    CONFIG.SyncClear true CONFIG.ClockEnable false CONFIG.Use_Custom_Output_Width false] [get_ips triangle_multiply_ip]
generate_target all [get_ips triangle_multiply_ip]
report_property [get_ips triangle_multiply_ip] -file [file join $work ip_properties.rpt]
if {$action eq "ip"} { close_project; exit }
add_files [list [file join $root hw pkg math_unit_pkg.sv] \
    [file join $root hw pkg texturizer_pkg.sv] \
    [file join $root hw pkg re_registers_pkg.sv] \
    [file join $root hw common reciprocal_lut.sv] \
    [file join $rtl triangle_multiply_unit.sv] [file join $rtl triangle_reciprocal.sv] \
    [file join $rtl triangle_math_unit.sv]]
set_property verilog_define {_VIVADO_} [current_fileset]
set_property top triangle_math_unit [current_fileset]
set_property generic MULTIPLIER_LATENCY=$stages [current_fileset]
update_compile_order -fileset sources_1
if {$action eq "sim"} {
    exec python3 [file join $root tb re math_unit generate_vectors.py] --output [file join $root out triangle_math_unit]
    add_files -fileset sim_1 [list [file join $root tb re math_unit triangle_units_tb.sv] \
        [file join $root tb re math_unit triangle_math_unit_tb.sv]]
    set_property verilog_define {_VIVADO_} [get_filesets sim_1]
    set_property generic IP_LATENCY=$stages [get_filesets sim_1]
    set_property xsim.simulate.runtime all [get_filesets sim_1]
    foreach top {triangle_units_tb triangle_math_unit_tb} {
        set_property top $top [get_filesets sim_1]
        set vectors [file join $root out triangle_math_unit]
        if {$top eq "triangle_units_tb"} {
            set options [list -testplusarg MULTIPLY=[file join $vectors multiply.txt] -testplusarg RECIPROCAL=[file join $vectors reciprocal.txt]]
        } else {
            set options [list -testplusarg VECTORS=[file join $vectors commands.txt] -testplusarg TIMING_SEED=731]
        }
        set_property xsim.simulate.xsim.more_options $options [get_filesets sim_1]
        launch_simulation
        close_sim
    }
} else {
    # Use the same part and 10 ns internal clock as the GPU evaluation.
    # OOC avoids assigning hundreds of standalone operand pins to package I/O.
    synth_ip [get_ips triangle_multiply_ip]
    synth_design -top triangle_math_unit -part xc7a100tcsg324-1 -mode out_of_context -generic MULTIPLIER_LATENCY=$stages
    create_clock -name gpu_clk -period 10.000 [get_ports clk_i]
    report_utilization -hierarchical -file [file join $work synthesis_utilization.rpt]
    opt_design
    place_design
    phys_opt_design
    route_design
    report_utilization -hierarchical -file [file join $work routed_utilization.rpt]
    report_timing_summary -delay_type min_max -report_unconstrained -file [file join $work routed_timing.rpt]
    report_timing -max_paths 20 -file [file join $work critical_paths.rpt]
    write_checkpoint -force [file join $work routed.dcp]
    set path [get_timing_paths -max_paths 1]
    set report [open [file join $work candidate.txt] w]
    puts $report "construction=$construction stages=$stages wrapper_response_latency=[expr {$stages + 1}]"
    puts $report "worst_setup_slack=[get_property SLACK $path]"
    close $report
}
close_project
exit
