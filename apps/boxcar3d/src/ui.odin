// microui setup + the UI shell: a single SCORE PANEL (top-left,
// auto-height) that carries both the controls and the scores. NO background
// rectangle (.NO_FRAME) and BARE glyphs - every icon and text run floats on
// the 3D scene, legible via a dark 1 px contrast outline (the SDF shader's
// distance band, see SHADOW_COL).
// Top row: the FF helix toggle + generation, PLAY/PAUSE, SKIP, RESEED, the
// pack toggle, SPEED (cycling), and at the end the trophy +
// the evolution-scoped best. The first and last are related pairs, each joined
// by a tight 6 px gap; BTN_GAP separates the items. The helix toggle and
// the car portraits share one left edge (the body's x).
// Below that: one row per car, sorted by score (live-first on ties,
// hud_car_row_less): portrait, state mark, live score. Icons are baked
// glyphs (tools/bake_font.py APP_ICONS).
//
// microui is the built-in `vendor:microui` collection; the app owns the
// input policy (mouse/scroll feed), the shim forwards raw events. Shared by
// both targets: the native window and the wasm browser (share popup + touch
// emulation).

package main

import "core:fmt"
import "core:sort"
import host "engine:apphost"
import gfx "engine:graphics"
import "vendor:microui"

ui_ctx: microui.Context

ui_mouse_x := i32(0)
ui_mouse_y := i32(0)
ui_scroll_delta := i32(0)

// Queued touch press (wasm touch emulation; always 0 on native). A press
// only registers once the control's hover is set, which takes two frames
// (the arrival frame sets the container's hover root, the next the control's
// hover, skipped while a button is down) - a zero-travel tap on the arrival
// frame would miss it. BEGAN queues the press (1); feed_ui_input steps
// 1 -> 2 -> 3, delivering it two frames after the pointer arrived.
ui_touch_down_pending := i32(0)

// Display scale (framebuffer px per logical px, gfx.Dpi_Scale). microui
// works in framebuffer pixels, so the layout multiplies every design px by
// this - the UI keeps its physical size on a HiDPI-scaled screen.
ui_dpp: f32 = 1.0

// The car portraits' row rects: recorded by build_ui, drawn by
// car_icon_render (car_icon.odin) after the microui command list - the
// overlay has no "second texture" command, so the quads go straight to the
// gfx overlay.
ui_icon_rects: [SOLO_MAX]microui.Rect
ui_icon_n := 0

init_ui :: proc() {
	microui.init(&ui_ctx)
	ui_ctx.text_width = font_text_width
	ui_ctx.text_height = font_text_height

	// Scale microui's size fields to the baked font (FONT_LINE_HEIGHT /
	// 18.0, 18.0 being microui's built-in default text height - the font
	// the layout numbers were designed for) and to ui_dpp (see its doc).
	ui_dpp = gfx.Dpi_Scale()
	ratio := f32(FONT_LINE_HEIGHT) / 18.0 * ui_dpp
	ui_ctx.style.size = microui.Vec2{i32(f32(68) * ratio), i32(f32(FONT_LINE_HEIGHT) * ui_dpp)}
	ui_ctx.style.padding = i32(f32(5) * ratio)
	ui_ctx.style.spacing = i32(f32(4) * ratio)
	ui_ctx.style.indent = i32(f32(24) * ratio)
	ui_ctx.style.title_height = i32(f32(24) * ratio)
	ui_ctx.style.footer_height = i32(f32(20) * ratio)
	ui_ctx.style.scrollbar_size = i32(f32(12) * ratio)
	ui_ctx.style.thumb_size = i32(f32(8) * ratio)

	// The car portrait atlas (car_icon.odin).
	icon_atlas_init()

	// The default control ink, saved once (the app never changes it).
	ui_def_text = ui_ctx.style.colors[.TEXT]
}

// microui metric callbacks backed by the baked font (font_data.odin).
font_text_width :: proc(font: microui.Font, str: string) -> i32 {
	_ = font
	w: i32 = 0
	for ch in str {
		if ch & 0xc0 == 0x80 {continue}
		r := int(ch)
		if r < 128 {w += i32(font_glyphs[r].xadvance + 0.5)}
	}
	return i32(f32(w) * ui_dpp)
}

