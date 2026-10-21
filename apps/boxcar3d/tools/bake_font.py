#!/usr/bin/env python3
"""Bake DejaVu Sans into an SDF atlas + Odin metrics for the microui overlay.

Each glyph is stored as a spread-clamped signed distance field (distance in
DESIGN px, positive inside the ink), sampled on a SDF_RES x FONT_SIZE grid.
The fragment shader thresholds the field with fwidth antialiasing and draws
the 1 px contrast outline as a distance band - crisp at any display scale
(it replaced the old 8-bit alpha bake).

Run once (or whenever the font/size changes):

    python3 apps/boxcar3d/tools/bake_font.py

Outputs:
  apps/boxcar3d/assets/font_atlas.bin   - SDF bytes (ATLAS_W * ATLAS_H)
  apps/boxcar3d/src/font_data.odin      - Glyph struct + per-glyph metrics + #load

Per-glyph metrics stored: atlas FIELD-rect (ax,ay,aw,ah in atlas px) - the
ink rect expanded by SDF_SPREAD on every side - + screen offsets (xoff,yoff
from the pen/ascender-top to the INK origin) + advance (xadvance). The
renderer draws each glyph's field quad at (pos.x + xoff - SDF_SPREAD,
pos.y + yoff - SDF_SPREAD), sized field_w = aw/SDF_RES, and advances the pen
by xadvance. The field clamps to ±SDF_SPREAD at the rect edge, so packed
regions meet at the same value and need no bleed padding.

Distance fields: glyphs are rasterized at SS x FONT_SIZE (FreeType), the
8x mask gets an exact Euclidean distance transform (scipy), and the field is
bilinear-sampled onto the SDF_RES grid (2x pixel centers fall between 8x
pixels, so each sample averages two 8x values). Custom icons are drawn at 2x
(48x48, as before), thresholded, and upscaled to the 8x grid.
"""

import os
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from scipy.ndimage import distance_transform_edt

FONT_PATH = "/usr/share/fonts/TTF/DejaVuSans.ttf"
FONT_SIZE = 16
ATLAS_W = 1024
PAD = 1  # atlas px between field regions (they meet at value 0 anyway)
SDF_RES = 2   # atlas px per design px (the 2x grid the field is stored on)
SS = 8        # raster supersampling for the distance transform
SDF_SPREAD = 4.0  # design px of field captured around the ink (outline + AA)

# ASCII 32..126 (printable). microui indexes font glyphs by ASCII code.
ASCII_RANGE = range(32, 127)
# Icons in microui-Icon order: CLOSE, CHECK, COLLAPSED, EXPANDED, RESIZE, WHITE.
# Mapped to Unicode symbols DejaVu Sans contains (verified via fc-list :charset=).
ICON_CHARS = ["\u2715", "\u2713", "\u25B6", "\u25BC", "\u21F2", "\u25A0"]

# App icons (boxcar3d top bar), continuing the table at slot 6, in table
# order. (kind, payload, name): "char" bakes a DejaVu Sans glyph (verified
# present), "draw" renders draw_custom_icons(payload). DejaVu's ⏸/⏭ render
# as hollow boxes at 24 px, so those two are drawn.
APP_ICONS = [
    ("char", "\u25B6", "PLAY"),    # ▶
    ("draw", "PAUSE", None),       # two bars
    ("draw", "SKIP", None),        # ▶|
    ("char", "\u00BB", "FF"),      # »
    ("char", "\u21BB", "RESEED"),  # ↻
    ("draw", "CARS3", None),       # three boxcars
    ("draw", "DICE", None),        # die (quincunx)
    ("draw", "HELIX", None),       # double helix
    ("draw", "TROPHY", None),      # cup (the "best" readout)
    ("draw", "SHARE", None),       # share nodes (three dots + two links)
]


