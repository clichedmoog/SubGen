#!/usr/bin/env python3
"""SubtitleGen app icon generator — colour/material revision.

Adapted from IconCandidate/generate_icon.py. The geometry section (tile,
speech bubbles, tails, caption pills, per-master layouts) is copied unchanged;
only palettes, opacities, glass material, light and shadows differ. Every run
checks that geometry against the original generator and the original SVG and
.icns files and stops if anything differs.

Writes three colour variants (SVG masters, 1024 px PNG, flat Icon Composer
layers), then for the selected variant the top-level SVG masters, AppIcon.icns,
AppIcon-1024.png and the light/dark contact sheet, plus a comparison sheet of
the original and all three variants.

    python3 IconColourRevision/generate_icon.py                 # all assets
    python3 IconColourRevision/generate_icon.py --system-check  # + what macOS draws

Grid: 1024x1024 canvas, 824x824 tile at (100,100) with continuous corners and
a soft drop shadow, both matched to Apple's own macOS 27 icons. Requires
rsvg-convert (librsvg), iconutil (macOS) and Pillow; --system-check also
needs swift.
"""
import importlib.util
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "source")
ORIGINAL = os.path.join(os.path.dirname(HERE), "IconCandidate")  # read only

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

# Colour and material only. Each palette is one colour family, after the
# macOS 27 Dock icons for iPhone Mirroring, Keynote and Numbers:
#   tile        field gradient, top / middle / bottom
#   glow        soft light behind the rear bubble (colour, opacity)
#   rear        rear bubble gradient, its top-left to bottom-right
#   lift        what the front glass adds to whatever is behind it, per R/G/B
#               (0..1 added to each channel, like a plus-lighter glass layer)
#   frost       blur of the scene seen through the front glass (full master)
#   veil        tint laid over the glass, and its opacity for full / small
#   glass_sheen white at the top of the glass, fading out downwards
#   rim         colour of the thin bright rim on both bubbles
#   shadow      cast-shadow colour and opacity for full / small
#   line1/2     transcript ink and translation line colours
#   layer_*     flat colours for the Icon Composer layers
PALETTES = {
    # iPhone Mirroring: cornflower field, deep ultramarine rear, pale glass in
    # front that turns lavender where it covers the rear; Keynote's indigo.
    "mirroring": dict(
        label="Mirroring Blue",
        tile=["#6AA7FA", "#4F8EFB", "#3B76EF"],
        glow=("#DDEBFF", 0.10), sheen=0.10,
        rear=["#3747C2", "#2736A3", "#1C2789"],
        rear_rim=0.30,
        lift=(0.25, 0.26, 0.26), frost=8,
        veil=("#E6F7FF", 0.10, 0.22), glass_sheen=0.20,
        rim="#DDF5FF", rim_opacity=0.85,
        shadow=("#0A1B6E", 0.30, 0.42),
        line1=("#192A8E", 0.95), line2=["#FFFFFF", "#D3F1FF"],
        layer_rear="#2736A3", layer_glass="#BFE6FF",
    ),
    # Keynote: deep blue-to-indigo field, sky-blue rear, ice glass in front.
    "keynote": dict(
        label="Keynote Deep Blue",
        tile=["#1767C3", "#0F4597", "#13206C"],
        glow=("#7CC6FF", 0.10), sheen=0.08,
        rear=["#62C4FB", "#3C9FEE", "#2478D9"],
        rear_rim=0.40,
        lift=(0.20, 0.21, 0.22), frost=8,
        veil=("#E4F5FF", 0.18, 0.38), glass_sheen=0.18,
        rim="#D2F0FF", rim_opacity=0.85,
        shadow=("#040D45", 0.38, 0.50),
        line1=("#0F1E68", 0.95), line2=["#1F74E4", "#1557C6"],
        layer_rear="#3C9FEE", layer_glass="#CDEBFF",
    ),
    # Numbers: green field into teal-black, vivid green rear, mint glass.
    "numbers": dict(
        label="Numbers Green",
        tile=["#228C34", "#0F5B27", "#07332D"],
        glow=("#B6FF7A", 0.08), sheen=0.08,
        rear=["#62D83C", "#30B42F", "#169226"],
        rear_rim=0.40,
        lift=(0.20, 0.22, 0.20), frost=8,
        veil=("#EEFFE6", 0.18, 0.38), glass_sheen=0.18,
        rim="#E4FFD6", rim_opacity=0.85,
        shadow=("#02190F", 0.38, 0.50),
        line1=("#0A3420", 0.95), line2=["#1EA132", "#108428"],
        layer_rear="#30B42F", layer_glass="#D2F5D0",
    ),
}
VARIANTS = ["mirroring", "keynote", "numbers"]
SELECTED = "mirroring"  # see report.md: chosen on look and on the small-size contrast numbers

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

