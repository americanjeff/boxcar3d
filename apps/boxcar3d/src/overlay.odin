// microui command-list renderer: walks the microui Context's
// command list and renders each command via the engine overlay API.
//
// microui emits 4 command types we handle: Rect, Text, Icon, Clip. Rects are
// colored quads, Text/Icons are SDF quads from the baked font atlas, Clips
// are scissor rects.
//
// Font atlas: baked offline (tools/bake_font.py, DejaVu Sans, FONT_SIZE px)
// - one spread-clamped signed-distance byte per glyph (SDF_RES atlas px per
// design px, SDF_SPREAD design px of field around each ink edge) +
// per-glyph metrics (font_data.odin, #load); app pictograms in slots 6+
// (draw_icon). One quad per glyph: the SDF shader thresholds the field with
// fwidth, so text is crisp at any display scale.

package main

import gfx "engine:graphics"
import "vendor:microui"

atlas_uploaded := false

init_overlay :: proc() {
	gfx.Overlay_Init()
}

shutdown_overlay :: proc() {
	gfx.Overlay_Shutdown()
}

// Convert the baked 1-byte/px SDF atlas to RGBA (the SDF value in every
// channel; the SDF shader reads .r) and upload once. The rgba buffer is
// kept alive (not freed) in case the GPU backend defers the initial data
// upload past the sg_make_image call.
atlas_rgba: []u8

upload_atlas :: proc() {
	if atlas_uploaded {
		return
	}
	n := FONT_ATLAS_W * FONT_ATLAS_H
	atlas_rgba = make([]u8, n * 4)
	for i in 0 ..< n {
		s := FONT_ATLAS_SDF[i]
		atlas_rgba[i * 4 + 0] = s
		atlas_rgba[i * 4 + 1] = s
		atlas_rgba[i * 4 + 2] = s
		atlas_rgba[i * 4 + 3] = s
	}
	gfx.Overlay_Upload_Atlas(i32(FONT_ATLAS_W), i32(FONT_ATLAS_H), atlas_rgba)
	atlas_uploaded = true
}

// Called after microui.end(ctx) and before gfx.Render_Frame.
render_ui_commands :: proc(ctx: ^microui.Context) {
	if !atlas_uploaded {
		upload_atlas()
	}

	w, h := gfx.Framebuffer_Size()
	gfx.Overlay_Begin(w, h)

	// SDF text outline (the frameless look's contrast rim): the shader
	// draws a smooth 1 design-px band outside each glyph's ink.
	gfx.Overlay_Set_Sdf(f32(SHADOW_COL.r) / 255.0, f32(SHADOW_COL.g) / 255.0,
						f32(SHADOW_COL.b) / 255.0, f32(SHADOW_COL.a) / 255.0,
						1.0, SDF_SPREAD)

	cmd: ^microui.Command = nil
	for microui.next_command(ctx, &cmd) {
		#partial switch v in cmd.variant {
		case ^microui.Command_Clip:
			gfx.Overlay_Clip(v.rect.x, v.rect.y, v.rect.w, v.rect.h)

		case ^microui.Command_Rect:
			col := mu_color_to_f32(v.color)
			gfx.Overlay_Rect(f32(v.rect.x), f32(v.rect.y), f32(v.rect.w), f32(v.rect.h), col)

		case ^microui.Command_Text:
			col := mu_color_to_f32(v.color)
			draw_text(v.str, v.pos, col, score_text_scale(v.font))

		case ^microui.Command_Icon:
			col := mu_color_to_f32(v.color)
			draw_icon(v.id, v.rect, col)
		}
	}

	gfx.Overlay_End()
}

// One SDF quad per character; metrics (atlas FIELD-rect + screen offsets +
// advance) from font_glyphs, indexed by ASCII code. pos.y is the top of the
// text line (microui convention); the field quad is placed at (pos.x + xoff -
// SDF_SPREAD, pos.y + yoff - SDF_SPREAD) so it covers ink + distance-field
// margin; the pen advances by xadvance. ts scales the whole line (the score
// rows' 1.5x text; 1.0 everywhere else).

