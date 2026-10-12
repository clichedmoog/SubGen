#!/usr/bin/env python3
"""SubtitleGen app icon generator.

Writes the SVG masters and Icon Composer layers, renders every PNG size with
rsvg-convert, packs AppIcon.icns with iconutil, and builds the light/dark
contact sheet and concept sheet.

    python3 IconCandidate/generate_icon.py                 # all assets
    python3 IconCandidate/generate_icon.py --system-check  # + what macOS draws

Grid: 1024x1024 canvas, 824x824 tile at (100,100) with continuous corners and
a soft drop shadow, both matched to Apple's own macOS 27 icons. Requires
rsvg-convert (librsvg), iconutil (macOS) and Pillow; --system-check also
needs swift.
"""
import math
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "source")

# Tile edge length per master, centred on the 1024 canvas. 824 is the standard
# macOS grid; Apple's own macOS 27 icons draw a smaller, shadowless tile in
# their 32 px (802) and 16 px (778) representations, and macOS boxes small
# representations that do not match that shape inside a grey square.
TILE_SIZE = {"full": 824.0, "32": 802.0, "16": 778.0}
TILE_RADIUS = 187.0  # at 824; radius and smoothing fitted to Apple's macOS 27 icon masks
SMOOTHING = 0.66


def num(v):
    return f"{v:.2f}"


# --------------------------------------------------------------------------
# Geometry
# --------------------------------------------------------------------------

def _corner(radius, smoothing, budget):
    """Figma-style smoothed corner parameters (continuous curvature)."""
    p = (1 + smoothing) * radius
    smoothing = min(smoothing, budget / radius - 1)
    p = min(p, budget)
    arc = 90 * (1 - smoothing)
    arc_len = math.sin(math.radians(arc / 2)) * radius * math.sqrt(2)
    alpha = (90 - arc) / 2
    p3p4 = radius * math.tan(math.radians(alpha / 2))
    beta = 45 * smoothing
    c = p3p4 * math.cos(math.radians(beta))
    d = c * math.tan(math.radians(beta))
    b = (p - arc_len - c - d) / 3
    return 2 * b, b, c, d, p, arc_len


def squircle(x, y, w, h, r, s=SMOOTHING):
    """Rounded square with smoothed (continuous-curvature) corners, traced clockwise."""
    a, b, c, d, p, arc = _corner(r, s, min(w, h) / 2)
    ab, abc, bc = a + b, a + b + c, b + c
    n = num
    return " ".join([
        f"M {n(x + w - p)} {n(y)}",
        f"c {n(a)} 0 {n(ab)} 0 {n(abc)} {n(d)} a {n(r)} {n(r)} 0 0 1 {n(arc)} {n(arc)}",
        f"c {n(d)} {n(c)} {n(d)} {n(bc)} {n(d)} {n(abc)}",
        f"L {n(x + w)} {n(y + h - p)}",
        f"c 0 {n(a)} 0 {n(ab)} {n(-d)} {n(abc)} a {n(r)} {n(r)} 0 0 1 {n(-arc)} {n(arc)}",
        f"c {n(-c)} {n(d)} {n(-bc)} {n(d)} {n(-abc)} {n(d)}",
        f"L {n(x + p)} {n(y + h)}",
        f"c {n(-a)} 0 {n(-ab)} 0 {n(-abc)} {n(-d)} a {n(r)} {n(r)} 0 0 1 {n(-arc)} {n(-arc)}",
        f"c {n(-d)} {n(-c)} {n(-d)} {n(-bc)} {n(-d)} {n(-abc)}",
        f"L {n(x)} {n(y + p)}",
        f"c 0 {n(-a)} 0 {n(-ab)} {n(d)} {n(-abc)} a {n(r)} {n(r)} 0 0 1 {n(arc)} {n(-arc)}",
        f"c {n(c)} {n(-d)} {n(bc)} {n(-d)} {n(abc)} {n(-d)}",
        "Z",
    ])


def _unit(vx, vy):
    length = math.hypot(vx, vy)
    return vx / length, vy / length


