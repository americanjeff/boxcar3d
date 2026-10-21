// Genome → Body_Model.
// Pure, deterministic: same genome in, same model out (no physics, no
// RNG). Body frame: x = forward, y = up, width along lateral z, centered
// on the mid-plane; the genome center is the body origin (≈ COM).

package main

import "core:math"

Triangle :: struct {
	points: [3][3]f32, // the triangle's 3 vertices, outward winding
}

Wheel_Mount :: struct {
	pos:          [3]f32, // mount point in the body frame
	axle_axis:    [3]f32, // spin axis (unit) - body lateral z
	strut_axis:   [3]f32, // (unit) - genome axle_angle: (0,-1,0) rotated about body z (0° = straight down)
	radius:       f32,
	density:      f32, // (kg/m³)
	mount_vertex: int, // sorted-ring index of this wheel's genome vertex (its chassis segment)
	z_half:       f32, // half-width at the mount vertex: wheel centers sit at ±(z_half + radius), inboard point coplanar with the mount corner
}

Body_Model :: struct {
	tris:            [dynamic]Triangle, // 32 surface triangles, 4 per segment
	wheels:          [dynamic]Wheel_Mount,
	heights:         [N_WIDTHS]f32, // width profile in RING order (index 8 = center)
	chassis_density: f32, // (kg/m³); 0 = caller supplies its own default.
	// RING order: fan wedge over ring edge k is degenerate
	// (fan_wedge_degenerate). Its 4 tris are kept - indexing stays
	// tris[4·seg..4·seg+3]; physics and render skip the segment.
	degenerate:      [8]bool,
}

destroy_body_model :: proc(bm: ^Body_Model) {
	if len(bm.tris) > 0 {delete(bm.tris)}
	if len(bm.wheels) > 0 {delete(bm.wheels)}
	bm^ = {}
}

// The genome's 8 vertex positions in strict circular order around the
// origin (the order the cap surface is fanned in). The angle genes are
// independent values in [0, 2π), so the gene order can self-intersect.
// SHARED by genome_to_body (physics hulls) and render's per-segment
// body meshes so render and physics always match.
sorted_ring :: proc(genome: ^Genome) -> [8][3]f32 {
	verts := [8][3]f32{}
	for i in 0 ..< 8 {verts[i] = genome_vertex_pos(genome, i)}
	for i in 1 ..< 8 { 	// insertion sort by angle around the origin
		p := verts[i]
		a := math.atan2(p[1], p[0])
		j := i - 1
		for ; j >= 0; j -= 1 {
			if math.atan2(verts[j][1], verts[j][0]) <= a {break}
			verts[j + 1] = verts[j]
		}
		verts[j + 1] = p
	}
	return verts
}

// Paper-blade floor. The body tiles each ring edge's fan triangle (center,
// v_i, v_j) into four tetrahedral hulls that taper to a point at both
// vertices - so the edge's minimum thickness is its APOTHEM (distance from
// the genome center to the chord). A long edge with a tiny apothem is a
// paper blade: Box3D builds the hulls fine, but if the blade is thinner
// than its tip's per-substep travel during a tumble, it tunnels through
// the heightfield.
//
// The floor is the tip's travel budget: a vertex at radius r sweeps
// ω·r·Δt_sub per substep at tumble rate ω, so the apothem must clear
// FAN_TIP_OMEGA · (TIME_STEP/SUB_STEPS) · r_max - SCALED by the edge's
// distance from the center (an absolute floor would be wrong).
//
// The phenotype refuses to build such a wedge (fan_wedge_degenerate):
// genome_to_body marks the segment degenerate, the hull builder skips its
// four tetrahedra, and the renderer skips its mesh. Short edges (chord ≤
// FAN_SHORT_LO) are exempt: a cleft under half a metre sits inside the
// body's own silhouette and cannot stick out to clip the ground.
FAN_TIP_OMEGA :: f32(30.0) // design crash-tumble bound (rad/s) for the travel floor
FAN_SHORT_LO :: f32(0.50)

// Per-edge apothem floor: the tip's per-substep travel at the edge's
// farthest vertex (see FAN_TIP_OMEGA).
fan_floor :: proc(r_max: f32) -> f32 {
	return FAN_TIP_OMEGA * (TIME_STEP / f32(SUB_STEPS)) * r_max
}

// The degenerate-wedge test for one ring edge. Call it with
// (a, b) = (ring[i], ring[i+1]) in ring order. Two failure modes, both of
// which make the wedge's fan triangle an invalid part of the body:
//
// PAPER BLADE: see above.
//
// WIDE GAP: the edge's CCW angular span is 180°+ - the fan center sits
// past the chord, so the wedge's fan triangle has reversed winding and
// overlaps its neighbors': the culler and the shadow pass both drop it.
// Skipping leaves the surviving wedges tiling a star-shaped body, which
// the birth cap seals. At most one edge can have this (the angular gaps
// sum to 360°).
fan_wedge_degenerate :: proc(a, b: [3]f32) -> bool {
	dx := a[0] - b[0]
	dy := a[1] - b[1]
	L := math.sqrt(dx * dx + dy * dy)
	if L <= FAN_SHORT_LO {return false}
	// Wide gap: the CCW span from a to b is 180°+ - the chord leaves the
	// fan center on its far side (a bowtie ring).
	gap := math.atan2(b[1], b[0]) - math.atan2(a[1], a[0])
	if gap < 0 {gap += 2.0 * math.PI}
	if gap >= math.PI {return true}
	ra := math.sqrt(a[0] * a[0] + a[1] * a[1])
	rb := math.sqrt(b[0] * b[0] + b[1] * b[1])
	cross := math.abs(a[0] * b[1] - a[1] * b[0])
	return cross / L < fan_floor(math.max(ra, rb))
}