def build_svg(master="full", palette=SELECTED, tail="notch"):
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
             "Generated by IconColourRevision/generate_icon.py; edit parameters there or this file directly. -->")
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
    glow, glow_opacity = P["glow"]
    s.append(f'<radialGradient id="tileGlow" cx="{num(bx + bw * 0.5)}" cy="{num(by + bh * 0.6)}" r="560" '
             f'gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{glow}" '
             f'stop-opacity="{glow_opacity}"/><stop offset="1" stop-color="{glow}" stop-opacity="0"/>'
             '</radialGradient>')
    s.append(f'<linearGradient id="tileSheen" x1="0" y1="{ty}" x2="0" y2="{ty + 380}" gradientUnits="userSpaceOnUse">'
             f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="{P["sheen"]}"/>'
             '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>')
    # Bright thin rim: strongest along the top, as on Apple's Liquid Glass tiles.
    s.append(f'<linearGradient id="tileRim" x1="0" y1="{ty}" x2="0" y2="{ty + th}" gradientUnits="userSpaceOnUse">'
             '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.55"/>'
             '<stop offset="0.3" stop-color="#FFFFFF" stop-opacity="0.16"/>'
             '<stop offset="0.8" stop-color="#FFFFFF" stop-opacity="0.08"/>'
             '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0.22"/></linearGradient>')
    b = P["rear"]
    s.append(f'<linearGradient id="backFill" x1="{num(bx)}" y1="{num(by)}" x2="{num(bx + bw * 0.45)}" '
             f'y2="{num(by + bh * 1.25)}" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{b[0]}"/>'
             f'<stop offset="0.5" stop-color="{b[1]}"/><stop offset="1" stop-color="{b[2]}"/></linearGradient>')
    s.append(f'<linearGradient id="glassSheen" x1="0" y1="{num(fy)}" x2="0" y2="{num(fy + bh * 0.8)}" '
             'gradientUnits="userSpaceOnUse">'
             f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="{P["glass_sheen"]}"/>'
             '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>')
    l2 = P["line2"]
    fcx = fx + bw / 2
    s.append(f'<linearGradient id="line2Fill" x1="{num(fcx - L["l2"] / 2)}" y1="0" x2="{num(fcx + L["l2"] / 2)}" '
             f'y2="0" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{l2[0]}"/>'
             f'<stop offset="1" stop-color="{l2[1]}"/></linearGradient>')

    # Tile drop shadow: unchanged from the original (dy 8, blur 14, 25% black;
    # matches Apple's macOS 27 icons), so the icon's alpha channel is unchanged.
    s.append('<filter color-interpolation-filters="sRGB" id="tileShadow" x="-10%" y="-10%" width="120%" height="125%">'
             '<feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="8" result="o"/>'
             '<feFlood flood-color="#000" flood-opacity="0.25"/><feComposite in2="o" operator="in"/>'
             '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>')
    shade, shade_full, shade_small = P["shadow"]
    # Bubble shadows are tinted with the family's deepest colour, not black.
    s.append('<filter color-interpolation-filters="sRGB" id="castSoft" x="-30%" y="-30%" width="160%" height="170%">'
             f'<feGaussianBlur in="SourceAlpha" stdDeviation="{8 if small else 22}"/>'
             f'<feOffset dy="{8 if small else 20}" result="o"/>'
             f'<feFlood flood-color="{shade}" flood-opacity="{shade_small if small else shade_full}"/>'
             '<feComposite in2="o" operator="in"/></filter>')
    s.append('<filter color-interpolation-filters="sRGB" id="castTight" x="-30%" y="-30%" width="160%" height="170%">'
             '<feGaussianBlur in="SourceAlpha" stdDeviation="4"/><feOffset dy="4" result="o"/>'
             f'<feFlood flood-color="{shade}" flood-opacity="0.16"/><feComposite in2="o" operator="in"/></filter>')
    # Glass: the scene behind the front bubble, lightly blurred, with a fixed
    # amount added to each channel (a plus-lighter layer). A deep rear seen
    # through it turns lavender, the field turns pale, as on iPhone Mirroring.
    lr, lg, lb = P["lift"]
    blur = "" if small else f'<feGaussianBlur stdDeviation="{P["frost"]}"/>'
    s.append('<filter color-interpolation-filters="sRGB" id="glassLift" x="-20%" y="-20%" width="140%" height="140%">'
             f'{blur}<feComponentTransfer><feFuncR type="linear" slope="1" intercept="{lr}"/>'
             f'<feFuncG type="linear" slope="1" intercept="{lg}"/>'
             f'<feFuncB type="linear" slope="1" intercept="{lb}"/></feComponentTransfer></filter>')
    # Lit top edge inside a shape: a thin specular line, not a bevel.
    s.append('<filter color-interpolation-filters="sRGB" id="rimLight" x="-10%" y="-10%" width="120%" height="120%">'
             '<feGaussianBlur in="SourceAlpha" stdDeviation="1.5" result="b"/>'
             f'<feOffset in="b" dx="{2 if small else 1.5}" dy="{6 if small else 3}" result="o"/>'
             '<feComposite in="SourceAlpha" in2="o" operator="out" result="edge"/>'
             f'<feFlood flood-color="{P["rim"]}" flood-opacity="0.9"/>'
             '<feComposite in2="edge" operator="in"/></filter>')
    # Thin even bright ring around a shape's edge.
    s.append('<filter color-interpolation-filters="sRGB" id="ring" x="-10%" y="-10%" width="120%" height="120%">'
             '<feMorphology in="SourceAlpha" operator="erode" radius="2.5" result="e"/>'
             '<feComposite in="SourceAlpha" in2="e" operator="out" result="r"/>'
             f'<feFlood flood-color="{P["rim"]}" flood-opacity="{P["rim_opacity"]}"/>'
             '<feComposite in2="r" operator="in"/></filter>')
    s.append("</defs>")

    # tile
    s.append('<use href="#tile" fill="url(#tileFill)"%s/>' % ("" if small else ' filter="url(#tileShadow)"'))
    s.append('<g clip-path="url(#tileClip)">')
    s.append('<use href="#tile" fill="url(#tileGlow)"/>')
    s.append('<use href="#tile" fill="url(#tileSheen)"/>')

    # rear bubble: solid, one step deeper (or lighter) than the field
    s.append('<use href="#back" filter="url(#castSoft)"/>')
    s.append('<use href="#back" fill="url(#backFill)"/>')
    s.append(f'<use href="#back" fill="#000" filter="url(#rimLight)" opacity="{P["rear_rim"]}"/>')
    if not small:
        s.append(f'<use href="#back" fill="#000" filter="url(#ring)" opacity="{P["rear_rim"]}"/>')

    # front bubble: clear glass over the field and the rear bubble
    veil, veil_full, veil_small = P["veil"]
    s.append('<use href="#front" filter="url(#castSoft)" opacity="0.75"/>')
    if not small:
        s.append('<use href="#front" filter="url(#castTight)"/>')
    s.append('<g clip-path="url(#frontClip)">')
    s.append('<g filter="url(#glassLift)"><use href="#tile" fill="url(#tileFill)"/>'
             '<use href="#tile" fill="url(#tileGlow)"/><use href="#back" filter="url(#castSoft)"/>'
             '<use href="#back" fill="url(#backFill)"/></g>')
    s.append(f'<use href="#front" fill="{veil}" fill-opacity="{veil_small if small else veil_full}"/>')
    s.append('<use href="#front" fill="url(#glassSheen)"/>')
    s.append("</g>")
    s.append('<use href="#front" fill="#000" filter="url(#rimLight)"/>')
    if not small:
        s.append('<use href="#front" fill="#000" filter="url(#ring)"/>')

    # caption lines: transcript (ink) above its translation
    ink, ink_opacity = P["line1"]
    s.append(f'<g fill="{ink}" fill-opacity="{ink_opacity}">{pill(*rows[0])}</g>')
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