def _fillet(corner, u_in, u_out, radius):
    """Round a polyline corner: arc start, arc end, SVG sweep flag, tangent length."""
    turn = math.acos(max(-1.0, min(1.0, u_in[0] * u_out[0] + u_in[1] * u_out[1])))
    t = radius * math.tan(turn / 2)
    start = (corner[0] - u_in[0] * t, corner[1] - u_in[1] * t)
    end = (corner[0] + u_out[0] * t, corner[1] + u_out[1] * t)
    sweep = 1 if u_in[0] * u_out[1] - u_in[1] * u_out[0] > 0 else 0
    return start, end, sweep, t


def bubble(x, y, w, h, r, tail):
    """Rounded speech bubble, tail at the bottom-left, traced clockwise.

    tail is a dict:
      tip_dy  tail depth below the body, as a fraction of h
      lean    outer-edge lean from vertical in degrees (+ = tip further left)
      j1      where the inner edge meets the bottom edge, as a fraction of w
      f1, f2  inner / outer concave fillet radii
      tip_r   tip rounding radius
    The outer edge is placed so its fillet ends exactly where the bottom-left
    corner arc begins; the outline never has a flat shelf or a kink.
    """
    Y = y + h
    lean = math.radians(tail["lean"])
    u_up = (math.sin(lean), -math.cos(lean))            # travelling up the outer edge
    turn = math.pi / 2 + lean                            # from up-edge onto the bottom edge
    t2 = tail["f2"] * math.tan(turn / 2)
    q2 = (x + r + t2, Y)                                 # outer edge meets the bottom line
    depth = tail["tip_dy"] * h
    tip = (q2[0] - u_up[0] * depth / -u_up[1], Y + depth)
    q1 = (x + tail["j1"] * w, Y)
    u_in = _unit(tip[0] - q1[0], tip[1] - q1[1])         # inner edge, travelling down

    a_s, a_e, a_sw, _ = _fillet(q1, (-1.0, 0.0), u_in, tail["f1"])
    t_s, t_e, t_sw, _ = _fillet(tip, u_in, u_up, tail["tip_r"])
    b_s, b_e, b_sw, _ = _fillet(q2, u_up, (-1.0, 0.0), tail["f2"])

    def arc(rad, sweep, p):
        return f"A {num(rad)} {num(rad)} 0 0 {sweep} {num(p[0])} {num(p[1])}"

    return " ".join([
        f"M {num(x + r)} {num(y)}", f"H {num(x + w - r)}", arc(r, 1, (x + w, y + r)),
        f"V {num(Y - r)}", arc(r, 1, (x + w - r, Y)),
        f"H {num(a_s[0])}", arc(tail["f1"], a_sw, a_e),
        f"L {num(t_s[0])} {num(t_s[1])}", arc(tail["tip_r"], t_sw, t_e),
        f"L {num(b_s[0])} {num(b_s[1])}", arc(tail["f2"], b_sw, b_e),
        arc(r, 1, (x, Y - r)), f"V {num(y + r)}", arc(r, 1, (x + r, y)), "Z",
    ])


def pill(cx, cy, w, h):
    return (f'<rect x="{num(cx - w / 2)}" y="{num(cy - h / 2)}" width="{num(w)}" '
            f'height="{num(h)}" rx="{num(h / 2)}"/>')


# --------------------------------------------------------------------------
# Design parameters
# --------------------------------------------------------------------------

PALETTES = {
    # Graphite "screening room" tile, amber speech, frosted glass caption.
    "ember": dict(
        tile=["#3B3B46", "#23232B", "#121217"],
        glow="#FFAA40", glow_opacity=0.12,
        back=["#FFD36A", "#FFA63C", "#FF7B2E"],
        back_edge="#B8400F",
        glass_top=0.93, glass_bottom=0.78, glass_tint="#F4F4F8",
        line1="#26262F", line2=["#FFB13F", "#FF7A2C"],
    ),
    "plum": dict(
        tile=["#6140B0", "#3C247A", "#1D113D"],
        glow="#FF9BCB", glow_opacity=0.16,
        back=["#FFCB60", "#FF9842", "#FF6157"],
        back_edge="#A8264A",
        glass_top=0.90, glass_bottom=0.72, glass_tint="#EFE9FA",
        line1="#2A1C52", line2=["#FFA640", "#FF6A3D"],
    ),
}

