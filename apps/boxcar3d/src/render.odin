// Renderer: hilly terrain mesh, the car (8 per-segment chassis meshes in
// the genome's 16-slot part palette + impostor wheel spheres whose outside
// sidewall is painted the pair's gene color via the engine's sphere polar
// cap), then submits one frame.

package main

import "core:fmt"
import "core:math"
import gfx "engine:graphics"
import b3 "engine:physics"

// ─── Mesh registry helpers ────────────────────────────────────────────
// FNV-1a 32-bit over the raw vertex + index bytes (dedup + non-zero handle).
mesh_hash :: proc(verts: []f32, indices: []u32) -> u32 {
	h := u32(0x811c9dc5)
	for b in transmute([]u8)verts {h = (h ~ u32(b)) * 0x01000193}
	for b in transmute([]u8)indices {h = (h ~ u32(b)) * 0x01000193}
	return h
}

// App-level mesh registration. The engine registry is keyed by the content
// hash: Register_Mesh does NOT dedup (every call takes a fresh slot), so
// identical geometry re-registered on a miss would exhaust the 4096-entry
// cap - a debris shard is rebuilt every frame it is drawn, and once the cap
// is hit EVERY registration fails (every car from that moment spawns
// without a chassis). The engine's Find → Register lifecycle: look up first,
// register only on a miss. Each handle is held for the renderer's lifetime;
// a slot you stop drawing is freed with release_mesh_slot.
mesh_reg_warned: bool // a refused registration (cap hit) has been reported

// A registration the engine registry refused (cap hit): warn once, return
// the invalid handle.
report_mesh_reg_failure :: proc(h: gfx.Mesh_Handle) -> gfx.Mesh_Handle {
	if !mesh_reg_warned {
		mesh_reg_warned = true
		fmt.eprintfln(
			"render: mesh registration FAILED (engine mesh registry full?) - geometry will be missing on screen",
		)
	}
	return h
}

register_mesh_cached :: proc(
	hash: u32,
	verts: []f32,
	indices: []u32,
	edges: []f32,
	kind: gfx.Mesh_Kind,
) -> gfx.Mesh_Handle {
	if h := gfx.Find_Mesh(hash); gfx.Is_Mesh_Handle_Valid(h) {return h}
	h := gfx.Register_Mesh(hash, verts, indices, kind)
	if !gfx.Is_Mesh_Handle_Valid(h) {return report_mesh_reg_failure(h)}
	gfx.Register_Mesh_Edges(h, edges)
	return h
}

// Car-owned registration: NO dedup - every call takes a fresh slot the
// caller owns. Car bodies and debris shards are private to their car, so
// the car releases them at teardown (release_car_meshes) and
// replace-and-releases the body on each break - per-car freeing is
// trivially safe (no shared slot to over-release). Contrast
// register_mesh_cached: that geometry is shared and process-lifetime, so it
// dedups via Find_Mesh and is released only on a reseed.
register_mesh_owned :: proc(
	hash: u32,
	verts: []f32,
	indices: []u32,
	edges: []f32,
	kind: gfx.Mesh_Kind,
) -> gfx.Mesh_Handle {
	h := gfx.Register_Mesh(hash, verts, indices, kind)
	if !gfx.Is_Mesh_Handle_Valid(h) {return report_mesh_reg_failure(h)}
	gfx.Register_Mesh_Edges(h, edges)
	return h
}

// Free a registry slot the app no longer draws (drops the one reference from
// the original Register_Mesh; freed at refcount 0; no-op for invalid handles).
// Reseed: the previous terrain / end-zone meshes; car-owned bodies + shards
// are released with their car (release_car_meshes).
release_mesh_slot :: proc(h: gfx.Mesh_Handle) {
	if gfx.Is_Mesh_Handle_Valid(h) {gfx.Release_Mesh_Reference(h)}
}

// A fresh car's per-segment mesh cache: one slot per segment, all the
// invalid sentinel. Mesh_Handle's zero value packs to slot index 0, which
// Is_Mesh_Handle_Valid calls VALID - an "unbuilt" entry must be the
// sentinel, never the struct's zero value.
debris_cache_empty :: proc() -> [8]gfx.Mesh_Handle {
	out: [8]gfx.Mesh_Handle
	for s in 0 ..< 8 {out[s] = gfx.Invalid_Mesh_Handle}
	return out
}

// Release every registry slot a car owns (8 segments + one break cap per
// shed segment + each shed segment's shard) and reset the lists to the
// invalid sentinel. Called at the car's teardown (the point its genome is
// destroyed), so a car's geometry never outlives it.
release_car_meshes :: proc(segs, caps, shards: ^[8]gfx.Mesh_Handle) {
	for s in 0 ..< 8 {
		release_mesh_slot(segs^[s])
		release_mesh_slot(caps^[s])
		release_mesh_slot(shards^[s])
	}
	segs^ = debris_cache_empty()
	caps^ = debris_cache_empty()
	shards^ = debris_cache_empty()
}

// The car stores (solo + pop_viewer.cars) are zero-initialized globals, so
// a fresh car's mesh fields are Mesh_Handle's zero value (a real slot!).
// Seed every car's handle lists to the sentinel at startup.
seed_car_mesh_handles :: proc() {
	solo.segs = debris_cache_empty()
	solo.caps = debris_cache_empty()
	solo.debris_mesh = debris_cache_empty()
	for &c in pop_viewer.cars {
		c.segs = debris_cache_empty()
		c.caps = debris_cache_empty()
		c.debris_mesh = debris_cache_empty()
	}
}

terrain_mesh: gfx.Mesh_Handle = gfx.Invalid_Mesh_Handle
// The red end zone (the last END_ZONE_LEN metres of the track); invalid
// when the track is shorter than the zone (terrain_mesh is then fully
// red).
terrain_end_mesh: gfx.Mesh_Handle = gfx.Invalid_Mesh_Handle

// The terrain seed the current meshes were built from (the displayed env's
// seed - a track re-seed changes it, see displayed_env in loop.odin).
terrain_mesh_seed: u64 = 0
// The displayed track line the current meshes end at (displayed_env - the
// on-screen generation's `target`, not the live frontier): a mid-walk line
// extension keeps the walked geometry until the view takes the next
// generation.
terrain_mesh_line: f32 = 0

// Skirt depth: side walls + underside below the lowest terrain vertex
// (visual only - physics uses the b3 heightfield, not this mesh).
TERRAIN_SKIRT_DEPTH :: f32(6.0)

// Rebuild the terrain meshes when the displayed env's seed has changed
// (windowed GA re-seed) or its line has moved (generation transition). The
// mesh ends at the displayed generation's env, never the live frontier.
// Called from the render thread, once per frame.
ensure_terrain_mesh :: proc(e: Env) {
	if e.seed == terrain_mesh_seed &&
	   e.line == terrain_mesh_line &&
	   gfx.Is_Mesh_Handle_Valid(terrain_mesh) {return}
	init_terrain_mesh(e.seed, e.line)
	terrain_mesh_seed = e.seed
	terrain_mesh_line = e.line
}

