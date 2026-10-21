#+build !wasm32
// Headless exposed-backface probe (diagnostic, not a gate).
// Replays one genome's rollout on the exact viewer pipeline (slot_tick),
// mirrors the viewer's cap bookkeeping, and ray-tests the surface the
// renderer would draw (surviving segment faces + cap quads + debris shards)
// against a sphere of viewpoints. Three detections:
//
// EXPOSED BACKFACE: first hit a backface - the culler drops it, so the
// viewer sees whatever is behind it (a co-located front face on a shared
// vertex/edge counts as covered).
//
// SEE-THROUGH HOLE: a ray enters the car's solid (footprint × height
// profile) with no hit at all.
//
// STALE WALL: two adjacent missing wedges whose caps disagree about the
// shared spoke - a floating interior wall.
//
//   boxcar3d backfaceprobe <genome> [terrain_seed] [line] [ticks]

package main

import "core:fmt"
import "core:math"
import "core:strconv"

pb_sub :: proc(a, b: [3]f32) -> [3]f32 {
	return {a[0] - b[0], a[1] - b[1], a[2] - b[2]}
}

pb_dot :: proc(a, b: [3]f32) -> f32 {
	return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

pb_cross :: proc(a, b: [3]f32) -> [3]f32 {
	return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]}
}

// Rotate body-frame vector v by world quat q ({x,y,z,w}, render's
// convention): v' = v + 2w(q×v) + 2q×(q×v).
pb_qrot :: proc(q: [4]f32, v: [3]f32) -> [3]f32 {
	q3 := [3]f32{q[0], q[1], q[2]}
	t := pb_cross(q3, v)
	t = {2.0 * t[0], 2.0 * t[1], 2.0 * t[2]}
	r := pb_cross(q3, t)
	return {v[0] + q[3] * t[0] + r[0], v[1] + q[3] * t[1] + r[1], v[2] + q[3] * t[2] + r[2]}
}

pb_xform :: proc(p: [3]f32, pos: [3]f32, q: [4]f32) -> [3]f32 {
	r := pb_qrot(q, p)
	return {pos[0] + r[0], pos[1] + r[1], pos[2] + r[2]}
}

// Möller–Trumbore; returns (t, hit).
pb_ray_tri :: proc(o, d, a, b, c: [3]f32) -> (f32, bool) {
	e1 := pb_sub(b, a)
	e2 := pb_sub(c, a)
	h := pb_cross(d, e2)
	det := pb_dot(e1, h)
	if math.abs(det) < 1e-12 {return 0.0, false}
	f := 1.0 / det
	s := pb_sub(o, a)
	u := pb_dot(s, h) * f
	if u < 0 || u > 1 {return 0.0, false}
	q := pb_cross(s, e1)
	v := pb_dot(d, q) * f
	if v < 0 || u + v > 1 {return 0.0, false}
	t := pb_dot(e2, q) * f
	if t > 1e-5 {return t, true}
	return 0.0, false
}

PB_Tri :: struct {
	a:     [3]f32,
	b:     [3]f32,
	c:     [3]f32,
	label: string,
}

