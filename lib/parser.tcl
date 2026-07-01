# lib/parser.tcl - Verilog/SV -> in-memory netlist (regex-based, lightweight).
#
# Supported subset (enough for the testcase and typical clock-path RTL):
#   - module <name> [#(...)] (<ansi_port_list>); ... endmodule
#   - wire/reg declarations, optional [msb:lsb]
#   - assign lhs = rhs;
#   - simple always @(...) begin ... end blocks (no nested begin/end)
#   - instantiations with named port maps: ModName inst (.p(n), ...);

namespace eval mcp {}

# Parse a whole file's text; return a dict: module_name -> module_dict.
proc mcp::parse_verilog {text} {
    set text [mcp::strip_comments $text]
    set out [dict create]
    set pos 0
    while {1} {
        if {![regexp -indices -start $pos {module\s+(\w+)} $text mrange nrange]} break
        set mod_start [lindex $mrange 0]
        set name [string range $text [lindex $nrange 0] [lindex $nrange 1]]
        set end_idx [string first "endmodule" $text $mod_start]
        if {$end_idx < 0} break
        set mod_text [string range $text $mod_start [expr {$end_idx - 1}]]
        set mod [mcp::parse_one_module $mod_text $name]
        if {[llength $mod] > 0} {
            dict set out $name $mod
        }
        set pos [expr {$end_idx + 9}]
    }
    return $out
}