// ─── Terrain visual mesh ──────────────────────────────────────────────
// The VISIBLE track: the terrain from the spawn approach to the finish
// line (x = S_SPAWN_X + line) - the track IS its prefix, so the mesh ends
// at the line and the last END_ZONE_LEN metres render red (the finish face).
// Top grid with true per-vertex normals (the hills and the drop-off ramp
// shade instead of lighting as one flat board), a skirt + underside below
// the boundary (the platform reads as solid, not a card), and the procedural
// grid material (cell lines + world axes = centerline marking). The height
// grid comes from profile_for(seed) + track_end_col_len(line): a pure
// function of the displayed (seed, line).
init_terrain_mesh :: proc(seed: u64, line: f32) {
	// Materialize the displayed profile into the seed-keyed cache first.
	profile_for(seed)
	// Release the previous track's GPU slots first: a reseed or line
	// extension changes the geometry, so the old meshes are stale. Each is
	// a single-reference slot (one release frees it); without this,
	// re-seeding in a long session leaks toward the 4096-entry cap.
	release_mesh_slot(terrain_mesh)
	release_mesh_slot(terrain_end_mesh)
	rows := TERRAIN_ROWS
	// Visible column span: the mesh ends at the finish line, on the nearest
	// grid column (track_end_col_len - shared with the physics heightfield,
	// so what you see is what you drive on).
	cols_end := track_end_col_len(line)
	cols := cols_end + 1
	sx, sz := TERRAIN_SCALE[0], TERRAIN_SCALE[2]

	// Height grid over the visible span - the normal pass needs the
	// neighbours.
	heights := make([dynamic]f32, rows * cols)
	for i in 0 ..< rows {
		for j in 0 ..< cols {
			wx := TERRAIN_X0 + sx * f32(j)
			wz := sz * f32(i) - TERRAIN_HALF_Z
			heights[i * cols + j] = terrain_height(wx, wz)
		}
	}

	// Per-vertex normal: sum of the diagonal cross products of every cell
	// the vertex touches.
	normals := make([dynamic][3]f32, rows * cols)
	for i in 0 ..< rows {
		for j in 0 ..< cols {
			n := [3]f32{}
			for ci in (i - 1) ..< (i + 1) {
				for cj in (j - 1) ..< (j + 1) {
					if ci < 0 || cj < 0 || ci + 1 >= rows || cj + 1 >= cols {continue}
					h00 := heights[ci * cols + cj]
					h10 := heights[ci * cols + cj + 1]
					h01 := heights[(ci + 1) * cols + cj]
					h11 := heights[(ci + 1) * cols + cj + 1]
					// The cell's two diagonals crossed point up (y =
					// 2*sx*sz, independent of the heights); a= h11-h00,
					// b = h10-h01.
					a, b := h11 - h00, h10 - h01
					n[0] += -(a + b) * sz
					n[1] += 2 * sx * sz
					n[2] += (b - a) * sx
				}
			}
			l := math.sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2])
			normals[i * cols + j] = [3]f32{n[0] / l, n[1] / l, n[2] / l}
		}
	}

	// Skirt bottom: below the lowest visible vertex (shared by both
	// parts, so their underside caps stay coplanar).
	bottom_y := f32(0.0)
	for h in heights {bottom_y = math.min(bottom_y, h)}
	bottom_y -= TERRAIN_SKIRT_DEPTH

	red_start := cols_end - int(math.floor(END_ZONE_LEN / TERRAIN_CELL + 0.5))
	if red_start < 0 {red_start = 0}
	if red_start >= cols_end {
		// Track shorter than the end zone: one fully red mesh.
		terrain_mesh = build_terrain_part(
			0,
			cols_end,
			rows,
			heights,
			normals,
			true,
			true,
			bottom_y,
		)
		terrain_end_mesh = gfx.Invalid_Mesh_Handle
	} else {
		// Green body (skirts its west end) + red end zone (skirts its
		// east end - the visible track end face). The shared seam column
		// is interior: neither part skirts it (no coincident faces).
		terrain_mesh = build_terrain_part(
			0,
			red_start,
			rows,
			heights,
			normals,
			true,
			false,
			bottom_y,
		)
		terrain_end_mesh = build_terrain_part(
			red_start,
			cols_end,
			rows,
			heights,
			normals,
			false,
			true,
			bottom_y,
		)
	}
	delete(heights)
	delete(normals)
}

// Build one part of the visible terrain: the top grid over columns
// col_lo..col_hi (inclusive), skirts on the boundary sides (the shared
// green/red seam is interior), and the underside cap. `heights`/`normals`
// are the FULL visible grid, so a part's edge vertices keep normals from
// their neighbours outside the part; skirt segments own their bottom twins
// (no sharing), plus 4 explicit cap-corner vertices.
build_terrain_part :: proc(
	col_lo, col_hi, rows: int,
	heights: [dynamic]f32,
	normals: [dynamic][3]f32,
	with_west, with_east: bool,
	bottom_y: f32,
) -> gfx.Mesh_Handle {
	sx, sz := TERRAIN_SCALE[0], TERRAIN_SCALE[2]
	cols := len(heights) / rows
	part_cols := col_hi - col_lo + 1
	grid_count := rows * part_cols
	// Skirt segments (one per quad), boundary-walk order: south row
	// west→east, east column south→north, north row east→west, west
	// column north→south.
	south_count := part_cols - 1
	north_count := part_cols - 1
	if part_cols == 1 {
		south_count = 0
		north_count = 0
	}
	east_count := rows - 1
	west_count := rows - 1
	if !with_east {east_count = 0}
	if !with_west {west_count = 0}
	seg_count := south_count + east_count + north_count + west_count
	vert_count := grid_count + 2 * seg_count + 4
	verts := make([dynamic]f32, vert_count * 6)
	cell_count := (rows - 1) * (part_cols - 1)
	indices := make([dynamic]u32, (cell_count + seg_count) * 6 + 6)

	// Top grid. Vertex x uses the GLOBAL column index so both parts land
	// at their correct world position under the shared TERRAIN_OFFSET.
	for i in 0 ..< rows {
		for j in 0 ..< part_cols {
			k2 := i * part_cols + j
			n := normals[i * cols + (col_lo + j)]
			verts[k2 * 6 + 0] = sx * f32(col_lo + j)
			verts[k2 * 6 + 1] = heights[i * cols + (col_lo + j)]
			verts[k2 * 6 + 2] = sz * f32(i)
			verts[k2 * 6 + 3] = n[0]
			verts[k2 * 6 + 4] = n[1]
			verts[k2 * 6 + 5] = n[2]
		}
	}
	for i in 0 ..< rows - 1 {
		for j in 0 ..< part_cols - 1 {
			i00 := i * part_cols + j
			i10 := i00 + 1
			i01 := (i + 1) * part_cols + j
			i11 := i01 + 1
			base := (i * (part_cols - 1) + j) * 6
			indices[base + 0] = u32(i00)
			indices[base + 1] = u32(i01)
			indices[base + 2] = u32(i10)
			indices[base + 3] = u32(i01)
			indices[base + 4] = u32(i11)
			indices[base + 5] = u32(i10)
		}
	}

	segs := make([dynamic][2]int, seg_count)
	k := 0
	for j in 0 ..< south_count {segs[k] = [2]int{j, j + 1};k += 1}
	for i in 0 ..< east_count {
		segs[k] = [2]int{i * part_cols + (part_cols - 1), (i + 1) * part_cols + (part_cols - 1)}
		k += 1
	}
	for j in 0 ..< north_count {
		segs[k] = [2]int {
			(rows - 1) * part_cols + (part_cols - 1 - j),
			(rows - 1) * part_cols + (part_cols - 2 - j),
		}
		k += 1
	}
	for i in 0 ..< west_count {segs[k] = [2]int{(i + 1) * part_cols, i * part_cols};k += 1}
	ensure(k == seg_count)

	// One skirt quad per segment: the two top vertices down to the
	// segment's own bottom twins. Outward = up × dir with up = (0,1,0):
	// (dz, -dx, 0). (A, D, C), (A, C, B) wind CCW seen from outside.
	for s, si in segs {
		a, b := s[0], s[1]
		ax, az := verts[a * 6 + 0], verts[a * 6 + 2]
		bx, bz := verts[b * 6 + 0], verts[b * 6 + 2]
		dx, dz := bx - ax, bz - az
		dl := math.sqrt(dx * dx + dz * dz)
		out := [3]f32{dz / dl, 0.0, -dx / dl}
		da := grid_count + 2 * si
		db := da + 1
		verts[da * 6 + 0] = ax
		verts[da * 6 + 1] = bottom_y
		verts[da * 6 + 2] = az
		verts[da * 6 + 3] = out[0]
		verts[da * 6 + 4] = out[1]
		verts[da * 6 + 5] = out[2]
		verts[db * 6 + 0] = bx
		verts[db * 6 + 1] = bottom_y
		verts[db * 6 + 2] = bz
		verts[db * 6 + 3] = out[0]
		verts[db * 6 + 4] = out[1]
		verts[db * 6 + 5] = out[2]
		idx := cell_count * 6 + 6 * si
		indices[idx + 0] = u32(a)
		indices[idx + 1] = u32(da)
		indices[idx + 2] = u32(db)
		indices[idx + 3] = u32(a)
		indices[idx + 4] = u32(db)
		indices[idx + 5] = u32(b)
	}
	delete(segs)

	// Underside cap (downward normal): four explicit corner bottom
	// vertices, (sw, ew, en) then (sw, en, sn) - the reverse of the top
	// winding.
	sw := u32(grid_count + 2 * seg_count)
	cx := [4]f32{sx * f32(col_lo), sx * f32(col_hi), sx * f32(col_hi), sx * f32(col_lo)}
	cz := [4]f32{0.0, 0.0, sz * f32(rows - 1), sz * f32(rows - 1)}
	for c in 0 ..< 4 {
		verts[(int(sw) + c) * 6 + 0] = cx[c]
		verts[(int(sw) + c) * 6 + 1] = bottom_y
		verts[(int(sw) + c) * 6 + 2] = cz[c]
		verts[(int(sw) + c) * 6 + 3] = 0.0
		verts[(int(sw) + c) * 6 + 4] = -1.0
		verts[(int(sw) + c) * 6 + 5] = 0.0
	}
	cap_idx := cell_count * 6 + 6 * seg_count
	indices[cap_idx + 0] = sw
	indices[cap_idx + 1] = sw + 1
	indices[cap_idx + 2] = sw + 2
	indices[cap_idx + 3] = sw
	indices[cap_idx + 4] = sw + 2
	indices[cap_idx + 5] = sw + 3

	return register_mesh_cached(
		mesh_hash(verts[:], indices[:]),
		verts[:],
		indices[:],
		nil,
		.HeightField,
	)
}

