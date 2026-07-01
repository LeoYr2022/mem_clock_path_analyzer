"""Render out/clock_tree.dot to out/clock_tree.png using PIL only.

Nicer version: 3x supersampled antialiasing, elbow edge routing,
distributed multi-input landings, and a legend.
"""
from __future__ import annotations

import math
import re
import sys
from collections import defaultdict, deque
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


NODE_RE = re.compile(r'"([^"]+)"\s*\[shape=(\w+),\s*label="([^"]+)"\];')
EDGE_RE = re.compile(r'"([^"]+)"\s*->\s*"([^"]+)";')

SS = 3  # supersample factor

# --- Palette ---------------------------------------------------------------
BG                = "#FBFAF7"
TITLE_BG          = "#243447"
TITLE_FG          = "#F5F8FA"
EDGE_COLOR        = "#2C3A45"
LABEL_FG          = "#131A20"

STYLES = {
    "doublecircle": ("#F6C86A", "#8A5A00"),  # root
    "hexagon":      ("#E06666", "#7B0F0F"),  # divider  (red square block)
    "trapezium":    ("#E06666", "#7B0F0F"),  # mux      (red square block)
    "house":        ("#E06666", "#7B0F0F"),  # icg      (red square block)
    "box3d":        ("#C0B3E1", "#4B3C88"),  # memory
    "octagon":      ("#E27878", "#7B0F0F"),  # unknown
    "ellipse":      ("#E3E3E3", "#555555"),
}

# Shapes drawn as a rounded-square block (per user request: clock mux/div/gate).
SQUARE_SHAPES = {"hexagon", "trapezium", "house"}


def parse_dot(text):
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
    # ASAP layering.
    layer = {n: 0 for n in nodes if not preds[n]}
    queue = deque(layer.keys())
    while queue:
        n = queue.popleft()
        for m in succs[n]:
            proposed = layer[n] + 1
            if proposed > layer.get(m, -1):
                layer[m] = proposed
                queue.append(m)
    for n in nodes:
        layer.setdefault(n, 0)
    # Pull sources forward next to their consumers.
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
    return layer, preds, succs