proc mcp::parse_one_module {mod_text mod_name} {
    # Skip past optional `#( ... )` parameter list, then take the port list `( ... )`.
    set idx 0
    if {[regexp -indices -start $idx "module\\s+${mod_name}" $mod_text kw]} {
        set idx [expr {[lindex $kw 1] + 1}]
    }
    # Optional parameter block
    set rest [string range $mod_text $idx end]
    if {[regexp -indices {^\s*#\s*\(} $rest hashp]} {
        set hash_open [expr {$idx + [lindex $hashp 1]}]
        set hash_close [mcp::find_matching_paren $mod_text $hash_open]
        if {$hash_close < 0} { return {} }
        set idx [expr {$hash_close + 1}]
    }
    # Port list `(`
    set rest [string range $mod_text $idx end]
    if {![regexp -indices {^\s*\(} $rest popen]} { return {} }
    set port_open [expr {$idx + [lindex $popen 1]}]
    set port_close [mcp::find_matching_paren $mod_text $port_open]
    if {$port_close < 0} { return {} }
    set port_list_raw [string range $mod_text [expr {$port_open + 1}] [expr {$port_close - 1}]]

    # Body: after `);` to end
    set semi [string first ";" $mod_text $port_close]
    if {$semi < 0} { return {} }
    set body [string range $mod_text [expr {$semi + 1}] end]

    set ports [mcp::parse_port_list $port_list_raw]

    set always_blocks [mcp::extract_always_blocks body]
    set assigns       [mcp::extract_assigns body]
    set wires         [mcp::extract_decls body wire]
    set regs          [mcp::extract_decls body reg]
    # (input/output non-ANSI decls in body would go here; not needed for testcase)
    set instances     [mcp::extract_instances $body]

    return [dict create \
        name           $mod_name \
        ports          $ports \
        wires          $wires \
        regs           $regs \
        assigns        $assigns \
        always_blocks  $always_blocks \
        instances      $instances]
}

# Parse an ANSI port list. Direction propagates from left to right when omitted.
# Returns a list of {name direction width}.
proc mcp::parse_port_list {raw} {
    set entries [mcp::split_toplevel $raw ,]
    set ports {}
    set last_dir "input"
    foreach e $entries {
        set e [mcp::trim_ws $e]
        if {$e eq ""} continue
        set dir $last_dir
        if {[regexp {^(input|output|inout)\s+(.*)$} $e -> d rest]} {
            set dir $d
            set last_dir $d
            set e [mcp::trim_ws $rest]
        }
        # optional net type
        regsub {^(reg|wire|logic)\s+} $e "" e
        set width 1
        if {[regexp {^\[\s*(-?\d+)\s*:\s*(-?\d+)\s*\]\s*(.*)$} $e -> msb lsb rest]} {
            set width [expr {abs($msb - $lsb) + 1}]
            set e [mcp::trim_ws $rest]
        }
        set name [mcp::trim_ws $e]
        if {$name eq ""} continue
        lappend ports [list $name $dir $width]
    }
    return $ports
}

# Extract `always @(sens) begin ... end` (and single-statement variants) from body.
# Modifies body by removing them.
proc mcp::extract_always_blocks {body_var} {
    upvar $body_var body
    set blocks {}
    set pat_beginend {(?s)always\s*@\s*\(([^)]*)\)\s*begin\s+(.*?)\s+end}
    while {[regexp $pat_beginend $body full sens body_stmts]} {
        lappend blocks [dict create sensitivity $sens body $body_stmts]
        regsub $pat_beginend $body " " body
    }
    set pat_single {always\s*@\s*\(([^)]*)\)\s*([^;]+;)}
    while {[regexp $pat_single $body full sens single]} {
        lappend blocks [dict create sensitivity $sens body $single]
        regsub $pat_single $body " " body
    }
    return $blocks
}

# Extract `assign lhs = rhs;` statements. Modifies body.
proc mcp::extract_assigns {body_var} {
    upvar $body_var body
    set assigns {}
    set pat {assign\s+([^\s=]+)\s*=\s*([^;]+);}
    foreach {full lhs rhs} [regexp -all -inline $pat $body] {
        lappend assigns [dict create lhs [mcp::trim_ws $lhs] rhs [mcp::trim_ws $rhs]]
    }
    regsub -all $pat $body " " body
    return $assigns
}

# Extract `<kind> [W:0] name, name, ...;` declarations. Modifies body.
proc mcp::extract_decls {body_var kind} {
    upvar $body_var body
    set out {}
    set pat "${kind}\\s+(?:\\\[\\s*(-?\\d+)\\s*:\\s*(-?\\d+)\\s*\\\])?\\s*(\[^;\]+);"
    foreach {full msb lsb names} [regexp -all -inline $pat $body] {
        set width 1
        if {$msb ne ""} {
            set width [expr {abs($msb - $lsb) + 1}]
        }
        foreach n [split $names ,] {
            set n [mcp::trim_ws $n]
            if {$n ne ""} {
                lappend out [list $n $width]
            }
        }
    }
    regsub -all $pat $body " " body
    return $out
}

# Extract instantiations from the remaining body.
# Body-portion assumed already stripped of assigns, decls, and always blocks.
proc mcp::extract_instances {body} {
    set instances {}
    set len [string length $body]
    set pos 0
    set keywords {module endmodule wire reg input output inout assign always \
                  initial parameter localparam if else case endcase begin end \
                  generate endgenerate function endfunction task endtask}
    while {$pos < $len} {
        if {![regexp -indices -start $pos {(\w+)\s+(\w+)\s*\(} $body full modrange instrange]} break
        set mod_name  [string range $body [lindex $modrange 0] [lindex $modrange 1]]
        set inst_name [string range $body [lindex $instrange 0] [lindex $instrange 1]]
        set open_idx  [lindex $full 1]
        if {$mod_name in $keywords} {
            set pos [expr {[lindex $modrange 1] + 1}]
            continue
        }
        set close_idx [mcp::find_matching_paren $body $open_idx]
        if {$close_idx < 0} break
        set port_map_raw [string range $body [expr {$open_idx + 1}] [expr {$close_idx - 1}]]
        set port_map [mcp::parse_port_map $port_map_raw]
        set semi [string first ";" $body $close_idx]
        if {$semi < 0} { set semi $close_idx }
        lappend instances [dict create \
            module   $mod_name \
            inst     $inst_name \
            port_map $port_map]
        set pos [expr {$semi + 1}]
    }
    return $instances
}

# Parse `.port(net), .port(net), ...` into a list of {port net}.
proc mcp::parse_port_map {raw} {
    set out {}
    foreach e [mcp::split_toplevel $raw ,] {
        set e [mcp::trim_ws $e]
        if {$e eq ""} continue
        if {[regexp {^\.(\w+)\s*\((.*)\)$} $e -> port net]} {
            lappend out [list $port [mcp::trim_ws $net]]
        } else {
            lappend out [list "" $e]
        }
    }
    return $out
}