// Track body and red end-zone materials (the grid lines are drawn
// procedurally by the material, not the vertices).
TERRAIN_BODY_COLOR :: [3]f32{0.28, 0.34, 0.22}
TERRAIN_END_COLOR :: [3]f32{0.75, 0.12, 0.10}

append_terrain :: proc() {
	if gfx.Is_Mesh_Handle_Valid(terrain_mesh) {
		gfx.Append_Mesh(
			handle = terrain_mesh,
			pos = TERRAIN_OFFSET,
			quat = {0.0, 0.0, 0.0, 1.0},
			scale = {1.0, 1.0, 1.0},
			color = TERRAIN_BODY_COLOR,
			alpha = 1.0,
			metallic = 0.0,
			roughness = 0.9,
			material_mode = .Ground_Grid,
			grid_cell_size = TERRAIN_CELL,
		)
	}
	if gfx.Is_Mesh_Handle_Valid(terrain_end_mesh) {
		gfx.Append_Mesh(
			handle = terrain_end_mesh,
			pos = TERRAIN_OFFSET,
			quat = {0.0, 0.0, 0.0, 1.0},
			scale = {1.0, 1.0, 1.0},
			color = TERRAIN_END_COLOR,
			alpha = 1.0,
			metallic = 0.0,
			roughness = 0.9,
			material_mode = .Ground_Grid,
			grid_cell_size = TERRAIN_CELL,
		)
	}
}

// ─── Chassis mesh ─────────────────────────────────────────────────────
// The body is 8 car-owned segment meshes (sorted-ring index), each drawn in
// its own palette slot color - the engine mesh format carries no per-vertex
// color (one color per Append_Mesh), so per-part paint comes from the
// per-segment draw calls. Each segment: the 4 outer faces (top cap, bottom
// cap, 2 belt tris) + the 8 hull edges, FLAT-shaded - one vertex per
// face-corner, each carrying its own face's normal (not shared/averaged), so
// a steep corner shades as a flat facet, not a smooth bleed.
//
// The shared 18-position layout: plus[i] 0..7 (z=+heights[i]), minus[i]
// 8..15 (z=−heights[i]), center+ 16 (z=+heights[8]), center− 17
// (z=−heights[8]). A segment's 6 local positions: 0=plus[seg], 1=plus[j],
// 2=minus[seg], 3=minus[j], 4=center+, 5=center−, j = (seg+1) % 8.
segment_positions :: proc(genome: ^Genome, seg: int) -> [6][3]f32 {
	bm := genome_to_body(genome)
	defer destroy_body_model(&bm)
	j := (seg + 1) % 8
	h_i, h_j := bm.heights[seg], bm.heights[j]
	h_c := bm.heights[8]
	// CIRCULAR order - must match the physics fan (see sorted_ring), or the
	// drawn chassis diverges from the simulated one.
	ring := sorted_ring(genome)
	return [6][3]f32 {
		{ring[seg][0], ring[seg][1], h_i},
		{ring[j][0], ring[j][1], h_j},
		{ring[seg][0], ring[seg][1], -h_i},
		{ring[j][0], ring[j][1], -h_j},
		{0.0, 0.0, h_c},
		{0.0, 0.0, -h_c},
	}
}

// The 4 outer faces in the body-mesh winding (outward), as local vertex
// triples over segment_positions' 6-position layout, + the 8 hull edges
// (belt rings, verticals, cap spokes). The single code path the segment
// (build_segment_mesh) and the shard (build_debris_mesh) are both built
// from - the shard can never drift from its segment.
SEGMENT_FACES :: [4][3]int{{0, 1, 4}, {3, 2, 5}, {3, 1, 0}, {3, 0, 2}}
SEGMENT_EDGES :: [8][2]int{{0, 1}, {2, 3}, {0, 2}, {1, 3}, {0, 4}, {1, 4}, {2, 5}, {3, 5}}

append_segment_surface :: proc(
	pos: [6][3]f32,
	verts: ^[dynamic]f32,
	indices: ^[dynamic]u32,
	edges: ^[dynamic]f32,
) {
	for f in SEGMENT_FACES {
		append_flat_tri(pos[f[0]], pos[f[1]], pos[f[2]], verts, indices)
	}
	for e in SEGMENT_EDGES {
		append_hull_edge(edges, pos[e[0]], pos[e[1]])
	}
}

// The 6 corner positions' centroid (body frame) - the instance origin the
// car's part meshes are drawn from (vertices stored centroid-LOCAL, so
// world = origin + R·(p − origin)).
segment_centroid :: proc(pos: [6][3]f32) -> [3]f32 {
	c := [3]f32{}
	for i in 0 ..< 6 {
		c[0] += pos[i][0] / 6.0
		c[1] += pos[i][1] / 6.0
		c[2] += pos[i][2] / 6.0
	}
	return c
}

// One body segment's mesh (car-owned). Drawn at the chassis pose in the
// segment's slot color; a broken segment stops being drawn as body (its
// shard takes over at the debris body's pose). Vertices are
// centroid-LOCAL (second return) - the instance origin is the segment's
// middle (segment_centroid).
build_segment_mesh :: proc(genome: ^Genome, seg: int) -> (gfx.Mesh_Handle, [3]f32) {
	pos := segment_positions(genome, seg)
	c := segment_centroid(pos)
	for i in 0 ..< 6 {
		pos[i] = {pos[i][0] - c[0], pos[i][1] - c[1], pos[i][2] - c[2]}
	}
	verts := make([dynamic]f32, 0, 4 * 3 * 6)
	indices := make([dynamic]u32, 0, 4 * 3)
	edges := make([dynamic]f32, 0, 8 * 8)
	append_segment_surface(pos, &verts, &indices, &edges)
	handle := register_mesh_owned(
		mesh_hash(verts[:], indices[:]),
		verts[:],
		indices[:],
		edges[:],
		.Hull,
	)
	delete(verts)
	delete(indices)
	delete(edges)
	return handle, c
}

// The car's 8 per-segment body meshes, one car-owned registration each. A
// degenerate segment (paper blade, wide-gap fan wedge) has no physics
// hull, so it gets no mesh - the invalid handle is skipped by every draw
// pass (its wheels still draw via the wheel pass). Returns the handles and
// each segment's centroid (body frame) - the instance origin; the same
// centroids anchor the debris shards.
build_car_segments :: proc(genome: ^Genome) -> ([8]gfx.Mesh_Handle, [8][3]f32) {
	out := debris_cache_empty()
	cent := [8][3]f32{}
	ring := sorted_ring(genome)
	for s in 0 ..< 8 {
		if fan_wedge_degenerate(ring[s], ring[(s + 1) % 8]) {continue}
		out[s], cent[s] = build_segment_mesh(genome, s)
	}
	return out, cent
}