TAILS = {
    # straight-down tail, outer edge almost vertical
    "notch": dict(tip_dy=0.25, lean=6.0, j1=0.50, f1=46.0, f2=26.0, tip_r=13.0),
    # longer tail, swept further left
    "sweep": dict(tip_dy=0.27, lean=18.0, j1=0.54, f1=60.0, f2=20.0, tip_r=14.0),
}

# Bubble layout per master. The amber bubble (spoken line) sits lower-left;
# the frosted glass bubble (its subtitle) is the same shape offset up-right and
# laid over it. Both tails point down-left, so both stay visible.
# back = amber bubble origin, off = glass bubble offset from it.
LAYOUTS = {
    # 64 px and up. Glass bubble and caption edges sit on the 16-unit grid
    # (whole pixels at 64 and 128 px).
    "full": dict(w=464.0, h=336.0, r=116.0, back=(208.0, 368.0), off=(144.0, -144.0),
                 line_h=48.0, gap=48.0, l1=272.0, l2=176.0),
    # 32 px: 32-unit grid; captions are 2 px lines with a 1 px gap.
    "32": dict(w=512.0, h=352.0, r=128.0, back=(192.0, 352.0), off=(128.0, -160.0),
               line_h=64.0, gap=32.0, l1=320.0, l2=192.0),
    # 16 px: 64-unit grid; one 1 px caption line.
    "16": dict(w=512.0, h=384.0, r=136.0, back=(192.0, 320.0), off=(128.0, -128.0),
               line_h=64.0, gap=0.0, l1=256.0, l2=0.0, line_dy=-32.0),
}


def captions(L):
    """Caption pills as (cx, cy, width, height) for the transcript and translation lines."""
    fx, fy = L["back"][0] + L["off"][0], L["back"][1] + L["off"][1]
    cx = fx + L["w"] / 2
    block = L["line_h"] * (2 if L["l2"] else 1) + (L["gap"] if L["l2"] else 0)
    top = fy + L["h"] / 2 - block / 2 + L.get("line_dy", 0.0)
    rows = [(cx, top + L["line_h"] / 2, L["l1"], L["line_h"])]
    if L["l2"]:
        rows.append((cx, top + L["line_h"] * 1.5 + L["gap"], L["l2"], L["line_h"]))
    return rows


# --------------------------------------------------------------------------
# SVG
# --------------------------------------------------------------------------