// Ring (segment) index of genome vertex `g` in `ring` (the sorted ring): the
// fan order is the sorted ring, so the genome vertex maps back through it by
// exact float match - both sides are genome_vertex_pos of the same genome.
// (By construction the position is always present.)
ring_index_of :: proc(genome: ^Genome, ring: [8][3]f32, g: int) -> (int, bool) {
	for k in 0 ..< 8 {
		if ring[k] == genome_vertex_pos(genome, g) {return k, true}
	}
	return 0, false
}

// Derive the Body_Model from the genome (pure). The body is a width-profile
// solid: each genome-polygon vertex v[i] (z=0) is offset to ±heights[i] and
// the polygon center to ±heights[8]. 8 top cap triangles fan each ring edge
// to the center (outward +z), 8 bottom caps mirror them, and the side belt
// over each ring edge (the quad (±v_i, ±v_j) corners, skew when the two
// widths differ) splits into two triangles. Wheel i mounts at its vertex's
// position with the strut-axis rule; its wheels sit at ±(z_half + radius).
genome_to_body :: proc(genome: ^Genome) -> Body_Model {
	ring := sorted_ring(genome)

	// Width profile in RING order: heights[i] = the half-width at ring
	// vertex i (the genome widths are in genome order), heights[8] = center.
	heights := [N_WIDTHS]f32{}
	for g in 0 ..< 8 {
		i, found := ring_index_of(genome, ring, g)
		ensure(found, "genome vertex not in sorted ring")
		heights[i] = genome.widths[g]
	}
	heights[8] = genome.widths[8]

	// Degenerate-wedge marks (fan_wedge_degenerate)
	degen := [8]bool{}
	for i in 0 ..< 8 {
		degen[i] = fan_wedge_degenerate(ring[i], ring[(i + 1) % 8])
	}

	bm := Body_Model {
		tris            = make([dynamic]Triangle, 0, 32),
		wheels          = make([dynamic]Wheel_Mount, 0, len(genome.wheels)),
		heights         = heights,
		chassis_density = genome.chassis_density,
		degenerate      = degen,
	}

	for i in 0 ..< 8 {
		j := (i + 1) % 8
		top_i := [3]f32{ring[i][0], ring[i][1], heights[i]}
		bot_i := [3]f32{ring[i][0], ring[i][1], -heights[i]}
		top_j := [3]f32{ring[j][0], ring[j][1], heights[j]}
		bot_j := [3]f32{ring[j][0], ring[j][1], -heights[j]}
		top_c := [3]f32{0.0, 0.0, heights[8]}
		bot_c := [3]f32{0.0, 0.0, -heights[8]}
		// Top cap: ring edge i→j to the center (outward +z).
		append(&bm.tris, Triangle{points = {top_i, top_j, top_c}})
		// Bottom cap: mirrored (outward −z), reversed winding.
		append(&bm.tris, Triangle{points = {bot_j, bot_i, bot_c}})
		// Side belt: the (generally skew) quad split along the i→j diagonal,
		// both triangles outward.
		append(&bm.tris, Triangle{points = {bot_j, top_j, top_i}})
		append(&bm.tris, Triangle{points = {bot_j, top_i, bot_i}})
	}

	for w in genome.wheels {
		if w.vertex < 0 {continue}
		pos := genome_vertex_pos(genome, w.vertex)
		mount_vertex, found := ring_index_of(genome, ring, w.vertex)
		ensure(found, "wheel vertex not in sorted ring")
		axle := [3]f32{0.0, 0.0, 1.0}
		s := math.sin(w.axle_angle)
		c := math.cos(w.axle_angle)
		strut := [3]f32{s, -c, 0.0}
		append(
			&bm.wheels,
			Wheel_Mount {
				pos = pos,
				axle_axis = axle,
				strut_axis = strut,
				radius = w.radius,
				density = w.density,
				mount_vertex = mount_vertex,
				z_half = heights[mount_vertex],
			},
		)
	}

	// Wheel-overlap constraint: the generated wheel spheres must not overlap
	// each other - a sphere that swallows its neighbor's strut line makes the
	// car illegible. Clamp each pair's radius to half the rest-position distance
	// to the nearest other sphere.
	// Static by design: the suspension DOF moves centers along in-plane strut axes,
	// so the within-pair lateral gap (2·(z_half + radius)) is exact. cross-pair
	// approach at full travel is a bounded,
	// accepted residual.
	centers := make([dynamic][3]f32, 0, 2 * len(bm.wheels))
	for i in 0 ..< len(bm.wheels) {
		w := &bm.wheels[i]
		c := [3]f32 {
			w.pos[0] + STRUT_WHEEL_TRAVEL * w.strut_axis[0],
			w.pos[1] + STRUT_WHEEL_TRAVEL * w.strut_axis[1],
			0.0,
		}
		append(&centers, [3]f32{c[0], c[1], c[2] + w.z_half + w.radius})
		append(&centers, [3]f32{c[0], c[1], c[2] - w.z_half - w.radius})
	}
	for i in 0 ..< len(bm.wheels) {
		low := f32(1e9)
		for s in 0 ..< 2 {
			ci := centers[2 * i + s]
			for j in 0 ..< len(bm.wheels) {
				for t in 0 ..< 2 {
					if j == i && t == s {continue}
					cj := centers[2 * j + t]
					dx := ci[0] - cj[0]
					dy := ci[1] - cj[1]
					dz := ci[2] - cj[2]
					d2 := dx * dx + dy * dy + dz * dz
					if d2 < low {low = d2}
				}
			}
		}
		if low < 1e9 {
			bm.wheels[i].radius = math.min(bm.wheels[i].radius, math.sqrt(low) * 0.5)
		}
	}
	delete(centers)
	return bm
}