def draw_custom_icons(name: str, d, canvas) -> None:
    """Draw one pictogram into `canvas` (48x48 L, 2x space) via `d`.

    `canvas` is passed too because some glyphs composite rotated pieces and
    need a masked paste (ImageDraw alone can't)."""
    if name == "PAUSE":
        # Two rounded bars (DejaVu's ⏸ bakes as a hollow box).
        d.rounded_rectangle([7 * 2, 6 * 2, 11 * 2, 18 * 2], radius=2, fill=255)
        d.rounded_rectangle([13 * 2, 6 * 2, 17 * 2, 18 * 2], radius=2, fill=255)
    elif name == "SKIP":
        # Play triangle + right bar (DejaVu's ⏭ bakes as a hollow box).
        d.polygon([(7 * 2, 6 * 2), (7 * 2, 18 * 2), (15 * 2, 12 * 2)], fill=255)
        d.rounded_rectangle([17 * 2, 6 * 2, 20 * 2, 18 * 2], radius=1.5, fill=255)
    elif name == "CARS3":
        # Three mini boxcars scattered at different angles (the pack - a
        # jumble, not a file). Each car is drawn on a padded 4x canvas
        # and MASKED-pasted (an unmasked paste writes the rotated piece's
        # empty corners over neighbors and punches square notches).
        # Before each car goes down, its dilated silhouette is pasted as
        # background: a ~1-unit dark moat keeps overlapping cars from
        # fusing into one blob at 18 px.
        def car4x():
            c = Image.new("L", (68, 60), 0)  # 17x15 design, 2u padding
            m = ImageDraw.Draw(c)
            m.rounded_rectangle([10, 10, 58, 32], radius=9, fill=255)
            for wx in (22, 48):
                m.ellipse([wx - 8, 42 - 8, wx + 8, 42 + 8], fill=255)
            return c

        def put(cx, cy, angle):
            rot = car4x().rotate(angle, resample=Image.BICUBIC, expand=True)
            halo = rot.filter(ImageFilter.MaxFilter(9))  # +1 design unit
            for piece in (halo, rot):
                # piece is 4x; the canvas is 2x -> halve ONCE (a /4 here
                # drew every car at half its designed size).
                small = piece.resize((int(piece.width / 2),
                                      int(piece.height / 2)), Image.LANCZOS)
                x = int(cx * 2 - small.width / 2)
                y = int(cy * 2 - small.height / 2)
                if piece is halo:
                    canvas.paste(0, (x, y), small)  # carve the moat
                else:
                    canvas.paste(small, (x, y), small)  # AA car
        put(8, 6, -12)
        put(16.5, 12, 9)
        put(8, 18, -6)
    elif name == "DICE":
        # Die face with a quincunx of five pips (the "randomize" glyph).
        # The pips are cut out (alpha 0) so they read at any tint.
        d.rounded_rectangle([4 * 2, 4 * 2, 20 * 2, 20 * 2], radius=4, fill=255)
        for cx, cy in ((8, 8), (16, 8), (12, 12), (8, 16), (16, 16)):
            d.ellipse([cx * 2 - 2.5, cy * 2 - 2.5, cx * 2 + 2.5, cy * 2 + 2.5],
                      fill=0)
    elif name == "HELIX":
        # Double helix: two anti-phase sine strands (one turn over the
        # height) + four rungs, the "evolve in background" glyph.
        def strand(phase: float):
            pts = []
            for k in range(33):
                y = 4 + 16 * k / 32
                x = 12 + 5 * math.sin(math.pi * y / 8 + phase)
                pts.append((x * 2, y * 2))
            return pts
        d.line(strand(0.0), fill=255, width=3, joint="curve")
        d.line(strand(math.pi), fill=255, width=3, joint="curve")
        for y in (6.0, 10.0, 14.0, 18.0):
            s = math.sin(math.pi * y / 8)
            x0, x1 = 12 + 5 * s, 12 - 5 * s
            d.line([min(x0, x1) * 2, y * 2, max(x0, x1) * 2, y * 2],
                   fill=255, width=2)
    elif name == "TROPHY":
        # Cup (flat top, round bottom) + side handles + stem + base:
        # the "best" readout glyph.
        d.rectangle([7 * 2, 4 * 2, 17 * 2, 9 * 2], fill=255)
        d.pieslice([7 * 2, 3 * 2, 17 * 2, 13 * 2], 0, 180, fill=255)
        d.arc([4 * 2, 5 * 2, 8 * 2, 10 * 2], 90, 270, fill=255, width=2)
        d.arc([16 * 2, 5 * 2, 20 * 2, 10 * 2], -90, 90, fill=255, width=2)
        d.rectangle([11 * 2, 12 * 2, 13 * 2, 16 * 2], fill=255)
        d.rounded_rectangle([8.5 * 2, 16 * 2, 15.5 * 2, 18.5 * 2],
                            radius=2, fill=255)
    elif name == "SHARE":
        # The classic share nodes: three dots (left-middle, right-top,
        # right-bottom) joined by two links - the "share this car" glyph.
        # Links first, dots over (the links stop short of the dot centers).
        d.line([9 * 2, 11 * 2, 15 * 2, 6.8 * 2], fill=255, width=3,
               joint="curve")
        d.line([9 * 2, 13 * 2, 15 * 2, 17.2 * 2], fill=255, width=3,
               joint="curve")
        for cx, cy in ((7.5, 12), (17, 5.8), (17, 18.2)):
            d.ellipse([cx * 2 - 3.2, cy * 2 - 3.2, cx * 2 + 3.2,
                       cy * 2 + 3.2], fill=255)