// The seal for one segment's hole in the surviving chassis - broken
// segments and skipped degenerate segments (birth caps, build_car_caps).
// The 4 into-wedge cut-cap quads
// cut_cap_tris(16, seg, 8+seg, 17, 8+j, j, true) over the shared
// 18-position layout: quad A on spoke seg = (center+, plus, minus,
// center−), quad B on spoke j = (center+, center−, minus, plus) - a small
// car-owned mesh + the 3 hole-seam edges, drawn in the segment's own slot
// color, so the chassis stays a sealed solid (no rebuild on break).
// void_left / void_right mark neighbors whose wedge is ALSO gone (broken
// mid-run or skipped at birth): the shared spoke quad then bounds void on
// both sides - interior to the merged pocket - and is omitted, or a run of
// missing wedges would float a wall in the pocket's middle.
build_segment_cap_mesh :: proc(
	genome: ^Genome,
	seg: int,
	void_left, void_right: bool,
) -> (
	gfx.Mesh_Handle,
	[3]f32,
) {
	bm := genome_to_body(genome)
	defer destroy_body_model(&bm)
	if void_left && void_right {return gfx.Invalid_Mesh_Handle, [3]f32{}}
	ring := sorted_ring(genome)
	j := (seg + 1) % 8
	pos := [18][3]f32{}
	for i in 0 ..< 8 {
		pos[i] = {ring[i][0], ring[i][1], bm.heights[i]}
		pos[8 + i] = {ring[i][0], ring[i][1], -bm.heights[i]}
	}
	pos[16] = {0.0, 0.0, bm.heights[8]}
	pos[17] = {0.0, 0.0, -bm.heights[8]}
	// Centroid-LOCAL storage (segment_centroid): the 6 anchors the cap is
	// built from, so the cap instance's origin is the cap's own middle.
	anchors := [6]int{16, seg, 8 + seg, 17, 8 + j, j}
	c := [3]f32{}
	for i in 0 ..< 6 {
		for k in 0 ..< 3 {c[k] += pos[anchors[i]][k] / 6.0}
	}
	for i in 0 ..< 6 {
		for k in 0 ..< 3 {pos[anchors[i]][k] -= c[k]}
	}
	verts := make([dynamic]f32, 0, 4 * 3 * 6)
	indices := make([dynamic]u32, 0, 4 * 3)
	edges := make([dynamic]f32, 0, 3 * 8)
	// Tri 0..1 = quad A (spoke seg), tri 2..3 = quad B (spoke j). The
	// into-wedge winding is correct for BOTH wedge kinds - the quads sit on
	// the rendered solid's outer boundary in each (a blade's slot wall, a
	// wide-gap wedge's fins), tangents pointing away from the body.
	cap_tris := cut_cap_tris(16, seg, 8 + seg, 17, 8 + j, j, true)
	for i in 0 ..< 4 {
		t := cap_tris[i]
		if (i < 2 && void_left) || (i >= 2 && void_right) {continue}
		append_flat_tri(pos[t[0]], pos[t[1]], pos[t[2]], &verts, &indices)
	}
	if !void_left {
		append_hull_edge(&edges, pos[16], pos[seg]) // cap: top-cap spoke
		append_hull_edge(&edges, pos[seg], pos[8 + seg]) // cap: vertical seam
		append_hull_edge(&edges, pos[8 + seg], pos[17]) // cap: bottom-cap spoke
	}
	handle := register_mesh_owned(
		mesh_hash(verts[:], indices[:]),
		verts[:],
		indices[:],
		edges[:],
		.Hull,
	)
	delete(verts)
	delete(indices)
	delete(edges)
	return handle, c
}

// Birth caps: the cavity seals for SKIPPED (degenerate) segments, built
// once at spawn - the same cut-wall quads the break system builds mid-run,
// so a car missing wedges at birth still reads as a sealed solid (without
// these, the pocket is open: the far-side hull quads show through,
// backface-culled - outline only). void flags = neighbors also skipped, so
// a run of skipped wedges gets only its outer boundary quads.
build_car_caps :: proc(genome: ^Genome) -> ([8]gfx.Mesh_Handle, [8][2]bool, [8][3]f32) {
	out := debris_cache_empty()
	flags := [8][2]bool{}
	cent := [8][3]f32{}
	bm := genome_to_body(genome)
	defer destroy_body_model(&bm)
	for s in 0 ..< 8 {
		if !bm.degenerate[s] {continue}
		out[s], cent[s] = build_segment_cap_mesh(
			genome,
			s,
			bm.degenerate[(s + 7) % 8],
			bm.degenerate[(s + 1) % 8],
		)
		flags[s] = [2]bool{bm.degenerate[(s + 7) % 8], bm.degenerate[(s + 1) % 8]}
	}
	return out, flags, cent
}

// The cap refresh decision for one segment (the pure core of
// refresh_car_caps, gated headlessly by evolvetest case 22): should the
// registered cap be (re)built, and with which void flags. `missing` = the
// current per-segment missing set (broken OR degenerate-skip);
// `caps_current` = a mesh is registered for s (false also covers the
// invalid-by-design sentinel, which the (vl && vr) case below accounts for).
cap_refresh_decision :: proc(
	missing: [8]bool,
	s: int,
	caps_current: bool,
	caps_flags: [8][2]bool,
) -> (
	bool,
	[2]bool,
) {
	vl := missing[(s + 7) % 8]
	vr := missing[(s + 1) % 8]
	now := [2]bool{vl, vr}
	if !missing[s] {return false, now}
	// A (vl, vr) = (true, true) cap is the invalid sentinel by design
	// (interior of a missing run): matching flags with no mesh are current,
	// not unbuilt.
	if caps_current || (vl && vr) {
		return caps_flags[s] != now, now
	}
	return true, now
}

// Refresh the car's caps against the CURRENT missing set (broken[] + the
// birth-degenerate marks). The void flags freeze into each cap mesh at
// build time, so a cap built BEFORE a neighbor went missing still carries
// the shared-spoke quad: interior to the merged pocket, a floating wall
// (a face from one side, a culled backface from the other). Rebuilds a cap
// only when its frozen flags no longer match (cap_refresh_decision); the
// second return of build_car_caps seeds `caps_flags` at birth. A cap built
// HERE (a mid-run break) also stores its centroid in cap_c - only BIRTH
// caps get one at spawn, and a break cap anchored at the chassis center
// would render displaced by −R·c.
refresh_car_caps :: proc(
	g: ^Genome,
	bot: ^Bot,
	caps: ^[8]gfx.Mesh_Handle,
	caps_flags: ^[8][2]bool,
	cap_c: ^[8][3]f32,
) {
	bm := genome_to_body(g)
	defer destroy_body_model(&bm)
	missing := [8]bool{}
	for s in 0 ..< 8 {missing[s] = bot.broken[s] || bm.degenerate[s]}
	for s in 0 ..< 8 {
		rebuild, now := cap_refresh_decision(
			missing,
			s,
			gfx.Is_Mesh_Handle_Valid(caps^[s]),
			caps_flags^,
		)
		if !rebuild {continue}
		release_mesh_slot(caps^[s])
		// A BREAK cap's centroid was never seeded at birth: store it so the
		// draw offset rides the cap's own anchor, not the chassis center.
		caps^[s], cap_c^[s] = build_segment_cap_mesh(g, s, now[0], now[1])
		caps_flags^[s] = now
	}
}

// Debris shard: one shed segment's 4 outer faces (the shared segment
// surface) + its cut face (the two planar quads of cut_cap_tris, normals
// OUT of the shard - the chassis hole's cap back-to-back with this one),
// 6 body-frame vertices, drawn at its debris body's live pose, OFFSET by
// the segment's centroid (the debris body's origin is the chassis position
// at break time, so the anchor must ride the chunk, not the chassis). The
// face winding matches the segment mesh (outward), so the shard is a fully
// enclosed chunk, sealed across its cut.
build_debris_mesh :: proc(genome: ^Genome, seg: int) -> gfx.Mesh_Handle {
	bm := genome_to_body(genome)
	defer destroy_body_model(&bm)
	// A degenerate segment carried no hulls; its shard has no surface (the
	// wheels it shed with it still draw via the wheel pass).
	if bm.degenerate[seg] {return gfx.Invalid_Mesh_Handle}
	pos := segment_positions(genome, seg)
	// Centroid-local (segment_centroid): the debris body's ORIGIN is the
	// chassis position at break time, not the chunk's middle - the caller
	// draws at body_pos + rot(body_quat, seg_c[seg]).
	c := segment_centroid(pos)
	for i in 0 ..< 6 {
		pos[i] = {pos[i][0] - c[0], pos[i][1] - c[1], pos[i][2] - c[2]}
	}
	// 4 outer + 4 cut-cap = 8 faces, flat-shaded (as the segment mesh).
	verts := make([dynamic]f32, 0, 8 * 3 * 6)
	indices := make([dynamic]u32, 0, 8 * 3)
	edges := make([dynamic]f32, 0, 8 * 8)
	append_segment_surface(pos, &verts, &indices, &edges)
	// + the cut face sealing the wedge the shard carried: the same quads that
	// cap the chassis hole, FLIPPED (normals out of the shard). Local layout:
	// 4=center+, 0=plus[seg], 2=minus[seg], 5=center−, 3=minus[j], 1=plus[j].
	for f in cut_cap_tris(4, 0, 2, 5, 3, 1, false) {
		append_flat_tri(pos[f[0]], pos[f[1]], pos[f[2]], &verts, &indices)
	}
	handle := register_mesh_owned(
		mesh_hash(verts[:], indices[:]),
		verts[:],
		indices[:],
		edges[:],
		.Hull,
	)
	delete(verts)
	delete(indices)
	delete(edges)
	return handle
}

