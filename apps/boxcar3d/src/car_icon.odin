// Car side-view portraits, rasterized on the CPU: the canonical boxcar
// silhouette (the 8 fan wedges in the segment palette colors, the hull
// edges, the wheel circles). A true projection of the 3D body looking
// along the lateral axis (cap fans coincide, belts edge-on, each wheel
// pair ±z → one circle). No GPU render, no readback: bit-identical on
// native and wasm.
//
// One raster (icon_draw_side_view) serves both consumers: the score
// panel's icon atlas (car_icon_raster → flush → render; a broken
// segment's wedge is missing, so the portrait shows the car's current
// shape) and the share popup's images (car_icon_render_rgba, raw RGBA
// for the JS overlay). Headless: icon_atlas is nil, the atlas raster /
// flush no-op; the share raster needs no renderer.

package main

import "core:mem"
import "core:math"
import gfx "engine:graphics"

// The row's icon slot in display px, supersampled ICON_SS× in the atlas;
// the GPU's LINEAR filter downsamples it 1:ICON_SS for the row.
ICON_W :: 68
ICON_H :: 27
ICON_SS :: 2
ICON_TILE_W :: ICON_W * ICON_SS
ICON_TILE_H :: ICON_H * ICON_SS
ICON_PAD :: f32(2.0) // source-px padding inside the tile
ICON_SLOTS :: SOLO_MAX
ICON_COLS :: 4
ICON_ATLAS_W :: ICON_TILE_W * ICON_COLS
ICON_ATLAS_H :: ICON_TILE_H * (ICON_SLOTS / ICON_COLS)

// The hull edge color (render's BODY_EDGE_COLOR rgb).
ICON_EDGE :: [3]u8{82, 89, 97}

icon_atlas: []u8
icon_atlas_dirty := false
icon_atlas_uploaded := false

// Per-slot visible-content rect in the tile (tile px), {cx0, cy0, cx1,
// cy1}: the portrait quad maps this sub-rect, not the whole tile (the
// side view is far narrower; a full-tile quad would leave a transparent
// left indent the pause/helix glyphs don't have). Zero = unrasterized
// (callers fall back to the full tile).
icon_slot_rect: [ICON_SLOTS][4]f32

// Allocate the CPU-side atlas (called from init_ui, the renderer is up).
// Kept alive for the process: the GPU backend may defer the initial data
// upload past the sg_make_image call.
icon_atlas_init :: proc() {
	icon_atlas = make([]u8, ICON_ATLAS_W * ICON_ATLAS_H * 4)
}

// Upload the atlas to the overlay's second texture (no-op while clean).
car_icon_flush :: proc() {
	if icon_atlas == nil || !icon_atlas_dirty {return}
	gfx.Overlay_Upload_Icons(ICON_ATLAS_W, ICON_ATLAS_H, icon_atlas)
	icon_atlas_dirty = false
	icon_atlas_uploaded = true
}

// Draw one portrait per score row (the rects ui recorded during build_ui),
// rotated by the car's current pitch so the side view tilts with the
// car's nose-up/down attitude. Called after render_ui_commands, in the
// same overlay frame.
car_icon_render :: proc(hud: ^Hud_Data) {
	if !icon_atlas_uploaded {return}
	for i in 0 ..< ui_icon_n {
		if i >= hud.n_cars {break}
		slot := hud.cars[i].id
		if slot < 0 || slot >= ICON_SLOTS {continue}
		r := ui_icon_rects[i]
		u0, v0, _, _ := icon_tile_uv(slot)
		// The quad maps the visible-content sub-rect (icon_slot_rect), not
		// the full tile - the quad in ui_icon_rects is sized to that content,
		// so sampling the whole tile would smear the car across it.
		cr := icon_slot_rect[slot]
		cu0 := u0 + f32(cr[0]) / f32(ICON_ATLAS_W)
		cu1 := u0 + f32(cr[2]) / f32(ICON_ATLAS_W)
		cv0 := v0 + f32(cr[1]) / f32(ICON_ATLAS_H)
		cv1 := v0 + f32(cr[3]) / f32(ICON_ATLAS_H)
		gfx.Overlay_Textured_Quad_Rot(
			f32(r.x) + f32(r.w) * 0.5,
			f32(r.y) + f32(r.h) * 0.5,
			f32(r.w),
			f32(r.h),
			hud.cars[i].pitch,
			cu0,
			cv0,
			cu1,
			cv1,
			{1.0, 1.0, 1.0, 1.0},
		)
	}
}

