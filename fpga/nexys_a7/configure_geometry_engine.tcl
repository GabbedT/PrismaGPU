# Preserve the manifest order and its compilation-unit imports, as in ZenithSoC.
# Source with PrismaGPU.xpr already open; this does not launch any run.
set ge_config_dir [file dirname [file normalize [info script]]]
set ge_root_dir [file normalize [file join $ge_config_dir ../..]]
set ge_manifest [file join $ge_root_dir hw geometry_engine _geometry_engine.f]
set ge_manifest_channel [open $ge_manifest r]
set ge_sources {}
while {[gets $ge_manifest_channel ge_line] >= 0} {
    set ge_line [string trim $ge_line]
    if {$ge_line eq ""} { continue }
    lappend ge_sources [file normalize [file join [file dirname $ge_manifest] $ge_line]]
}
close $ge_manifest_channel

set_property source_mgmt_mode None [current_project]
foreach ge_source $ge_sources {
    if {![file exists $ge_source]} { error "Missing Geometry Engine source: $ge_source" }
    if {[llength [get_files -quiet $ge_source]] == 0} {
        add_files -norecurse -fileset sources_1 $ge_source
    }
}
set_property file_type SystemVerilog [get_files $ge_sources]
set_property library xil_defaultlib [get_files $ge_sources]
set_property used_in_synthesis true [get_files $ge_sources]
set_property top geometry_engine [get_filesets sources_1]
set_property top_auto_set false [get_filesets sources_1]
reorder_files -fileset sources_1 -front $ge_sources
# Clear automatic exclusions left over from the previous hierarchy scan.
set_property is_enabled true [get_files $ge_sources]
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
    -value {-mode out_of_context} -objects [get_runs synth_1]
