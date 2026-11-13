# License-free checks for recursive manifests and real source-set boundaries.
package require tcltest
namespace import ::tcltest::*
set script_dir [file dirname [file dirname [file normalize [info script]]]]
set root [file normalize [file join $script_dir ../..]]
source [file join $script_dir sources.tcl]
configure -testdir [file dirname [info script]] -tmpdir /tmp

test gpu-manifest-1 {shared files are unique and packages precede consumers} -body {
    set sources [read_manifest [file join $root hw _prismaGPU.f]]
    set names [lmap path $sources {file tail $path}]
    list [expr {[llength $sources] == [llength [lsort -unique $sources]]}] \
        [lindex $names 0] [lindex $names end] \
        [expr {[lsearch $names gpu_ddr_interface.sv] < [lsearch $names raster_engine.sv]}] \
        [expr {[lsearch $names geometry_engine.sv] < [lsearch $names prismaGPU.sv]}]
} -result {1 triangle_pkg.sv prismaGPU.sv 1 1}

test ge-manifest-1 {GE build contains no RE or SoC sources} -body {
    set sources [read_manifest [file join $root hw geometry_engine _geometry_engine.f]]
    list [file tail [lindex $sources end]] \
        [llength [lsearch -all -glob $sources */raster_engine/*]] \
        [llength [lsearch -all -glob $sources *ZenithSoC*]]
} -result {geometry_engine.sv 0 0}

test manifest-cycle-1 {cycles fail instead of recursing indefinitely} -setup {
    set fixture [makeDirectory prisma_manifest_cycle]
    set channel [open [file join $fixture cycle.f] w]
    puts $channel {-F cycle.f}
    close $channel
} -body {
    read_manifest [file join $fixture cycle.f]
} -cleanup {
    removeDirectory prisma_manifest_cycle
} -returnCodes error -match glob -result {Recursive source manifest:*}

test manifest-missing-1 {missing RTL fails before Vivado starts} -setup {
    set fixture [makeDirectory prisma_manifest_missing]
    set channel [open [file join $fixture missing.f] w]
    puts $channel {missing.sv}
    close $channel
} -body {
    read_manifest [file join $fixture missing.f]
} -cleanup {
    removeDirectory prisma_manifest_missing
} -returnCodes error -match glob -result {Missing RTL source:*}

set failed $::tcltest::numTests(Failed)
cleanupTests
exit [expr {$failed != 0}]