// The tile's UV rect in the atlas (row-major, ICON_COLS per row).
icon_tile_uv :: proc(slot: int) -> (u0, v0, u1, v1: f32) {
	col := slot % ICON_COLS
	row := slot / ICON_COLS
	u0 = f32(col * ICON_TILE_W) / f32(ICON_ATLAS_W)
	v0 = f32(row * ICON_TILE_H) / f32(ICON_ATLAS_H)
	u1 = u0 + f32(ICON_TILE_W) / f32(ICON_ATLAS_W)
	v1 = v0 + f32(ICON_TILE_H) / f32(ICON_ATLAS_H)
	return
}

// A raster target: a W×H RGBA buffer (row-major; opaque pixels are
// straight - the overlay pipeline blends premultiplied, so that is the
// atlas convention too).
Icon_Raster :: struct {
	pix: []u8, // W*H*4
	w, h: int,
}

ir_px_set :: proc(r: ^Icon_Raster, x, y: int, col: [4]u8) {
	i := (y * r.w + x) * 4
	r.pix[i] = col[0]
	r.pix[i + 1] = col[1]
	r.pix[i + 2] = col[2]
	r.pix[i + 3] = col[3]
}

// The bbox → target fit for one raster (icon_draw_side_view computes it).
Icon_Map :: struct {
	minx, miny, scale, ox, oy: f32,
}

// Body frame → target: x right, y UP in the body frame → y down in the
// target.
icon_map_pt :: proc(m: Icon_Map, h: int, p: [2]f32) -> [2]f32 {
	return {
		(p[0] - m.minx) * m.scale + m.ox,
		f32(h) - ((p[1] - m.miny) * m.scale + m.oy),
	}
}

icon_xy :: proc(p: [3]f32) -> [2]f32 {
	return {p[0], p[1]}
}

