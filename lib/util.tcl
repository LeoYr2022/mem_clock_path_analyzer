# lib/util.tcl - shared helpers

namespace eval mcp {}

proc mcp::read_file {path} {
    set fh [open $path r]
    set data [read $fh]
    close $fh
    return $data
}

proc mcp::write_file {path content} {
    set dir [file dirname $path]
    if {$dir ne "" && ![file exists $dir]} {
        file mkdir $dir
    }
    set fh [open $path w]
    puts -nonewline $fh $content
    close $fh
}

proc mcp::strip_comments {text} {
    # Remove /* ... */ block comments (non-greedy, dot matches newline via (?s))
    regsub -all {(?s)/\*.*?\*/} $text " " text
    # Remove // line comments
    regsub -all {//[^\n]*} $text " " text
    return $text
}

proc mcp::trim_ws {s} {
    regsub -all {\s+} $s " " s
    return [string trim $s]
}

# Split a top-level list by `sep`, respecting () [] {} nesting.
proc mcp::split_toplevel {s sep} {
    set out {}
    set depth 0
    set curr ""
    set len [string length $s]
    for {set i 0} {$i < $len} {incr i} {
        set ch [string index $s $i]
        if {$ch eq "(" || $ch eq "\[" || $ch eq "\{"} { incr depth }
        if {$ch eq ")" || $ch eq "\]" || $ch eq "\}"} { incr depth -1 }
        if {$ch eq $sep && $depth == 0} {
            lappend out [string trim $curr]
            set curr ""
        } else {
            append curr $ch
        }
    }
    if {[string length [string trim $curr]] > 0} {
        lappend out [string trim $curr]
    }
    return $out
}

# Find the index of the ')' that matches an '(' at position `open_idx`.
proc mcp::find_matching_paren {text open_idx} {
    set depth 0
    set len [string length $text]
    for {set i $open_idx} {$i < $len} {incr i} {
        set ch [string index $text $i]
        if {$ch eq "("} { incr depth }
        if {$ch eq ")"} {
            incr depth -1
            if {$depth == 0} { return $i }
        }
    }
    return -1
}

proc mcp::log {msg} {
    puts stderr "\[mcp\] $msg"
}
