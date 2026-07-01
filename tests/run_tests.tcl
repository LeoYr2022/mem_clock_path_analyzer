#!/usr/bin/env tclsh
# tests/run_tests.tcl - end-to-end regression test.
#
# Runs bin/mem_clk_path.tcl against testcase/, then diffs the generated
# report.txt and clock_tree.dot against testcase/expected/.

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]

set tool     [file join $root bin  mem_clk_path.tcl]
set filelist [file join $root testcase filelist.f]
set memlist  [file join $root testcase memlist.txt]
set expected_dir [file join $root testcase expected]
set actual_dir   [file join $root out]

set report_out [file join $actual_dir report.txt]
set dot_out    [file join $actual_dir clock_tree.dot]

puts "==> Running analyzer on testcase/"
set cmd [list tclsh $tool -f $filelist -top top -mem $memlist \
    -report $report_out -dot $dot_out]
if {[catch {exec {*}$cmd} out]} {
    puts stderr "TOOL FAILED:"
    puts stderr $out
    exit 1
}
puts $out

proc slurp {path} {
    set fh [open $path r]
    set data [read $fh]
    close $fh
    return $data
}

proc diff_files {label a b} {
    set aa [slurp $a]
    set bb [slurp $b]
    if {$aa eq $bb} {
        puts "  PASS: $label matches expected"
        return 1
    }
    puts stderr "  FAIL: $label differs from expected"
    puts stderr "    expected: $a"
    puts stderr "    actual  : $b"
    # Show a short unified-ish diff
    set alines [split $aa \n]
    set blines [split $bb \n]
    set n [expr {max([llength $alines], [llength $blines])}]
    for {set i 0} {$i < $n} {incr i} {
        set al [lindex $alines $i]
        set bl [lindex $blines $i]
        if {$al ne $bl} {
            puts stderr "    line [expr {$i+1}]:"
            puts stderr "      -EXP: $al"
            puts stderr "      +GOT: $bl"
        }
    }
    return 0
}

puts "\n==> Diffing generated outputs vs testcase/expected/"
set ok 1
if {![diff_files report.txt \
        [file join $expected_dir report.txt] $report_out]} { set ok 0 }
if {![diff_files clock_tree.dot \
        [file join $expected_dir clock_tree.dot] $dot_out]} { set ok 0 }

if {!$ok} { exit 1 }

puts "\n==> Optional: rendering DOT to PNG (if 'dot' is on PATH)"
if {[catch {exec dot -Tpng $dot_out -o [file join $actual_dir clock_tree.png]} err]} {
    puts "  (skipped: $err)"
} else {
    puts "  wrote [file join $actual_dir clock_tree.png]"
}

puts "\nALL TESTS PASSED"
exit 0