# (script adapted from a sibling app; lives in this app's tools/)
APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ATLAS_BIN = os.path.join(APP_DIR, "assets", "font_atlas.bin")
FONT_DATA_ODIN = os.path.join(APP_DIR, "src", "font_data.odin")


def sdf_field(mask8: np.ndarray):
    """Exact Euclidean signed distance field for an 8x ink mask.

    Returns (field, w2, h2): `field` is a uint8 array on the SDF_RES grid
    covering the ink + SDF_SPREAD on every side (values 0..255, 128 = the
    outline, clamped to ±SDF_SPREAD design px), (w2, h2) the ink size in
    SDF_RES grid px."""
    bh, bw = mask8.shape
    m8 = int(SDF_SPREAD * SS) + 2  # 8x px margin (>= the field extent)
    padded = np.zeros((bh + 2 * m8, bw + 2 * m8), bool)
    padded[m8:m8 + bh, m8:m8 + bw] = mask8
    d_in = distance_transform_edt(padded)      # inside px -> nearest outside
    d_out = distance_transform_edt(~padded)    # outside px -> nearest inside
    sd8 = np.where(padded, d_in, -d_out) / SS  # design px, positive inside
    w2, h2 = round(bw / (SS / SDF_RES)), round(bh / (SS / SDF_RES))
    m2 = int(SDF_SPREAD * SDF_RES)
    aw2, ah2 = w2 + 2 * m2, h2 + 2 * m2
    i = np.arange(aw2)[None, :]                # region-local 2x columns
    j = np.arange(ah2)[:, None]                # region-local 2x rows
    # Each 2x pixel center lands halfway between two 8x pixels (4x apart):
    # average the 2x2 neighborhood at that position.
    x8 = 4 * (i - m2) + 1 + m8
    y8 = 4 * (j - m2) + 1 + m8
    sd = (sd8[y8, x8] + sd8[y8, x8 + 1] + sd8[y8 + 1, x8] + sd8[y8 + 1, x8 + 1]) * 0.25
    field = np.clip(127.5 + (sd / SDF_SPREAD) * 127.0, 0, 255)
    return field.astype(np.uint8), w2, h2