// The world-space triangles the renderer would draw right now: surviving
// segment faces, the registered caps (with their FROZEN void flags - a cap
// exists for a segment once it reads missing, unless its flags are both
// true, i.e. the invalid-by-design sentinel), and the debris shards at their
// live poses. Faithful to the renderer's build procs incl. their skips.
pb_surface :: proc(g: ^Genome, slot: ^Rollout_Slot, cap_flags: [8][2]bool) -> []PB_Tri {
	out := make([dynamic]PB_Tri, 0, 96)
	sim := &slot.sim
	bm := &sim.body_model
	cpos, cq := b3_pos_quat(sim.bot.chassis)
	face_names := [4]string{"top", "bot", "belt", "belt"}
	for s in 0 ..< 8 {
		if sim.bot.broken[s] {continue}
		if bm.degenerate[s] {continue}
		sp := segment_positions(g, s)
		for f, fi in SEGMENT_FACES {
			lbl := fmt.aprintf("seg{}:{}", s, face_names[fi])
			append(
				&out,
				PB_Tri {
					a = pb_xform(sp[f[0]], cpos, cq),
					b = pb_xform(sp[f[1]], cpos, cq),
					c = pb_xform(sp[f[2]], cpos, cq),
					label = lbl,
				},
			)
		}
	}
	// Caps, the 18-position layout of build_segment_cap_mesh.
	ring := sorted_ring(g)
	pos18 := [18][3]f32{}
	for i in 0 ..< 8 {
		pos18[i] = {ring[i][0], ring[i][1], bm.heights[i]}
		pos18[8 + i] = {ring[i][0], ring[i][1], -bm.heights[i]}
	}
	pos18[16] = {0.0, 0.0, bm.heights[8]}
	pos18[17] = {0.0, 0.0, -bm.heights[8]}
	for s in 0 ..< 8 {
		if !sim.bot.broken[s] && !bm.degenerate[s] {continue}
		if cap_flags[s][0] && cap_flags[s][1] {continue}
		j := (s + 1) % 8
		ct := cut_cap_tris(16, s, 8 + s, 17, 8 + j, j, true)
		quad_names := [4]string{"A", "A", "B", "B"}
		for i in 0 ..< 4 {
			if i < 2 && cap_flags[s][0] {continue}
			if i >= 2 && cap_flags[s][1] {continue}
			t := ct[i]
			lbl := fmt.aprintf("cap{}:{}", s, quad_names[i])
			append(
				&out,
				PB_Tri {
					a = pb_xform(pos18[t[0]], cpos, cq),
					b = pb_xform(pos18[t[1]], cpos, cq),
					c = pb_xform(pos18[t[2]], cpos, cq),
					label = lbl,
				},
			)
		}
	}
	// Debris shards at their live poses (skipped for degenerate segs).
	for d in sim.bot.debris {
		if bm.degenerate[d.seg] {continue}
		dpos, dq := b3_pos_quat(d.body)
		sp := segment_positions(g, d.seg)
		for f, fi in SEGMENT_FACES {
			lbl := fmt.aprintf("shard{}:outer{}", d.seg, fi)
			append(
				&out,
				PB_Tri {
					a = pb_xform(sp[f[0]], dpos, dq),
					b = pb_xform(sp[f[1]], dpos, dq),
					c = pb_xform(sp[f[2]], dpos, dq),
					label = lbl,
				},
			)
		}
		ct := cut_cap_tris(4, 0, 2, 5, 3, 1, false)
		quad_names := [4]string{"cutA", "cutA", "cutB", "cutB"}
		for i in 0 ..< 4 {
			t := ct[i]
			lbl := fmt.aprintf("shard{}:{}", d.seg, quad_names[i])
			append(
				&out,
				PB_Tri {
					a = pb_xform(sp[t[0]], dpos, dq),
					b = pb_xform(sp[t[1]], dpos, dq),
					c = pb_xform(sp[t[2]], dpos, dq),
					label = lbl,
				},
			)
		}
	}
	return out[:]
}

// 2D ray (o + t·d in the ring plane) vs segment a→b (z ignored); returns
// (t, hit) in the ray's own parameter.
pb_ray_seg2 :: proc(o, d: [2]f32, a, b: [3]f32) -> (f32, bool) {
	ex := b[0] - a[0]
	ey := b[1] - a[1]
	denom := d[0] * ey - d[1] * ex
	if math.abs(denom) < 1e-12 {return 0.0, false}
	fx := a[0] - o[0]
	fy := a[1] - o[1]
	t := (fx * ey - fy * ex) / denom
	if t < 1e-6 {return 0.0, false}
	u := (fx * d[1] - fy * d[0]) / denom
	if u < 0.0 || u > 1.0 {return 0.0, false}
	return t, true
}

