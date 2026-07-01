"""Render out/clock_tree.dot into a draw.io / diagrams.net file.

Emits out/clock_tree.drawio as valid mxGraphModel XML. The file can be
opened in the draw.io desktop app or at diagrams.net directly — no
Graphviz install needed.

Node shapes/colors match tests/render_tree.py:
    doublecircle  -> gold ellipse (root / top input)
    hexagon/trapezium/house  -> red rounded rectangle (div, mux, icg)
    box3d         -> purple 3D cube (memory)
    others        -> plain rectangle
"""
from __future__ import annotations

import re
import sys
from collections import defaultdict, deque
from pathlib import Path
from xml.sax.saxutils import escape

NODE_RE = re.compile(r'"([^"]+)"\s*\[shape=(\w+),\s*label="([^"]+)"\];')
EDGE_RE = re.compile(r'"([^"]+)"\s*->\s*"([^"]+)";')

# --- Palette (matches render_tree.py) --------------------------------------
STYLES = {
    "doublecircle":
        "ellipse;whiteSpace=wrap;html=1;fillColor=#F6C86A;strokeColor=#8A5A00;"
        "fontSize=13;fontStyle=1;",
    "hexagon":  # divider
        "rounded=1;whiteSpace=wrap;html=1;fillColor=#E06666;strokeColor=#7B0F0F;"
        "fontColor=#FFFFFF;fontSize=13;fontStyle=1;arcSize=15;",
    "trapezium":  # mux
        "rounded=1;whiteSpace=wrap;html=1;fillColor=#E06666;strokeColor=#7B0F0F;"
        "fontColor=#FFFFFF;fontSize=13;fontStyle=1;arcSize=15;",
    "house":  # icg
        "rounded=1;whiteSpace=wrap;html=1;fillColor=#E06666;strokeColor=#7B0F0F;"
        "fontColor=#FFFFFF;fontSize=13;fontStyle=1;arcSize=15;",
    "box3d":  # memory
        "shape=cube;whiteSpace=wrap;html=1;boundedLbl=1;backgroundOutline=1;"
        "darkOpacity=0.05;fillColor=#C0B3E1;strokeColor=#4B3C88;fontSize=13;fontStyle=1;",
    "octagon":
        "shape=step;perimeter=stepPerimeter;whiteSpace=wrap;html=1;"
        "fillColor=#E27878;strokeColor=#7B0F0F;fontSize=13;",
    "ellipse":
        "ellipse;whiteSpace=wrap;html=1;fillColor=#E3E3E3;strokeColor=#555555;fontSize=13;",
}
DEFAULT_STYLE = ("rounded=0;whiteSpace=wrap;html=1;fillColor=#EEEEEE;"
                 "strokeColor=#666666;fontSize=13;")

EDGE_STYLE = ("edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;"
              "jettySize=auto;html=1;strokeColor=#2C3A45;strokeWidth=2;"
              "endArrow=block;endFill=1;endSize=8;")

NODE_W = 160
NODE_H = 70
COL_GAP = 120
ROW_GAP = 40
MARGIN_X = 40
MARGIN_Y = 40


def parse_dot(text: str):
    nodes = {}
    for nid, shape, label in NODE_RE.findall(text):
        nodes[nid] = {"shape": shape, "label": label.replace("\\n", "\n")}
    edges = EDGE_RE.findall(text)
    return nodes, edges


def graph_layers(nodes, edges):
    preds = defaultdict(set)
    succs = defaultdict(set)
    for a, b in edges:
        preds[b].add(a)
        succs[a].add(b)
    layer = {n: 0 for n in nodes if not preds[n]}
    q = deque(layer.keys())
    while q:
        n = q.popleft()
        for m in succs[n]:
            proposed = layer[n] + 1
            if proposed > layer.get(m, -1):
                layer[m] = proposed
                q.append(m)
    for n in nodes:
        layer.setdefault(n, 0)
    # Pull sources forward next to their consumer to avoid long spans.
    changed = True
    while changed:
        changed = False
        for n in nodes:
            if preds[n] or not succs[n]:
                continue
            desired = min(layer[m] for m in succs[n]) - 1
            if desired > layer[n]:
                layer[n] = desired
                changed = True
    return layer


def compute_positions(nodes, layer):
    by_layer = defaultdict(list)
    for n, l in layer.items():
        by_layer[l].append(n)
    for l in by_layer:
        by_layer[l].sort()
    max_col_count = max(len(v) for v in by_layer.values()) if by_layer else 1
    total_h = max_col_count * NODE_H + (max_col_count - 1) * ROW_GAP
    positions = {}
    for l in sorted(by_layer):
        ns = by_layer[l]
        x = MARGIN_X + l * (NODE_W + COL_GAP)
        col_total = len(ns) * NODE_H + (len(ns) - 1) * ROW_GAP
        y0 = MARGIN_Y + (total_h - col_total) // 2
        for i, n in enumerate(ns):
            positions[n] = (x, y0 + i * (NODE_H + ROW_GAP))
    return positions, by_layer, total_h


def build_drawio(nodes, edges) -> str:
    layer = graph_layers(nodes, edges)
    positions, by_layer, total_h = compute_positions(nodes, layer)
    max_layer = max(by_layer) if by_layer else 0
    page_w = MARGIN_X * 2 + (max_layer + 1) * NODE_W + max_layer * COL_GAP
    page_h = MARGIN_Y * 2 + total_h

    cells = []
    cells.append('<mxCell id="0" />')
    cells.append('<mxCell id="1" parent="0" />')

    id_map = {}
    for i, (nid, meta) in enumerate(nodes.items()):
        cell_id = f"v{i}"
        id_map[nid] = cell_id
        style = STYLES.get(meta["shape"], DEFAULT_STYLE)
        label = escape(meta["label"]).replace("\n", "&#10;")
        x, y = positions[nid]
        cells.append(
            f'<mxCell id="{cell_id}" value="{label}" style="{style}"'
            f' vertex="1" parent="1">'
            f'<mxGeometry x="{x}" y="{y}" width="{NODE_W}" height="{NODE_H}"'
            f' as="geometry" /></mxCell>'
        )

    for i, (a, b) in enumerate(edges):
        cell_id = f"e{i}"
        cells.append(
            f'<mxCell id="{cell_id}" style="{EDGE_STYLE}" edge="1"'
            f' parent="1" source="{id_map[a]}" target="{id_map[b]}">'
            f'<mxGeometry relative="1" as="geometry" /></mxCell>'
        )

    body = "\n        ".join(cells)
    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<mxfile host="app.diagrams.net" agent="mem_clk_path_analyzer" '
        'version="24.0.0">\n'
        '  <diagram id="clock_tree" name="Memory Clock Path">\n'
        f'    <mxGraphModel dx="{page_w}" dy="{page_h}" grid="1" gridSize="10"'
        ' guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1"'
        f' pageScale="1" pageWidth="{page_w}" pageHeight="{page_h}"'
        ' math="0" shadow="0">\n'
        '      <root>\n'
        f'        {body}\n'
        '      </root>\n'
        '    </mxGraphModel>\n'
        '  </diagram>\n'
        '</mxfile>\n'
    )
    return xml


def main():
    src = Path("out/clock_tree.dot")
    dst = Path("out/clock_tree.drawio")
    nodes, edges = parse_dot(src.read_text())
    xml = build_drawio(nodes, edges)
    dst.write_text(xml, encoding="utf-8")
    print(f"wrote {dst}  ({len(nodes)} nodes, {len(edges)} edges)")


if __name__ == "__main__":
    sys.exit(main())