// Outward unit normal of a triangle from its 3 points (CCW when viewed
// from outside).
tri_normal :: proc(pa, pb, pc: [3]f32) -> [3]f32 {
	n := [3]f32 {
		(pb[1] - pa[1]) * (pc[2] - pa[2]) - (pb[2] - pa[2]) * (pc[1] - pa[1]),
		(pb[2] - pa[2]) * (pc[0] - pa[0]) - (pb[0] - pa[0]) * (pc[2] - pa[2]),
		(pb[0] - pa[0]) * (pc[1] - pa[1]) - (pb[1] - pa[1]) * (pc[0] - pa[0]),
	}
	nl := math.sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2])
	if nl > 1e-9 {n = {n[0] / nl, n[1] / nl, n[2] / nl}}
	return n
}

// Append one flat-shaded triangle: 3 fresh vertices (pos + the face's own
// outward normal, NOT shared/averaged) + 3 indices pointing at them.
append_flat_tri :: proc(pa, pb, pc: [3]f32, verts: ^[dynamic]f32, indices: ^[dynamic]u32) {
	n := tri_normal(pa, pb, pc)
	base := u32(len(verts^) / 6)
	append(verts, pa[0], pa[1], pa[2], n[0], n[1], n[2])
	append(verts, pb[0], pb[1], pb[2], n[0], n[1], n[2])
	append(verts, pc[0], pc[1], pc[2], n[0], n[1], n[2])
	append(indices, base, base + 1, base + 2)
}

// Hull edge color for the body outlines: a light cool gray that the edge
// shader blends 50% toward each hull's face hue (edge.glsl FORK tint),
// so outlines read as a lighter version of the body color. Straight linear
// RGBA; the engine premultiplies it over the surface.
BODY_EDGE_COLOR :: [4]f32{0.32, 0.35, 0.38, 1.0}

// Append one hull edge (endpoint0.xyz, flag0, endpoint1.xyz, flag1) to the
// edge overlay's flat list. flag = 1.0 (convex crease / face boundary); the
// hull-kind overlay ignores it and colors from BODY_EDGE_COLOR instead.
append_hull_edge :: proc(edges: ^[dynamic]f32, a, b: [3]f32) {
	append(edges, a[0], a[1], a[2], 1.0, b[0], b[1], b[2], 1.0)
}

// The 4 triangles closing one shed segment's cut - the hexagon
// {a, b, c, d, e, f} = {center+, v_i+, v_i−, center−, v_j−, v_j+} (the six
// vertices the segment's 4 faces bound once the neighbor segments keep
// theirs) - as two planar quads, one on each spoke's vertical plane (the
// plane through the width axis and the ring vertex), sharing the a–d axis
// edge: quad A (spoke i) = (a,b,c) + (a,c,d), quad B (spoke j) = (a,d,e) +
// (a,e,f). `into_wedge` = true: normals point INTO the shed wedge - the cap
// of the HOLE left in the surviving chassis; false: the same quads flipped  - 
// the DEBRIS shard's cut face, pointing out of the chunk (back-to-back with
// the chassis cap, so at the moment of the break the two sealed pieces share
// one plane with opposite normals - no coincident front faces, no z-fight).
// Winding follows the CCW ring (sorted_ring's angle sort): with `into_wedge`
// the normals land on the wedge side, e.g. quad A's ∝ (−y_i, x_i, 0) points
// at the next ring vertex. That side is the solid's exterior for both wedge
// kinds (thin blade: the slot; wide gap: past the fins - see
// build_segment_cap_mesh), which is why the cap always passes true and the
// shard (a piece of the surviving body) always passes false.
cut_cap_tris :: proc(a, b, c, d, e, f: int, into_wedge: bool) -> [4][3]int {
	if into_wedge {
		return [4][3]int{{a, b, c}, {a, c, d}, {a, d, e}, {a, e, f}}
	}
	return [4][3]int{{b, a, c}, {c, a, d}, {d, a, e}, {e, a, f}}
}

// Encode a waypoint's index as a deterministic hue and its state as
// brightness (the waypoint_color pattern shared by the repo's apps).
waypoint_color :: proc(index, count: int, activated: bool, is_target: bool) -> [3]f32 {
	hue := f32(index) / f32(max(count, 1))
	s :: f32(0.85)
	v := f32(0.45)
	if is_target {v = 0.8}
	if activated {v = 1.0}
	h6 := hue * 6.0
	i := int(h6) % 6
	f := h6 - f32(int(h6))
	p := v * (1.0 - s)
	q := v * (1.0 - s * f)
	t := v * (1.0 - s * (1.0 - f))
	switch i {
	case 0:
		return {v, t, p}
	case 1:
		return {q, v, p}
	case 2:
		return {p, v, t}
	case 3:
		return {p, q, v}
	case 4:
		return {t, p, v}
	case:
		return {v, p, q}
	}
}

// ─── Render init / close / scene ──────────────────────────────────────
init_render :: proc() {
	// Box3D's per-step "unstable: NULL" NaN diagnostic flood is cosmetic  - 
	// the NaN is handled by the app's failure guard - so silence it here
	// too (the sink is process-global; native sets it in main as well).
	b3.Set_Log_Sink(.Silent)
	gfx.Init_Renderer()
	gfx.Set_Sun({0.45, 0.75, 0.5}, {1.0, 0.95, 0.85}, 0.12, 1.1)
	gfx.Set_Sky_Turbidity(2.0)
	gfx.Set_Exposure(-2.0)
	ensure_terrain_mesh(env) // startup: nothing on screen yet
	seed_car_mesh_handles()
}

close_render :: proc() {
	gfx.Shutdown_Renderer()
}

// Density → brightness: heavier = darker, lighter = lighter, so mass is
// legible from color. `t` is the density normalized to [0,1] over its gene
// range (chassis 0.05–2.0, wheels 1–30).

// Car material presets (metallic/roughness PBR). Roughness 1.0 = matte clay
// (the current look), ~0.55 = plastic, ~0.35 = glossy. Per-part alphas
// (1.0 = opaque, 0.5 = semi).
CHASSIS_METALLIC :: f32(0.0)
CHASSIS_ROUGHNESS :: f32(1.0)
CHASSIS_ALPHA :: f32(0.9)
WHEEL_METALLIC :: f32(0.0)
WHEEL_ROUGHNESS :: f32(0.9)
WHEEL_ALPHA :: f32(1.0)
PISTON_ALPHA :: f32(1.0)

// ─── Wheel sidewall (the impostor's polar cap) ───────────────────────
// The gene's wheel color paints only the OUTSIDE SIDEWALL: the impostor
// sphere's polar cap (Append_Sphere's cap_color / cap_threshold), the
// outward-facing region around the wheel body's local +z (the axle).
// WHEEL_SIDEWALL_DEG is the cap's angular radius from the outward pole  - 
// the "how much of the wheel is colored" knob: 0 = no cap (gene color on
// the whole sphere), 90 = a hemisphere. The rest of the tire keeps the
// neutral base (the pattern rings stay legible on it).
WHEEL_SIDEWALL_DEG :: f32(55.0)
WHEEL_TIRE_COLOR :: [3]f32{0.30, 0.32, 0.40} // neutral tire base
// 180° about local y (up): turns the cap's local +z pole to −z for the
// left wheel. Applied in the wheel's LOCAL frame (the right factor of the
// quat product) and a SYMMETRY of the ring pattern (each equator plane
// maps to itself), so the rendered rings - and their spin direction  - 
// match the physics. A world/chassis-frame flip would conjugate the spin
// part of the physics quat and reverse the visible spin.
WHEEL_CAP_FLIP :: [4]f32{0.0, 1.0, 0.0, 0.0}