def build_svg(master="full", palette="ember", tail="notch"):
    P = PALETTES[palette]
    L = LAYOUTS[master]
    T = dict(TAILS[tail])
    small = master != "full"
    if small:  # chunkier tail so it survives at 16/32 px
        T.update(tip_dy=T["tip_dy"] * 1.12, tip_r=T["tip_r"] * 1.6, f1=T["f1"] * 1.1)
    tw = th = TILE_SIZE[master]
    tx = ty = (1024.0 - tw) / 2
    bw, bh, br = L["w"], L["h"], L["r"]
    bx, by = L["back"]
    fx, fy = bx + L["off"][0], by + L["off"][1]
    back_d = bubble(bx, by, bw, bh, br, T)
    front_d = bubble(fx, fy, bw, bh, br, T)
    rows = captions(L)

    s = ['<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">']
    s.append(f"<!-- SubtitleGen app icon | master={master} palette={palette} tail={tail}. "
             "Generated by IconCandidate/generate_icon.py; edit parameters there or this file directly. -->")
    s.append("<defs>")
    s.append(f'<path id="tile" d="{squircle(tx, ty, tw, th, TILE_RADIUS * tw / 824.0)}"/>')
    s.append(f'<path id="back" d="{back_d}"/>')
    s.append(f'<path id="front" d="{front_d}"/>')
    s.append('<clipPath id="tileClip"><use href="#tile"/></clipPath>')
    s.append('<clipPath id="frontClip"><use href="#front"/></clipPath>')
    t = P["tile"]
    s.append(f'<linearGradient id="tileFill" x1="0" y1="{ty}" x2="0" y2="{ty + th}" gradientUnits="userSpaceOnUse">'
             f'<stop offset="0" stop-color="{t[0]}"/><stop offset="0.55" stop-color="{t[1]}"/>'
             f'<stop offset="1" stop-color="{t[2]}"/></linearGradient>')
    s.append(f'<radialGradient id="tileGlow" cx="{num(bx + bw * 0.5)}" cy="{num(by + bh * 0.6)}" r="560" '
             f'gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{P["glow"]}" '
             f'stop-opacity="{P["glow_opacity"]}"/><stop offset="1" stop-color="{P["glow"]}" stop-opacity="0"/>'
             '</radialGradient>')
    s.append(f'<linearGradient id="tileSheen" x1="0" y1="{ty}" x2="0" y2="{ty + 380}" gradientUnits="userSpaceOnUse">'
             '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.09"/>'
             '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>')
    s.append(f'<linearGradient id="tileRim" x1="0" y1="{ty}" x2="0" y2="{ty + th}" gradientUnits="userSpaceOnUse">'
             '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.45"/>'
             '<stop offset="0.3" stop-color="#FFFFFF" stop-opacity="0.12"/>'
             '<stop offset="0.8" stop-color="#FFFFFF" stop-opacity="0.05"/>'
             '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0.18"/></linearGradient>')
    b = P["back"]
    s.append(f'<linearGradient id="backFill" x1="{num(bx)}" y1="{num(by)}" x2="{num(bx + bw * 0.45)}" '
             f'y2="{num(by + bh * 1.25)}" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{b[0]}"/>'
             f'<stop offset="0.5" stop-color="{b[1]}"/><stop offset="1" stop-color="{b[2]}"/></linearGradient>')
    s.append(f'<linearGradient id="glassFill" x1="0" y1="{num(fy)}" x2="0" y2="{num(fy + bh * 1.25)}" '
             'gradientUnits="userSpaceOnUse">'
             f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="{P["glass_top"]}"/>'
             f'<stop offset="1" stop-color="{P["glass_tint"]}" stop-opacity="{P["glass_bottom"]}"/></linearGradient>')
    l2 = P["line2"]
    fcx = fx + bw / 2
    s.append(f'<linearGradient id="line2Fill" x1="{num(fcx - L["l2"] / 2)}" y1="0" x2="{num(fcx + L["l2"] / 2)}" '
             f'y2="0" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{l2[0]}"/>'
             f'<stop offset="1" stop-color="{l2[1]}"/></linearGradient>')

    # Tile drop shadow: dy 8, blur 14, 25% black; matches the alpha falloff
    # below and beside the tile in Apple's macOS 27 App Store icons.
    s.append('<filter color-interpolation-filters="sRGB" id="tileShadow" x="-10%" y="-10%" width="120%" height="125%">'
             '<feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="8" result="o"/>'
             '<feFlood flood-color="#000" flood-opacity="0.25"/><feComposite in2="o" operator="in"/>'
             '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>')
    s.append('<filter color-interpolation-filters="sRGB" id="castSoft" x="-30%" y="-30%" width="160%" height="170%">'
             f'<feGaussianBlur in="SourceAlpha" stdDeviation="{8 if small else 22}"/>'
             f'<feOffset dy="{8 if small else 20}" result="o"/>'
             f'<feFlood flood-color="#000" flood-opacity="{0.5 if small else 0.42}"/>'
             '<feComposite in2="o" operator="in"/></filter>')
    s.append('<filter color-interpolation-filters="sRGB" id="castTight" x="-30%" y="-30%" width="160%" height="170%">'
             '<feGaussianBlur in="SourceAlpha" stdDeviation="4"/><feOffset dy="4" result="o"/>'
             '<feFlood flood-color="#000" flood-opacity="0.22"/><feComposite in2="o" operator="in"/></filter>')
    s.append('<filter color-interpolation-filters="sRGB" id="frost" x="-20%" y="-20%" width="140%" height="140%">'
             '<feGaussianBlur stdDeviation="34"/></filter>')
    # Lit top edge inside a shape (specular rim).
    s.append('<filter color-interpolation-filters="sRGB" id="rimLight" x="-10%" y="-10%" width="120%" height="120%">'
             '<feGaussianBlur in="SourceAlpha" stdDeviation="2" result="b"/>'
             f'<feOffset in="b" dx="{2 if small else 3}" dy="{6 if small else 5}" result="o"/>'
             '<feComposite in="SourceAlpha" in2="o" operator="out" result="edge"/>'
             '<feFlood flood-color="#FFFFFF" flood-opacity="0.9"/>'
             '<feComposite in2="edge" operator="in"/></filter>')
    # Darker lower edge on the solid bubble, so it reads as a thick object.
    s.append('<filter color-interpolation-filters="sRGB" id="rimShade" x="-10%" y="-10%" width="120%" height="120%">'
             '<feGaussianBlur in="SourceAlpha" stdDeviation="7" result="b"/>'
             '<feOffset in="b" dx="-4" dy="-9" result="o"/>'
             '<feComposite in="SourceAlpha" in2="o" operator="out" result="edge"/>'
             f'<feFlood flood-color="{P["back_edge"]}" flood-opacity="0.5"/>'
             '<feComposite in2="edge" operator="in"/></filter>')
    # Thin even ring around the glass edge.
    s.append('<filter color-interpolation-filters="sRGB" id="ring" x="-10%" y="-10%" width="120%" height="120%">'
             '<feMorphology in="SourceAlpha" operator="erode" radius="2.5" result="e"/>'
             '<feComposite in="SourceAlpha" in2="e" operator="out" result="r"/>'
             '<feFlood flood-color="#FFFFFF" flood-opacity="0.6"/><feComposite in2="r" operator="in"/></filter>')
    s.append("</defs>")

    # tile
    s.append('<use href="#tile" fill="url(#tileFill)"%s/>' % ("" if small else ' filter="url(#tileShadow)"'))
    s.append('<g clip-path="url(#tileClip)">')
    s.append('<use href="#tile" fill="url(#tileGlow)"/>')
    s.append('<use href="#tile" fill="url(#tileSheen)"/>')

    # back bubble: solid amber
    s.append('<use href="#back" filter="url(#castSoft)"/>')
    s.append('<use href="#back" fill="url(#backFill)"/>')
    if not small:
        s.append('<use href="#back" fill="#000" filter="url(#rimShade)"/>')
    s.append('<use href="#back" fill="#000" filter="url(#rimLight)" opacity="0.7"/>')

    # front bubble: frosted glass, refracting the amber bubble behind it
    s.append('<use href="#front" filter="url(#castSoft)" opacity="0.9"/>')
    if not small:
        s.append('<use href="#front" filter="url(#castTight)"/>')
    s.append('<g clip-path="url(#frontClip)">')
    if small:
        s.append('<use href="#tile" fill="url(#tileFill)"/>')
        s.append('<use href="#back" fill="url(#backFill)" opacity="0.6"/>')
    else:
        s.append('<g filter="url(#frost)"><use href="#tile" fill="url(#tileFill)"/>'
                 '<use href="#tile" fill="url(#tileGlow)"/><use href="#back" fill="url(#backFill)"/></g>')
    s.append('<use href="#front" fill="url(#glassFill)"/>')
    s.append("</g>")
    s.append('<use href="#front" fill="#000" filter="url(#rimLight)"/>')
    if not small:
        s.append('<use href="#front" fill="#000" filter="url(#ring)"/>')

    # caption lines: transcript (ink) above its translation (amber)
    s.append(f'<g fill="{P["line1"]}" fill-opacity="0.9">{pill(*rows[0])}</g>')
    if len(rows) > 1:
        s.append(f'<g fill="url(#line2Fill)">{pill(*rows[1])}</g>')
    s.append("</g>")

    s.append('<g clip-path="url(#tileClip)">'
             '<use href="#tile" fill="none" stroke="url(#tileRim)" stroke-width="5"/></g>')
    s.append("</svg>")
    return "\n".join(s)


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

