# lib/trace.tcl - walk each memory instance's clock pin back to a root.
#
# Single-hierarchy tracing (all clock elements instantiated directly under `top`),
# which matches the testcase and is the common case for memory clock trees.

namespace eval mcp {}

# Produce a list of trace dicts, one per memory instance in `top_name`.
proc mcp::trace_all {modules top_name mem_modules} {
    if {![dict exists $modules $top_name]} {
        error "top module '$top_name' not present in parsed modules"
    }
    set top [dict get $modules $top_name]
    set traces {}
    foreach inst [dict get $top instances] {
        set mod_name [dict get $inst module]
        if {![dict exists $mem_modules $mod_name]} continue
        set clk_port [dict get $mem_modules $mod_name]
        set clk_net  [mcp::find_net_for_port $inst $clk_port]
        set path     [mcp::trace_net $modules $top_name $clk_net {}]
        lappend traces [dict create \
            mem_inst     [dict get $inst inst] \
            mem_module   $mod_name \
            mem_clk_port $clk_port \
            mem_clk_net  $clk_net \
            path         $path]
    }
    return $traces
}

# Recursively trace `net` back to a root within `mod_name`.
# Returns a list of node dicts ordered root -> sink.
proc mcp::trace_net {modules mod_name net visited} {
    set key "$mod_name:$net"
    if {[lsearch $visited $key] >= 0} {
        return [list [dict create kind UNKNOWN net $net module $mod_name \
            note "cycle detected"]]
    }
    lappend visited $key

    set mod [dict get $modules $mod_name]

    # (a) net is a top-level input port of this module -> external root
    foreach p [dict get $mod ports] {
        lassign $p pname pdir pwidth
        if {$pname eq $net && $pdir eq "input"} {
            return [list [dict create \
                kind ROOT_INPUT \
                net  $net \
                inst "(top-input)" \
                module $mod_name]]
        }
    }

    # (b) net driven by an instance's output port
    foreach inst [dict get $mod instances] {
        set inst_mod_name [dict get $inst module]
        if {![dict exists $modules $inst_mod_name]} continue
        set inst_mod [dict get $modules $inst_mod_name]
        set role [expr {[dict exists $inst_mod role] ? [dict get $inst_mod role] : [dict create kind UNKNOWN]}]
        foreach pm [dict get $inst port_map] {
            lassign $pm p n
            if {$n ne $net} continue
            set pdir [mcp::_port_direction $inst_mod $p]
            if {$pdir ne "output"} continue
            # Build the node for this element
            set node [dict create \
                kind     [dict get $role kind] \
                net      $net \
                inst     [dict get $inst inst] \
                module   $inst_mod_name \
                role     $role \
                port_map [dict get $inst port_map]]
            # Decide what to trace next
            set upstream ""
            switch -- [dict get $role kind] {
                ROOT {
                    return [list $node]
                }
                MUX {
                    set primary_port [lindex [dict get $role clock_inputs] 0]
                    set upstream [mcp::find_net_for_port $inst $primary_port]
                }
                DIV -
                ICG -
                BUF -
                INV {
                    set upstream [mcp::find_net_for_port $inst [dict get $role clock_input]]
                }
                MEM -
                UNKNOWN -
                default {
                    return [list $node]
                }
            }
            if {$upstream eq ""} {
                return [list $node]
            }
            set prev [mcp::trace_net $modules $mod_name $upstream $visited]
            return [concat $prev [list $node]]
        }
    }

    # (c) net driven by an assign inside this module
    foreach a [dict get $mod assigns] {
        if {[dict get $a lhs] eq $net} {
            return [list [dict create \
                kind ASSIGN \
                net  $net \
                rhs  [dict get $a rhs] \
                module $mod_name]]
        }
    }

    # (d) nothing drives it in the visible scope
    return [list [dict create \
        kind UNKNOWN net $net module $mod_name note "no driver found"]]
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