density_brightness :: proc(t: f32) -> f32 {
	return 1.6 - 1.1 * math.clamp(t, 0.0, 1.0)
}

// ─── PID gauge glow pairs ─────────────────────────────────────────────
// Six small glow spheres riding inside the chassis - one left/right bead
// pair per live-PID scalar. The three pair positions are the corners of a
// tight equilateral triangle in the body's forward/up (x–y) plane, centered
// on the left/right (z) axis: BEARING at the top corner, YAW at the
// rear-down corner, STEER at the forward-down corner (sense → rate →
// command). Beads of a pair sit at z = ±r - touching at the z = 0
// centerline, so the three left beads form one triangle and the three
// right beads its mirror.
// A pair maps the value's position in its display range to a LEFT/RIGHT
// brightness split - the low end lights the left dot, the high end the
// right, a smoothstep crossfade (slow at the extremes, fast through the
// middle), floored so the dim side never fully dies. The pair's TOTAL
// brightness ramps non-linearly off neutral, so a calm car shows only
// embers; the bright side is always the side the car is committing to.
// Sign conventions: bearing > 0 aims LEFT, so it is mapped FLIPPED
// (left-leading = the range's low end). Body +z is LEFT (chassis_axes); a
// positive yaw about +Y (up) moves the nose toward −z = RIGHT, so yaw > 0
// commits RIGHT, mapped as-is like steer - with base = −kp·e − kd·yaw,
// kd > 0 only damps if yaw > 0 is the right-yawing direction.
// RENDER-ONLY: the values are recomputed from the live chassis pose with
// the exact math pid_drive_car runs (memoryless P+D, PID_COEFF), so the
// physics path and the cross-driver determinism gate are untouched.
// NaN-inert: a degenerate body (solver blow-up) skips the gauges.
GAUGE_RADIUS :: f32(0.05) // bead radius (m)
// The cluster sits under the sunlit roof: the beads ride in the hull's
// shadow and the bright top face fills ~90% of the pixel, so the gain runs
// ~6× what a sunlit side-positioned bead needs.
GAUGE_GLOW_MIN :: f32(4.8) // ember floor at neutral (over-unity scale)
GAUGE_GLOW_MAX :: f32(240.0) // full-glow peak (over-unity scale)
// The 3 pair corners form an equilateral triangle in the x–y plane, edge =
// 2r + gap: same-side beads at neighboring corners keep `gap` of surface
// between them - as tight as possible without overlapping.
GAUGE_TRIANGLE_GAP :: f32(0.01) // surface gap between corner beads (m)
// The floor stays tight relative to the peak: at full deviation the dim
// side must stay an ember, not half the peak.
GAUGE_SPLIT_FLOOR :: f32(0.06) // dim-side floor of the L/R split
GAUGE_YAW_SCALE :: f32(4.0) // rad/s mapped to a range end
GAUGE_HUES: [3][3]f32 = {
	{0.25, 0.90, 1.00}, // bearing: cyan
	{1.00, 0.60, 0.15}, // yaw: amber
	{1.00, 0.28, 0.20}, // steer: red-orange
}

// One pair's t in [0,1]: 0 = the LEFT-leading extreme, 1 = the right.
// ok = false when any input is non-finite (the caller renders nothing).
gauge_ts :: proc(bot: ^Bot, cp: [3]f32, q: [4]f32) -> (ts: [3]f32, ok: bool) {
	// Display gauge: the live materialized profile (not a rollout world's).
	e := pid_lookahead_bearing(cp, q, PID_COEFF.lookahead, env_profile[:])
	yaw := b3.Body_GetAngularVelocity(bot.chassis)[1]
	base := -PID_COEFF.kp * e - PID_COEFF.kd * yaw
	if base > PID_COEFF.steer_max {base = PID_COEFF.steer_max}
	if base < -PID_COEFF.steer_max {base = -PID_COEFF.steer_max}
	// NaN guard, the app's idiom (camera.odin): a degenerate body leaves
	// the chassis pose at NaN and NaN is sticky through the bearing math.
	if e != e || yaw != yaw || base != base {
		return [3]f32{}, false
	}
	return [3]f32 {
			math.clamp(0.5 - e / f32(math.PI), 0.0, 1.0),
			math.clamp(0.5 + yaw / GAUGE_YAW_SCALE, 0.0, 1.0),
			math.clamp((base + PID_COEFF.steer_max) / (2 * PID_COEFF.steer_max), 0.0, 1.0),
		},
		true
}

// Smoothstep L/R split of one pair, floored so the dim side stays an ember.
gauge_split :: proc(t: f32) -> (lf, rf: f32) {
	s := t * t * (3 - 2 * t)
	lf = math.clamp(1 - s, GAUGE_SPLIT_FLOOR, 1 - GAUGE_SPLIT_FLOOR)
	rf = math.clamp(s, GAUGE_SPLIT_FLOOR, 1 - GAUGE_SPLIT_FLOOR)
	return lf, rf
}

// Total glow: ember at neutral, non-linear ramp toward either extreme.
gauge_gain :: proc(t: f32) -> f32 {
	dev := math.abs(t - 0.5) * 2
	return GAUGE_GLOW_MIN + (GAUGE_GLOW_MAX - GAUGE_GLOW_MIN) * math.pow(dev, 1.5)
}

// Append the three glow pairs at the chassis's live pose. The beads are
// opaque so they render in the opaque pass and the semi-transparent shell
// (CHASSIS_ALPHA) blends over them for free. They are impostor spheres with
// the great-circle pattern switched off (pattern = 0.0), so they are clean
// matte balls - no surface pattern to read as texture at this size.
render_gauge_spheres :: proc(cp: [3]f32, q: [4]f32, ts: [3]f32) {
	// Body frame: x forward, y up, z LEFT (chassis_axes). Build all three
	// world axes from the chassis quat so the local cluster (which spans
	// x, y, and z) rides the car.
	fwd, left := chassis_axes(q)
	// up = left × forward (ẑ×x̂ = ŷ in the body frame; rotations preserve
	// the cross product).
	up := [3]f32 {
		left[1] * fwd[2] - left[2] * fwd[1],
		left[2] * fwd[0] - left[0] * fwd[2],
		left[0] * fwd[1] - left[1] * fwd[0],
	}
	// Equilateral triangle in the x–y plane, centroid at the chassis
	// center; circumradius R = edge / √3 (edge = 2r + gap).
	r := GAUGE_RADIUS
	R := (2 * r + GAUGE_TRIANGLE_GAP) / f32(math.SQRT_THREE)
	corners := [3][2]f32{{0.0, R}, {-0.8660254 * R, -0.5 * R}, {0.8660254 * R, -0.5 * R}}
	identity_q := [4]f32{0, 0, 0, 1}
	for i in 0 ..< 3 {
		lf, rf := gauge_split(ts[i])
		g := gauge_gain(ts[i])
		for side in 0 ..< 2 {
			// side 0 = LEFT bead (local z = +r), side 1 = RIGHT bead
			// (local z = −r); they touch at z = 0, the centerline.
			lz := r
			frac := lf
			if side == 1 {
				lz = -r
				frac = rf
			}
			pos := [3]f32{}
			for k in 0 ..< 3 {
				pos[k] = cp[k] + corners[i][0] * fwd[k] + corners[i][1] * up[k] + lz * left[k]
			}
			col := [3]f32 {
				GAUGE_HUES[i][0] * g * frac,
				GAUGE_HUES[i][1] * g * frac,
				GAUGE_HUES[i][2] * g * frac,
			}
			gfx.Append_Sphere(
				pos = pos,
				quat = identity_q,
				radius = r,
				color = col,
				alpha = 1.0,
				metallic = 0.0,
				roughness = 0.3,
				pattern = 0.0,
			)
		}
	}
}