// Rasterize the car's side view into `r` (cleared first): the 8 fan wedges
// (segment slot colors), the hull edges (ring edges + cap spokes), and the
// wheels (tire disc + sidewall hub + rim edge). A broken OR degenerate
// segment is missing - it has no physics hull either. The bbox is fit with
// ICON_PAD padding. Returns the visible content rect {cx0, cy0, cx1, cy1}
// in target px (all zeros = an empty silhouette).
icon_draw_side_view :: proc(
	r: ^Icon_Raster,
	g: ^Genome,
	colors: [N_COLORS][3]u8,
	broken: [8]bool,
) -> [4]f32 {
	empty := [4]f32{0.0, 0.0, 0.0, 0.0}
	ring := sorted_ring(g)
	bm := genome_to_body(g)
	defer destroy_body_model(&bm)

	// i-th enabled wheel pair → its genome slot (palette 8+slot) - the same
	// walk wheel_slot_map does, from the decoded genome (decode_genes keeps
	// every slot, disabled ones in, so the enabled walk matches).
	wslot: [N_WHEELS]int
	ne := 0
	for s in 0 ..< len(g.wheels) {
		if g.wheels[s].vertex < 0 {continue}
		wslot[ne] = s
		ne += 1
	}

	// Bounding box: the ring + the wheel circles (mount + strut travel).
	// A ring point joins the box only while one of its two wedges is alive
	// (broken OR degenerate-skip), so a shed/absent needle doesn't shrink
	// the portrait.
	minx, miny := f32(1e9), f32(1e9)
	maxx, maxy := -f32(1e9), -f32(1e9)
	for s in 0 ..< 8 {
		alive := !broken[s] && !bm.degenerate[s]
		prev_alive := !broken[(s + 7) % 8] && !bm.degenerate[(s + 7) % 8]
		if !alive && !prev_alive {continue}
		p := ring[s]
		minx = math.min(minx, p[0])
		miny = math.min(miny, p[1])
		maxx = math.max(maxx, p[0])
		maxy = math.max(maxy, p[1])
	}
	nw := len(bm.wheels)
	cx: [N_WHEELS][2]f32
	cr: [N_WHEELS]f32
	for i in 0 ..< nw {
		w := &bm.wheels[i]
		cx[i] = {
			w.pos[0] + STRUT_WHEEL_TRAVEL * w.strut_axis[0],
			w.pos[1] + STRUT_WHEEL_TRAVEL * w.strut_axis[1],
		}
		cr[i] = w.radius
		minx = math.min(minx, cx[i][0] - cr[i])
		miny = math.min(miny, cx[i][1] - cr[i])
		maxx = math.max(maxx, cx[i][0] + cr[i])
		maxy = math.max(maxy, cx[i][1] + cr[i])
	}
	if maxx <= minx || maxy <= miny {return empty}
	scale := math.min(
		(f32(r.w) - 2 * ICON_PAD) / (maxx - minx),
		(f32(r.h) - 2 * ICON_PAD) / (maxy - miny),
	)
	if scale <= 0 {return empty}
	ox := (f32(r.w) - (maxx - minx) * scale) * 0.5
	oy := (f32(r.h) - (maxy - miny) * scale) * 0.5
	m := Icon_Map{minx, miny, scale, ox, oy}

	mem.set(raw_data(r.pix), 0, len(r.pix))

	cb := density_brightness(
		(g.chassis_density - CHASSIS_DENSITY_LO) / (CHASSIS_DENSITY_HI - CHASSIS_DENSITY_LO),
	)
	// The 8 fan wedges (the top-cap fan, each in its segment's slot color).
	for s in 0 ..< 8 {
		if broken[s] || bm.degenerate[s] {continue}
		j := (s + 1) % 8
		ir_fill_tri(
			r,
			icon_map_pt(m, r.h, {0.0, 0.0}),
			icon_map_pt(m, r.h, icon_xy(ring[s])),
			icon_map_pt(m, r.h, icon_xy(ring[j])),
			icon_px(colors[s], cb),
		)
	}
	// The hull edges: the ring edges (each belongs to its segment) + the cap
	// spokes (each belongs to its two segments - drawn while either survives).
	edge := icon_px(ICON_EDGE, 1.0)
	for s in 0 ..< 8 {
		if !broken[s] && !bm.degenerate[s] {
			ir_draw_line(
				r,
				icon_map_pt(m, r.h, icon_xy(ring[s])),
				icon_map_pt(m, r.h, icon_xy(ring[(s + 1) % 8])),
				edge,
			)
		}
		prev := (s + 7) % 8
		if (!broken[s] && !bm.degenerate[s]) || (!broken[prev] && !bm.degenerate[prev]) {
			ir_draw_line(r, icon_map_pt(m, r.h, {0.0, 0.0}), icon_map_pt(m, r.h, icon_xy(ring[s])), edge)
		}
	}
	// The wheels (each ±z pair's near-side disc): tire + the sidewall hub
	// (the polar cap projects to a central disc of r·sin(WHEEL_SIDEWALL_DEG)).
	hub_k := math.sin(WHEEL_SIDEWALL_DEG * (math.PI / 180.0))
	for i in 0 ..< nw {
		w := &bm.wheels[i]
		wb := density_brightness(
			(w.density - WHEEL_DENSITY_LO) / (WHEEL_DENSITY_HI - WHEEL_DENSITY_LO),
		)
		c := icon_map_pt(m, r.h, cx[i])
		rad := cr[i] * scale
		tire_lit := icon_tonemap(
			{WHEEL_TIRE_COLOR[0] * wb, WHEEL_TIRE_COLOR[1] * wb, WHEEL_TIRE_COLOR[2] * wb},
		)
		tire := [4]u8 {
			icon_clamp_u8(tire_lit[0]),
			icon_clamp_u8(tire_lit[1]),
			icon_clamp_u8(tire_lit[2]),
			255,
		}
		ir_fill_circle(r, c, rad, tire)
		ir_fill_circle(r, c, rad * hub_k, icon_px(colors[8 + wslot[i]], wb))
		ir_draw_circle_line(r, c, rad, edge)
	}
	return {ox, oy, ox + (maxx - minx) * scale, oy + (maxy - miny) * scale}
}