font_text_height :: proc(font: microui.Font) -> i32 {
	_ = font
	return i32(f32(FONT_LINE_HEIGHT) * ui_dpp)
}

// The offset of a score string's decimal point from its start (px): the
// advances of the characters before the '.' (score strings are ASCII  - 
// tprintf "{:.1f}"). build_ui subtracts it from one shared column so the
// dots line down the list.
font_dot_offset :: proc(str: string) -> f32 {
	pre, _ := font_score_dots(str)
	return pre
}

// The advances (design px) before and after a score string's decimal
// point (score strings are ASCII). build_ui uses the widest pair to size
// the portrait's box against the score column.
font_score_dots :: proc(str: string) -> (pre, post: f32) {
	dot := -1
	i := 0
	for ch in str {
		if ch == '.' && dot < 0 {dot = i}
		i += 1
	}
	i = 0
	for ch in str {
		r := int(ch)
		if r < 128 {
			a := f32(font_glyphs[r].xadvance)
			if i < dot {pre += a} else if i > dot {post += a}
		}
		i += 1
	}
	return
}

// The score rows' text scale (the rows run 50% taller than the font's line,
// so the scores ride along). microui's Font is an opaque rawptr the app
// never fills, so the handle carries the scale: 0 = normal, 1 = large;
// overlay.odin's draw_text reads it back per command.
SCORE_FONT := microui.Font(rawptr(uintptr(1)))

score_text_scale :: proc(font: microui.Font) -> f32 {
	if uintptr(font) == 1 {
		return 1.5
	}
	return 1.0
}

// Per-frame input, called at the top of each frame before microui.begin.
feed_ui_input :: proc() {
	mx, my := host.Get_Mouse_Pos()
	microui.input_mouse_move(&ui_ctx, i32(mx), i32(my))
	if ui_scroll_delta != 0 {
		microui.input_scroll(&ui_ctx, 0, ui_scroll_delta)
		ui_scroll_delta = 0
	}
	// Deliver the queued touch press (see ui_touch_down_pending).
	if ui_touch_down_pending == 1 {
		ui_touch_down_pending = 2
	} else if ui_touch_down_pending == 2 {
		ui_touch_down_pending = 3
	} else if ui_touch_down_pending == 3 {
		ui_touch_down_pending = 0
		ui_mouse_down(.LEFT)
	}
}

ui_mouse_down :: proc(btn: microui.Mouse) {
	microui.input_mouse_down(&ui_ctx, ui_mouse_x, ui_mouse_y, btn)
}

ui_mouse_up :: proc(btn: microui.Mouse) {
	microui.input_mouse_up(&ui_ctx, ui_mouse_x, ui_mouse_y, btn)
}

mouse_over_ui :: proc() -> bool {
	return ui_ctx.hover_root != nil
}

// Score panel: fixed width, auto height (control row + one row per car).
// Column widths measured from the baked font (bake_font.py's FONT_SIZE,
// ~10 px/char at the current 16 px). Each car row leads with the car's
// SIDE-VIEW portrait (car_icon.odin's icon atlas, one textured quad per
// row); a finished car's check mark is drawn over it. The portrait starts
// at the body's left edge, the same as the helix toggle - one vertical
// line down the panel.

// Control widths (see the header for the top-row layout). The pane is
// exactly this row's width (it follows the two measured numbers); it also
// bounds the hold message, so keep it ≥ its widest text.
BTN_SEG :: i32(26) // cycling speed button ("8x" ≈ 20 px at 16 px)
BTN_GAP :: i32(12) // air between the top-row controls
ICON_S :: i32(18) // icon button: the glyph IS the button's width
PANEL_MARGIN :: i32(8) // air between the panel and the screen's left/top edge

// Speed values, in cycling order (one button steps through them).
Speed_Seg :: struct {
	label: string,
	n:     int,
}
// @(rodata): indexed at runtime (a :: constant has no runtime address).
@(rodata)
SPEED_SEGS := [4]Speed_Seg{{"1x", 1}, {"2x", 2}, {"4x", 4}, {"8x", 8}}