// The first t at which the 2D ray enters the star-shaped footprint: its
// boundary is the surviving chords + the spokes at each skipped run's ends.
// The eye is always outside (the probe's radius > max_r), so the first
// crossing is the entry.
pb_footprint_entry :: proc(o, d: [2]f32, ring: [8][3]f32, degen: [8]bool) -> (f32, bool) {
	if math.abs(d[0]) < 1e-9 && math.abs(d[1]) < 1e-9 {return 0.0, false}
	best := f32(1e30)
	zero := [3]f32{}
	for s in 0 ..< 8 {
		if !degen[s] {
			t, ok := pb_ray_seg2(o, d, ring[s], ring[(s + 1) % 8])
			if ok && t < best {best = t}
		} else {
			if !degen[(s + 7) % 8] {
				t, ok := pb_ray_seg2(o, d, zero, ring[s])
				if ok && t < best {best = t}
			}
			if !degen[(s + 1) % 8] {
				t, ok := pb_ray_seg2(o, d, zero, ring[(s + 1) % 8])
				if ok && t < best {best = t}
			}
		}
	}
	return best, best < 1e30
}

// The height-profile value at a footprint-boundary point: linear over the
// containing wedge (barycentric over the center + the chord's endpoints), or
// the center→vertex blend on a boundary spoke.
pb_height_at :: proc(p: [2]f32, ring: [8][3]f32, heights: [9]f32, degen: [8]bool) -> f32 {
	hc := heights[8]
	for s in 0 ..< 8 {
		if degen[s] {continue}
		a, b := ring[s], ring[(s + 1) % 8]
		ex := b[0] - a[0]
		ey := b[1] - a[1]
		L := math.sqrt(ex * ex + ey * ey)
		cross := (p[0] - a[0]) * ey - (p[1] - a[1]) * ex
		if math.abs(cross) > 1e-3 * L {continue}
		det := a[0] * b[1] - a[1] * b[0]
		if math.abs(det) < 1e-12 {return hc}
		beta := (p[0] * b[1] - p[1] * b[0]) / det
		gamma := (a[0] * p[1] - a[1] * p[0]) / det
		return (1.0 - beta - gamma) * hc + beta * heights[s] + gamma * heights[(s + 1) % 8]
	}
	r := math.sqrt(p[0] * p[0] + p[1] * p[1])
	if r < 1e-9 {return hc}
	for s in 0 ..< 8 {
		rr := math.sqrt(ring[s][0] * ring[s][0] + ring[s][1] * ring[s][1])
		if rr < 1e-9 {continue}
		cross := p[0] * ring[s][1] - p[1] * ring[s][0]
		if math.abs(cross) > 1e-3 * rr {continue}
		if p[0] * ring[s][0] + p[1] * ring[s][1] < 0.0 {continue}
		f := r / rr
		if f > 1.0 {f = 1.0}
		return hc + (heights[s] - hc) * f
	}
	return hc
}