// The score panel's atlas slot (the shape is bit-identical to the share
// images). The tile is NOT contiguous in the atlas - ICON_COLS tiles share
// each atlas row - so rasterize into a scratch tile, then blit it in row
// by row. Sets the dirty flag; call car_icon_flush to push to the GPU.
car_icon_raster :: proc(slot: int, g: ^Genome, colors: [N_COLORS][3]u8, broken: [8]bool) {
	if icon_atlas == nil {return}
	ensure(slot >= 0 && slot < ICON_SLOTS)
	tmp := make([]u8, ICON_TILE_W * ICON_TILE_H * 4, context.allocator)
	r := Icon_Raster {
		pix = tmp,
		w   = ICON_TILE_W,
		h   = ICON_TILE_H,
	}
	icon_slot_rect[slot] = icon_draw_side_view(&r, g, colors, broken)
	row_b := ICON_TILE_W * 4
	top := ((slot / ICON_COLS) * ICON_TILE_H * ICON_ATLAS_W +
		(slot % ICON_COLS) * ICON_TILE_W) * 4
	for y in 0 ..< ICON_TILE_H {
		dst := icon_atlas[top + y*ICON_ATLAS_W*4 : top + (y*ICON_ATLAS_W + ICON_TILE_W)*4]
		copy(dst, tmp[y*row_b : (y + 1)*row_b])
	}
	delete(tmp)
	icon_atlas_dirty = true
}

// The share popup's images: rasterize the side view into a fresh W×H RGBA
// buffer (no renderer needed). Caller deletes the returned slice.
car_icon_render_rgba :: proc(
	w, h: int,
	g: ^Genome,
	colors: [N_COLORS][3]u8,
	broken: [8]bool,
	allocator := context.allocator,
) -> []u8 {
	pix := make([]u8, w * h * 4, allocator)
	r := Icon_Raster {
		pix = pix,
		w   = w,
		h   = h,
	}
	icon_draw_side_view(&r, g, colors, broken)
	return pix
}

// The renderer's AgX tone-map, so the portrait matches the main view's lit
// render (raw albedo would read as a different hue - e.g. a blue chassis
// rendering pink). `scale` folds in the app's exposure stop (Set_Exposure)
// and a representative sun + sky light for a side-facing belt; the albedo
// is 0..1, linear.
ICON_TONEMAP_EV :: f32(-2.0) // Set_Exposure in render.odin
ICON_TONEMAP_LIGHT :: f32(1.8) // representative side-belt light (sun + sky)

agx_channel :: proc(x: f32) -> f32 {
	x2 := x * x
	x4 := x2 * x2
	return(
		x4 * 15.5 * x2 -
		x4 * 40.14 * x +
		x4 * 31.96 -
		x2 * 6.868 * x +
		x2 * 0.4298 +
		x * 0.1191 -
		0.00232 \
	)
}

icon_tonemap :: proc(c: [3]f32) -> [3]f32 {
	scale := ICON_TONEMAP_LIGHT * math.pow(2.0, ICON_TONEMAP_EV)
	v := [3]f32{c[0] * scale, c[1] * scale, c[2] * scale}
	m := [3]f32 {
		0.8424790501594543 * v[0] + 0.0423282422125339 * v[1] + 0.0423756539821624 * v[2],
		0.0784336030483245 * v[0] + 0.8784686326980590 * v[1] + 0.0784336030483245 * v[2],
		0.0792237445712089 * v[0] + 0.0791661292314529 * v[1] + 0.8791429996490478 * v[2],
	}
	for i in 0 ..< 3 {
		m[i] = math.log2(math.max(m[i], 1e-10))
		m[i] = math.max(-12.4739, math.min(4.02607, m[i]))
		m[i] = (m[i] + 12.47393) * 0.0606060
		m[i] = agx_channel(m[i])
	}
	return {
		1.1968790292739868 * m[0] - 0.0528968535363674 * m[1] - 0.0529716350138187 * m[2],
		-0.0980208814144134 * m[0] + 1.1519031524658203 * m[1] - 0.0980434492230415 * m[2],
		-0.0990297421813011 * m[0] - 0.0989611744880676 * m[1] + 1.1510736942291259 * m[2],
	}
}

icon_clamp_u8 :: proc(x: f32) -> u8 {
	return u8(math.max(0.0, math.min(1.0, x)) * 255.0)
}

// A palette slot × density brightness, tone-mapped to match the 3D render.
icon_px :: proc(c: [3]u8, b: f32) -> [4]u8 {
	lit := icon_tonemap({f32(c[0]) / 255.0 * b, f32(c[1]) / 255.0 * b, f32(c[2]) / 255.0 * b})
	return {icon_clamp_u8(lit[0]), icon_clamp_u8(lit[1]), icon_clamp_u8(lit[2]), 255}
}

