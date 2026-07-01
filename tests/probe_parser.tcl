#!/usr/bin/env tclsh
# Ad-hoc parser probe. Prints what parse_verilog produced for the testcase.
set here [file dirname [info script]]
set root [file dirname $here]
source [file join $root lib util.tcl]
source [file join $root lib parser.tcl]

set files {
    testcase/rtl/pll_model.v
    testcase/rtl/clk_div2.v
    testcase/rtl/clk_mux.v
    testcase/rtl/icg.v
    testcase/rtl/sram_stub.v
    testcase/rtl/top.v
}

foreach f $files {
    puts "=== $f ==="
    set text [mcp::read_file [file join $root $f]]
    set mods [mcp::parse_verilog $text]
    dict for {name mod} $mods {
        puts "  module $name"
        puts "    ports:    [dict get $mod ports]"
        puts "    wires:    [dict get $mod wires]"
        puts "    regs:     [dict get $mod regs]"
        puts "    assigns:  [dict get $mod assigns]"
        puts "    always:   [dict get $mod always_blocks]"
        puts "    inst:     [dict get $mod instances]"
    }
}
