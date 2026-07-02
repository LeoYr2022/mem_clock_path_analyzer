# lib/emit.tcl - text report + Graphviz DOT writers.

namespace eval mcp {}

proc mcp::emit_report {traces report_path} {
    set out ""
    append out "RTL Memory Clock-Path Analyzer Report\n"
    append out "=====================================\n\n"
    append out "Memories traced: [llength $traces]\n\n"
    foreach t $traces {
        set mem_inst [dict get $t mem_inst]
        set mem_mod  [dict get $t mem_module]
        set clk_port [dict get $t mem_clk_port]
        append out "Memory: $mem_inst  ($mem_mod.$clk_port)\n"
        append out "  Path from root:\n"
        set ratio 1
        foreach node [dict get $t path] {
            set kind [dict get $node kind]
            set net  [expr {[dict exists $node net] ? [dict get $node net] : ""}]
            switch -- $kind {
                ROOT_INPUT {
                    append out [format "    %-12s %-14s  (top-level input)\n" \
                        "\[ROOT_IN\]" $net]
                }
                ROOT {
                    append out [format "    %-12s %-14s  (module: %s, inst: %s)\n" \
                        "\[ROOT\]" $net [dict get $node module] [dict get $node inst]]
                }
                BUF {
                    append out [format "    %-12s %-14s  (module: %s, inst: %s)\n" \
                        "\[BUF\]" $net [dict get $node module] [dict get $node inst]]
                }
                INV {
                    append out [format "    %-12s %-14s  (module: %s, inst: %s)\n" \
                        "\[INV\]" $net [dict get $node module] [dict get $node inst]]
                }
                DIV {
                    set role [dict get $node role]
                    set r [dict get $role ratio]
                    if {$r > 0} { set ratio [expr {$ratio * $r}] }
                    append out [format "    %-12s %-14s  (module: %s, inst: %s)\n" \
                        "\[DIV /$r\]" $net [dict get $node module] [dict get $node inst]]
                }
                MUX {
                    set role [dict get $node role]
                    set sel_port [dict get $role select]
                    set clk_ins  [dict get $role clock_inputs]
                    set inst_pmap [dict get $node port_map]
                    set sel_net ""
                    set input_nets {}
                    foreach pm $inst_pmap {
                        lassign $pm pp nn
                        if {$pp eq $sel_port} { set sel_net $nn }
                        if {[lsearch $clk_ins $pp] >= 0} { lappend input_nets $nn }
                    }
                    append out [format "    %-12s %-14s  (module: %s, inst: %s)  sel=%s  inputs: %s\n" \
                        "\[MUX\]" $net [dict get $node module] [dict get $node inst] \
                        $sel_net [join $input_nets ", "]]
                }
                ICG {
                    set role [dict get $node role]
                    set en_port [dict get $role enable]
                    set inst_pmap [dict get $node port_map]
                    set en_net ""
                    foreach pm $inst_pmap {
                        lassign $pm pp nn
                        if {$pp eq $en_port} { set en_net $nn }
                    }
                    append out [format "    %-12s %-14s  (module: %s, inst: %s)  en=%s\n" \
                        "\[ICG\]" $net [dict get $node module] [dict get $node inst] $en_net]
                }
                ASSIGN {
                    append out [format "    %-12s %-14s  <= %s\n" \
                        "\[ASSIGN\]" $net [dict get $node rhs]]
                }
                UNKNOWN {
                    set note [expr {[dict exists $node note] ? [dict get $node note] : "cannot classify"}]
                    append out [format "    %-12s %-14s  <%s>\n" \
                        "\[UNKNOWN\]" $net $note]
                }
                default {
                    append out [format "    %-12s %-14s\n" "\[$kind\]" $net]
                }
            }
        }
        append out [format "    %-12s %s.%s\n" "\[PIN\]" $mem_inst $clk_port]
        append out "  Effective divide ratio: $ratio\n\n"
    }
    mcp::write_file $report_path $out
}

proc mcp::emit_dot {traces dot_path} {
    set out "digraph clock_tree {\n"
    append out "  rankdir=LR;\n"
    append out "  node \[fontname=\"Helvetica\"\];\n"
    set nodes [dict create]
    set edges [dict create]
    foreach t $traces {
        set mem_inst [dict get $t mem_inst]
        set mem_mod  [dict get $t mem_module]
        set clk_port [dict get $t mem_clk_port]
        set mem_id   "mem_${mem_inst}"
        dict set nodes $mem_id [list shape box3d label "${mem_mod}\\n${mem_inst}"]
        set prev_id ""
        foreach node [dict get $t path] {
            set kind [dict get $node kind]
            set net  [expr {[dict exists $node net] ? [dict get $node net] : "?"}]
            set nscope [expr {[dict exists $node path] ? [dict get $node path] : "top"}]
            set id "n_[mcp::_sanitize ${nscope}_$net]"
            switch -- $kind {
                ROOT_INPUT {
                    set shape doublecircle
                    set label "$net\\n(top input)"
                }
                ROOT {
                    set shape doublecircle
                    set label "$net\\n(root)"
                }
                DIV {
                    set r [dict get [dict get $node role] ratio]
                    set shape hexagon
                    set label "$net\\ndiv /$r"
                }
                MUX {
                    set shape trapezium
                    set label "$net\\nMUX"
                }
                ICG {
                    set shape house
                    set label "$net\\nICG"
                }
                BUF {
                    set shape ellipse
                    set label "$net\\nbuf"
                }
                INV {
                    set shape invtriangle
                    set label "$net\\ninv"
                }
                ASSIGN {
                    set shape ellipse
                    set label "$net\\nassign"
                }
                UNKNOWN {
                    set shape octagon
                    set label "$net\\nunknown"
                }
                default {
                    set shape ellipse
                    set label $net
                }
            }
            dict set nodes $id [list shape $shape label $label]
            # For MUX nodes, also emit edges from every clock input, not just
            # the primary one on the traced path. The alternate input(s) show
            # up as source nodes (e.g. a top-level clock port).
            if {$kind eq "MUX"} {
                set role [dict get $node role]
                set clk_ins [dict get $role clock_inputs]
                set inst_pmap [dict get $node port_map]
                foreach in_port $clk_ins {
                    set in_net ""
                    foreach pm $inst_pmap {
                        lassign $pm pp nn
                        if {$pp eq $in_port} { set in_net $nn; break }
                    }
                    if {$in_net eq ""} continue
                    set in_id "n_[mcp::_sanitize ${nscope}_$in_net]"
                    if {![dict exists $nodes $in_id]} {
                        dict set nodes $in_id \
                            [list shape doublecircle \
                                  label "$in_net\\n(top input)"]
                    }
                    dict set edges "$in_id -> $id" 1
                }
            }
            if {$prev_id ne ""} {
                dict set edges "$prev_id -> $id" 1
            }
            set prev_id $id
        }
        if {$prev_id ne ""} {
            dict set edges "$prev_id -> $mem_id" 1
        }
    }
    dict for {id attrs} $nodes {
        set shape [dict get $attrs shape]
        set label [dict get $attrs label]
        append out "  \"$id\" \[shape=$shape, label=\"$label\"\];\n"
    }
    dict for {edge _} $edges {
        set parts [split $edge " "]
        set a [lindex $parts 0]
        set b [lindex $parts 2]
        append out "  \"$a\" -> \"$b\";\n"
    }
    append out "}\n"
    mcp::write_file $dot_path $out
}

proc mcp::_sanitize {s} {
    return [string map {. _ - _ : _ / _ \\ _} $s]
}
