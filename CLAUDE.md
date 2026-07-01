# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common commands

```bash
# Run the analyzer on the canonical testcase
tclsh bin/mem_clk_path.tcl \
    -f testcase/filelist.f -top top -mem testcase/memlist.txt \
    -report out/report.txt -dot out/clock_tree.dot

# Full regression: runs the analyzer and diffs both outputs against testcase/expected/
tclsh tests/run_tests.tcl

# Render the DOT into out/clock_tree.png (styled PIL renderer, no Graphviz install needed)
python tests/render_tree.py

# Ad-hoc parser probe — dumps the parsed netlist for each testcase RTL file
tclsh tests/probe_parser.tcl
```

There is no single-test harness — `tests/run_tests.tcl` is the only regression. When a change alters the tool's output on purpose, regenerate the golden files by running the analyzer and copying `out/report.txt` and `out/clock_tree.dot` into `testcase/expected/`.

`tclsh` (8.5+) is required. `python` + `Pillow` is only needed for `render_tree.py`; the analyzer itself is Tcl-only.

## Architecture

The analyzer is a four-stage pipeline. Each stage is one file in `lib/`, and `bin/mem_clk_path.tcl` is a thin CLI that wires them together:

1. **Parse** (`lib/parser.tcl`) — regex-based Verilog/SV → in-memory netlist. For each `module ... endmodule` block it produces a dict with `ports`, `wires`, `regs`, `assigns`, `always_blocks`, and `instances`. The parser is deliberately lightweight — it handles the constructs listed in `README.md#Supported-syntax-caveats` (ANSI ports, `wire`/`reg` decls, single-line `assign`, single-level `always @(...) begin ... end`, named-port instantiations). Order of body extraction matters — always-blocks are pulled first, then assigns, then decls, then whatever remains is treated as instantiations.

2. **Detect** (`lib/detect.tcl`) — classifies each *module* by its clock-path role (`ROOT`, `BUF`, `INV`, `MUX`, `DIV`, `ICG`, `MEM`, or `UNKNOWN`) and stores it under `role` inside the module dict. Classification is by pattern-matching the module's assigns and always-blocks (behavioral ternary → MUX, `q <= ~q` → DIV/2, counter increment + `== N-1` → DIV/N, `clk & en` → ICG) plus configurable cell-name regexes (`-clk_root_pattern`, `-mux_cell_pattern`, `-icg_cell_pattern`). The role dict records which port(s) act as `clock_input`, `clock_output`, `select`, `enable`, and (for dividers) `ratio`.

3. **Trace** (`lib/trace.tcl`) — for each memory instance under `-top`, walks the clock pin backward one net at a time. Only single-level hierarchy is supported (all clock elements are instantiated directly under top). At each step: is the net a top-level input? (→ `ROOT_INPUT`). Is it driven by an instance output? (→ consult that module's `role`, follow `clock_input` upstream). Is it driven by an in-module `assign`? (→ `ASSIGN` node, terminate). A MUX has multiple clock inputs; the trace follows `clock_inputs[0]` (the `sel=0` branch) as the "primary" path — the other input still shows up in the DOT (see stage 4).

4. **Emit** (`lib/emit.tcl`) — writes the text report and the Graphviz DOT. For MUX nodes, `emit_dot` explicitly walks *all* clock inputs (not just the traced one) and creates a source node for any input that isn't already on the traced path — this is how `test_clk` appears as a second input into `sel_clk`. Shared upstream nodes (multiple memories sharing the same clock chain) are automatically deduped because nodes are keyed by their net name.

Data flow between stages: a single `all_modules` dict is threaded through `parse_verilog` (accumulates modules across files) → `classify_modules` (annotates each module with `role`) → `trace_all` (returns a list of trace dicts per memory) → `emit_report` / `emit_dot`.

## Testcase and golden-diff workflow

`testcase/rtl/*.v` defines the canonical topology `PLL → DIV/2 → MUX → ICG → SRAM×2`. It exercises every element category the tool recognizes, and `testcase/expected/` holds the exact byte-for-byte expected `report.txt` and `clock_tree.dot`. `tests/run_tests.tcl` fails on any diff — so when output formatting changes intentionally, both files must be regenerated and committed together with the code change.

`testcase/memlist.txt` is the source of truth for which module names are memories and which port is their clock (`SRAM_1RW CLK` in the testcase); anything not listed there is treated as a normal clock-path element.

## Rendering

`tests/render_tree.py` reads `out/clock_tree.dot` directly (its own tiny regex parser, not Graphviz). It uses a 3× supersample + Lanczos downsample for antialiasing. The `STYLES` map controls shape colors, and `SQUARE_SHAPES = {"hexagon","trapezium","house"}` — a user-requested override — forces clock mux / divider / ICG to render as red rounded-square blocks rather than the DOT-native shapes. Roots stay gold ellipses and memories stay purple box3d so the classes remain visually distinct.

The DOT file itself uses standard shape names, so `dot -Tpng out/clock_tree.dot -o out.png` renders it fine with system Graphviz too.