def render(svg_path, size, out):
    subprocess.run(["rsvg-convert", "--width", str(size), "--height", str(size),
                    "--format", "png", svg_path, "--output", out], check=True)


def write(path, text):
    with open(path, "w") as f:
        f.write(text + "\n")


def _font(size):
    for path in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def concept_sheet(out_path, variants):
    """Concept sheet: each variant at 256 px plus its 32 px rendition."""
    tmp = tempfile.mkdtemp()
    try:
        cell, pad = 280, 12
        sheet = Image.new("RGBA", (len(variants) * cell, cell + 48), (236, 236, 241, 255))
        draw = ImageDraw.Draw(sheet)
        for i, (label, master_overrides, pal, tail) in enumerate(variants):
            saved = {k: dict(v) for k, v in LAYOUTS.items()}
            for master, override in master_overrides.items():
                LAYOUTS[master].update(override)
            pngs = {}
            for master, size in (("full", 256), ("32", 32)):
                svg = os.path.join(tmp, f"{i}-{master}.svg")
                write(svg, build_svg(master, pal, tail))
                pngs[master] = os.path.join(tmp, f"{i}-{master}.png")
                render(svg, size, pngs[master])
            LAYOUTS.clear()
            LAYOUTS.update(saved)
            x = i * cell
            sheet.alpha_composite(Image.open(pngs["full"]).convert("RGBA"), (x + pad, pad))
            sheet.alpha_composite(Image.open(pngs["32"]).convert("RGBA"), (x + pad + 20, cell + 4))
            draw.text((x + pad + 70, cell + 10), label, fill=(40, 40, 46, 255), font=_font(17))
        sheet.save(out_path)
    finally:
        shutil.rmtree(tmp)
    print("wrote", out_path)


