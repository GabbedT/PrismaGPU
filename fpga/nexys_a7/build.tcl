# Called from an isolated build directory by Make; may also be run directly there.
if {$argc != 8} {
    error "Expected: project|synth|route gpu|ge|triangle_setup part period io_delay uncertainty multiplier_stages jobs"
}
lassign $argv action block part period io_delay uncertainty stages jobs
if {$action ni {project synth route}} { error "Unknown action: $action" }
if {$block ni {gpu ge triangle_setup}} { error "Unknown block: $block" }
foreach value [list $period $io_delay $uncertainty] {
    if {![string is double -strict $value] || !($value >= 0.0 && $value < 1000000.0)} {
        error "Timing values must be finite, nonnegative ns values"
    }
}
if {$period <= 0 || $io_delay >= $period || $uncertainty >= $period} {
    error "Period must be positive; I/O budget and uncertainty must be below the period"
}
if {![string is integer -strict $stages] || $stages < 1 || $stages > 30} {
    error "Multiplier stages must be 1..30"
}
if {![string is integer -strict $jobs] || $jobs < 1 || $jobs > 32} { error "Jobs must be 1..32" }
set script_dir [file dirname [file normalize [info script]]]
set root [file normalize [file join $script_dir ../..]]
set work [file normalize [pwd]]
# Avoid overwriting source directories when invoked manually from the wrong place.
if {![string match "[file join $script_dir build]/*" $work] ||
    [string match "[file join $script_dir build legacy]*" $work]} {
    error "Run from a configuration directory under $script_dir/build (use Make)"
}
source [file join $script_dir sources.tcl]
source [file join $script_dir reports.tcl]
switch $block {
    gpu {
        set top prisma_gpu_eval
        set sources [read_manifest [file join $root hw _prismaGPU.f]]
        lappend sources [file join $script_dir rtl prisma_gpu_eval.sv]
    }
    ge {
        set top geometry_engine
        set sources [read_manifest [file join $root hw geometry_engine _geometry_engine.f]]
    }
    triangle_setup {
        set top triangle_setup
        set sources [read_manifest [file join $root hw raster_engine _raster_engine.f]]
    }
}
# Every invocation builds a fresh project. Reports from a prior route cannot survive
# a failed or synthesis-only rerun and be mistaken for current results.
foreach directory {project reports} {
    file delete -force [file join $work $directory]
}
foreach checkpoint {synthesized.dcp routed.dcp} {
    file delete -force [file join $work $checkpoint]
}
set_param general.maxThreads $jobs
# Do not continue reporting after a rejected or failed XDC command.
set_msg_config -id {Designutils 20-1307} -new_severity ERROR
set_msg_config -id {Common 17-1548} -new_severity ERROR
create_project evaluation [file join $work project] -part $part
set_property source_mgmt_mode None [current_project]
add_files -norecurse -fileset sources_1 $sources
set_property file_type SystemVerilog [get_files $sources]
set_property library xil_defaultlib [get_files $sources]
set_property top $top [get_filesets sources_1]
set_property top_auto_set false [get_filesets sources_1]
reorder_files -fileset sources_1 -front $sources
set_property is_enabled true [get_files $sources]
set_property verilog_define {_VIVADO_} [get_filesets sources_1]
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
    -value {-mode out_of_context} -objects [get_runs synth_1]
if {$block ne "ge"} {
    set_property generic [list MULTIPLIER_LATENCY=$stages] [get_filesets sources_1]
    create_ip -name mult_gen -vendor xilinx.com -library ip -version 12.0 -module_name triangle_multiply_ip
    set_property -dict [list CONFIG.PortAWidth 54 CONFIG.PortBWidth 33 \
        CONFIG.PortAType Signed CONFIG.PortBType Signed CONFIG.MultType Parallel_Multiplier \
        CONFIG.Multiplier_Construction Use_Mults CONFIG.PipeStages $stages \
        CONFIG.SyncClear true CONFIG.ClockEnable false CONFIG.Use_Custom_Output_Width false] \
        [get_ips triangle_multiply_ip]
    generate_target all [get_ips triangle_multiply_ip]
    report_property [get_ips triangle_multiply_ip] -file [file join $work multiplier_properties.rpt]
}
set constraints [file join $work project evaluation.xdc]
set channel [open $constraints w]
puts $channel [list set eval_period $period]
puts $channel [list set eval_io_delay $io_delay]
puts $channel [list set eval_uncertainty $uncertainty]
set template [open [file join $script_dir evaluation.xdc] r]
puts $channel [read $template]
close $template
close $channel
add_files -norecurse -fileset constrs_1 $constraints
set channel [open [file join $work configuration.txt] w]
puts $channel "Vivado: [version -short]"
puts $channel "action=$action block=$block top=$top part=$part"
puts $channel "period_ns=$period io_max_ns=$io_delay io_min_ns=0 setup_uncertainty_ns=$uncertainty"
puts $channel "multiplier_stages=$stages define=_VIVADO_ jobs=$jobs"
puts $channel "GPU FIFO depths: input=16 triangles=2 output=16 raster_queue=2 (RTL defaults)"
puts $channel "Scope: standalone OOC; no ZenithSoC, DDR controller, clock IP, pins or bitstream"
puts $channel "Sources (compilation order):\n[join $sources \n]"
close $channel
# Hash RTL and flow inputs so archived results can be identified after source edits.
set inputs [concat $sources [glob [file join $script_dir *.tcl]] \
    [list [file join $script_dir evaluation.xdc] [file join $script_dir Makefile]]]
exec sha256sum {*}$inputs > [file join $work sources.sha256]
if {$action eq "project"} {
    puts "Project: [file join $work project evaluation.xpr]"
    close_project
    exit 0
}
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "Synthesis failed: [get_property STATUS [get_runs synth_1]]"
}
open_run synth_1
if {[llength [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]] != 0} {
    error "Unresolved black boxes; refusing to report incomplete GPU area"
}
write_checkpoint -force [file join $work synthesized.dcp]
write_reports [file join $work reports synthesis]
if {$action eq "route"} {
    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force [file join $work routed.dcp]
    write_reports [file join $work reports routed]
    report_route_status -file [file join $work reports routed route_status.rpt]
    # Negative slack is a valid evaluation result, not a script failure.
    puts "Review routed timing_summary.rpt for WNS/TNS, WHS/THS and unconstrained paths."
}
close_project
exit 0