def main() -> None:
    font = ImageFont.truetype(FONT_PATH, FONT_SIZE)
    font8 = ImageFont.truetype(FONT_PATH, FONT_SIZE * SS)
    ascent, descent = font.getmetrics()
    line_height = ascent + descent

    def bake8(ch: str):
        """Render one char at SS x FONT_SIZE. Returns (mask8 (bool, cropped
        to the ink bbox) or None, xoff, yoff, xadvance). xoff/yoff are the
        ink origin relative to the pen, in design px (anchor 'la' puts the
        ascender-top-left at the draw position, matching microui)."""
        advance = font.getlength(ch)
        cw = int(math.ceil(advance)) * SS + 8 * SS
        chh = (line_height + 8) * SS
        img = Image.new("L", (cw, chh), 0)
        draw = ImageDraw.Draw(img)
        draw.text((4 * SS, 4 * SS), ch, font=font8, fill=255, anchor="la")
        mask8 = np.asarray(img, dtype=np.uint8) >= 128
        ys, xs = np.nonzero(mask8)
        if len(xs) == 0:
            return None, 0.0, 0.0, float(advance)
        bx0, by0 = int(xs.min()), int(ys.min())
        mask8 = mask8[by0:by0 + int(ys.max()) - by0 + 1,
                      bx0:bx0 + int(xs.max()) - bx0 + 1]
        return mask8, (bx0 - 4 * SS) / SS, (by0 - 4 * SS) / SS, float(advance)

    # Bake every glyph (ASCII then icons), keeping a record per char.
    records = []  # list of dict: ch, field, xoff, yoff, xadvance, ax, ay, aw, ah
    for ch in [chr(c) for c in ASCII_RANGE] + ICON_CHARS:
        mask8, xoff, yoff, adv = bake8(ch)
        field, _, _ = sdf_field(mask8) if mask8 is not None else (None, 0, 0)
        records.append({"ch": ch, "field": field, "xoff": xoff,
                        "yoff": yoff, "xadvance": adv,
                        "ax": 0, "ay": 0, "aw": 0, "ah": 0})

    # App icons: "char" entries bake like the rest; "draw" entries render the
    # 2x canvas (as before), upscale the AA coverage to the 8x grid, and
    # threshold it (a smooth-coverage threshold keeps the 8x edge fine).
    for kind, payload, name in APP_ICONS:
        if kind == "char":
            mask8, xoff, yoff, adv = bake8(payload)
        else:
            canvas = Image.new("L", (48, 48), 0)
            draw_custom_icons(payload, ImageDraw.Draw(canvas), canvas)
            cov8 = np.asarray(canvas.resize((48 * SS // 2, 48 * SS // 2),
                                            Image.LANCZOS), dtype=np.uint8)
            mask8 = cov8 >= 128
            ys, xs = np.nonzero(mask8)
            if len(xs) == 0:
                mask8 = None
            else:
                bx0, by0 = int(xs.min()), int(ys.min())
                mask8 = mask8[by0:by0 + int(ys.max()) - by0 + 1,
                              bx0:bx0 + int(xs.max()) - bx0 + 1]
            xoff, yoff, adv = 0.0, 0.0, 0.0
        field, _, _ = sdf_field(mask8) if mask8 is not None else (None, 0, 0)
        records.append({"ch": payload, "field": field, "xoff": xoff,
                        "yoff": yoff, "xadvance": adv,
                        "ax": 0, "ay": 0, "aw": 0, "ah": 0})

    # Shelf-pack (tallest-first) the FIELD regions into a wide atlas; crop
    # height afterward. Field regions clamp to value 0 at their edges, so
    # PAD only guards against packing bugs.
    pack_order = sorted(records,
                        key=lambda r: r["field"].shape[0] if r["field"] is not None else 0,
                        reverse=True)
    atlas = np.zeros((4096, ATLAS_W), np.uint8)
    x, y, row_h = PAD, PAD, 0
    for r in pack_order:
        field = r["field"]
        if field is None:
            continue
        fh, fw = field.shape
        if x + fw + PAD > ATLAS_W:
            y += row_h + PAD
            x = PAD
            row_h = 0
        atlas[y:y + fh, x:x + fw] = field
        r["ax"], r["ay"], r["aw"], r["ah"] = x, y, fw, fh
        x += fw + PAD
        row_h = max(row_h, fh)

    used_h = y + row_h + PAD
    atlas_h = 1 << (used_h - 1).bit_length()  # round up to power of two
    atlas = atlas[:atlas_h]

    os.makedirs(os.path.dirname(ATLAS_BIN), exist_ok=True)
    with open(ATLAS_BIN, "wb") as f:
        f.write(atlas.tobytes())
    print(f"atlas: {ATLAS_W}x{atlas_h} (SDF, {SDF_RES}x density, "
          f"spread {SDF_SPREAD} px) -> {ATLAS_BIN} ({ATLAS_W * atlas_h} bytes)")

    # Build per-char lookup from the records (ASCII by code, icons in order).
    by_ch = {r["ch"]: r for r in records}

    def fmt_glyph(r) -> str:
        return "{%d, %d, %d, %d, %r, %r, %r}" % (
            r["ax"], r["ay"], r["aw"], r["ah"],
            r["xoff"], r["yoff"], r["xadvance"])

    zero = "{0, 0, 0, 0, 0.0, 0.0, 0.0}"

    # ASCII table: [128]Glyph positional literal, entries 0..31 and 127 are
    # zero glyphs; 32..126 are the baked glyphs (in ASCII order).
    ascii_lines = []
    for code in range(128):
        if code in ASCII_RANGE:
            ascii_lines.append("\t%s," % fmt_glyph(by_ch[chr(code)]))
        else:
            ascii_lines.append("\t%s," % zero)

    # Icon table: microui order first (CLOSE, CHECK, COLLAPSED, EXPANDED,
    # RESIZE, WHITE), then the app icons (Unicode chars then custom names).
    icon_names = (["CLOSE", "CHECK", "COLLAPSED", "EXPANDED", "RESIZE", "WHITE"]
                  + [(n or p) for _, p, n in APP_ICONS])
    icon_chars = ICON_CHARS + [p for _, p, _ in APP_ICONS]
    icon_lines = []
    for i, ch in enumerate(icon_chars):
        label = ch if len(ch) == 1 else ""
        icon_lines.append("\t%s,  // %s%s" % (
            fmt_glyph(by_ch[ch]), icon_names[i], " %s" % ch if label else ""))

    n_icons = len(icon_chars)
    odin = odin_source(ATLAS_W, atlas_h, line_height,
                       ascii_lines, icon_lines, n_icons)

    # Preview of the app icons (slot 6+) on button-style tiles: the eyeball
    # gate before wiring them into the top bar (ink = field > 128).
    preview = Image.new("RGB", ((n_icons - 6) * 64 + 8, 96), (60, 60, 62))
    for i in range(n_icons - 6):
        r = by_ch[icon_chars[6 + i]]
        if r["field"] is None:
            continue
        ink = (r["field"] > 128).astype(np.uint8) * 255
        sq = Image.fromarray(ink, "L")
        tx = 8 + i * 64
        preview.paste((235, 235, 235), (tx + 12, 28),
                      sq.resize((40, 40), Image.LANCZOS))
    with open("/tmp/icon_preview.png", "wb") as f:
        preview.save(f)
    print("preview: /tmp/icon_preview.png (slots 6..%d)" % (n_icons - 1))
    os.makedirs(os.path.dirname(FONT_DATA_ODIN), exist_ok=True)
    with open(FONT_DATA_ODIN, "w") as f:
        f.write(odin)
    print(f"odin:  -> {FONT_DATA_ODIN}")


def odin_source(atlas_w, atlas_h, line_height,
                ascii_lines, icon_lines, n_icons) -> str:
    return f"""// GENERATED BY tools/bake_font.py - do not edit by hand.
// Re-bake with: python3 apps/boxcar3d/tools/bake_font.py
//
// DejaVu Sans baked at {FONT_SIZE} px design size into an SDF atlas: one
// byte/px spread-clamped signed distance (design px, positive inside,
// SDF_RES = {SDF_RES} atlas px per design px), plus per-glyph metrics for
// microui's atlas-based font system. overlay.odin uploads the bytes as
// RGBA (the SDF value in every channel) and the SDF fragment shader
// thresholds with fwidth AA + a 1 px outline band (draw_text / draw_icon).
// Glyph ax/ay/aw/ah is the FIELD rect - the ink expanded by SDF_SPREAD  - 
// so the quad must extend SDF_SPREAD past the ink on every side.

package main

FONT_ATLAS_W :: {atlas_w}
FONT_ATLAS_H :: {atlas_h}
FONT_LINE_HEIGHT :: {line_height}
SDF_RES :: {SDF_RES}      // atlas px per design px
SDF_SPREAD :: {SDF_SPREAD} // design px of field captured around each ink edge

Glyph :: struct {{
	ax, ay, aw, ah: i32, // atlas FIELD-rect (ink + SDF_SPREAD margin, atlas px)
	xoff, yoff:     f32, // ink origin offset from pen (pen at text top-left)
	xadvance:       f32, // pen advance width
}}

// Indexed by ASCII code. Entries for 0..31 and 127 are zero glyphs (no ink,
// zero advance); only 32..126 are baked.
font_glyphs: [128]Glyph = {{
{chr(10).join(ascii_lines)}
}}

// Slots 0..5: microui icon order (CLOSE, CHECK, COLLAPSED, EXPANDED, RESIZE,
// WHITE), drawn from Unicode symbols DejaVu Sans provides (U+2715, U+2713,
// U+25B6, U+25BC, U+21F2, U+25A0). Slots 6+ are app icons (boxcar3d top
// bar), in table order: PLAY, PAUSE, SKIP, FF, RESEED, CARS3, DICE, HELIX,
// TROPHY, SHARE - PLAY/FF/RESEED are DejaVu Sans glyphs, the rest custom
// drawn; see tools/bake_font.py and the Ui_Icon enum in ui.odin.
font_icon_glyphs: [{n_icons}]Glyph = {{
{chr(10).join(icon_lines)}
}}

// The baked SDF atlas (1 byte/px, spread-clamped distance), embedded at
// compile time. @(rodata) makes it runtime-addressable (a `::` constant is
// compile-time-only and can't be passed to the upload proc as a []u8).
@(rodata)
FONT_ATLAS_SDF := #load("../assets/font_atlas.bin")
"""


if __name__ == "__main__":
    main()