# --- Shapes ----------------------------------------------------------------
def draw_shape(draw, shape, cx, cy, w, h, fill, outline, stroke):
    w2, h2 = w // 2, h // 2
    if shape in SQUARE_SHAPES:
        radius = min(w, h) // 8
        draw.rounded_rectangle((cx - w2, cy - h2, cx + w2, cy + h2),
                               radius=radius, fill=fill,
                               outline=outline, width=stroke)
        return
    if shape == "doublecircle":
        draw.ellipse((cx - w2, cy - h2, cx + w2, cy + h2),
                     fill=fill, outline=outline, width=stroke)
        pad = int(6 * SS)
        draw.ellipse((cx - w2 + pad, cy - h2 + pad,
                      cx + w2 - pad, cy + h2 - pad),
                     outline=outline, width=max(1, stroke // 2))
    elif shape == "hexagon":
        pts = [
            (cx - w2, cy),
            (cx - w2 // 2, cy - h2),
            (cx + w2 // 2, cy - h2),
            (cx + w2, cy),
            (cx + w2 // 2, cy + h2),
            (cx - w2 // 2, cy + h2),
        ]
        _polygon(draw, pts, fill, outline, stroke)
    elif shape == "trapezium":
        indent = int(w2 * 0.32)
        pts = [
            (cx - w2, cy + h2),
            (cx - w2 + indent, cy - h2),
            (cx + w2 - indent, cy - h2),
            (cx + w2, cy + h2),
        ]
        _polygon(draw, pts, fill, outline, stroke)
    elif shape == "house":
        peak = int(h2 * 0.55)
        pts = [
            (cx - w2, cy + h2),
            (cx - w2, cy - h2 + peak),
            (cx, cy - h2),
            (cx + w2, cy - h2 + peak),
            (cx + w2, cy + h2),
        ]
        _polygon(draw, pts, fill, outline, stroke)
    elif shape == "box3d":
        depth = int(14 * SS)
        front = [
            (cx - w2, cy - h2 + depth // 2),
            (cx + w2 - depth, cy - h2 + depth // 2),
            (cx + w2 - depth, cy + h2),
            (cx - w2, cy + h2),
        ]
        back = [(x + depth, y - depth) for x, y in front]
        # Top face
        _polygon(draw, [front[0], back[0], back[1], front[1]],
                 _shade(fill, 1.10), outline, stroke)
        # Right face
        _polygon(draw, [front[1], back[1], back[2], front[2]],
                 _shade(fill, 0.85), outline, stroke)
        # Front face
        _polygon(draw, front, fill, outline, stroke)
    elif shape == "octagon":
        d = w2 // 3
        pts = [
            (cx - w2 + d, cy - h2), (cx + w2 - d, cy - h2),
            (cx + w2, cy - h2 + d), (cx + w2, cy + h2 - d),
            (cx + w2 - d, cy + h2), (cx - w2 + d, cy + h2),
            (cx - w2, cy + h2 - d), (cx - w2, cy - h2 + d),
        ]
        _polygon(draw, pts, fill, outline, stroke)
    else:
        radius = min(w, h) // 5
        draw.rounded_rectangle((cx - w2, cy - h2, cx + w2, cy + h2),
                               radius=radius, fill=fill,
                               outline=outline, width=stroke)


def _polygon(draw, pts, fill, outline, stroke):
    draw.polygon(pts, fill=fill, outline=outline)
    closed = pts + [pts[0]]
    for a, b in zip(closed, closed[1:]):
        draw.line(a + b, fill=outline, width=stroke)


def _shade(hex_color, factor):
    h = hex_color.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    r = max(0, min(255, int(r * factor)))
    g = max(0, min(255, int(g * factor)))
    b = max(0, min(255, int(b * factor)))
    return f"#{r:02X}{g:02X}{b:02X}"


def _load_font(size):
    for name in ("segoeui.ttf", "arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def render(dot_path: str, png_path: str):
    text = Path(dot_path).read_text()
    nodes, edges = parse_dot(text)
    layer, preds, succs = graph_layers(nodes, edges)

    by_layer = defaultdict(list)
    for n, l in layer.items():
        by_layer[l].append(n)
    for l in by_layer:
        by_layer[l].sort()

    max_layer = max(by_layer) if by_layer else 0
    max_col   = max(len(v) for v in by_layer.values()) if by_layer else 1

    node_w = 190 * SS
    node_h = 82 * SS
    col_gap = 110 * SS
    row_gap = 45 * SS
    margin_x = 60 * SS
    title_h  = 56 * SS
    top_pad  = 34 * SS
    bottom_m = 96 * SS

    canvas_w = margin_x * 2 + (max_layer + 1) * node_w + max_layer * col_gap
    canvas_h = title_h + top_pad + max_col * node_h + \
               (max_col - 1) * row_gap + bottom_m

    img = Image.new("RGB", (canvas_w, canvas_h), BG)
    draw = ImageDraw.Draw(img)

    font_title = _load_font(int(20 * SS))
    font_node  = _load_font(int(13 * SS))
    font_lgd   = _load_font(int(12 * SS))

    # Title bar
    draw.rectangle((0, 0, canvas_w, title_h), fill=TITLE_BG)
    title = "Memory Clock-Path : ref_clk → PLL → ÷2 → MUX → ICG → SRAM × 2"
    tb = draw.textbbox((0, 0), title, font=font_title)
    draw.text(((canvas_w - (tb[2] - tb[0])) // 2,
               (title_h - (tb[3] - tb[1])) // 2 - tb[1]),
              title, fill=TITLE_FG, font=font_title)

    # Positions
    positions = {}
    area_top = title_h + top_pad
    area_bottom = canvas_h - bottom_m
    for l in sorted(by_layer):
        ns = by_layer[l]
        column_x = margin_x + l * (node_w + col_gap) + node_w // 2
        total_h = len(ns) * node_h + (len(ns) - 1) * row_gap
        start_y = area_top + (area_bottom - area_top - total_h) // 2 + node_h // 2
        for i, n in enumerate(ns):
            positions[n] = (column_x, start_y + i * (node_h + row_gap))

    # Distribute incoming edges along the left edge of each target.
    incoming = defaultdict(list)
    for a, b in edges:
        incoming[b].append(a)

    endpoints = {}
    for b, srcs in incoming.items():
        srcs.sort(key=lambda s: positions[s][1])
        bx, by = positions[b]
        n = len(srcs)
        for i, a in enumerate(srcs):
            if n == 1:
                yoff = 0
            else:
                yoff = int((i - (n - 1) / 2) * (node_h * 0.30))
            ax, ay = positions[a]
            start = (ax + node_w // 2 + 2 * SS, ay)
            end   = (bx - node_w // 2 - 2 * SS, by + yoff)
            endpoints[(a, b)] = (start, end)

    # --- Draw edges (behind nodes) ---
    lw = 2 * SS
    arrow_len = 12 * SS
    arrow_wid = 6 * SS
    for (a, b), ((sx, sy), (ex, ey)) in endpoints.items():
        if abs(sy - ey) < 2 * SS:
            draw.line((sx, sy, ex, ey), fill=EDGE_COLOR, width=lw)
        else:
            mid_x = (sx + ex) // 2
            draw.line((sx, sy, mid_x, sy), fill=EDGE_COLOR, width=lw)
            draw.line((mid_x, sy, mid_x, ey), fill=EDGE_COLOR, width=lw)
            draw.line((mid_x, ey, ex, ey), fill=EDGE_COLOR, width=lw)
            # Round the two corners
            r = lw // 2
            for jx, jy in ((mid_x, sy), (mid_x, ey)):
                draw.ellipse((jx - r, jy - r, jx + r, jy + r), fill=EDGE_COLOR)
        # Arrowhead pointing right into the target left edge
        draw.polygon([
            (ex + arrow_len // 2, ey),
            (ex - arrow_len // 2, ey - arrow_wid),
            (ex - arrow_len // 2, ey + arrow_wid),
        ], fill=EDGE_COLOR)

    # --- Draw nodes ---
    for n, (cx, cy) in positions.items():
        shape = nodes[n]["shape"]
        label = nodes[n]["label"]
        fill, outline = STYLES.get(shape, ("#EEEEEE", "#666666"))
        draw_shape(draw, shape, cx, cy, node_w, node_h,
                   fill, outline, stroke=3 * SS)
        _draw_multiline(draw, label, cx, cy, font_node, LABEL_FG)

    # --- Legend ---
    legend_items = [
        ("Root / top input", "doublecircle"),
        ("Divider (÷N)",     "hexagon"),
        ("Mux",              "trapezium"),
        ("ICG / clock gate", "house"),
        ("Memory",           "box3d"),
    ]
    swatch_w = 44 * SS
    swatch_h = 28 * SS
    gap = 30 * SS

    widths = []
    for label, shp in legend_items:
        tb = draw.textbbox((0, 0), label, font=font_lgd)
        widths.append(swatch_w + 10 * SS + (tb[2] - tb[0]))
    total = sum(widths) + gap * (len(legend_items) - 1)

    x = (canvas_w - total) // 2
    y = canvas_h - bottom_m + 26 * SS
    for (label, shp), item_w in zip(legend_items, widths):
        fill, outline = STYLES.get(shp, ("#EEEEEE", "#666666"))
        draw_shape(draw, shp, x + swatch_w // 2, y + swatch_h // 2,
                   swatch_w, swatch_h, fill, outline, stroke=2 * SS)
        draw.text((x + swatch_w + 10 * SS, y + 5 * SS),
                  label, fill="#333333", font=font_lgd)
        x += item_w + gap

    # --- Downsample for AA ---
    out = img.resize((canvas_w // SS, canvas_h // SS), Image.LANCZOS)
    out.save(png_path)
    print(f"wrote {png_path}  ({out.size[0]}x{out.size[1]})")


def _draw_multiline(draw, text, cx, cy, font, color):
    lines = text.split("\n")
    try:
        asc, dsc = font.getmetrics()
        lh = asc + dsc + 2 * SS
    except Exception:
        lh = 15 * SS
    total_h = lh * len(lines)
    ty = cy - total_h // 2
    for line in lines:
        tb = draw.textbbox((0, 0), line, font=font)
        lw_text = tb[2] - tb[0]
        draw.text((cx - lw_text // 2, ty), line, fill=color, font=font)
        ty += lh


def main():
    render("out/clock_tree.dot", "out/clock_tree.png")


if __name__ == "__main__":
    sys.exit(main())