// App icon glyphs beyond microui's own five (bake_font.py's APP_ICONS);
// the font_icon_glyphs slot is the value + 6, continuing microui's icon
// slots.
Ui_Icon :: enum u32 {
	PLAY, // ▶
	PAUSE, // two bars
	SKIP, // ▶|
	FF, // »
	RESEED, // ↻
	CARS3, // scattered boxcars (the pack)
	DICE, // die (quincunx; in the showcase it is "evolve from here")
	HELIX, // double helix
	TROPHY, // cup (the "best" readout)
	SHARE, // share nodes (three dots + two links - the share popup)
}

ui_icon :: proc(id: Ui_Icon, rect: microui.Rect, col: microui.Color) {
	microui.draw_icon(&ui_ctx, microui.Icon(u32(id) + 6), rect, col)
}

// Default control ink, saved at init. State lives in the glyph color:
// lit = the warm accent, hover = pure white, idle = the light text.
ui_def_text: microui.Color

ui_btn_col :: proc(lit, hover: bool) -> microui.Color {
	if lit {
		return microui.Color{188, 160, 104, 255}
	}
	if hover {
		return microui.Color{255, 255, 255, 255}
	}
	return ui_def_text
}

// The dark rim every glyph gets for legibility over the 3D scene (the
// panel and buttons draw no background - see the header): the SDF shader's
// outline band, set once per frame in overlay.odin's render_ui_commands
// from SHADOW_COL, so each glyph is a single quad - no offset passes, no
// overdraw.

// The outline color fed to the SDF shader (straight 0-255).
SHADOW_COL :: microui.Color{10, 10, 10, 160}

ui_text :: proc(rect: microui.Rect, str: string, col: microui.Color,
				font: microui.Font = ui_ctx.style.font) {
	lh := i32(f32(FONT_LINE_HEIGHT) * ui_dpp * score_text_scale(font))
	pos := microui.Vec2{rect.x, rect.y + (rect.h - lh) / 2}
	microui.draw_text(&ui_ctx, font, str, pos, col)
}

// Bare icon button: no frame, the glyph IS the control. Click detection
// is the low-level update_control with a unique id from `tag`
// (microui.button won't do this job: it stretches its built-in icon
// across the whole rect, an empty label hashes EVERY such button to one
// shared id, and it draws the frame we don't want).
ui_button_icon :: proc(tag: string, rect: microui.Rect, icon: Ui_Icon, lit: bool) -> bool {
	bid := microui.get_id(&ui_ctx, tag)
	microui.update_control(&ui_ctx, bid, rect)
	submit := ui_ctx.mouse_pressed_bits == {.LEFT} && ui_ctx.focus_id == bid
	is := i32(f32(ICON_S) * ui_dpp)
	ui_icon(
		icon,
		{rect.x + (rect.w - is) / 2, rect.y + (rect.h - is) / 2, is, is},
		ui_btn_col(lit, ui_ctx.hover_id == bid),
	)
	return submit
}

// Bare text segment (the speed control): the label is the button  - 
// outlined text, no frame.
ui_button_seg :: proc(tag: string, rect: microui.Rect, label: string) -> bool {
	bid := microui.get_id(&ui_ctx, tag)
	microui.update_control(&ui_ctx, bid, rect)
	submit := ui_ctx.mouse_pressed_bits == {.LEFT} && ui_ctx.focus_id == bid
	ui_text(rect, label, ui_btn_col(false, ui_ctx.hover_id == bid))
	return submit
}

// One on-screen car in the score panel.
Hud_Car_State :: enum {
	Live,
	Finished,
	Failed,
}

Hud_Car :: struct {
	id:     int,
	colors: [N_COLORS][3]u8, // the car's 16-slot part palette
	score:  f64,
	state:  Hud_Car_State,
	pitch:  f32, // nose-up/down (radians): live = current tilt, done = the run's final tilt
}