// Fire a sphere of rays at the car; reports exposed backfaces and
// see-through holes (detection rules in the file header).
pb_raytest :: proc(
	tris: []PB_Tri,
	cpos: [3]f32,
	cq: [4]f32,
	ring: [8][3]f32,
	heights: [9]f32,
	degen: [8]bool,
	radius: f32,
	tag: string,
) {
	n_back := 0
	n_seethru := 0
	n_rays := 0
	ex_back := make([dynamic]string, 0, 12)
	ex_see := make([dynamic]string, 0, 12)
	qinv := [4]f32{-cq[0], -cq[1], -cq[2], cq[3]}
	els := [7]f32{-70, -45, -20, 0, 25, 50, 70}
	dists := [3]f32{0.0, 0.35, -0.35}
	for az_deg := 0; az_deg < 360; az_deg += 15 {
		az := f32(az_deg) * math.PI / 180.0
		for el in els {
			elr := el * math.PI / 180.0
			for dv in dists {
				// Aim 0.3m off the chassis's centerline in world x (forward):
				// a ray aimed exactly at cpos terminates on the cap walls'
				// shared centerline edge - a measure-zero graze whose
				// hit/miss is float noise.
				target := [3]f32{cpos[0] + 0.3, cpos[1] + dv, cpos[2]}
				o := [3]f32 {
					target[0] + radius * math.cos(elr) * math.cos(az),
					target[1] + radius * math.sin(elr),
					target[2] + radius * math.cos(elr) * math.sin(az),
				}
				d := [3]f32 {
					-math.cos(elr) * math.cos(az),
					-math.sin(elr),
					-math.cos(elr) * math.sin(az),
				}
				n_rays += 1
				best_t := f32(1e9)
				best_i := -1
				co_front := false
				for tri, i in tris {
					t, hit := pb_ray_tri(o, d, tri.a, tri.b, tri.c)
					if !hit || t > best_t + 2e-3 {continue}
					if t < best_t {
						best_t = t
						best_i = i
						co_front = false
					}
					n := pb_cross(pb_sub(tri.b, tri.a), pb_sub(tri.c, tri.a))
					hp := [3]f32{o[0] + d[0] * t, o[1] + d[1] * t, o[2] + d[2] * t}
					if pb_dot(n, pb_sub(o, hp)) >= 0 {co_front = true}
				}
				if best_i >= 0 {
					tri := tris[best_i]
					n := pb_cross(pb_sub(tri.b, tri.a), pb_sub(tri.c, tri.a))
					hp := [3]f32{o[0] + d[0] * best_t, o[1] + d[1] * best_t, o[2] + d[2] * best_t}
					// A co-located front face (a shared vertex/edge tie,
					// float-noise apart in t) covers the pixel: not exposed.
					if pb_dot(n, pb_sub(o, hp)) < 0 && !co_front {
						n_back += 1
						if len(ex_back) < 10 {
							ex := fmt.aprintf(
								"    backface az={} el={} dvt={:.2f} {} hit=({:.2f},{:.2f},{:.2f}) n=({:.2f},{:.2f},{:.2f})",
								az_deg,
								int(el),
								dv,
								tri.label,
								hp[0],
								hp[1],
								hp[2],
								n[0],
								n[1],
								n[2],
							)
							append(&ex_back, ex)
						}
					}
					continue
				}
				// No face hit: does the ray enter the car's solid (footprint
				// × height profile - the loose body-frame bbox over-reports
				// for thin cars)?
				ob := pb_qrot(qinv, pb_sub(o, cpos))
				db := pb_qrot(qinv, d)
				te, entered := pb_footprint_entry(
					[2]f32{ob[0], ob[1]},
					[2]f32{db[0], db[1]},
					ring,
					degen,
				)
				if !entered {continue}
				pe := [2]f32{ob[0] + db[0] * te, ob[1] + db[1] * te}
				// A cusp entry (the axis, where all boundary spokes meet) is
				// a measure-zero graze of the fin edges: not a hole.
				if pe[0] * pe[0] + pe[1] * pe[1] < 1e-4 {continue}
				he := pb_height_at(pe, ring, heights, degen)
				ze := ob[2] + db[2] * te
				if math.abs(ze) > he {continue}
				n_seethru += 1
				if len(ex_see) < 10 {
					ex := fmt.aprintf(
						"    seethru  az={} el={} dvt={:.2f} entry=({:.2f},{:.2f},{:.2f})",
						az_deg,
						int(el),
						dv,
						pe[0],
						pe[1],
						ze,
					)
					append(&ex_see, ex)
				}
			}
		}
	}
	fmt.printfln(
		"  raytest [{}]: {} rays -> {} exposed-backface first hits, {} see-through",
		tag,
		n_rays,
		n_back,
		n_seethru,
	)
	fmt.printfln(
		"    pose pos=({:.2f},{:.2f},{:.2f}) quat=({:.3f},{:.3f},{:.3f},{:.3f})",
		cpos[0],
		cpos[1],
		cpos[2],
		cq[0],
		cq[1],
		cq[2],
		cq[3],
	)
	for s in ex_back {fmt.printfln(s)}
	for s in ex_see {fmt.printfln(s)}
	delete(ex_back)
	delete(ex_see)
}