LAYER_FILES = ["0-background.svg", "1-rear-bubble.svg", "2-glass-bubble.svg", "3-captions.svg"]


def write_layers(layer_dir, palette=SELECTED):
    """Flat, unmasked layers for Icon Composer (macOS 26+ Liquid Glass icons).

    Icon Composer adds the rounded mask, specular rim, translucency, blur and
    shadows itself, so these carry shapes and flat fills only: no filters, no
    opacity, no gradients on the foreground layers. The background is full
    bleed (no tile mask) with the field gradient.
    """
    os.makedirs(layer_dir, exist_ok=True)
    P, L, T = PALETTES[palette], LAYOUTS["full"], TAILS["notch"]
    bx, by = L["back"]
    fx, fy = bx + L["off"][0], by + L["off"][1]
    rows = captions(L)
    head = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
    t = P["tile"]
    layers = {
        "0-background.svg": (
            '<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1024" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{t[0]}"/><stop offset="0.55" stop-color="{t[1]}"/>'
            f'<stop offset="1" stop-color="{t[2]}"/></linearGradient></defs>'
            '<rect width="1024" height="1024" fill="url(#g)"/>'),
        "1-rear-bubble.svg": f'<path fill="{P["layer_rear"]}" d="{bubble(bx, by, L["w"], L["h"], L["r"], T)}"/>',
        "2-glass-bubble.svg": f'<path fill="{P["layer_glass"]}" d="{bubble(fx, fy, L["w"], L["h"], L["r"], T)}"/>',
        "3-captions.svg": (
            f'<g fill="{P["line1"][0]}">{pill(*rows[0])}</g>'
            f'<g fill="{P["line2"][1]}">{pill(*rows[1])}</g>'),
    }
    for name in LAYER_FILES:
        write(os.path.join(layer_dir, name), head + layers[name] + "</svg>")


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