# iconset name -> (master, pixel size). Every pixel size from 16 to 1024 is
# present. icon_32x32.png (32 pt @1x, chunk ic05) is left out on purpose: on
# macOS 27.2 any ic05 made macOS draw the 32 px icon inside a grey rounded
# square, whatever its tile size or shadow; without it, 32 px drawing uses
# icon_16x16@2x and is not boxed. Xcode 26's own AppIcon.icns fallbacks for
# Apple's apps (Xcode, Final Cut Pro, Calculator, ...) also have no ic05.
RENDITIONS = [
    ("icon_16x16.png", "16", 16),
    ("icon_16x16@2x.png", "32", 32),
    ("icon_32x32@2x.png", "full", 64),
    ("icon_128x128.png", "full", 128),
    ("icon_128x128@2x.png", "full", 256),
    ("icon_256x256.png", "full", 256),
    ("icon_256x256@2x.png", "full", 512),
    ("icon_512x512.png", "full", 512),
    ("icon_512x512@2x.png", "full", 1024),
]

MASTER_FILES = {"full": "AppIcon.svg", "32": "AppIcon-32.svg", "16": "AppIcon-16.svg"}


def write_layers(layer_dir):
    """Flat, unmasked layers for Icon Composer (macOS 26+ Liquid Glass icons).

    Icon Composer adds the rounded mask, specular rim, blur and shadows itself,
    so these carry shapes and fills only.
    """
    os.makedirs(layer_dir, exist_ok=True)
    P, L, T = PALETTES["ember"], LAYOUTS["full"], TAILS["notch"]
    bx, by = L["back"]
    fx, fy = bx + L["off"][0], by + L["off"][1]
    rows = captions(L)
    head = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
    t, b = P["tile"], P["back"]
    layers = {
        "0-background.svg": (
            '<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1024" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{t[0]}"/><stop offset="0.55" stop-color="{t[1]}"/>'
            f'<stop offset="1" stop-color="{t[2]}"/></linearGradient></defs>'
            '<rect width="1024" height="1024" fill="url(#g)"/>'),
        "1-amber-bubble.svg": (
            f'<defs><linearGradient id="g" x1="{num(bx)}" y1="{num(by)}" x2="{num(bx + L["w"] * 0.45)}" '
            f'y2="{num(by + L["h"] * 1.25)}" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{b[0]}"/>'
            f'<stop offset="0.5" stop-color="{b[1]}"/><stop offset="1" stop-color="{b[2]}"/></linearGradient></defs>'
            f'<path fill="url(#g)" d="{bubble(bx, by, L["w"], L["h"], L["r"], T)}"/>'),
        "2-glass-bubble.svg": f'<path fill="#FFFFFF" d="{bubble(fx, fy, L["w"], L["h"], L["r"], T)}"/>',
        "3-captions.svg": (
            f'<g fill="{P["line1"]}">{pill(*rows[0])}</g>'
            f'<g fill="{P["line2"][1]}">{pill(*rows[1])}</g>'),
    }
    for name, body in layers.items():
        write(os.path.join(layer_dir, name), head + body + "</svg>")