// One raytest frame at the car's current pose: rebuild the drawn surface
// and fire the probe.
pb_raytest_now :: proc(
	g: ^Genome,
	slot: ^Rollout_Slot,
	cap_flags: [8][2]bool,
	ring: [8][3]f32,
	bm: ^Body_Model,
	envelope_r: f32,
	tag: string,
) {
	tris := pb_surface(g, slot, cap_flags)
	cp, cq := b3_pos_quat(slot.sim.bot.chassis)
	pb_raytest(tris, cp, cq, ring, bm.heights, bm.degenerate, envelope_r, tag)
	delete(tris)
}

// Two adjacent missing wedges share one spoke. Each side's cap owns the
// shared-spoke quad unless its frozen void flag omitted it. Exactly one side
// keeping its quad = a floating interior wall in the merged pocket (front
// from one side, culled backface from the other). `cap_flags[s]` = the void
// flags frozen in segment s's registered cap.
pb_stale_walls :: proc(slot: ^Rollout_Slot, cap_flags: [8][2]bool) {
	sim := &slot.sim
	bm := &sim.body_model
	for s in 0 ..< 8 {
		prev := (s + 7) % 8
		if !(sim.bot.broken[prev] || bm.degenerate[prev]) {continue}
		if !(sim.bot.broken[s] || bm.degenerate[s]) {continue}
		prev_has := !cap_flags[prev][1]
		s_has := !cap_flags[s][0]
		if prev_has != s_has {
			owner := s
			if prev_has {owner = prev}
			fmt.printfln(
				"  STALE WALL: shared spoke {} (between missing seg{} and seg{}) - quad kept only by cap{}",
				s,
				prev,
				s,
				owner,
			)
		}
	}
}