# --------------------------------------------------------------------------
# Geometry check against the original candidate
# --------------------------------------------------------------------------

GEOMETRY_RE = re.compile(r'<path id="(?:tile|back|front)" d="[^"]*"/>|<rect [^>]*/>|<path [^>]*\bd="[^"]*"')


def geometry(svg_text):
    """Every shape in an SVG: the tile/bubble path elements and caption rects, colours stripped."""
    shapes = GEOMETRY_RE.findall(svg_text)
    return [re.sub(r'\s(?:fill|stroke|opacity|fill-opacity)="[^"]*"', "", s) for s in shapes]


def load_original():
    """Import IconCandidate/generate_icon.py without writing __pycache__ into IconCandidate/."""
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("original_generator", os.path.join(ORIGINAL, "generate_icon.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read(path):
    with open(path) as f:
        return f.read()


def check_geometry():
    """Stop unless every variant's shapes are byte-identical to the original's.

    Compared, per master: the original generator's output, the original SVG
    files on disk, and (for the full master) the Icon Composer layer files.
    """
    orig = load_original()
    lines = []
    for master, fname in MASTER_FILES.items():
        ref_gen = geometry(orig.build_svg(master, "ember", "notch"))
        ref_file = geometry(read(os.path.join(ORIGINAL, "source", fname)))
        if ref_gen != ref_file:
            sys.exit(f"original generator and {fname} disagree; cannot use them as reference")
        for v in VARIANTS:
            mine = geometry(build_svg(master, v))
            if mine != ref_file:
                sys.exit(f"geometry changed: master={master} variant={v}")
        lines.append(f"{fname}: {len(ref_file)} shapes (tile, rear, front, {len(ref_file) - 3} caption) "
                     f"identical to IconCandidate/source/{fname} in all {len(VARIANTS)} variants")
    orig_layers = os.path.join(ORIGINAL, "source", "icon-composer-layers")
    ref = [geometry(read(os.path.join(orig_layers, n)))
           for n in ("1-amber-bubble.svg", "2-glass-bubble.svg", "3-captions.svg")]
    tmp = tempfile.mkdtemp()
    try:
        for v in VARIANTS:
            write_layers(tmp, v)
            mine = [geometry(read(os.path.join(tmp, n))) for n in LAYER_FILES[1:]]
            if mine != ref:
                sys.exit(f"Icon Composer layer geometry changed: variant={v}")
    finally:
        shutil.rmtree(tmp)
    lines.append("icon-composer-layers: rear bubble, glass bubble and caption shapes identical to "
                 "IconCandidate/source/icon-composer-layers in all variants")
    return lines


def check_alpha(icns):
    """Compare every representation's alpha channel with IconCandidate/AppIcon.icns.

    Every fully opaque and fully transparent pixel must match. Pixels on the
    tile's anti-aliased edge (alpha strictly between 0 and 255 in the
    original) may differ slightly, because the rim, sheen and glow drawn over
    the tile edge changed opacity; the tile outline itself is unchanged.
    """
    work = tempfile.mkdtemp()
    try:
        a, b = os.path.join(work, "orig.iconset"), os.path.join(work, "new.iconset")
        subprocess.run(["iconutil", "--convert", "iconset", os.path.join(ORIGINAL, "AppIcon.icns"), "--output", a],
                       check=True)
        subprocess.run(["iconutil", "--convert", "iconset", icns, "--output", b], check=True)
        if sorted(os.listdir(a)) != sorted(os.listdir(b)):
            sys.exit(f"representation sets differ: {sorted(os.listdir(a))} vs {sorted(os.listdir(b))}")
        lines = []
        for name, _, size in RENDITIONS:
            pa = Image.open(os.path.join(a, name)).getchannel("A").tobytes()
            pb = Image.open(os.path.join(b, name)).getchannel("A").tobytes()
            diff = [(x, y) for x, y in zip(pa, pb) if x != y]
            solid = [d for d in diff if d[0] in (0, 255)]
            worst = max((abs(x - y) for x, y in diff), default=0)
            if solid or worst > 16:
                sys.exit(f"alpha channel differs in {name}: {len(solid)} opaque/clear pixels, max step {worst}")
            edge = sum(1 for x in pa if 0 < x < 255)
            lines.append(f"{name} ({size} px): opaque and clear pixels identical; "
                         f"{len(diff)} of {edge} edge pixels differ, by at most {worst}/255")
        return lines
    finally:
        shutil.rmtree(work)


# --------------------------------------------------------------------------
# Small-size readability
# --------------------------------------------------------------------------

# Pixel (column, row) at 32 and 16 px whose whole footprint lies inside one
# region of the 32 / 16 master (worked out from LAYOUTS, away from rounded
# corners, captions and the rear bubble's cast shadow).
PROBES = {
    "32": dict(field=(5, 8), rear=(8, 16), glass=(24, 9), overlap=(13, 14), line1=(18, 10), line2=(18, 13)),
    "16": dict(field=(2, 5), rear=(4, 8), glass=(12, 6), overlap=(7, 7), line1=(9, 5)),
}
# (label, region a, region b): what has to stay apart for the icon to read.
PAIRS = {
    "32": [("rear / field", "rear", "field"), ("glass / field", "glass", "field"),
           ("glass over rear / rear", "overlap", "rear"), ("transcript / glass", "line1", "glass"),
           ("translation / glass over rear", "line2", "overlap")],
    "16": [("rear / field", "rear", "field"), ("glass / field", "glass", "field"),
           ("glass over rear / rear", "overlap", "rear"), ("transcript / glass over rear", "line1", "overlap")],
}


def _linear(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _lab(rgb):
    r, g, b = (_linear(c) for c in rgb)
    xyz = (0.4124 * r + 0.3576 * g + 0.1805 * b, 0.2126 * r + 0.7152 * g + 0.0722 * b,
           0.0193 * r + 0.1192 * g + 0.9505 * b)
    f = [t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
         for t in (xyz[0] / 0.95047, xyz[1], xyz[2] / 1.08883)]
    return 116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2])


def contrast(c1, c2):
    """WCAG 2 contrast ratio and CIE76 colour difference of two sRGB colours."""
    l1 = sum(w * _linear(c) for w, c in zip((0.2126, 0.7152, 0.0722), c1))
    l2 = sum(w * _linear(c) for w, c in zip((0.2126, 0.7152, 0.0722), c2))
    ratio = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    return ratio, math.dist(_lab(c1), _lab(c2))


def readability(pngs):
    """pngs: {"32": path, "16": path}. Returns rows of (size, pair, colour a, colour b, ratio, dE)."""
    rows = []
    for master in ("32", "16"):
        im = Image.open(pngs[master]).convert("RGB")
        px = {k: im.getpixel(p) for k, p in PROBES[master].items()}
        for label, a, b in PAIRS[master]:
            ratio, de = contrast(px[a], px[b])
            rows.append((int(master), label, "#%02X%02X%02X" % px[a], "#%02X%02X%02X" % px[b],
                         round(ratio, 2), round(de, 1)))
    return rows


# --------------------------------------------------------------------------
# Comparison sheet
# --------------------------------------------------------------------------

def _round_rect(draw, box, r, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


def comparison_sheet(out_path, columns):
    """Original plus each variant: 256 px icon, true-size 64/32/16 on light and
    dark, 32 and 16 px magnified, palette chips and the small-size scores.

    columns: list of dict(title, subtitle, svgs={master: path}, chips=[(name, hex)],
    score=str, selected=bool).
    """
    s = 2  # drawn at 2x so text and chips stay crisp; icon pixels are scaled with NEAREST
    col_w, pad, top = 360, 28, 112
    W = pad + len(columns) * (col_w + pad)
    H = 846
    sheet = Image.new("RGBA", (W * s, H * s), (242, 242, 245, 255))
    draw = ImageDraw.Draw(sheet)
    ink, sub, faint = (29, 29, 31, 255), (99, 99, 106, 255), (170, 170, 178, 255)
    draw.text((pad * s, 30 * s), "SubtitleGen icon — colour & material revision", fill=ink, font=_font(26 * s))
    draw.text((pad * s, 66 * s), "Same geometry in every column (tile, bubbles, tails, captions); only palette, "
              "opacity, glass, light and shadow differ.", fill=sub, font=_font(14 * s))
    work = tempfile.mkdtemp()
    try:
        for i, col in enumerate(columns):
            x0 = pad + i * (col_w + pad)
            card = (x0 * s, top * s, (x0 + col_w) * s, (H - pad) * s)
            if col["selected"]:
                _round_rect(draw, card, 22 * s, (255, 255, 255, 255), outline=(10, 132, 255, 255), width=3 * s)
            else:
                _round_rect(draw, card, 22 * s, (255, 255, 255, 255), outline=(222, 222, 228, 255), width=1 * s)
            y = top + 18
            draw.text(((x0 + 20) * s, y * s), col["title"], fill=ink, font=_font(18 * s))
            if col["selected"]:
                tw = draw.textlength("SELECTED", font=_font(11 * s))
                bx1 = (x0 + col_w - 20) * s
                _round_rect(draw, (bx1 - tw - 20 * s, (y + 1) * s, bx1, (y + 21) * s), 10 * s, (10, 132, 255, 255))
                draw.text((bx1 - tw - 10 * s, (y + 4) * s), "SELECTED", fill=(255, 255, 255, 255), font=_font(11 * s))
            draw.text(((x0 + 20) * s, (y + 26) * s), col["subtitle"], fill=sub, font=_font(12 * s))

            def png(master, size):
                out = os.path.join(work, f"{i}-{master}-{size}.png")
                render(col["svgs"][master], size, out)
                return Image.open(out).convert("RGBA")

            # 256 px icon, rendered at 512 for the 2x sheet
            big = png("full", 256 * s)
            y = top + 66
            sheet.alpha_composite(big, ((x0 + (col_w - 256) // 2) * s, y * s))
            y += 256 + 14
            # true-size strip on light and dark
            for bg, fg in (((246, 246, 248, 255), sub), ((30, 30, 32, 255), (190, 190, 196, 255))):
                _round_rect(draw, ((x0 + 16) * s, y * s, (x0 + col_w - 16) * s, (y + 92) * s), 14 * s, bg)
                xx = x0 + 30
                for master, size in (("full", 64), ("32", 32), ("16", 16)):
                    im = png(master, size).resize((size * s, size * s), Image.NEAREST)
                    sheet.alpha_composite(im, (xx * s, (y + 12 + (64 - size)) * s))
                    draw.text((xx * s, (y + 78) * s), f"{size}", fill=fg, font=_font(10 * s))
                    xx += size + 14
                xx += 8
                # magnified 32 and 16
                for master, size, z in (("32", 32, 2), ("16", 16, 4)):
                    im = png(master, size).resize((size * z * s, size * z * s), Image.NEAREST)
                    sheet.alpha_composite(im, (xx * s, (y + 12) * s))
                    draw.text((xx * s, (y + 78) * s), f"{size} x{z}", fill=fg, font=_font(10 * s))
                    xx += size * z + 14
                y += 100
            # palette chips
            y += 6
            for j, (name, hexcol) in enumerate(col["chips"]):
                cx = x0 + 20 + (j % 3) * 104
                cy = y + (j // 3) * 40
                rgb = tuple(int(hexcol[k:k + 2], 16) for k in (1, 3, 5)) + (255,)
                _round_rect(draw, (cx * s, cy * s, (cx + 26) * s, (cy + 26) * s), 7 * s, rgb,
                            outline=(0, 0, 0, 40), width=1 * s)
                draw.text(((cx + 32) * s, (cy + 1) * s), name, fill=sub, font=_font(10 * s))
                draw.text(((cx + 32) * s, (cy + 13) * s), hexcol, fill=ink, font=_font(10 * s))
            y += 2 * 40 + 2
            for k, text in enumerate(col["score"]):
                draw.text(((x0 + 20) * s, (y + k * 17) * s), text, fill=sub if k == 0 else ink,
                          font=_font(11 * s))
        sheet.save(out_path)
    finally:
        shutil.rmtree(work)


# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------

def _chips(P):
    return [("field top", P["tile"][0]), ("field bottom", P["tile"][2]), ("rear", P["rear"][1]),
            ("glass layer", P["layer_glass"]), ("transcript", P["line1"][0]), ("translation", P["line2"][1])]


ORIGINAL_CHIPS = [("field top", "#3B3B46"), ("field bottom", "#121217"), ("rear", "#FFA63C"),
                  ("glass layer", "#FFFFFF"), ("transcript", "#26262F"), ("translation", "#FF7A2C")]


def _min_scores(rows):
    out = {}
    for size in (32, 16):
        sel = [r for r in rows if r[0] == size]
        out[size] = (min(r[5] for r in sel), min(r[4] for r in sel))
    return out


def build():
    report = {"geometry": check_geometry()}
    for line in report["geometry"]:
        print("geometry:", line)

    work = tempfile.mkdtemp()
    try:
        # variants: SVG masters, flat layers, 1024 px PNG, small-size scores
        scores = {}
        for v in VARIANTS + ["original"]:
            if v == "original":
                svgs = {m: os.path.join(ORIGINAL, "source", f) for m, f in MASTER_FILES.items()}
            else:
                vdir = os.path.join(HERE, "variants", v)
                os.makedirs(vdir, exist_ok=True)
                svgs = {m: os.path.join(vdir, f) for m, f in MASTER_FILES.items()}
                for m, path in svgs.items():
                    write(path, build_svg(m, v))
                write_layers(os.path.join(vdir, "icon-composer-layers"), v)
                render(svgs["full"], 1024, os.path.join(vdir, "AppIcon-1024.png"))
            pngs = {}
            for m in ("32", "16"):
                pngs[m] = os.path.join(work, f"{v}-{m}.png")
                render(svgs[m], int(m), pngs[m])
            scores[v] = readability(pngs)
        report["readability"] = scores
        # Ranking: weakest key pair at 16 px first, then at 32 px.
        ranking = sorted(VARIANTS, key=lambda v: (_min_scores(scores[v])[16][0], _min_scores(scores[v])[32][0]),
                         reverse=True)
        report["ranking"] = ranking
        print("ranking by weakest small-size pair (dE at 16 px, then 32 px):", ", ".join(ranking))
        for v, rows in scores.items():
            for size, label, a, b, ratio, de in rows:
                print(f"readability {v:9s} {size:2d}px {label:30s} {a} vs {b}  contrast {ratio:5.2f}  dE {de:5.1f}")

        # selected variant: masters, layers, .icns, 1024 px, contact sheet
        os.makedirs(SRC, exist_ok=True)
        for master, fname in MASTER_FILES.items():
            write(os.path.join(SRC, fname), build_svg(master, SELECTED))
        write_layers(os.path.join(SRC, "icon-composer-layers"), SELECTED)
        iconset = os.path.join(work, "AppIcon.iconset")
        os.makedirs(iconset)
        for name, master, size in RENDITIONS:
            render(os.path.join(SRC, MASTER_FILES[master]), size, os.path.join(iconset, name))
        icns = os.path.join(HERE, "AppIcon.icns")
        subprocess.run(["iconutil", "--convert", "icns", iconset, "--output", icns], check=True)

        # Round trip: unpack the .icns and check every representation.
        check = os.path.join(work, "check.iconset")
        subprocess.run(["iconutil", "--convert", "iconset", icns, "--output", check], check=True)
        if len(os.listdir(check)) != len(RENDITIONS):
            sys.exit(f"expected {len(RENDITIONS)} representations, got {sorted(os.listdir(check))}")
        for name, _, size in RENDITIONS:
            im = Image.open(os.path.join(check, name))
            if im.size != (size, size) or im.mode != "RGBA":
                sys.exit(f"bad representation {name}: {im.size} {im.mode}")
        shutil.copy(os.path.join(check, "icon_512x512@2x.png"), os.path.join(HERE, "AppIcon-1024.png"))
        contact_sheet(check, os.path.join(HERE, "contact-sheet.png"))
        report["alpha"] = check_alpha(icns)
        for line in report["alpha"]:
            print("alpha:", line)
    finally:
        shutil.rmtree(work)

    columns = []
    for v in ["original"] + VARIANTS:
        m = _min_scores(scores[v])
        score = ["Lowest ΔE and lowest contrast over the key pairs:",
                 f"32 px   ΔE {m[32][0]:.0f}   contrast {m[32][1]:.2f}:1",
                 f"16 px   ΔE {m[16][0]:.0f}   contrast {m[16][1]:.2f}:1"]
        if v == "original":
            columns.append(dict(title="Original", subtitle="graphite + amber, opaque glass (IconCandidate)",
                                svgs={k: os.path.join(ORIGINAL, "source", f) for k, f in MASTER_FILES.items()},
                                chips=ORIGINAL_CHIPS, score=score, selected=False))
        else:
            P = PALETTES[v]
            sub = {"mirroring": "cornflower field, ultramarine rear, pale glass",
                   "keynote": "navy field, sky-blue rear, ice glass",
                   "numbers": "green field, vivid green rear, mint glass"}[v]
            letter = "ABC"[VARIANTS.index(v)]
            columns.append(dict(title=f"{letter} · {P['label']}", subtitle=sub,
                                svgs={k: os.path.join(HERE, "variants", v, f) for k, f in MASTER_FILES.items()},
                                chips=_chips(P), score=score, selected=v == SELECTED))
    comparison_sheet(os.path.join(HERE, "colour-comparison.png"), columns)

    with open(os.path.join(HERE, "validation.json"), "w") as f:
        json.dump(report, f, indent=1)
    for name in ("AppIcon.icns", "AppIcon-1024.png", "contact-sheet.png", "colour-comparison.png", "validation.json"):
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
