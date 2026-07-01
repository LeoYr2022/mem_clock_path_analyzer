# mem_clk_path_analyzer

Standalone Tcl tool that parses Verilog/SystemVerilog RTL, traces the clock
path feeding each memory instance back to its root clock source, and emits
both a human-readable report and a Graphviz DOT diagram of the clock tree.

No EDA tool licenses required — just `tclsh` (8.5+).

## Why

Memory macros in an SoC often receive clocks that have been muxed, divided,
and gated inside the RTL before reaching the memory's clock pin. When
debugging timing, power, or CDC issues, you need to know — for every memory
instance — the exact chain of elements between the root clock and the memory,
and the resulting effective divide ratio and mux/enable conditions.

## Repo layout

```
bin/mem_clk_path.tcl       CLI entry point
lib/util.tcl               regex/file helpers
lib/parser.tcl             Verilog/SV -> in-memory netlist
lib/detect.tcl             classify a module by clock-path role
lib/trace.tcl              backward trace from mem CLK pin to root
lib/emit.tcl               text report + Graphviz DOT writers
testcase/rtl/*.v           canonical RTL: PLL -> DIV/2 -> MUX -> ICG -> SRAM x2
testcase/filelist.f        newline-separated list of RTL files
testcase/memlist.txt       memory module names + clock port
testcase/expected/         golden outputs the regression test diffs against
tests/run_tests.tcl        runs the tool on testcase/ and diffs vs expected/
tests/render_tree.py       renders the DOT into a styled PNG using PIL only
tests/render_drawio.py     converts the DOT into an editable draw.io file
tests/probe_parser.tcl     ad-hoc parser dump (dev aid)
```

## Usage

```
tclsh bin/mem_clk_path.tcl \
    -f      testcase/filelist.f \
    -top    top \
    -mem    testcase/memlist.txt \
    -report out/report.txt \
    -dot    out/clock_tree.dot
```

Optional flags:

| Flag                  | Default              | Purpose                                     |
|-----------------------|----------------------|---------------------------------------------|
| `-clk_root_pattern`   | `(?i)pll\|dll`       | Module names matched here become ROOTs.     |
| `-mux_cell_pattern`   | `(?i)CKMUX\|CLKMUX`  | Cell-name pattern for gate-level mux cells. |
| `-icg_cell_pattern`   | `(?i)ICG\|CKGT\|CLKGATE` | Cell-name pattern for ICG cells.        |

Exits non-zero if a memory clock path contains any node the tool cannot
classify. Add a regex or extend `lib/detect.tcl` when this happens.

## What the tool recognizes

| Element         | Pattern recognized                                                                    |
|-----------------|----------------------------------------------------------------------------------------|
| ROOT            | Module name matches `-clk_root_pattern`; or top-level `input` port on the traced net.  |
| BUF / INV       | `assign y = x;` or `assign y = ~x;`.                                                   |
| MUX             | `assign y = sel ? b : a;`, or instance whose module name matches `-mux_cell_pattern`.  |
| DIV /2          | `always @(posedge <clk>) q <= ~q;`.                                                    |
| DIV /N          | Counter-increment pattern with `== N-1` comparator.                                    |
| ICG / gated clk | `assign g = clk & en;` (with optional `~` on `en`); or `-icg_cell_pattern` instance.   |

Anything else on the traced path is reported as `[UNKNOWN]` and causes a
non-zero exit.

## Testcase clock tree

```
   ref_clk --> pll_model(u_pll) --pll_clk--> clk_div2(u_div) --clk_div2--> clk_mux(u_mux) --sel_clk--> icg(u_icg) --gated_clk--> SRAM_1RW(u_sram_a).CLK
                                                                              ^                                              \--> SRAM_1RW(u_sram_b).CLK
                                                                     test_clk-|
                                                              sel = test_en
                                                                                                      en = mem_en
```

Expected report (excerpt):

