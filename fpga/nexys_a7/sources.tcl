# Resolve nested -F paths relative to each manifest, preserving first occurrence.
# Shared packages and reciprocal_lut appear in both GE and RE manifests.
proc read_manifest {manifest {stack {}}} {
    set manifest [file normalize $manifest]
    if {$manifest in $stack} { error "Recursive source manifest: $manifest" }
    lappend stack $manifest
    set channel [open $manifest r]
    set sources {}
    try {
        while {[gets $channel line] >= 0} {
            set line [string trim $line]
            if {$line eq "" || [string match {#*} $line] || [string match {//*} $line]} { continue }
            if {[regexp {^-F\s+(.+)$} $line -> nested]} {
                set entries [read_manifest [file join [file dirname $manifest] $nested] $stack]
            } else {
                if {[string match {-*} $line]} { error "Unsupported manifest option: $line" }
                set path [file normalize [file join [file dirname $manifest] $line]]
                if {![file isfile $path]} { error "Missing RTL source: $path" }
                set entries [list $path]
            }
            foreach path $entries {
                if {$path ni $sources} { lappend sources $path }
            }
        }
    } finally {
        close $channel
    }
    return $sources
}
