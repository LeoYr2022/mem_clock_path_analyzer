# lib/trace.tcl - walk each memory instance's clock pin back to a root,
# crossing module hierarchy.
#
# A "scope" is the hierarchical path of instances from top down to the module
# currently being traced. Each frame is {inst_name module_name port_map};
# the first frame is {"" <top> ""}. Tracing a net within a module can:
#   - stop at a clock ROOT / top-level input,
#   - follow a clock element (DIV/MUX/ICG/BUF/INV) upstream in the same scope,
#   - GO UP through a module input port into the parent scope, or
#   - DESCEND into a plain hierarchical submodule that drives the net.

namespace eval mcp {}

# Human-readable path of the *module* at the top of a scope (its instance
# chain). Empty instance names (the top frame) are dropped; "top" if none.
proc mcp::_scope_path {scope} {
    set parts {}
    foreach frame $scope {
        set iname [lindex $frame 0]
        if {$iname ne ""} { lappend parts $iname }
    }
    if {[llength $parts] == 0} { return "top" }
    return [join $parts /]
}

# Produce a list of trace dicts, one per memory instance found anywhere under
# `top_name`.
proc mcp::trace_all {modules top_name mem_modules} {
    if {![dict exists $modules $top_name]} {
        error "top module '$top_name' not present in parsed modules"
    }
    set mems {}
    set top_scope [list [list "" $top_name ""]]
    mcp::_collect_memories $modules $top_scope $mem_modules mems
    set traces {}
    foreach m $mems {
        set scope   [dict get $m scope]
        set clk_net [dict get $m clk_net]
        set path    [mcp::trace_net $modules $scope $clk_net {}]
        lappend traces [dict create \
            mem_inst     [dict get $m hier] \
            mem_module   [dict get $m module] \
            mem_clk_port [dict get $m clk_port] \
            mem_clk_net  $clk_net \
            path         $path]
    }
    return $traces
}

# Recursively find memory instances. For each, record the *containing* module
# scope and the net wired to its clock port (traced from the parent's view).
proc mcp::_collect_memories {modules scope mem_modules acc_var} {
    upvar $acc_var acc
    set mod_name [lindex [lindex $scope end] 1]
    if {![dict exists $modules $mod_name]} return
    set mod [dict get $modules $mod_name]
    foreach inst [dict get $mod instances] {
        set imod  [dict get $inst module]
        set iname [dict get $inst inst]
        if {[dict exists $mem_modules $imod]} {
            set clk_port [dict get $mem_modules $imod]
            set clk_net  [mcp::find_net_for_port $inst $clk_port]
            set base [mcp::_scope_path $scope]
            set hier [expr {$base eq "top" ? $iname : "$base/$iname"}]
            lappend acc [dict create \
                module   $imod \
                inst     $iname \
                hier     $hier \
                clk_port $clk_port \
                clk_net  $clk_net \
                scope    $scope]
        } elseif {[dict exists $modules $imod]} {
            set child [concat $scope \
                [list [list $iname $imod [dict get $inst port_map]]]]
            mcp::_collect_memories $modules $child $mem_modules acc
        }
    }
}

# Trace `net` in the module at the top of `scope` back toward a root.
# Returns a list of node dicts ordered root -> sink.
proc mcp::trace_net {modules scope net visited} {
    set frame   [lindex $scope end]
    set cur_mod [lindex $frame 1]
    set depth   [llength $scope]
    set path    [mcp::_scope_path $scope]
    set key     "$depth:$cur_mod:$net"
    if {[lsearch $visited $key] >= 0} {
        return [list [dict create kind UNKNOWN net $net module $cur_mod \
            path $path note "cycle detected"]]
    }
    lappend visited $key
    set mod [dict get $modules $cur_mod]

    # (a) net driven by an instance output inside cur_mod
    foreach inst [dict get $mod instances] {
        set imod [dict get $inst module]
        if {![dict exists $modules $imod]} continue
        set imod_dict [dict get $modules $imod]
        set role [expr {[dict exists $imod_dict role] ? \
            [dict get $imod_dict role] : [dict create kind UNKNOWN]}]
        foreach pm [dict get $inst port_map] {
            lassign $pm p n
            if {$n ne $net} continue
            if {[mcp::_port_direction $imod_dict $p] ne "output"} continue
            set kind [dict get $role kind]
            if {$kind in {ROOT DIV MUX ICG BUF INV}} {
                set node [dict create \
                    kind $kind net $net inst [dict get $inst inst] \
                    module $imod role $role \
                    port_map [dict get $inst port_map] path $path]
                if {$kind eq "ROOT"} { return [list $node] }
                if {$kind eq "MUX"} {
                    set up_port [lindex [dict get $role clock_inputs] 0]
                } else {
                    set up_port [dict get $role clock_input]
                }
                set upstream [mcp::find_net_for_port $inst $up_port]
                if {$upstream eq ""} { return [list $node] }
                set prev [mcp::trace_net $modules $scope $upstream $visited]
                return [concat $prev [list $node]]
            } elseif {$kind eq "MEM"} {
                return [list [dict create kind UNKNOWN net $net module $imod \
                    path $path note "driven by memory output"]]
            } else {
                # Plain hierarchical submodule: descend and trace what drives
                # its output port `p` internally.
                set child [concat $scope \
                    [list [list [dict get $inst inst] $imod \
                        [dict get $inst port_map]]]]
                return [mcp::trace_net $modules $child $p $visited]
            }
        }
    }

    # (b) net driven by an assign inside cur_mod
    foreach a [dict get $mod assigns] {
        if {[dict get $a lhs] eq $net} {
            return [list [dict create kind ASSIGN net $net \
                rhs [dict get $a rhs] module $cur_mod path $path]]
        }
    }

    # (c) net is an input port of cur_mod
    foreach p [dict get $mod ports] {
        lassign $p pname pdir pwidth
        if {$pname eq $net && $pdir eq "input"} {
            if {$depth <= 1} {
                return [list [dict create kind ROOT_INPUT net $net \
                    inst "(top-input)" module $cur_mod path $path]]
            }
            # Go up: map this port to the parent net via the frame's port_map.
            set parent_net ""
            foreach pm [lindex $frame 2] {
                lassign $pm pp nn
                if {$pp eq $net} { set parent_net $nn; break }
            }
            if {$parent_net eq ""} {
                return [list [dict create kind UNKNOWN net $net \
                    module $cur_mod path $path note "unconnected up-port"]]
            }
            return [mcp::trace_net $modules \
                [lrange $scope 0 end-1] $parent_net $visited]
        }
    }

    # (d) no driver found in the visible scope
    return [list [dict create kind UNKNOWN net $net module $cur_mod \
        path $path note "no driver found"]]
}

proc mcp::find_net_for_port {inst port} {
    foreach pm [dict get $inst port_map] {
        lassign $pm p n
        if {$p eq $port} { return $n }
    }
    return ""
}

proc mcp::_port_direction {mod_dict port_name} {
    foreach p [dict get $mod_dict ports] {
        lassign $p n d w
        if {$n eq $port_name} { return $d }
    }
    return ""
}
