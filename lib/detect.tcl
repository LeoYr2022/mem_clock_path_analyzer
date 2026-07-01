# lib/detect.tcl - classify each parsed module by its clock-path role.
#
# After classification each module dict gains a `role` key. Trace consults
# only the role, not the raw RTL, when it crosses instance boundaries.

namespace eval mcp {}

# Classify all modules in place. `mem_modules` is a dict {mod_name -> clk_port};
# memories are marked with role kind MEM and skipped by other detectors.
proc mcp::classify_modules {modules_var mem_modules opts} {
    upvar $modules_var modules
    dict for {name mod} $modules {
        if {[dict exists $mem_modules $name]} {
            dict set modules $name role \
                [dict create kind MEM clock_input [dict get $mem_modules $name]]
            continue
        }
        dict set modules $name role [mcp::classify_one $name $mod $opts]
    }
}

proc mcp::classify_one {name mod opts} {
    set ports         [dict get $mod ports]
    set assigns       [dict get $mod assigns]
    set always_blocks [dict get $mod always_blocks]

    set in_ports  [mcp::_ports_of_dir $ports input]
    set out_ports [mcp::_ports_of_dir $ports output]

    set clk_root_pat [dict get $opts -clk_root_pattern]
    set mux_cell_pat [dict get $opts -mux_cell_pattern]
    set icg_cell_pat [dict get $opts -icg_cell_pattern]

    # --- ROOT: module name matches PLL/DLL pattern ---
    if {[regexp $clk_root_pat $name]} {
        set in [lindex $in_ports 0]
        set out [lindex $out_ports 0]
        return [dict create kind ROOT clock_input $in clock_output $out]
    }

    # --- ICG-style cell name (explicit user override) ---
    if {[regexp $icg_cell_pat $name]} {
        return [mcp::_icg_from_ports $in_ports $out_ports $assigns]
    }
    # --- MUX cell name (explicit user override) ---
    if {[regexp $mux_cell_pat $name]} {
        return [mcp::_mux_from_ports $in_ports $out_ports $assigns]
    }

    # --- DIV: always block with `posedge clk` driving a toggle FF (÷2)
    # or a counter (÷N).
    foreach blk $always_blocks {
        set sens [dict get $blk sensitivity]
        set body [dict get $blk body]
        if {![regexp {posedge\s+(\w+)} $sens -> clk]} continue
        # toggle FF: `q <= ~q`
        if {[regexp {(\w+)\s*<=\s*~\s*(\w+)} $body -> lhs rhs]} {
            if {$lhs eq $rhs} {
                set out [mcp::_driven_output $lhs $assigns $out_ports]
                return [dict create \
                    kind DIV ratio 2 \
                    clock_input $clk clock_output $out]
            }
        }
        # counter divider: `cnt <= cnt + 1`, output derived from cnt
        if {[regexp {(\w+)\s*<=\s*(\w+)\s*\+\s*1} $body -> lhs rhs]} {
            if {$lhs eq $rhs} {
                set ratio 0
                if {[regexp {==\s*(\d+)} $body -> n]} {
                    set ratio [expr {$n + 1}]
                }
                set out [lindex $out_ports 0]
                return [dict create \
                    kind DIV ratio $ratio \
                    clock_input $clk clock_output $out]
            }
        }
    }

    # --- MUX (behavioral): assign out = sel ? b : a ---
    foreach a $assigns {
        set rhs [dict get $a rhs]
        if {[regexp {^\(?\s*(\w+)\s*\)?\s*\?\s*(\w+)\s*:\s*(\w+)\s*$} $rhs -> sel then_in else_in]} {
            return [dict create kind MUX \
                clock_output [dict get $a lhs] \
                clock_inputs [list $else_in $then_in] \
                select $sel]
        }
    }

    # --- ICG / gate: assign g = clk & en  (or `& ~en`) ---
    foreach a $assigns {
        set rhs [dict get $a rhs]
        if {[regexp {^\s*(\w+)\s*&\s*~?\s*(\w+)\s*$} $rhs -> op1 op2]} {
            # heuristic: whichever operand's port name says "clk"/"ck" is the clock
            set clk_op $op1
            set en_op  $op2
            if {[regexp -nocase {clk|ck} $op2] && ![regexp -nocase {clk|ck} $op1]} {
                set clk_op $op2
                set en_op  $op1
            }
            return [dict create kind ICG \
                clock_output [dict get $a lhs] \
                clock_input  $clk_op \
                enable       $en_op]
        }
    }

    # --- BUF / INV: assign y = x  or  assign y = ~x ---
    foreach a $assigns {
        set rhs [dict get $a rhs]
        if {[regexp {^\s*(\w+)\s*$} $rhs -> in]} {
            return [dict create kind BUF \
                clock_output [dict get $a lhs] clock_input $in]
        }
        if {[regexp {^\s*~\s*(\w+)\s*$} $rhs -> in]} {
            return [dict create kind INV \
                clock_output [dict get $a lhs] clock_input $in]
        }
    }

    return [dict create kind UNKNOWN]
}

proc mcp::_ports_of_dir {ports dir} {
    set out {}
    foreach p $ports {
        lassign $p name pdir width
        if {$pdir eq $dir} { lappend out $name }
    }
    return $out
}

# Find which output port is driven (directly or via a reg) by `signal`.
proc mcp::_driven_output {signal assigns out_ports} {
    foreach a $assigns {
        if {[regexp "\\m${signal}\\M" [dict get $a rhs]]} {
            return [dict get $a lhs]
        }
    }
    if {[llength $out_ports] > 0} { return [lindex $out_ports 0] }
    return $signal
}

proc mcp::_icg_from_ports {in_ports out_ports assigns} {
    set clk_in [lindex $in_ports 0]
    set en    [lindex $in_ports 1]
    set out   [lindex $out_ports 0]
    foreach p $in_ports {
        if {[regexp -nocase {clk|ck} $p]} { set clk_in $p }
        if {[regexp -nocase {en}      $p]} { set en    $p }
    }
    return [dict create kind ICG \
        clock_input $clk_in enable $en clock_output $out]
}

proc mcp::_mux_from_ports {in_ports out_ports assigns} {
    # Assume clock inputs are the ones named clk*/ck*; sel is the one named sel/s.
    set clk_ins {}
    set sel ""
    foreach p $in_ports {
        if {[regexp -nocase {clk|ck} $p]} {
            lappend clk_ins $p
        } elseif {[regexp -nocase {sel|^s$} $p]} {
            set sel $p
        }
    }
    set out [lindex $out_ports 0]
    return [dict create kind MUX \
        clock_inputs $clk_ins select $sel clock_output $out]
}