// What the top bar draws. The shared frame driver (loop.odin) fills it each
// frame and consumes the request flags (clearing them). Keeping the panel
// off the session/viewer globals is what lets the same UI run in both
// targets.
Hud_Data :: struct {
	prog:           Evo_Progress,
	best_screen:    f64, // evolution-scoped "best" (see Pop_Viewer.best_screen)
	hold:           string, // non-empty when no cars are on screen (why)
	cars:           [SOLO_MAX]Hud_Car,
	n_cars:         int,
	// Control state (the driver fills it; the UI draws from it).
	paused:         bool,
	ff:             bool,
	speed:          int, // 1, 2, 4, or 8 physics ticks/frame
	view:           int, // 0 = concurrent pack, 1 = serial solo (the pack button is a toggle, default solo)
	showcase:       bool, // booted from a #car= link: the panel omits the evolution controls (helix/gen/pack/speed)
	// Request flags set by the UI (restart: by the evolvetest view-sequence
	// gate), consumed (and cleared) by the driver.
	toggle_pause:   bool,
	skip_requested: bool, // next unit: next car (solo) / next generation (pack)
	restart:        bool,
	reseed_track:   bool,
	reseed_cars:    bool,
	ff_requested:   bool, // toggle changed; new value in `ff`
	view_requested: bool, // the pack toggle was clicked; the driver flips view_mode
	evolve_from_here: bool, // the showcase's die glyph: warm-start a full population from the shared car
	share_requested:  bool, // the share glyph: open the share popup (wasm)
	// Rank hysteresis: the panel's row order last frame (car id per row)  - 
	// the contract is on the sort in build_ui.
	row_prev:       [SOLO_MAX]int,
	row_prev_n:     int,
}

// A car must lead its row neighbour by this much (m) to move up past it.
ROW_HYSTERESIS :: f64(0.5)

// The score panel's row order: highest score on top; a car's LIVE state
// breaks score ties; then the car's index, so the order is deterministic
// frame to frame. The fillers (solo_fill_cars / pop_viewer_fill_cars)
// write index order; the display sorts each frame. Portraits follow their
// cars: car_icon_render looks each row up by the car's own id, and the row
// rects are recorded from the same sorted array.
hud_car_row_less :: proc(a, b: Hud_Car) -> int {
	if a.score > b.score {return -1}
	if a.score < b.score {return 1}
	a_live := a.state == .Live
	b_live := b.state == .Live
	if a_live != b_live {
		if a_live {
			return -1
		}
		return 1
	}
	if a.id != b.id {
		if a.id < b.id {
			return -1
		}
		return 1
	}
	return 0
}

// The portrait quad's size for one car row (ui_icon_rects): the visible
// content (icon_slot_rect - the tile's center-fit) as large as the row
// allows - full row height (the rows' spacing keeps the quads from
// touching), width up to pw_max (the space left of the score column),
// content aspect preserved (the atlas is 2x supersampled - downscaling is
// free).
portrait_row_size :: proc(c: ^Hud_Car, row_h: i32, pw_max: i32) -> (pw, ph: i32) {
	cr := [4]f32{0, 0, f32(ICON_TILE_W), f32(ICON_TILE_H)}
	if c.id >= 0 && c.id < ICON_SLOTS {cr = icon_slot_rect[c.id]}
	cw, ch := cr[2] - cr[0], cr[3] - cr[1]
	if cw <= 0 || ch <= 0 {cw, ch = f32(ICON_W), f32(ICON_H)}
	s := f32(row_h) / ch
	pw = i32(cw * s)
	if pw > pw_max {
		s = f32(pw_max) / cw
		pw = pw_max
	}
	ph = i32(ch * s)
	if pw < 1 {pw = 1}
	if ph < 1 {ph = 1}
	return
}

