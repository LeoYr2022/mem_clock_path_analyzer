#!/usr/bin/env tclsh
# bin/mem_clk_path.tcl - CLI entry point for the RTL memory clock-path analyzer.

set script_dir [file dirname [file normalize [info script]]]
set lib_dir    [file join [file dirname $script_dir] lib]

source [file join $lib_dir util.tcl]
source [file join $lib_dir parser.tcl]
source [file join $lib_dir detect.tcl]
source [file join $lib_dir trace.tcl]
source [file join $lib_dir emit.tcl]

proc usage {} {
    puts stderr "Usage:"
    puts stderr "  tclsh mem_clk_path.tcl -f <filelist> -top <top> -mem <memlist> \\"
    puts stderr "        -report <path> -dot <path> \\"
    puts stderr "        \[-clk_root_pattern <regex>\] \\"
    puts stderr "        \[-mux_cell_pattern <regex>\]  \\"
    puts stderr "        \[-icg_cell_pattern <regex>\]"
    exit 2
}

array set opts {
    -clk_root_pattern {(?i)pll|dll}
    -mux_cell_pattern {(?i)CKMUX|CLKMUX}
    -icg_cell_pattern {(?i)ICG|CKGT|CLKGATE}
}

set pending ""
foreach arg $argv {
    if {$pending eq ""} {
        set pending $arg
    } else {
        set opts($pending) $arg
        set pending ""
    }
}
if {$pending ne ""} { usage }

foreach required {-f -top -mem -report -dot} {
    if {![info exists opts($required)]} {
        puts stderr "ERROR: missing required arg $required"
        usage
    }
}

proc read_list_file {path} {
    set out {}
    foreach ln [split [mcp::read_file $path] \n] {
        set ln [string trim $ln]
        if {$ln eq ""} continue
        if {[string index $ln 0] eq "#"} continue
        lappend out $ln
    }
    return $out
}

# --- Load filelist and memory-module list -------------------------------
set files [read_list_file $opts(-f)]
set filelist_dir [file dirname [file normalize $opts(-f)]]

set mem_modules [dict create]
foreach ln [read_list_file $opts(-mem)] {
    set toks [regexp -inline -all {\S+} $ln]
    set m [lindex $toks 0]
    set p [lindex $toks 1]
    if {$p eq ""} { set p CLK }
    dict set mem_modules $m $p
}

# --- Parse all RTL ------------------------------------------------------
set all_modules [dict create]
foreach f $files {
    set fpath $f
    if {![file exists $fpath]} {
        set fpath [file join $filelist_dir $f]
    }
    if {![file exists $fpath]} {
        puts stderr "ERROR: file not found: $f"
        exit 1
    }
    set text [mcp::read_file $fpath]
    set mods [mcp::parse_verilog $text]
    dict for {mn md} $mods {
        dict set all_modules $mn $md
    }
}

# --- Classify modules ---------------------------------------------------
mcp::classify_modules all_modules $mem_modules [array get opts]

# --- Trace memory clock paths -------------------------------------------
if {![dict exists $all_modules $opts(-top)]} {
    puts stderr "ERROR: top module '$opts(-top)' not found among parsed modules"
    exit 1
}
set traces [mcp::trace_all $all_modules $opts(-top) $mem_modules]

if {[llength $traces] == 0} {
    puts stderr "ERROR: no memory instances of \[dict keys \$mem_modules\] found under $opts(-top)"
    exit 1
}

# --- Emit outputs -------------------------------------------------------
mcp::emit_report $traces $opts(-report)
mcp::emit_dot    $traces $opts(-dot)

# --- Check for unknowns -------------------------------------------------
set unknown 0
foreach t $traces {
    foreach node [dict get $t path] {
        if {[dict get $node kind] eq "UNKNOWN"} { incr unknown }
    }
}

puts "wrote $opts(-report)"
puts "wrote $opts(-dot)"
puts "memories traced : [llength $traces]"
puts "unknown nodes   : $unknown"

if {$unknown > 0} {
    puts stderr "WARNING: [set unknown] clock-path node(s) could not be classified"
    exit 1
}
exit 0