```
Memory: u_sram_a  (SRAM_1RW.CLK)
  Path from root:
    [ROOT]       pll_clk         (module: pll_model, inst: u_pll)
    [DIV /2]     clk_div2        (module: clk_div2, inst: u_div)
    [MUX]        sel_clk         (module: clk_mux, inst: u_mux)  sel=test_en  inputs: clk_div2, test_clk
    [ICG]        gated_clk       (module: icg, inst: u_icg)  en=mem_en
    [PIN]        u_sram_a.CLK
  Effective divide ratio: 2
```

## Regression test

```
tclsh tests/run_tests.tcl
```

Runs the analyzer, diffs `report.txt` + `clock_tree.dot` against
`testcase/expected/`. If `dot` is on `PATH`, it also renders
`out/clock_tree.png` for eyeball verification.

## Rendering the DOT as a picture

The analyzer writes `out/clock_tree.dot` — a plain Graphviz DOT file.
There are three supported ways to turn it into a picture.

### Option 1 — `tests/render_tree.py` (no external install)

Uses Python + PIL only. Produces the styled PNG shown in this repo
(red rounded-square blocks for clock mux / divider / gate, gold
doublecircle for roots, purple box3d for memories, title bar and legend).

```
python tests/render_tree.py
# -> writes out/clock_tree.png  (~1510x395 px)
```

Requires just `Pillow` (`pip install Pillow`). The script reads
`out/clock_tree.dot` and always writes `out/clock_tree.png`.

### Option 2 — Graphviz `dot`

The DOT file is standard-conformant, so you can render it with any
Graphviz version:

```
dot -Tpng out/clock_tree.dot -o out/clock_tree.png
dot -Tsvg out/clock_tree.dot -o out/clock_tree.svg
dot -Tpdf out/clock_tree.dot -o out/clock_tree.pdf
```

Installing Graphviz:

| Platform      | Command                                                    |
|---------------|------------------------------------------------------------|
| Windows       | `winget install Graphviz.Graphviz` (or `choco install graphviz`) |
| macOS         | `brew install graphviz`                                    |
| Debian/Ubuntu | `sudo apt install graphviz`                                |
| Fedora/RHEL   | `sudo dnf install graphviz`                                |

`tests/run_tests.tcl` automatically renders a PNG via `dot -Tpng`
when it finds `dot` on `PATH` — otherwise it prints a skip note and
the test still passes.

### Option 3 — draw.io / diagrams.net

`tests/render_drawio.py` converts the DOT into an editable draw.io file
(no install beyond Python — same shape/color scheme as the PNG):

```
python tests/render_drawio.py
# -> writes out/clock_tree.drawio
```

Then open the file in one of:

- **draw.io Desktop** — File → Open, pick `out/clock_tree.drawio`.
- **diagrams.net (web)** — go to <https://app.diagrams.net>, choose
  *Open Existing Diagram* → *Device*, pick the `.drawio` file.
- **VS Code** — install the *Draw.io Integration* extension
  (`hediet.vscode-drawio`) and open the file directly.

Once opened you can re-arrange nodes, tweak colors, and export to
PNG / SVG / PDF via *File → Export as…*.

## Supported-syntax caveats

The parser is regex-based and intentionally minimal — it handles the
constructs used in the testcase and typical clock-path RTL:

- ANSI-style port lists; simple `[msb:lsb]` widths.
- `wire`/`reg` decls (with optional width).
- `assign lhs = rhs;` — single-line RHS.
- `always @(sensitivity) begin ... end` — one level of `begin/end`, no nested blocks.
- Named-port instantiations `.port(net)`; optional `#(...)` parameter block.

It does **not** support: full SystemVerilog packages/interfaces, generate
loops with computed indices, macro preprocessing (run `verilator -E` or
similar first if you need it), or multi-level hierarchical clocking (all
clock elements should be instantiated directly under the top module).

The scope matches the tool's purpose: a fast, license-free audit of the
memory clock tree at RTL bring-up. For anything beyond that, use PrimeTime
or Genus.