build_ui :: proc(hud: ^Hud_Data) {
	microui.begin(&ui_ctx)

	fb_w, _ := gfx.Framebuffer_Size()

	// The pane is exactly the top row's width (see the header for the
	// layout); the width follows the two measured numbers (a NO_TITLE
	// window's body is the full rect, and the row starts at its left edge).
	// One uniform row pitch for every row, so the vertical gaps are equal.
	// Every design px scaled to framebuffer px (ui_dpp; style.padding/
	// spacing were already scaled in init_ui).
	lh := i32(f32(FONT_LINE_HEIGHT) * ui_dpp)
	icon_s := i32(f32(ICON_S) * ui_dpp)
	btn_seg := i32(f32(BTN_SEG) * ui_dpp)
	btn_gap := i32(f32(BTN_GAP) * ui_dpp)
	panel_margin := i32(f32(PANEL_MARGIN) * ui_dpp)
	gap6 := i32(f32(6) * ui_dpp)
	bh := lh // button-row height
	row_h := lh * 3 / 2 // score rows run 50% taller than the text row
	row_pitch := row_h + ui_ctx.style.spacing
	// The two numbers on the control row: the generation (hugging the FF
	// helix) and the best (hugging the trophy). Measured before sizing
	// the pane, since the width follows them.
	gen_num := fmt.tprintf("%d", hud.prog.generation)
	if hud.ff {
		gen_num = fmt.tprintf("%d/%d", hud.prog.generation, hud.prog.next_generation)
	}
	best_num := "--"
	if hud.best_screen > 0 {
		best_num = fmt.tprintf("{:.1f}", hud.best_screen)
	}
	gen_tw := ui_ctx.text_width(ui_ctx.style.font, gen_num)
	best_tw := ui_ctx.text_width(ui_ctx.style.font, best_num)
	// Row 0: play/skip/die/trophy/share are always present; the FF helix +
	// generation and the pack toggle + speed are normal-mode only (see
	// the showcase field).
	sw := i32(0)
	if hud.showcase {
		// play, skip, die, trophy (static), share = 5 glyphs.
		sw = 5 * icon_s + best_tw + gap6 + 5 * btn_gap
	} else {
		sw = 7 * icon_s + btn_seg + gen_tw + best_tw + 2 * gap6 + 8 * btn_gap
	}
	car_rows := i32(hud.n_cars)
	if car_rows < 1 {car_rows = 1}
	// Height: 2× padding + (control row + car rows), all on the same
	// pitch.
	sh := 2 * ui_ctx.style.padding + (1 + car_rows) * row_pitch

	// PANEL_MARGIN off the screen's left/top edges - the panel is frameless
	// (no rect of its own to act as a margin), so the glyphs would otherwise
	// hug the corner.
	sc := microui.get_container(&ui_ctx, "boxcar3d_scores")
	sc.rect.x = panel_margin
	sc.rect.y = panel_margin
	sc.rect.w = sw
	sc.rect.h = sh

	// NO_FRAME: the panel draws no background rectangle - the glyphs
	// carry their own SDF shader outline band.
	if microui.begin_window(
		&ui_ctx,
		"boxcar3d_scores",
		{panel_margin, panel_margin, sw, sh},
		{.NO_CLOSE, .NO_RESIZE, .NO_TITLE, .NO_SCROLL, .NO_FRAME},
	) {
		by := sc.body.y
		x := sc.body.x
		// The FF evolve-in-background toggle; lit when on. The generation
		// on screen sits right beside it (with FF ON the second number is
		// how far ahead the session has run).
		if !hud.showcase {
			if ui_button_icon("ff", {x, by, icon_s, bh}, .HELIX, hud.ff) {
				hud.ff = !hud.ff
				hud.ff_requested = true
			}
			x += icon_s + gap6
			ui_text({x, by, gen_tw, lh}, gen_num, ui_def_text)
			x += gen_tw + btn_gap
		}
		if ui_button_icon("play", {x, by, icon_s, bh}, hud.paused ? Ui_Icon.PLAY : .PAUSE, false) {
			hud.toggle_pause = true
		}
		x += icon_s + btn_gap
		if ui_button_icon("skip", {x, by, icon_s, bh}, .SKIP, false) {
			// Next unit in the active view - the driver consumes the request.
			hud.skip_requested = true
		}
		x += icon_s + btn_gap
		// The die: normal mode re-seeds the cars; in the showcase it is
		// "evolve from here" (a full population from the shared car).
		if ui_button_icon("die", {x, by, icon_s, bh}, .DICE, false) {
			if hud.showcase {
				hud.evolve_from_here = true
			} else {
				hud.reseed_cars = true
			}
		}
		x += icon_s + btn_gap
		if !hud.showcase {
			// The pack toggle: the glyph is ALWAYS the scattered trio, so
			// the button says "pack" no matter the state; lit = concurrent
			// pack on, off (default) = serial solo.
			if ui_button_icon("view_pack", {x, by, icon_s, bh}, .CARS3, hud.view == 0) {
				hud.view_requested = true
			}
			x += icon_s + btn_gap
			// Speed: one cycling button (1x -> 2x -> 4x -> 8x -> 1x).
			idx := 0
			for i in 0 ..< len(SPEED_SEGS) {
				if hud.speed == SPEED_SEGS[i].n {
					idx = i
				}
			}
			if ui_button_seg("speed", {x, by, btn_seg, bh}, SPEED_SEGS[idx].label) {
				hud.speed = SPEED_SEGS[(idx + 1) % len(SPEED_SEGS)].n
			}
			x += btn_seg + btn_gap
		}
		// Best: trophy + the number, tight gap (they are related); "--"
		// while no car on screen has progressed (nothing demonstrated).
		ui_icon(.TROPHY, {x, by + (bh - icon_s) / 2, icon_s, icon_s}, ui_def_text)
		x += icon_s + gap6
		ui_text({x, by, best_tw, lh}, best_num, ui_def_text)
		x += best_tw + btn_gap
		// The share glyph: opens the share popup (wasm DOM overlay; inert
		// native, where the shims no-op).
		if ui_button_icon("share", {x, by, icon_s, bh}, .SHARE, false) {
			hud.share_requested = true
		}

		// One pitch below the control row.
		gy := by + row_pitch
		// Leaderboard order - see hud_car_row_less - with RANK HYSTERESIS:
		// a car only overtakes its neighbour once it leads by
		// ROW_HYSTERESIS, so a close pack's raw per-frame sort stops
		// flickering (no oscillation).
		sort.quick_sort_proc(hud.cars[:hud.n_cars], hud_car_row_less)
		if hud.row_prev_n == hud.n_cars && hud.n_cars > 1 {
			prev_row: [SOLO_MAX]int
			for i in 0 ..< hud.n_cars {
				prev_row[hud.row_prev[i]] = i
			}
			passes := 0
			for passes < 8 {
				passes += 1
				moved := false
				for i in 1 ..< hud.n_cars {
					a := &hud.cars[i - 1]
					b := &hud.cars[i]
					// Desired order: a above b (a.score >= b.score). If b
					// sat above a last frame and the overtake margin is
					// still under the hysteresis band, restore last frame's
					// order.
					if prev_row[b.id] < prev_row[a.id] && a.score - b.score < ROW_HYSTERESIS {
						hud.cars[i - 1], hud.cars[i] = hud.cars[i], hud.cars[i - 1]
						moved = true
					}
				}
				if !moved {break}
			}
		}
		for i in 0 ..< hud.n_cars {hud.row_prev[i] = hud.cars[i].id}
		hud.row_prev_n = hud.n_cars
		// One decimal column for the whole list: find the widest portrait
		// and the widest integer part so every score's dot lands at the
		// same x (the dots line down the list). The portrait box is the
		// panel width minus the gap and the score column (the dot offset +
		// the fractional tail) - the largest the portraits may grow.
		ss := score_text_scale(SCORE_FONT)
		max_pre := f32(0)
		max_post := f32(0)
		for i in 0 ..< hud.n_cars {
			pre, post := font_score_dots(fmt.tprintf("{:.1f}", hud.cars[i].score))
			if p := pre * ss; p > max_pre {max_pre = p}
			if p := post * ss; p > max_post {max_post = p}
		}
		pw_max := sc.body.w - gap6 - i32((max_pre + max_post) * ui_dpp)
		if pw_max < 1 {pw_max = 1}
		max_pw := i32(0)
		for i in 0 ..< hud.n_cars {
			pw, _ := portrait_row_size(&hud.cars[i], row_h, pw_max)
			if pw > max_pw {max_pw = pw}
		}
		dot_col := f32(sc.body.x + max_pw + gap6) + max_pre * ui_dpp
		ui_icon_n = 0
		for i in 0 ..< hud.n_cars {
			c := &hud.cars[i]
			ry := gy + i32(i) * row_pitch
			// The car's side-view portrait (car_icon.odin): the 8 fan wedges
			// in the segment colors + the wheels, one textured quad per row
			// (drawn after the command list, see ui_icon_rects). A broken
			// segment's wedge is missing from the silhouette.
			pw, ph := portrait_row_size(c, row_h, pw_max)
			ir := microui.Rect{sc.body.x, ry + (row_h - ph) / 2, pw, ph}
			ui_icon_rects[i] = ir
			ui_icon_n = i + 1
			if c.state == .Finished {
				// Status mark over the portrait: check = track end reached
				// (stopped/failed cars show no mark). Mark color: black on
				// light body colors, white on dark (slot 0 = the body-colour
				// slot). The mark scales with the portrait.
				lum :=
					f32(c.colors[0][0]) * 0.299 / 255.0 +
					f32(c.colors[0][1]) * 0.587 / 255.0 +
					f32(c.colors[0][2]) * 0.114 / 255.0
				icon_col := microui.Color{255, 255, 255, 255}
				if lum > 0.6 {icon_col = microui.Color{20, 20, 20, 255}}
				ms := i32(16 * f32(ph) / f32(ICON_H))
				mark := microui.Rect{ir.x + (ir.w - ms) / 2, ir.y + (ir.h - ms) / 2, ms, ms}
				microui.draw_icon(&ui_ctx, .CHECK, mark, icon_col)
			}
			// Score tint: a stopped car (finished or failed) drops to light
			// gray.
			scol := ui_def_text
			if c.state != .Live {
				scol = microui.Color{170, 170, 170, 255}
			}
			// Decimal-aligned: every score's '.' sits at dot_col.
			score := fmt.tprintf("{:.1f}", c.score)
			tx := i32(dot_col - font_dot_offset(score) * ui_dpp *
						score_text_scale(SCORE_FONT))
			ui_text({tx, ry, sc.body.x + sc.body.w - tx, row_h}, score, scol, SCORE_FONT)
		}
		if hud.n_cars == 0 {
			// No rows to push it down: the hold message takes the first
			// car slot.
			ry := gy
			ui_text({sc.body.x, ry, sc.body.w, lh}, hud.hold, ui_def_text)
		}
		microui.end_window(&ui_ctx)
	}

	// The engine latches GL_OUT_OF_MEMORY when a GPU allocation fails - on
	// a memory-starved GPU that is a resize whose new render targets no
	// longer fit in the remaining VRAM. The failed targets are unusable, so
	// the only recovery is a restart; say so instead of leaving a frozen
	// window.
	if gfx.Gpu_Oom() {
		// We are outside any window here (after end_window), where microui's
		// clip stack is empty and its draw helpers assert, so the banner is
		// its own frameless window, one row tall, centered below the panel.
		oom_msg := "GPU OUT OF MEMORY - a resize could not allocate GPU resources. Restart the app."
		oom_tw := ui_ctx.text_width(ui_ctx.style.font, oom_msg)
		oom_pad := i32(f32(8) * ui_dpp)
		oom_w := oom_tw + 2 * oom_pad
		oom_x := (fb_w - oom_w) / 2
		if oom_x < panel_margin {oom_x = panel_margin}
		oom_y := panel_margin + sh + panel_margin
		if microui.begin_window(
			&ui_ctx,
			"gpu_oom_banner",
			{oom_x, oom_y, oom_w, lh},
			{.NO_CLOSE, .NO_RESIZE, .NO_TITLE, .NO_SCROLL, .NO_FRAME},
		) {
			microui.draw_rect(&ui_ctx, {oom_x, oom_y, oom_w, lh}, microui.Color{140, 30, 30, 235})
			ui_text(
				{oom_x + oom_pad, oom_y, oom_tw, lh},
				oom_msg,
				microui.Color{255, 240, 240, 255},
			)
			microui.end_window(&ui_ctx)
		}
	}

	microui.end(&ui_ctx)
}