probe_backface :: proc(args: []string) -> int {
	if len(args) < 1 {
		fmt.eprintfln("usage: boxcar3d backfaceprobe <genome> [terrain_seed] [line] [ticks]")
		return 2
	}
	path := args[0]
	seed := u64(0)
	line := f32(0)
	ticks := 900
	if len(args) >= 2 {seed, _ = parse_u64(args[1])}
	if len(args) >= 3 {line, _ = parse_f32(args[2])}
	if len(args) >= 4 {ticks, _ = strconv.parse_int(args[3])}
	genes, _, ok := load_genome(path)
	if !ok {
		fmt.eprintfln("backfaceprobe: could not load genome {}", path)
		return 1
	}
	e := Env {
		seed = seed,
		line = line,
	}
	if e.seed == 0 {e.seed = TERRAIN_DEFAULT_SEED}
	if e.line <= 0 {e.line = f32(TARGET_START_LEN)}
	g := decode_genes(&genes)
	defer destroy_genome(&g)
	slot := Rollout_Slot{}
	slot_start(&slot, &genes, "", 0, 0, e)
	sim := &slot.sim
	bm := &sim.body_model

	fmt.printfln("backfaceprobe: {} env seed=0x{:x} line={:.0f}m", path, e.seed, e.line)
	ring := sorted_ring(&g)
	max_r := f32(0.0)
	max_h := bm.heights[8]
	for i in 0 ..< 8 {
		if bm.heights[i] > max_h {max_h = bm.heights[i]}
		r := math.sqrt(ring[i][0] * ring[i][0] + ring[i][1] * ring[i][1])
		if r > max_r {max_r = r}
	}
	for w in bm.wheels {
		fmt.printfln(
			"  wheel pair @ring{} r={:.3f} mount=({:.2f},{:.2f})",
			w.mount_vertex,
			w.radius,
			w.pos[0],
			w.pos[1],
		)
	}
	for s in 0 ..< 8 {
		a := ring[s]
		b := ring[(s + 1) % 8]
		L := math.sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]))
		cross := math.abs(a[0] * b[1] - a[1] * b[0])
		fmt.printfln(
			"  seg{}: chord={:.3f} apothem={:.3f} degenerate={} mass={:.4f}",
			s,
			L,
			cross / L,
			bm.degenerate[s],
			sim.bot.seg_mass[s],
		)
	}

	// Mirror the viewer's cap bookkeeping (build_car_caps at birth,
	// refresh_car_caps at each break tick): cap_flags[s] = the void flags
	// frozen in segment s's registered cap; cap_seen[s] = its flags have
	// been set at least once (s read missing).
	cap_flags := [8][2]bool{}
	cap_seen := [8]bool{}
	for s in 0 ..< 8 {
		if !bm.degenerate[s] {continue}
		cap_flags[s] = [2]bool{bm.degenerate[(s + 7) % 8], bm.degenerate[(s + 1) % 8]}
		cap_seen[s] = true
		fmt.printfln(
			"  birth cap seg{} void_left={} void_right={}",
			s,
			cap_flags[s][0],
			cap_flags[s][1],
		)
	}
	envelope_r := max_r + max_h + f32(1.5)
	prev_nbreaks := 0
	for tick := 1; tick <= ticks; tick += 1 {
		alive := slot_tick(&slot)
		nb := sim.bot.n_breaks
		if nb != prev_nbreaks {
			for i := prev_nbreaks; i < nb; i += 1 {
				ev := sim.break_events[i]
				fmt.printfln(
					"  BREAK tick={} t={:.3f}s seg={} impulse={:.2f} mass={:.4f} ratio={:.0f}",
					tick,
					ev.t,
					ev.seg,
					ev.impulse,
					sim.bot.seg_mass[ev.seg],
					ev.ratio,
				)
			}
			// refresh_car_caps body, minus the mesh registration.
			for s in 0 ..< 8 {
				if !sim.bot.broken[s] && !bm.degenerate[s] {continue}
				vl := sim.bot.broken[(s + 7) % 8] || bm.degenerate[(s + 7) % 8]
				vr := sim.bot.broken[(s + 1) % 8] || bm.degenerate[(s + 1) % 8]
				now := [2]bool{vl, vr}
				if cap_seen[s] && cap_flags[s] == now {continue}
				verb := "cap built"
				if cap_seen[s] {verb = "cap refreshed"}
				fmt.printfln(
					"  {} tick={} seg{} void_left={} void_right={}",
					verb,
					tick,
					s,
					vl,
					vr,
				)
				cap_flags[s] = now
				cap_seen[s] = true
			}
			pb_stale_walls(&slot, cap_flags)
			pb_raytest_now(&g, &slot, cap_flags, ring, bm, envelope_r, "break")
			prev_nbreaks = nb
		}
		if tick == 2 {
			pb_raytest_now(&g, &slot, cap_flags, ring, bm, envelope_r, "intact control")
		}
		if !alive {break}
	}
	pb_stale_walls(&slot, cap_flags)
	pb_raytest_now(&g, &slot, cap_flags, ring, bm, envelope_r, "final")
	cf, _ := b3_pos_quat(sim.bot.chassis)
	fmt.printfln(
		"  outcome: {} breaks={} failed={} x={:.1f}",
		outcome_name(outcome_of(sim)),
		sim.bot.n_breaks,
		sim.failed,
		cf[0],
	)
	destroy_sim(&slot.sim)
	return 0
}