def contact_sheet(iconset, out_path):
    """Light and dark rows at 16/32/64/128/256 px, plus 16 and 32 magnified 4x."""
    sizes = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (64, "icon_32x32@2x.png"),
             (128, "icon_128x128.png"), (256, "icon_256x256.png")]
    zooms = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png")]
    gap, margin, label_h = 36, 40, 34
    width = margin * 2 + sum(s for s, _ in sizes) + gap * (len(sizes) - 1) + 2 * gap + 64 + 128 + gap
    row_h = margin + 256 + label_h + margin
    sheet = Image.new("RGBA", (width, row_h * 2), (0, 0, 0, 0))
    font = _font(15)
    for row, (bg, fg, name) in enumerate([((245, 245, 247, 255), (60, 60, 67, 255), "Light"),
                                          ((28, 28, 30, 255), (200, 200, 205, 255), "Dark")]):
        y0 = row * row_h
        panel = Image.new("RGBA", (width, row_h), bg)
        sheet.alpha_composite(panel, (0, y0))
        draw = ImageDraw.Draw(sheet)
        draw.text((margin, y0 + 12), name, fill=fg, font=font)
        base = y0 + margin + 256
        x = margin
        for size, fname in sizes:
            im = Image.open(os.path.join(iconset, fname)).convert("RGBA")
            assert im.size == (size, size), (fname, im.size)
            sheet.alpha_composite(im, (x, base - size))
            draw.text((x, base + 8), f"{size} px", fill=fg, font=font)
            x += size + gap
        x += gap
        for size, fname in zooms:
            im = Image.open(os.path.join(iconset, fname)).convert("RGBA").resize((size * 4, size * 4), Image.NEAREST)
            sheet.alpha_composite(im, (x, base - size * 4))
            draw.text((x, base + 8), f"{size} px x4", fill=fg, font=font)
            x += size * 4 + gap
    sheet.save(out_path)


def build():
    os.makedirs(SRC, exist_ok=True)
    for master, fname in MASTER_FILES.items():
        write(os.path.join(SRC, fname), build_svg(master))
    write_layers(os.path.join(SRC, "icon-composer-layers"))

    work = tempfile.mkdtemp()
    try:
        iconset = os.path.join(work, "AppIcon.iconset")
        os.makedirs(iconset)
        for name, master, size in RENDITIONS:
            render(os.path.join(SRC, MASTER_FILES[master]), size, os.path.join(iconset, name))
        icns = os.path.join(HERE, "AppIcon.icns")
        subprocess.run(["iconutil", "--convert", "icns", iconset, "--output", icns], check=True)

        # Round trip: unpack the .icns and check every representation.
        check = os.path.join(work, "check.iconset")
        subprocess.run(["iconutil", "--convert", "iconset", icns, "--output", check], check=True)
        for name, _, size in RENDITIONS:
            im = Image.open(os.path.join(check, name))
            if im.size != (size, size) or im.mode != "RGBA":
                sys.exit(f"bad representation {name}: {im.size} {im.mode}")
        shutil.copy(os.path.join(check, "icon_512x512@2x.png"), os.path.join(HERE, "AppIcon-1024.png"))
        contact_sheet(check, os.path.join(HERE, "contact-sheet.png"))
    finally:
        shutil.rmtree(work)

    concept_sheet(os.path.join(HERE, "concepts.png"), [
        ("selected", {}, "ember", "notch"),
        ("glass in front, lower-right", {"full": dict(back=(214.0, 236.0), off=(128.0, 150.0)),
                                         "32": dict(back=(186.0, 200.0), off=(144.0, 166.0))}, "ember", "notch"),
        ("swept tail", {}, "ember", "sweep"),
        ("plum palette", {}, "plum", "notch"),
    ])
    for name in ("AppIcon.icns", "AppIcon-1024.png", "contact-sheet.png", "concepts.png"):
        print("wrote", os.path.join(HERE, name))