ir_fill_tri :: proc(r: ^Icon_Raster, a, b, c: [2]f32, col: [4]u8) {
	minx := math.max(0, int(math.floor(math.min(a[0], math.min(b[0], c[0])))))
	maxx := math.min(r.w, int(math.ceil(math.max(a[0], math.max(b[0], c[0])))))
	miny := math.max(0, int(math.floor(math.min(a[1], math.min(b[1], c[1])))))
	maxy := math.min(r.h, int(math.ceil(math.max(a[1], math.max(b[1], c[1])))))
	for y in miny ..< maxy {
		for x in minx ..< maxx {
			if tri_contains({f32(x) + 0.5, f32(y) + 0.5}, a, b, c) {
				ir_px_set(r, x, y, col)
			}
		}
	}
}

// The pixel is inside the triangle: all three edge tests agree on sign
// (either winding).
tri_contains :: proc(p, a, b, c: [2]f32) -> bool {
	d1 := edge_sign(p, a, b)
	d2 := edge_sign(p, b, c)
	d3 := edge_sign(p, c, a)
	has_neg := d1 < 0 || d2 < 0 || d3 < 0
	has_pos := d1 > 0 || d2 > 0 || d3 > 0
	return !(has_neg && has_pos)
}

edge_sign :: proc(p, a, b: [2]f32) -> f32 {
	return (p[0] - b[0]) * (a[1] - b[1]) - (p[1] - b[1]) * (a[0] - b[0])
}

ir_fill_circle :: proc(r: ^Icon_Raster, c: [2]f32, rad: f32, col: [4]u8) {
	if rad < 0.25 {return}
	minx := math.max(0, int(math.floor(c[0] - rad)))
	maxx := math.min(r.w, int(math.ceil(c[0] + rad)))
	miny := math.max(0, int(math.floor(c[1] - rad)))
	maxy := math.min(r.h, int(math.ceil(c[1] + rad)))
	for y in miny ..< maxy {
		for x in minx ..< maxx {
			dx := f32(x) + 0.5 - c[0]
			dy := f32(y) + 0.5 - c[1]
			if dx * dx + dy * dy <= rad * rad {
				ir_px_set(r, x, y, col)
			}
		}
	}
}

// A 2-source-px-wide line (1 display px): pixels within 1.0 of the segment.
ir_draw_line :: proc(r: ^Icon_Raster, a, b: [2]f32, col: [4]u8) {
	minx := math.max(0, int(math.floor(math.min(a[0], b[0])) - 2))
	maxx := math.min(r.w, int(math.ceil(math.max(a[0], b[0])) + 3))
	miny := math.max(0, int(math.floor(math.min(a[1], b[1])) - 2))
	maxy := math.min(r.h, int(math.ceil(math.max(a[1], b[1])) + 3))
	for y in miny ..< maxy {
		for x in minx ..< maxx {
			if seg_dist({f32(x) + 0.5, f32(y) + 0.5}, a, b) <= 1.0 {
				ir_px_set(r, x, y, col)
			}
		}
	}
}

seg_dist :: proc(p, a, b: [2]f32) -> f32 {
	abx := b[0] - a[0]
	aby := b[1] - a[1]
	l2 := abx * abx + aby * aby
	if l2 < 1e-12 {
		dx := p[0] - a[0]
		dy := p[1] - a[1]
		return math.sqrt(dx * dx + dy * dy)
	}
	t := math.clamp((p[0] - a[0]) * abx + (p[1] - a[1]) * aby, 0.0, l2) / l2
	dx := p[0] - (a[0] + t * abx)
	dy := p[1] - (a[1] + t * aby)
	return math.sqrt(dx * dx + dy * dy)
}

ir_draw_circle_line :: proc(r: ^Icon_Raster, c: [2]f32, rad: f32, col: [4]u8) {
	if rad < 1.0 {return}
	minx := math.max(0, int(math.floor(c[0] - rad) - 2))
	maxx := math.min(r.w, int(math.ceil(c[0] + rad) + 3))
	miny := math.max(0, int(math.floor(c[1] - rad) - 2))
	maxy := math.min(r.h, int(math.ceil(c[1] + rad) + 3))
	for y in miny ..< maxy {
		for x in minx ..< maxx {
			dx := f32(x) + 0.5 - c[0]
			dy := f32(y) + 0.5 - c[1]
			if math.abs(math.sqrt(dx * dx + dy * dy) - rad) <= 1.0 {
				ir_px_set(r, x, y, col)
			}
		}
	}
}
