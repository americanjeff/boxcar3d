#+build wasm32
// Pause-time diagnostic dump to the browser console: on the rising edge of
// sim_paused (the UI pause button or SPACE), print the car on screen - raw
// genome, decoded geometry, live sim state. The runtime's write reaches
// odin_env.write, which the JS glue routes to console.log, so the single
// fmt.println lands in the devtools console.
//
// Read-only by contract: it never touches a world (the hull check builds +
// destroys scratch hulls) and allocates only on the frame's context.
// `SKIPPED` marks a segment whose fan wedge is degenerate (see
// fan_wedge_degenerate): the phenotype builds no hulls and no mesh for it.

package main

import "core:fmt"
import "core:math"
import "core:strings"
import b3 "engine:physics"

// Rising-edge memory, updated every wasm frame (single-threaded).
pause_dump_prev := false

// Called once per wasm frame, at the end of wasm_frame - AFTER
// driver_frame, so a pause toggled this frame by the UI button is caught.
maybe_pause_dump :: proc() {
	paused := sim_paused
	if paused && !pause_dump_prev {
		out := pause_dump_report()
		if len(out) > 0 {
			fmt.println(out)
			delete(out)
		}
	}
	pause_dump_prev = paused
}

// Build the report for the car on screen - the solo's current car
// (view_mode 1) or the pack's lead (view_mode 0). Returns "" when nothing
// is on screen yet. (odin's `+`/`+=` only concatenate constant strings, so
// the report is a line list joined with strings.concatenate - the same
// pattern as rollout_telemetry.)
pause_dump_report :: proc() -> string {
	genes: ^Genes
	sim: ^Sim_State
	env: Env
	view: string
	gen: int
	npop: int
	idx := 0
	if view_mode == 1 {
		if !solo.ready || len(solo.last.pop) == 0 {return ""}
		idx = solo.cur
		if idx < 0 {idx = 0}
		if idx >= len(solo.last.pop) {idx = len(solo.last.pop) - 1}
		genes = &solo.last.pop[idx]
		if solo.active {sim = &solo.car}
		env = solo.last.env
		view = "solo"
		gen = solo.gen
		npop = len(solo.last.pop)
	} else {
		if !pop_viewer.ready {return ""}
		idx = pop_viewer.lead_idx
		if idx < 0 || idx >= pop_viewer.n {idx = 0}
		genes = &pop_viewer.cars[idx].genes
		sim = &pop_viewer.cars[idx].sim
		env = pop_viewer.last.env
		view = "pack"
		gen = pop_viewer.last.index
		npop = pop_viewer.n
	}

	g := decode_genes(genes)
	bm := genome_to_body(&g)

	lines := make([dynamic]string, 0, 80, context.allocator)
	append(
		&lines,
		fmt.aprintf(
			"── boxcar3d pause-dump ── view={} gen={} car={}/{} env_seed=0x{:x} line={:.0f} m\n",
			view,
			gen,
			idx,
			npop,
			env.seed,
			env.line,
		),
	)

	append(&lines, "genome (raw genes):\n")
	for i in 0 ..< N_VERTICES {
		v := genes.vertices[i]
		append(
			&lines,
			fmt.aprintf(
				"  v{} angle={:.4f} rad ({:6.2f} deg) mag={:.3f}\n",
				i,
				v.angle,
				v.angle * 180.0 / math.PI,
				v.magnitude,
			),
		)
	}
	for i in 0 ..< N_WHEELS {
		w := genes.wheels[i]
		if w.vertex < 0 {
			append(
				&lines,
				fmt.aprintf(
					"  w{} DISABLED (axle={:.3f} rad r={:.3f} d={:.2f})\n",
					i,
					w.axle_angle,
					w.radius,
					w.density,
				),
			)
		} else {
			append(
				&lines,
				fmt.aprintf(
					"  w{} vertex={} axle={:.3f} rad r={:.3f} d={:.2f}\n",
					i,
					w.vertex,
					w.axle_angle,
					w.radius,
					w.density,
				),
			)
		}
	}
	{
		wparts := make([dynamic]string, N_WIDTHS + 2, context.allocator)
		wparts[0] = "  widths (8 vertex + center):"
		for i in 0 ..< N_WIDTHS {
			wparts[i + 1] = fmt.aprintf(" {:.3f}", genes.widths[i])
		}
		wparts[N_WIDTHS + 1] = "\n"
		append(&lines, strings.concatenate(wparts[:]))
	}
	append(&lines, fmt.aprintf("  chassis_density={:.3f}\n", genes.chassis_density))
	{
		same := true
		for s in 1 ..< N_COLORS {
			if genes.colors[s] != genes.colors[0] {
				same = false
				break
			}
		}
		if same {
			c := genes.colors[0]
			append(&lines, fmt.aprintf("  colors: ({},{},{}) x16\n", c[0], c[1], c[2]))
		} else {
			cparts := make([dynamic]string, N_COLORS + 2, context.allocator)
			cparts[0] = "  colors:"
			for s in 0 ..< N_COLORS {
				c := genes.colors[s]
				cparts[s + 1] = fmt.aprintf(" [{},{},{}]", c[0], c[1], c[2])
			}
			cparts[N_COLORS + 1] = "\n"
			append(&lines, strings.concatenate(cparts[:]))
		}
	}

	order := [N_VERTICES]int{}
	for i in 0 ..< N_VERTICES {order[i] = i}
	for i in 1 ..< N_VERTICES { 	// insertion sort by decoded angle (stable for ties)
		// Save the key FIRST - the shifts below overwrite order[i].
		key := order[i]
		a := g.vertices[key].angle
		j := i - 1
		for ; j >= 0; j -= 1 {
			if g.vertices[order[j]].angle <= a {break}
			order[j + 1] = order[j]
		}
		order[j + 1] = key
	}
	{
		rparts := make([dynamic]string, 0, 17, context.allocator)
		append(&rparts, "decoded ring (genome idx):")
		for k in 0 ..< N_VERTICES {
			if k > 0 {append(&rparts, " -> ")}
			append(&rparts, fmt.aprintf("v{}", order[k]))
		}
		append(&rparts, " -> (wrap)\n")
		append(&lines, strings.concatenate(rparts[:]))
	}
	for k in 0 ..< N_VERTICES {
		i := order[k]
		j := order[(k + 1) % N_VERTICES]
		pi := genome_vertex_pos(&g, i)
		pj := genome_vertex_pos(&g, j)
		dx := pi[0] - pj[0]
		dy := pi[1] - pj[1]
		L := math.sqrt(dx * dx + dy * dy)
		cross := math.abs(f64(pi[0]) * f64(pj[1]) - f64(pi[1]) * f64(pj[0]))
		apo := f32(0.0)
		if L > 0.0 {apo = f32(cross / f64(L))}
		flag := ""
		if bm.degenerate[k] {
			flag = "   << SKIPPED (degenerate wedge: no hulls, no mesh)"
		} else if bm.degenerate[k] != fan_wedge_degenerate(pi, pj) {
			// Should never happen - the dump and the phenotype disagree.
			flag = "   << MISMATCH (dump/sim fan-skip differ!)"
		}
		append(
			&lines,
			fmt.aprintf(
				"  edge v{}->v{}: ({:+.2f},{:+.2f})->({:+.2f},{:+.2f}) L={:.3f} apothem={:.3f}{}\n",
				i,
				j,
				pi[0],
				pi[1],
				pj[0],
				pj[1],
				L,
				apo,
				flag,
			),
		)
	}

	append(&lines, "hulls (b3CreateHull on each segment's 4 tetrahedra):\n")
	for k in 0 ..< N_VERTICES {
		i := order[k]
		j := order[(k + 1) % N_VERTICES]
		n_null := 0
		min_vol := f64(1e18)
		for s in 0 ..< 4 {
			t := bm.tris[4 * k + s]
			pts := [4][3]f32{{0.0, 0.0, 0.0}, t.points[0], t.points[1], t.points[2]}
			hull := b3.Create_Hull(pts[:], 4)
			if b3.Hull_Base(hull) == nil {
				n_null += 1
			} else {
				b3.Destroy_Hull(hull)
			}
			a := t.points[0]
			b := t.points[1]
			c := t.points[2]
			cx := f64(b[1]) * f64(c[2]) - f64(b[2]) * f64(c[1])
			cy := f64(b[2]) * f64(c[0]) - f64(b[0]) * f64(c[2])
			cz := f64(b[0]) * f64(c[1]) - f64(b[1]) * f64(c[0])
			vol := math.abs(f64(a[0]) * cx + f64(a[1]) * cy + f64(a[2]) * cz) / 6.0
			if vol < min_vol {min_vol = vol}
		}
		mark := ""
		switch {
		case bm.degenerate[k] && n_null > 0:
			mark = "   << SKIPPED in sim + NULL HULL here"
		case bm.degenerate[k]:
			mark = "   << SKIPPED in sim (legal hulls, just no contact)"
		case n_null > 0:
			mark = "   << NULL HULL"
		}
		append(
			&lines,
			fmt.aprintf(
				"  seg {} (v{}->v{}): null={} min_tet_vol={:.3e}{}\n",
				k,
				i,
				j,
				n_null,
				min_vol,
				mark,
			),
		)
	}

	if sim != nil {
		cp := b3.Body_GetPosition(sim.bot.chassis)
		cr := b3.Body_GetRotation(sim.bot.chassis)
		lv := b3.Body_GetLinearVelocity(sim.bot.chassis)
		append(
			&lines,
			fmt.aprintf(
				"live sim: pos=({:.2f},{:.2f},{:.2f}) quat=({:.3f},{:.3f},{:.3f},{:.3f}) vel=({:.2f},{:.2f},{:.2f}) t={:.2f} s\n",
				cp[0],
				cp[1],
				cp[2],
				cr[0],
				cr[1],
				cr[2],
				cr[3],
				lv[0],
				lv[1],
				lv[2],
				sim.sim_time,
			),
		)
		{
			bparts := make([dynamic]string, 0, 10, context.allocator)
			append(&bparts, fmt.aprintf("  breaks={} (max {}):", sim.bot.n_breaks, MAX_BREAKS))
			for s in 0 ..< N_VERTICES {
				if sim.bot.broken[s] {append(&bparts, fmt.aprintf(" seg{}", s))}
			}
			append(&bparts, "\n  seg_mass: ")
			for s in 0 ..< N_VERTICES {
				append(&bparts, fmt.aprintf("{:.3f} ", sim.bot.seg_mass[s]))
			}
			append(&bparts, "\n")
			append(&lines, strings.concatenate(bparts[:]))
		}
		for i in 0 ..< len(sim.bot.wheels) {
			w := sim.bot.wheels[i]
			wp := b3.Body_GetPosition(w.wheel_l)
			append(
				&lines,
				fmt.aprintf(
					"  wheel{}: mount_v={} r={:.3f} d={:.2f} world=({:.2f},{:.2f},{:.2f})\n",
					i,
					w.mount_vertex,
					w.radius,
					w.density,
					wp[0],
					wp[1],
					wp[2],
				),
			)
		}
	}
	destroy_body_model(&bm)
	destroy_genome(&g)
	return strings.concatenate(lines[:])
}