// Render a single Bot's per-segment chassis + wheels at its live physics
// pose, per-part colors. `segs`/`caps`/`debris` are the car's per-segment
// mesh caches, indexed by sorted-ring segment: `segs[s]` the body segment
// (drawn while `!bot.broken[s]`), `caps[s]` the hole seal, `debris[s]` the
// shard - both invalid-sentinel until that segment breaks; built once at
// spawn / break, not per frame. `palette` is the 16-slot part palette
// (0–7 = the segments, 8–15 = the wheel slots); `wheel_slot[i]` maps the
// i-th enabled wheel pair (bot.wheels order) to its genome wheel slot.
render_bot_mesh :: proc(
	bot: ^Bot,
	segs: []gfx.Mesh_Handle,
	caps: []gfx.Mesh_Handle,
	debris: []gfx.Mesh_Handle,
	seg_c: [8][3]f32,
	cap_c: [8][3]f32,
	palette: [N_COLORS][3]u8,
	wheel_slot: [N_WHEELS]int,
) {
	chassis_pos, chassis_quat := b3_pos_quat(bot.chassis)
	// Mass → shade: every chassis part is scaled by the chassis density,
	// each wheel pair by its own density (heavier = darker).
	cb := density_brightness(
		(bot.chassis_density - CHASSIS_DENSITY_LO) / (CHASSIS_DENSITY_HI - CHASSIS_DENSITY_LO),
	)
	// PID gauge read (render-only; see render_gauge_spheres): feeds the
	// glow pairs at the end.
	gts, gts_ok := gauge_ts(bot, chassis_pos, chassis_quat)
	// Chassis: 8 segment meshes in 8 slot colors. A broken segment s stops
	// being drawn as body (its shard rides the debris body); its cap seals
	// the hole it left, in the SAME color as the segment.
	for s in 0 ..< 8 {
		pc := palette[s]
		col := [3]f32 {
			f32(pc[0]) / 255.0 * cb,
			f32(pc[1]) / 255.0 * cb,
			f32(pc[2]) / 255.0 * cb,
		}
		// The meshes are centroid-local (segment_centroid): the draw pos is
		// the chassis pose with the part's centroid added back.
		if !bot.broken[s] && gfx.Is_Mesh_Handle_Valid(segs[s]) {
			off := quat_rotv(chassis_quat, seg_c[s])
			gfx.Append_Mesh(
				handle = segs[s],
				pos = {chassis_pos[0] + off[0], chassis_pos[1] + off[1], chassis_pos[2] + off[2]},
				quat = chassis_quat,
				scale = {1.0, 1.0, 1.0},
				color = col,
				alpha = CHASSIS_ALPHA,
				metallic = CHASSIS_METALLIC,
				roughness = CHASSIS_ROUGHNESS,
			)
		}
		if gfx.Is_Mesh_Handle_Valid(caps[s]) {
			off := quat_rotv(chassis_quat, cap_c[s])
			gfx.Append_Mesh(
				handle = caps[s],
				pos = {chassis_pos[0] + off[0], chassis_pos[1] + off[1], chassis_pos[2] + off[2]},
				quat = chassis_quat,
				scale = {1.0, 1.0, 1.0},
				color = col,
				alpha = CHASSIS_ALPHA,
				metallic = CHASSIS_METALLIC,
				roughness = CHASSIS_ROUGHNESS,
			)
		}
	}
	// Debris shards: each shed segment rides its own free body; the shard is
	// the segment's 4 faces in the body frame at the debris body's pose, in
	// the segment's OWN slot color (the paint follows the part).
	if len(bot.debris) > 0 {
		for d in bot.debris {
			dm := debris[d.seg]
			if gfx.Is_Mesh_Handle_Valid(dm) {
				pc := palette[d.seg]
				pos, quat := b3_pos_quat(d.body)
				// Centroid-local shard (build_debris_mesh): the debris body's
				// origin is the chassis position at break time, so add the
				// chunk's centroid back to the draw pos.
				off := quat_rotv(quat, seg_c[d.seg])
				pos = {pos[0] + off[0], pos[1] + off[1], pos[2] + off[2]}
				gfx.Append_Mesh(
					handle = dm,
					pos = pos,
					quat = quat,
					scale = {1.0, 1.0, 1.0},
					color = {
						f32(pc[0]) / 255.0 * cb,
						f32(pc[1]) / 255.0 * cb,
						f32(pc[2]) / 255.0 * cb,
					},
					alpha = CHASSIS_ALPHA,
					metallic = CHASSIS_METALLIC,
					roughness = CHASSIS_ROUGHNESS,
				)
			}
		}
	}
	for w, i in bot.wheels {
		// Dead pair: the strut joint went with its segment, so no
		// piston - the wheel spheres still render as free debris.
		if !bot.broken[w.mount_vertex] {
			render_strut_pair(w, chassis_pos, chassis_quat)
		}
		wb := density_brightness(
			(w.density - WHEEL_DENSITY_LO) / (WHEEL_DENSITY_HI - WHEEL_DENSITY_LO),
		)
		// The pair's genome slot's wheel color, scaled by the pair's own
		// density - the SIDEWALL cap's paint.
		pw := palette[8 + wheel_slot[i]]
		wheel_col := [3]f32 {
			f32(pw[0]) / 255.0 * wb,
			f32(pw[1]) / 255.0 * wb,
			f32(pw[2]) / 255.0 * wb,
		}
		tire_col := [3]f32 {
			WHEEL_TIRE_COLOR[0] * wb,
			WHEEL_TIRE_COLOR[1] * wb,
			WHEEL_TIRE_COLOR[2] * wb,
		}
		cap_th := math.cos(WHEEL_SIDEWALL_DEG * (math.PI / 180.0))
		pair := [2]b3.BodyId{w.wheel_l, w.wheel_r}
		for wheel, wi in pair {
			pos, quat := b3_pos_quat(wheel)
			// The cap's pole is the wheel's local +z (the axle); the right
			// wheel (pair[1]) already points out. The left wheel's outward
			// face is −z: flip the pole with WHEEL_CAP_FLIP (see its doc).
			if wi == 0 {
				quat = quat_mul(quat, WHEEL_CAP_FLIP)
			}
			// Append_Sphere renders through the engine's impostor-sphere
			// shader: three dark great-circle rings along the local axes,
			// riding the live physics quat, so rolling spin is legible.
			gfx.Append_Sphere(
				pos = pos,
				quat = quat,
				radius = w.radius,
				color = tire_col,
				alpha = WHEEL_ALPHA,
				metallic = WHEEL_METALLIC,
				roughness = WHEEL_ROUGHNESS,
				cap_color = wheel_col,
				cap_threshold = cap_th,
			)
		}
	}
	// The glow pairs ride a whole chassis: a fully wrecked car (no surviving
	// segment) skips them so no beads float over the debris.
	if gts_ok && chassis_has_segment(bot, segs) {
		render_gauge_spheres(chassis_pos, chassis_quat, gts)
	}
}

// Any surviving body segment to draw (the gauge beads' precondition).
chassis_has_segment :: proc(bot: ^Bot, segs: []gfx.Mesh_Handle) -> bool {
	for s in 0 ..< 8 {
		if !bot.broken[s] && gfx.Is_Mesh_Handle_Valid(segs[s]) {return true}
	}
	return false
}

// The i-th enabled wheel pair (bot.wheels order) → its genome wheel slot:
// walk the slots in order, collecting the enabled ones (vertex ≥ 0).
// genome_to_body appends the mounts in exactly this slot order
// (body_model.odin), and build_bot follows bm.wheels, so bot.wheels[i] is
// the i-th enabled slot - the map is filled once per spawn and the render
// reads it back.
wheel_slot_map :: proc(g: ^Genes) -> [N_WHEELS]int {
	out := [N_WHEELS]int{}
	n := 0
	for s in 0 ..< N_WHEELS {
		if g.wheels[s].vertex < 0 {continue}
		out[n] = s
		n += 1
	}
	return out
}

// Render the population viewer: the terrain once + each viewer car at its live
// physics pose (all spawn at the origin; no lane offset), per-part colors from
// the genome's 16-slot palette, camera following the current lead.
// Mirrors render_scene's frame setup.
render_pop_viewer :: proc(cam: ^Camera_State) {
	ensure_terrain_mesh(displayed_env())
	if pop_viewer.terrain_hold_active {pop_viewer.terrain_hold_active = false}
	gfx.Reset_Frame_Arena()
	gfx.Set_Edge_Overlay(
		true,
		show_hulls = true,
		show_meshes = false,
		show_heightfields = false,
		hull_color = BODY_EDGE_COLOR,
	)
	append_terrain()
	for i in 0 ..< pop_viewer.n {
		car := &pop_viewer.cars[i]
		render_bot_mesh(
			&car.sim.bot,
			car.segs[:],
			car.caps[:],
			car.debris_mesh[:],
			car.seg_c,
			car.cap_c,
			car.genes.colors,
			car.wheel_slot,
		)
	}
	lead_pos, ok := pop_viewer_lead_pos()
	if ok {
		if pop_viewer.cam_cut {
			// The hold expired (the previous lead finished off the end):
			// cut to the new lead in one frame instead of gliding
			// backwards through empty terrain (follow_camera's target
			// formula, without the 10% lerp).
			cam.target = [3]f32{lead_pos[0], lead_pos[1] + 1.0, lead_pos[2]}
			pop_viewer.cam_cut = false
		} else {
			follow_camera(cam, lead_pos)
		}
	}
	right, up, forward, eye := camera_basis(cam^)
	gfx.Render_Frame(
		right,
		up,
		forward,
		eye,
		CAMERA_FOV_RAD,
		CAMERA_NEAR,
		CAMERA_FAR,
		pop_viewer.sim_time,
		view_debug_mode,
	)
}