draw_text :: proc(str: string, pos: microui.Vec2, color: [4]f32, ts: f32) {
	px := f32(pos.x)
	py := f32(pos.y)
	for ch in str {
		if ch & 0xc0 == 0x80 {
			continue // skip UTF-8 continuation bytes
		}
		r := int(ch)
		if r >= 128 {
			continue
		}
		g := font_glyphs[r]
		if g.aw > 0 && g.ah > 0 {
			draw_glyph(g, px, py, color, ts)
		}
		px += g.xadvance * ui_dpp * ts
	}
}

// The shader thresholds the field, so the ink edge lands exactly on the
// glyph outline.
draw_glyph :: proc(g: Glyph, px, py: f32, color: [4]f32, ts: f32) {
	fw := f32(g.aw) / f32(SDF_RES) * ts // field size in design px
	fh := f32(g.ah) / f32(SDF_RES) * ts
	sx := px + (g.xoff - SDF_SPREAD) * ui_dpp * ts
	sy := py + (g.yoff - SDF_SPREAD) * ui_dpp * ts
	u0 := f32(g.ax) / f32(FONT_ATLAS_W)
	v0 := f32(g.ay) / f32(FONT_ATLAS_H)
	u1 := f32(g.ax + g.aw) / f32(FONT_ATLAS_W)
	v1 := f32(g.ay + g.ah) / f32(FONT_ATLAS_H)
	gfx.Overlay_Sdf_Quad(
		sx,
		sy,
		fw * ui_dpp,
		fh * ui_dpp,
		u0,
		v0,
		u1,
		v1,
		color,
	)
}

// Icons are baked glyphs in font_icon_glyphs, stretched to fill the rect.
// Slots 0..4: microui's own icons (CLOSE ✕, CHECK ✓, COLLAPSED ▶, EXPANDED ▼,
// RESIZE ⇲); slot 5: microui's WHITE ■ (never emitted, not handled here).
// Slots 6+: app icons (ui.odin's Ui_Icon, value + 6 = the table slot).

draw_icon :: proc(id: microui.Icon, rect: microui.Rect, color: [4]f32) {
	gi := -1
	#partial switch id {
	case .CLOSE:
		gi = 0
	case .CHECK:
		gi = 1
	case .COLLAPSED:
		gi = 2
	case .EXPANDED:
		gi = 3
	case .RESIZE:
		gi = 4
	case:
		// App icon slot (Ui_Icon value + 6): no per-slot case to forget.
		if u32(id) >= 6 && u32(id) < u32(len(font_icon_glyphs)) {gi = int(u32(id))}
	}
	if gi < 0 || gi >= int(len(font_icon_glyphs)) {
		return
	}
	g := font_icon_glyphs[gi]
	if g.aw == 0 || g.ah == 0 {
		return
	}
	u0 := f32(g.ax) / f32(FONT_ATLAS_W)
	v0 := f32(g.ay) / f32(FONT_ATLAS_H)
	u1 := f32(g.ax + g.aw) / f32(FONT_ATLAS_W)
	v1 := f32(g.ay + g.ah) / f32(FONT_ATLAS_H)
	// Aspect-fit the INK into the rect (centered); the quad extends
	// SDF_SPREAD*s past the ink on every side (field margin, where the
	// shader draws the outline band).
	ink_w := f32(g.aw) / f32(SDF_RES) - 2 * SDF_SPREAD
	ink_h := f32(g.ah) / f32(SDF_RES) - 2 * SDF_SPREAD
	s := min(f32(rect.w) / ink_w, f32(rect.h) / ink_h)
	dw := (f32(g.aw) / f32(SDF_RES)) * s
	dh := (f32(g.ah) / f32(SDF_RES)) * s
	dx := f32(rect.x) + (f32(rect.w) - ink_w * s) / 2 - SDF_SPREAD * s
	dy := f32(rect.y) + (f32(rect.h) - ink_h * s) / 2 - SDF_SPREAD * s
	gfx.Overlay_Sdf_Quad(dx, dy, dw, dh, u0, v0, u1, v1, color)
}

mu_color_to_f32 :: proc(c: microui.Color) -> [4]f32 {
	return {f32(c.r) / 255.0, f32(c.g) / 255.0, f32(c.b) / 255.0, f32(c.a) / 255.0}
}