SYSTEM_ICON_SWIFT = r"""
import AppKit
// Draws NSWorkspace's icon for a bundle at several pixel sizes.
let path = CommandLine.arguments[1], outDir = CommandLine.arguments[2]
let icon = NSWorkspace.shared.icon(forFile: path)
for size in [512, 128, 64, 32, 16] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(size).png"))
}
"""


def system_check(out_path):
    """Wrap AppIcon.icns in a throwaway .app and draw what macOS itself shows for it.

    On macOS 26+ an icon that does not fit the system shape is shrunk into a
    grey rounded square; this sheet shows whether that happens.
    """
    work = tempfile.mkdtemp()
    try:
        app = os.path.join(work, "IconCheck.app", "Contents")
        os.makedirs(os.path.join(app, "Resources"))
        os.makedirs(os.path.join(app, "MacOS"))
        shutil.copy(os.path.join(HERE, "AppIcon.icns"), os.path.join(app, "Resources", "AppIcon.icns"))
        write(os.path.join(app, "Info.plist"),
              '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
              f"<key>CFBundleIdentifier</key><string>local.subtitlegen.iconcheck.{os.getpid()}</string>"
              "<key>CFBundleExecutable</key><string>IconCheck</string>"
              "<key>CFBundleIconFile</key><string>AppIcon</string>"
              "<key>CFBundlePackageType</key><string>APPL</string></dict></plist>")
        write(os.path.join(app, "MacOS", "IconCheck"), "#!/bin/sh\nexit 0")
        script = os.path.join(work, "icon.swift")
        write(script, SYSTEM_ICON_SWIFT)
        subprocess.run(["swift", script, os.path.dirname(app), work], check=True)
        sizes = [512, 128, 64, 32, 16]
        for size in sizes:
            # A boxed icon has the light grey container showing just inside its edge.
            r, g, b, _ = Image.open(os.path.join(work, f"{size}.png")).convert("RGBA").getpixel((size // 8, size // 2))
            boxed = r > 150 and abs(r - b) < 12 and abs(r - g) < 12
            print(f"system render {size}px: {'boxed in grey container' if boxed else 'drawn as is'}")
        gap, margin = 32, 32
        width = margin * 2 + sum(sizes) + gap * (len(sizes) - 1) + gap + 32 * 4 + gap + 16 * 4
        row_h = margin * 2 + 512 + 30
        sheet = Image.new("RGBA", (width, row_h * 2), (0, 0, 0, 0))
        draw = ImageDraw.Draw(sheet)
        font = _font(15)
        for row, (bg, fg) in enumerate([((245, 245, 247, 255), (60, 60, 67, 255)),
                                        ((28, 28, 30, 255), (200, 200, 205, 255))]):
            y0 = row * row_h
            sheet.alpha_composite(Image.new("RGBA", (width, row_h), bg), (0, y0))
            base = y0 + margin + 512
            x = margin
            for size in sizes:
                sheet.alpha_composite(Image.open(os.path.join(work, f"{size}.png")).convert("RGBA"), (x, base - size))
                draw.text((x, base + 6), f"{size}", fill=fg, font=font)
                x += size + gap
            for size in (32, 16):
                im = Image.open(os.path.join(work, f"{size}.png")).convert("RGBA").resize((size * 4, size * 4), Image.NEAREST)
                sheet.alpha_composite(im, (x, base - size * 4))
                draw.text((x, base + 6), f"{size} x4", fill=fg, font=font)
                x += size * 4 + gap
        sheet.save(out_path)
    finally:
        shutil.rmtree(work)
    print("wrote", out_path)


if __name__ == "__main__":
    build()
    if "--system-check" in sys.argv:
        system_check(os.path.join(HERE, "system-render-check.png"))