b3_pos_quat :: proc(body: b3.BodyId) -> ([3]f32, [4]f32) {
	return b3.Body_GetPosition(body), b3.Body_GetRotation(body)
}

// ─── Suspension strut render ─────────────────────────────────
// Per-wheel suspension: one diagonal PISTON per wheel - a thin ROD from the
// chassis corner on this wheel's side to the wheel's live inner equator
// (the point on the sphere closest to the centerline - the rod stops at the
// sphere's innermost edge, never the hub), plus a thick BARREL sleeve fixed
// to the chassis at 35% of the rest line.
// Contracts: the wheel joint's frame A is orthonormal, so the suspension
// axis must be ⊥ to the axle - a diagonal DOF is not representable in the
// wheel joint. The pistons attach at the REFLECTED VERTEX of each pair's
// polygon vertex, the mount corner (mount_xy, ±z_half); the wheels sit at
// z = ±(z_half + radius), so the inboard point (center pulled r in) is at
// z = ±z_half, COPLANAR with its mount corner - each piston is a pure
// side-plane (xy) line from the corner to the inboard point. Quats are
// {x, y, z, w}.

// Where up the side-cap ridge (mount corner → polygon center) the pistons
// mount: 0.5 = the mount corner (coplanar with the inboard points), 1.0 =
// the center (shared by both wheels of a side). The anchor is
// (mount_xy · (2−2f), ±(z_half + (2f−1)·(z_center − z_half))).
PISTON_MOUNT_FRAC :: f32(0.5)
quat_mul :: proc(a, b: [4]f32) -> [4]f32 {
	return {
		a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
		a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
		a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
		a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
	}
}

quat_rotv :: proc(q: [4]f32, v: [3]f32) -> [3]f32 {
	// v' = v + 2w(a×v) + 2(a×(a×v)), a = (x, y, z) - the Hamilton conjugate
	// product without materializing q*.
	a := [3]f32{q[0], q[1], q[2]}
	c1 := [3]f32{a[1] * v[2] - a[2] * v[1], a[2] * v[0] - a[0] * v[2], a[0] * v[1] - a[1] * v[0]}
	c2 := [3]f32 {
		a[1] * c1[2] - a[2] * c1[1],
		a[2] * c1[0] - a[0] * c1[2],
		a[0] * c1[1] - a[1] * c1[0],
	}
	return {
		v[0] + 2.0 * (q[3] * c1[0] + c2[0]),
		v[1] + 2.0 * (q[3] * c1[1] + c2[1]),
		v[2] + 2.0 * (q[3] * c1[2] + c2[2]),
	}
}

// Chassis-frame point → world, using the caller's already-fetched chassis pose.
chassis_point :: proc(p: [3]f32, q: [4]f32, local: [3]f32) -> [3]f32 {
	r := quat_rotv(q, local)
	return {p[0] + r[0], p[1] + r[1], p[2] + r[2]}
}

render_strut_pair :: proc(w: Wheel_Joint, ch_p: [3]f32, ch_q: [4]f32) {
	u := w.strut_axis
	s := math.clamp(w.radius / 0.5, 0.5, 1.5) // strut scale, 1.0 at reference r=0.5
	// Chassis z in world - the axle direction; the inner equator is the wheel
	// center pulled r toward the centerline along it.
	zw := quat_rotv(ch_q, [3]f32{0.0, 0.0, 1.0})
	sides := [2]f32{-1.0, +1.0}
	for side in sides {
		body := w.wheel_l
		if side > 0 {body = w.wheel_r}
		wpos, _ := b3_pos_quat(body)
		// Live wheel mount point: the inner equator - where the piston reaches
		// the wheel.
		inner := [3]f32 {
			wpos[0] - side * w.radius * zw[0],
			wpos[1] - side * w.radius * zw[1],
			wpos[2] - side * w.radius * zw[2],
		}
		// Chassis mount point: the reflected copy of this pair's polygon
		// vertex on this side (the mount corner), PISTON_MOUNT_FRAC of the
		// way up the ridge toward the polygon center.
		f := PISTON_MOUNT_FRAC
		corner := [3]f32 {
			w.mount[0] * (2.0 - 2.0 * f),
			w.mount[1] * (2.0 - 2.0 * f),
			side * (w.z_half + (2.0 * f - 1.0) * (w.z_center - w.z_half)),
		}
		// Rest line corner → rest inner equator: fixes the barrel. The rest
		// inner equator sits at z = ±z_half (center at ±(z_half + radius)
		// pulled r in) - coplanar with the corner.
		rest_inner := [3]f32 {
			w.mount[0] + STRUT_WHEEL_TRAVEL * u[0],
			w.mount[1] + STRUT_WHEEL_TRAVEL * u[1],
			side * w.z_half,
		}
		rd := [3]f32 {
			rest_inner[0] - corner[0],
			rest_inner[1] - corner[1],
			rest_inner[2] - corner[2],
		}
		rl := math.sqrt(rd[0] * rd[0] + rd[1] * rd[1] + rd[2] * rd[2])
		// Barrel (sleeve): fixed to the chassis at 35% of the rest line  - 
		// the shock mount, chunky on purpose (the car's most legible moving
		// part).
		barrel := [3]f32 {
			corner[0] + 0.35 * rd[0],
			corner[1] + 0.35 * rd[1],
			corner[2] + 0.35 * rd[2],
		}
		gfx.Append_Capsule(
			pos = chassis_point(ch_p, ch_q, barrel),
			quat = quat_mul(ch_q, quat_x_to({rd[0] / rl, rd[1] / rl, rd[2] / rl})),
			half_length = 0.20 * s,
			radius = 0.13 * s,
			color = {0.15, 0.15, 0.17},
			alpha = PISTON_ALPHA,
			metallic = 0.7,
			roughness = 0.35,
		)
		// Rod: chassis corner → live inner equator. Its x-y projection is the
		// physical DOF line, so length/angle sweep with the travel.
		vw := chassis_point(ch_p, ch_q, corner)
		d := [3]f32{inner[0] - vw[0], inner[1] - vw[1], inner[2] - vw[2]}
		dl := math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
		if dl > 1e-4 {
			mid := [3]f32{vw[0] + d[0] * 0.5, vw[1] + d[1] * 0.5, vw[2] + d[2] * 0.5}
			gfx.Append_Capsule(
				pos = mid,
				quat = quat_x_to({d[0] / dl, d[1] / dl, d[2] / dl}),
				half_length = dl / 2.0,
				radius = 0.07 * s,
				color = {0.6, 0.6, 0.65},
				alpha = PISTON_ALPHA,
				metallic = 0.8,
				roughness = 0.3,
			)
		}
	}
}

// Render the terrain-only scene (the cars are drawn by render_pop_viewer).
// view_debug_mode (browser 'v' cycles it): 0 = lit, 1 = view-space depth
// grayscale (every shape type renders its linear camera distance - wheels
// vs hull directly comparable), 2 = shadow cascade index, 3 = depth dump.
view_debug_mode: i32

render_scene :: proc(cam: ^Camera_State) {
	ensure_terrain_mesh(displayed_env())
	gfx.Reset_Frame_Arena()
	// Draw the body part seams as dark outlines, matching the wheel rings.
	gfx.Set_Edge_Overlay(
		true,
		show_hulls = true,
		show_meshes = false,
		show_heightfields = false,
		hull_color = BODY_EDGE_COLOR,
	)
	append_terrain()

	right, up, forward, eye := camera_basis(cam^)
	gfx.Render_Frame(
		right,
		up,
		forward,
		eye,
		CAMERA_FOV_RAD,
		CAMERA_NEAR,
		CAMERA_FAR,
		0.0,
		view_debug_mode,
	)
}

