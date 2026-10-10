# Run from any directory with Vivado -mode batch -source <this file>.
set ge_script_dir [file dirname [file normalize [info script]]]
open_project [file join $ge_script_dir PrismaGPU.xpr]
set_param general.maxThreads 2

source [file join $ge_script_dir configure_geometry_engine.tcl]

if {[get_property NEEDS_REFRESH [get_runs synth_1]] ||
    [regexp -nocase {error|failed|cancelled} [get_property STATUS [get_runs synth_1]]]} {
    reset_run synth_1
}
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    launch_runs synth_1 -jobs 2
    wait_on_run synth_1
}
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "Geometry Engine synthesis failed: [get_property STATUS [get_runs synth_1]]"
}
open_run synth_1
source [file join $ge_script_dir report_geometry_engine.tcl]
