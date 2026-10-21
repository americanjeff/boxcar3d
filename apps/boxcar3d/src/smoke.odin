#+build !wasm32
// Headless smoke-test battery (validates the body/sensors with no GUI):
// 16 suites (see run_smoke). Run with `boxcar3d smoke`.

package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import b3 "engine:physics"

// Build the car from the genome, step for a couple of seconds, and check it
// didn't explode: the chassis stays finite and both wheels stay attached
// (finite, near the chassis).
smoke_settle :: proc() -> bool {
	sim := spawn_fixed_sim(S_SPAWN_X, 0.0)
	defer destroy_sim(&sim)

	if len(sim.bot.wheels) != 2 {
		fmt.eprintfln("smoke: expected 2 wheel pairs, got {}", len(sim.bot.wheels))
		return false
	}

	for _ in 0 ..< 120 {
		b3.World_Step(sim.world, TIME_STEP, SUB_STEPS)
		sim.sim_time += TIME_STEP
	}

	cp := b3.Body_GetPosition(sim.bot.chassis)
	if !is_finite3(cp) {
		fmt.eprintfln("smoke: chassis NaN after settle: {}", cp)
		return false
	}

	for w, i in sim.bot.wheels {
		pair := [2]b3.BodyId{w.wheel_l, w.wheel_r}
		for wheel in pair {
			wp := b3.Body_GetPosition(wheel)
			if !is_finite3(wp) {
				fmt.eprintfln("smoke: wheel {} NaN after settle", i)
				return false
			}
			dx := wp[0] - cp[0]
			dy := wp[1] - cp[1]
			dz := wp[2] - cp[2]
			d := math.sqrt(dx * dx + dy * dy + dz * dz)
			if d > 3.0 {
				fmt.eprintfln("smoke: wheel {} detached (dist {:.2f})", i, d)
				return false
			}
		}
	}

	fmt.printfln("smoke settle: OK (mass {:.2f} kg, wheels attached)", sim.bot.mass)
	return true
}

// Spin both wheels forward for a few seconds and check the car moves at
// least 0.2 m along +x - the spin motors are wired up.
smoke_scripted :: proc() -> bool {
	sim := spawn_fixed_sim(S_SPAWN_X, 0.0)
	defer destroy_sim(&sim)

	for w in sim.bot.wheels {
		set_wheel_spin_speed(w.joint_l, -SPIN_SPEED)
		set_wheel_spin_speed(w.joint_r, -SPIN_SPEED)
	}
	for _ in 0 ..< 180 {
		b3.World_Step(sim.world, TIME_STEP, SUB_STEPS);sim.sim_time += TIME_STEP
	}

	cp := b3.Body_GetPosition(sim.bot.chassis)
	if !is_finite3(cp) {
		fmt.eprintfln("smoke: chassis NaN under drive")
		return false
	}
	if cp[0] < S_SPAWN_X + 0.2 {
		fmt.eprintfln("smoke: car did not move forward under spin (x={:.2f})", cp[0])
		return false
	}
	fmt.printfln("smoke scripted: OK (drove +x to {:.2f} m)", cp[0])
	return true
}

// Terrain profile: same seed → byte-identical
// profile, different seed → different profile, a sweep of seeds stays inside
// the heightfield quantization range, seed 0 is a no-op, and the spawn
// approach (x < 0) is flat.
smoke_terrain :: proc() -> bool {
	capture :: proc() -> [TERRAIN_COLS]f32 {
		return env_profile
	}
	regenerate_terrain(0x1)
	a := capture()
	regenerate_terrain(0x1)
	b := capture()
	if a != b {
		fmt.eprintfln("smoke: terrain profile not deterministic for a fixed seed")
		return false
	}
	regenerate_terrain(0x2)
	c := capture()
	if c == a {
		fmt.eprintfln("smoke: terrain profile identical across different seeds")
		return false
	}
	for seed in u64(0x10) ..< u64(0x20) {
		regenerate_terrain(seed)
		// No compression: the raw profile span must fit the quantization
		// range (±400 m): compression would flatten the difficulty ramp
		// and quietly undo it.
		if env_fit_scale < 1.0 - 1e-6 {
			fmt.eprintfln(
				"smoke: terrain span {:.0f} m compressed (scale {:.3f} < 1) - widen TERRAIN_MIN_H/MAX_H (seed 0x{:x})",
				env_span_raw,
				env_fit_scale,
				seed,
			)
			return false
		}
		for h in env_profile[:] {
			if h < TERRAIN_MIN_H - 1e-4 || h > TERRAIN_MAX_H + 1e-4 {
				fmt.eprintfln(
					"smoke: terrain height {:.3f} outside [{}, {}] (seed 0x{:x})",
					h,
					TERRAIN_MIN_H,
					TERRAIN_MAX_H,
					seed,
				)
				return false
			}
		}
	}
	// seed 0 is a no-op ("no change").
	regenerate_terrain(0x3)
	snap := capture()
	regenerate_terrain(0)
	if capture() != snap {
		fmt.eprintfln("smoke: regenerate_terrain(0) modified the profile")
		return false
	}
	// The spawn approach (x < 0) must be flat (constant; the range fit may
	// translate the whole profile off zero).
	regenerate_terrain(0x1)
	base := terrain_centerline(TERRAIN_X0)
	for j in 0 ..< TERRAIN_COLS {
		x := TERRAIN_X0 + TERRAIN_CELL * f32(j)
		if x >= 0.0 {break}
		if math.abs(terrain_centerline(x) - base) > 1e-4 {
			fmt.eprintfln("smoke: spawn approach not flat at x={:.1f}", x)
			return false
		}
	}
	// The far-end ramp must keep its difficulty: the max forward slope over
	// the last 10% of the centerline (post-fit) must approach the design
	// maximum 1.0·MAX_TILE_TILT = 1.5 rad (86°) across seeds (the per-column
	// tilt is U(−1,1)·MAX·ramp - symmetric, so the far end has near-max
	// uphill AND near-max downhill). If MAX or the ramp were changed, the
	// terrain would go flat at the far end, or a range-fit compression
	// would flatten it - this catches both.
	worst := f32(0.0)
	for seed in u64(0x10) ..< u64(0x20) {
		regenerate_terrain(seed)
		start := TERRAIN_COLS * 9 / 10
		for j in (start + 1) ..< TERRAIN_COLS {
			slope := math.atan2(env_profile[j] - env_profile[j - 1], TERRAIN_CELL)
			if slope > worst {worst = slope}
		}
	}
	if worst < 0.95 {
		fmt.eprintfln(
			"smoke: far-end ramp flattened to {:.2f} rad (< 0.95) - terrain change or range fit compressing?",
			worst,
		)
		return false
	}
	return true
}

// Genome store round-trip: every gene (vertices, wheel axle/radius/DENSITY,
// chassis density, width profile) must survive save_genome → load_genome
// exactly - a gene that reverts to its zero value on reload would silently
// make the reloaded car a different car.
smoke_store_roundtrip :: proc() -> bool {
	path := "/tmp/boxcar3d_store_roundtrip.genome"
	g := Genes{}
	g.chassis_density = f32(9.125)
	for i in 0 ..< N_VERTICES {
		g.vertices[i].angle = f32(0.1 * f32(i + 1))
		g.vertices[i].magnitude = f32(0.3 * f32(i + 2))
	}
	for i in 0 ..< N_WHEELS {
		g.wheels[i].vertex = i % N_VERTICES
		g.wheels[i].axle_angle = f32(0.5 * f32(i + 1))
		g.wheels[i].radius = f32(0.2 * f32(i + 1))
		g.wheels[i].density = f32(1.0 + 0.25 * f32(i))
	}
	g.wheels[N_WHEELS - 1].vertex = -1 // disabled slot; must round-trip as -1
	for i in 0 ..< N_WIDTHS {
		g.widths[i] = 0.1 + 0.05 * f32(i)
	}
	// Palette distinct per slot so a mis-indexed C line is caught.
	for i in 0 ..< N_COLORS {
		g.colors[i] = [3]u8{u8(i * 16), u8(255 - i * 15), u8(i * 3)}
	}
	meta := Genome_Meta {
		gen      = 7,
		fitness  = 2.5,
		n_wheels = N_WHEELS,
	}
	if !save_genome(path, &g, meta) {return false}
	defer os.remove(path)
	lg, lm, ok := load_genome(path)
	if !ok {return false}
	if lm.gen != meta.gen ||
	   lm.n_wheels != meta.n_wheels ||
	   lm.fitness != meta.fitness {return false}
	if lg.chassis_density != g.chassis_density {return false}
	for i in 0 ..< N_VERTICES {
		if lg.vertices[i].angle != g.vertices[i].angle ||
		   lg.vertices[i].magnitude != g.vertices[i].magnitude {return false}
	}
	for i in 0 ..< N_WHEELS {
		w := &lg.wheels[i]
		if w.vertex != g.wheels[i].vertex ||
		   w.axle_angle != g.wheels[i].axle_angle ||
		   w.radius != g.wheels[i].radius ||
		   w.density != f32(1.0 + 0.25 * f32(i)) {return false}
	}
	for i in 0 ..< N_WIDTHS {
		if lg.widths[i] != g.widths[i] {return false}
	}
	// The palette must survive bitwise (a mis-indexed C line would swap
	// two part colours).
	for i in 0 ..< N_COLORS {
		if lg.colors[i] != g.colors[i] {
			fmt.eprintfln("smoke: store round-trip colour slot {} mismatch", i)
			return false
		}
	}
	return true
}

// The inherited 16-slot part palette: init, crossover inheritance,
// mutation re-roll, and the v3 store fallback. Deterministic throughout.
smoke_colors :: proc() -> bool {
	// Init: one random RGB fills all 16 slots.
	r := rng_init(0xc010a)
	g := random_genes(&r)
	for s in 1 ..< N_COLORS {
		if g.colors[s] != g.colors[0] {
			fmt.eprintfln("smoke: init palette slot {} != slot 0", s)
			return false
		}
	}

	// Inheritance: distinct per-slot palettes on both parents; each
	// slot follows the donor of its group's FIRST gene (vertex k → 2k,
	// wheel j → 16+3j) under every cut placement.
	W := N_VERTICES * 2 + 3 * max_axles
	ma := Genes{}
	mb := Genes{}
	for k in 0 ..< N_COLORS {
		ma.colors[k] = [3]u8{u8(k * 16), 0, u8(255 - k * 16)}
		mb.colors[k] = [3]u8{0, u8(k * 15), 128}
	}
	cases := [][2]int{{0, W - 1}, {0, 0}, {17, 17}, {15, 16}, {8, 20}}
	for ci in 0 ..< len(cases) {
		c0, c1 := crossover_two_cuts(&ma, &mb, cases[ci][0], cases[ci][1])
		// Each slot must follow the donor of its group's first gene.
		for k in 0 ..< N_VERTICES {
			gi := 2 * k
			from_b := cases[ci][0] <= gi && gi <= cases[ci][1]
			e0 := from_b ? mb.colors[k] : ma.colors[k]
			e1 := from_b ? ma.colors[k] : mb.colors[k]
			if c0.colors[k] != e0 || c1.colors[k] != e1 {
				fmt.eprintfln(
					"smoke: donor vertex slot {} (gene {}) cut ({},{})",
					k,
					gi,
					cases[ci][0],
					cases[ci][1],
				)
				return false
			}
		}
		for j in 0 ..< N_WHEELS {
			gi := N_VERTICES * 2 + 3 * j
			from_b := cases[ci][0] <= gi && gi <= cases[ci][1]
			e0 := from_b ? mb.colors[8 + j] : ma.colors[8 + j]
			e1 := from_b ? ma.colors[8 + j] : mb.colors[8 + j]
			if c0.colors[8 + j] != e0 || c1.colors[8 + j] != e1 {
				fmt.eprintfln(
					"smoke: donor wheel slot {} (gene {}) cut ({},{})",
					8 + j,
					gi,
					cases[ci][0],
					cases[ci][1],
				)
				return false
			}
		}
	}

	// Mutation re-roll:
	// (a) rate 0 - no gene, no colour moves.
	ra := rng_init(0xd5)
	ga := random_genes(&ra)
	ga0 := ga
	mutate(&ra, &ga, 0.0, 0.01)
	if ga != ga0 {
		fmt.eprintfln("smoke: rate-0 mutation changed the genome")
		return false
	}
	// (b) rate 1 - every slot re-rolls; a shadow genome with a sentinel
	// palette on the SAME seed must land on identical RGBs (the re-rolls
	// are pure RNG draws, independent of the prior paint).
	rb := rng_init(0x5eed)
	xb := random_genes(&rb)
	yc := xb
	for s in 0 ..< N_COLORS {yc.colors[s] = [3]u8{}}
	rb2 := rng_init(0x5eed)
	rb3 := rng_init(0x5eed)
	// Note: xb's shape draws came from rb; reseed the two mutate calls
	// from the SAME state so their coin/gauss/re-roll streams match.
	mutate(&rb2, &xb, 1.0, 0.01)
	mutate(&rb3, &yc, 1.0, 0.01)
	for s in 0 ..< N_COLORS {
		if xb.colors[s] != yc.colors[s] {
			fmt.eprintfln("smoke: rate-1 re-roll slot {} not pure RNG", s)
			return false
		}
	}
	// (c) mapping table - every flat gene index maps to exactly the
	// slots the spec assigns (vertices gi/2; wheel triples + wheel
	// densities → 8+wheel; chassis 40 + center width 57 → all 8 triangle
	// slots; widths 49-56 → gi-49).
	for gi in 0 ..< GENE_DIM {
		got := gene_color_slots(gi)
		want := [N_COLORS]bool{}
		switch {
		case gi < 16:
			want[gi / 2] = true
		case gi < 40:
			want[8 + (gi - 16) / 3] = true
		case gi == 40:
			for k in 0 ..< N_VERTICES {want[k] = true}
		case gi < 49:
			want[8 + (gi - 41)] = true
		case gi < 57:
			want[gi - 49] = true
		case:
			for k in 0 ..< N_VERTICES {want[k] = true}
		}
		if got != want {
			fmt.eprintfln("smoke: mapping for gene {} mismatches the spec", gi)
			return false
		}
	}

	// Store: a v3 file (no C lines) loads with all 16 slots filled
	// from the legacy hash-derived colour.
	g3 := Genes{}
	g3.chassis_density = f32(2.5)
	for i in 0 ..< N_VERTICES {
		g3.vertices[i].angle = f32(0.3 * f32(i))
		g3.vertices[i].magnitude = f32(0.5 + 0.1 * f32(i))
	}
	for i in 0 ..< N_WHEELS {
		g3.wheels[i].vertex = i % 4
		g3.wheels[i].axle_angle = f32(1.0)
		g3.wheels[i].radius = f32(0.3)
		g3.wheels[i].density = f32(800.0)
	}
	for i in 0 ..< N_WIDTHS {g3.widths[i] = f32(0.4)}
	meta := Genome_Meta {
		gen      = 3,
		fitness  = 1.0,
		n_wheels = N_WHEELS,
	}
	v4_path := "/tmp/boxcar3d_v3_fixture_v4.genome"
	v3_path := "/tmp/boxcar3d_v3_fixture.genome"
	if !save_genome(v4_path, &g3, meta) {return false}
	defer os.remove(v4_path)
	defer os.remove(v3_path)
	raw, rerr := os.read_entire_file_from_path(v4_path, context.allocator)
	if rerr != nil {return false}
	v4s := string(raw)
	// v4s is a ZERO-COPY alias of raw's bytes - consume it, then free raw
	// once (never free the alias separately).
	v3lines := make([dynamic]string, 0, 10)
	for line in strings.split(v4s, "\n") {
		if strings.has_prefix(line, "boxcar3d genome v4") {
			append(&v3lines, "boxcar3d genome v3\n")
			continue
		}
		if strings.has_prefix(line, "C ") {continue}
		append(&v3lines, line)
		if len(line) > 0 {append(&v3lines, "\n")}
	}
	v3s := strings.concatenate(v3lines[:])
	delete(v3lines)
	delete(raw)
	if os.write_entire_file_from_string(v3_path, v3s) != nil {return false}
	delete(v3s)
	lg3, _, ok3 := load_genome(v3_path)
	if !ok3 {
		fmt.eprintfln("smoke: v3 fixture failed to load")
		return false
	}
	ec := waypoint_color(int(genes_hash(&g3) % 10), 10, false, false)
	for s in 0 ..< N_COLORS {
		want := [3]u8{u8(int(ec[0] * 255.0)), u8(int(ec[1] * 255.0)), u8(int(ec[2] * 255.0))}
		if lg3.colors[s] != want {
			fmt.eprintfln("smoke: v3 fallback slot {} != hash colour", s)
			return false
		}
	}
	fmt.printfln("smoke colors: OK (init, inheritance, re-roll, v3 fallback)")
	return true
}

// A parked, undriven car must be stalled out at ~NO_MOVE_TIME (the liveness
// gate's stillness window - no movement in any direction for the whole
// window; it fires before the slower NO_PROGRESS_TIME no-progress window, so
// it wins here): it fails, it is flagged stalled, and it fires on schedule.
smoke_stall :: proc() -> bool {
	sim := spawn_fixed_sim(S_SPAWN_X, 0.0)
	defer destroy_sim(&sim)
	for sim.sim_time < NO_MOVE_TIME + 2.0 && !sim.failed {
		step_sim(&sim)
	}
	if !sim.failed || !sim.stalled {
		fmt.eprintfln(
			"smoke: parked car not stalled out (failed={}, stalled={}, t={:.1f})",
			sim.failed,
			sim.stalled,
			sim.sim_time,
		)
		return false
	}
	if sim.sim_time < NO_MOVE_TIME || sim.sim_time > NO_MOVE_TIME + 1.0 {
		fmt.eprintfln(
			"smoke: no-move window fired at t={:.2f}, expected ~{:.1f}",
			sim.sim_time,
			NO_MOVE_TIME,
		)
		return false
	}
	return true
}

// Step the car a few ticks and check the 28-sensor vector (N_SENSORS) is
// finite.
smoke_sensors :: proc() -> bool {
	sim := spawn_fixed_sim(S_SPAWN_X, 0.0)
	defer destroy_sim(&sim)

	s_buf := [N_SENSORS]f32{}
	for _ in 0 ..< 10 {
		sensors(&sim, s_buf[:])
		pid_drive_car(&sim, PID_COEFF)
		step_sim(&sim)
	}
	for i in 0 ..< N_SENSORS {
		if !is_finite(s_buf[i]) {
			fmt.eprintfln("smoke: sensor {} non-finite", i)
			return false
		}
	}
	fmt.printfln("smoke sensors: OK ({} sensors, all finite)", N_SENSORS)
	return true
}

// The invariants a chassis must hold after any number of breaks: n_breaks
// never exceeds MAX_BREAKS, the broken mask agrees with it (each break sheds
// exactly one new segment), ≥1 segment survives, the rebuilt chassis has
// positive mass and a finite pose, and the run failed once the cap was hit.
break_invariants_ok :: proc(sim: ^Sim_State) -> bool {
	bot := &sim.bot
	survivors := 0
	for i in 0 ..< 8 {
		if !bot.broken[i] {survivors += 1}
	}
	if survivors != 8 - bot.n_breaks {
		fmt.eprintfln(
			"smoke breaks: mask/count drift (survivors={} n_breaks={})",
			survivors,
			bot.n_breaks,
		)
		return false
	}
	if bot.n_breaks > MAX_BREAKS {
		fmt.eprintfln("smoke breaks: cap overrun ({} breaks > {} max)", bot.n_breaks, MAX_BREAKS)
		return false
	}
	if survivors < 1 || bot.mass <= 0 {
		fmt.eprintfln(
			"smoke breaks: no drawable chassis (survivors={} mass={:.3f})",
			survivors,
			bot.mass,
		)
		return false
	}
	cp := b3.Body_GetPosition(bot.chassis)
	if !is_finite3(cp) {
		fmt.eprintfln("smoke breaks: chassis NaN after the rebuild")
		return false
	}
	if bot.n_breaks >= MAX_BREAKS && !sim.failed {
		fmt.eprintfln("smoke breaks: cap hit without a failed run")
		return false
	}
	return true
}

// Break e2e gate: a belly-down 15 m/s kick (impact ~17 m/s) must shed at
// least one segment, the rebuilt chassis must stay finite, and the run
// must end (no hang) - the rebuild is the risky part. Second scenario: a
// tumbling car at K=1 sheds several segments in single frames - the
// per-frame batch must be capped at the remaining budget so n_breaks stops
// at exactly MAX_BREAKS (≥1 segment surviving: a massful body, a drawable
// mesh).
smoke_breaks :: proc() -> bool {
	// K=1 (the cap part below overrides K the same way): at the production
	// K=50 the 15 m/s drop's break margin is a knife-edge each retune flips.
	// K=1 makes the first landing (several N·s on the lightest segments'
	// 0.12 kg) the reliable trigger.
	save_k := BREAK_K
	BREAK_K = f32(1.0)
	sim := spawn_fixed_sim(S_SPAWN_X, math.PI)
	defer destroy_sim(&sim)
	v := f32(15.0)
	b3.Body_SetLinearVelocity(sim.bot.chassis, 0.0, -v, 0.0)
	for w in sim.bot.wheels {
		b3.Body_SetLinearVelocity(w.wheel_l, 0.0, -v, 0.0)
		b3.Body_SetLinearVelocity(w.wheel_r, 0.0, -v, 0.0)
	}
	for _ in 0 ..< 10 * 60 {
		pid_drive_car(&sim, PID_COEFF)
		step_sim(&sim)
		if sim.failed {break}
	}
	BREAK_K = save_k
	if sim.bot.n_breaks == 0 {
		fmt.eprintfln("smoke breaks: a {:.0f} m/s belly impact shed no segment", v)
		return false
	}
	if !break_invariants_ok(&sim) {
		return false
	}
	fmt.printfln(
		"smoke breaks: OK ({} segment(s) shed on a {:.0f} m/s impact, run ends cleanly)",
		sim.bot.n_breaks,
		v,
	)

	// Cap-overshoot: pre-wreck the car to 6 breaks via the production shed
	// path, leaving segments 4+5 - the bottom sector, which the spawn drop
	// hits in one frame. That batch would run 6→8; the per-frame budget
	// must cap it at 1, so the 7th break ends the run with exactly one
	// segment still on.
	old_k := BREAK_K
	old_rest := chassis_restitution
	BREAK_K = 1.0
	chassis_restitution = 0.6
	sim2 := spawn_fixed_sim(S_SPAWN_X, math.PI)
	defer destroy_sim(&sim2)
	cb := &sim2.bot
	lost := [6]int{0, 1, 2, 3, 6, 7}
	apply_breaks(sim2.world, &sim2.body_model, cb, lost[:])
	cb.n_breaks = 6
	b3.Body_SetLinearVelocity(cb.chassis, 10.0, -40.0, 0.0)
	for w in cb.wheels {
		b3.Body_SetLinearVelocity(w.wheel_l, 10.0, -40.0, 0.0)
		b3.Body_SetLinearVelocity(w.wheel_r, 10.0, -40.0, 0.0)
	}
	for _ in 0 ..< 30 * 60 {
		pid_drive_car(&sim2, PID_COEFF)
		step_sim(&sim2)
		if sim2.failed || sim2.finished {break}
	}
	BREAK_K = old_k
	chassis_restitution = old_rest
	if !break_invariants_ok(&sim2) {
		return false
	}
	if cb.n_breaks != MAX_BREAKS {
		fmt.eprintfln(
			"smoke breaks: cap scenario must end at the cap ({} breaks, want {})",
			cb.n_breaks,
			MAX_BREAKS,
		)
		return false
	}
	fmt.printfln(
		"smoke breaks: cap OK (pre-wrecked car's 2-segment batch capped: {} breaks, 1 segment still on)",
		cb.n_breaks,
	)
	return true
}

// Pins the strict extension rule (pure, no physics): the line moves only
// when the record has REACHED it - then it doubles, capped at the terrain
// reach. Also pins the (seed, line) model: set_line moves env.line with
// no version machinery, and profile_for materializes once per seed (a
// key hit never re-rolls - the profile is a pure function of its seed).
smoke_track_len :: proc() -> bool {
	// Fingerprint of the profile cache (proves a repeated profile_for is a
	// key hit: no re-roll).
	fingerprint :: proc() -> f64 {
		h := f64(0)
		for i in 0 ..< TERRAIN_COLS {
			h = h * 131.0 + f64(env_profile[i])
		}
		return h
	}
	ok := true
	// 1. Record below the line: the line holds (no creep).
	e := Env {
		seed = u64(0),
		line = f32(1200.0),
	}
	if adapt_track_len(1199.99, e) != 1200.0 {
		fmt.eprintfln("smoke: line crept below the record ({:g}m)", adapt_track_len(1199.99, e))
		ok = false
	}
	// 2. Record at the line: doubles.
	if adapt_track_len(1200.0, e) != 2400.0 {
		fmt.eprintfln(
			"smoke: line did not double at the record ({:g}m)",
			adapt_track_len(1200.0, e),
		)
		ok = false
	}
	// 3. Doubling past the cap: clamped to the reach.
	e2 := Env{seed = u64(0), line = f32(1700.0)}
	if adapt_track_len(1700.0, e2) != 3200.0 {
		fmt.eprintfln(
			"smoke: line not capped at the reach ({:g}m)",
			adapt_track_len(1700.0, e2),
		)
		ok = false
	}
	// 4. Record above the line, doubling below a larger cap: exactly 2×.
	env_max_len = 4000.0
	if adapt_track_len(1300.0, e) != 2600.0 {
		fmt.eprintfln("smoke: 2× extension wrong ({:g}m)", adapt_track_len(1300.0, e))
		ok = false
	}
	env_max_len = 3200.0
	// 5. set_line: a same-value set changes nothing, a different value
	//    changes env.line (no version machinery to check).
	save_line := env.line
	save_env_seed := env.seed
	save_seed := env_profile_seed
	save_valid := env_profile_valid
	save_prof := env_profile
	env.line = f32(1200.0)
	set_line(1200.0)
	if env.line != f32(1200.0) {
		fmt.eprintfln("smoke: set_line left line unchanged (line={:g}m)", env.line)
		ok = false
	}
	set_line(1300.0)
	if env.line != f32(1300.0) {
		fmt.eprintfln("smoke: set_line did not move the line (line={:g}m)", env.line)
		ok = false
	}
	set_line(1200.0) // restore
	// 6. profile_for materializes once per seed: a second call with the same
	//    seed is a key hit - no re-roll (fingerprint + cache key untouched).
	regenerate_terrain(0xf1)
	f0 := fingerprint()
	profile_for(0xf1)
	if fingerprint() != f0 || env_profile_seed != 0xf1 || !env_profile_valid {
		fmt.eprintfln("smoke: profile_for re-rolled on a key hit (seed 0xf1)")
		ok = false
	}
	env.line = save_line
	env.seed = save_env_seed
	env_profile_seed = save_seed
	env_profile = save_prof
	env_profile_valid = save_valid
	if !ok {
		fmt.eprintfln("smoke track_len: FAILED")
		return false
	}
	fmt.printfln("smoke track_len: OK (strict extension rule + (seed, line) gate)")
	return true
}

// No ground exists past the finish line (the heightfield is truncated at
// the line, like the mesh): a car spawned past the line must FALL - not
// drive on invisible terrain - and the drop check must retire it, well
// before the stall window could.
smoke_track_end :: proc() -> bool {
	env.line = TARGET_START_LEN
	x_end := S_SPAWN_X + env.line + 10.0
	sim := spawn_fixed_sim(x_end, 0.0)
	defer destroy_sim(&sim)

	y0 := b3.Body_GetPosition(sim.bot.chassis)[1]
	for _ in 0 ..< 60 {step_sim(&sim)}
	cp := b3.Body_GetPosition(sim.bot.chassis)
	drop := y0 - cp[1]
	if drop <= 1.0 {
		fmt.eprintfln(
			"smoke: car past the line did not fall (drop {:.2f} m - invisible ground?)",
			drop,
		)
		return false
	}
	for sim.sim_time < NO_GROUND_TIME + 2.0 && !sim.failed {
		step_sim(&sim)
	}
	if !sim.failed || sim.stalled {
		fmt.eprintfln(
			"smoke: car past the line not retired by the liveness gate (failed={}, stalled={}, t={:.2f})",
			sim.failed,
			sim.stalled,
			sim.sim_time,
		)
		return false
	}
	fmt.printfln(
		"smoke track_end: OK (fell {:.1f} m in 1 s, dropped out at t={:.2f})",
		drop,
		sim.sim_time,
	)
	return true
}

// The solo ends a car's run the moment it reaches the finish line
// (solo_step tears the world down on finished), and the GA rollout stops
// ticking at the same instant (slot_tick returns false on finished). The
// pack must treat finished the same way: the car stops being driven and
// freezes at the line, instead of being driven off the truncated
// heightfield's edge to fall into the void until the no-ground window
// fails it ~3 s later. A pack is over once every
// car is stopped (finished or failed), and a stopped car is out of the
// lead race.
smoke_pack_line :: proc() -> bool {
	genome := fixed_genome()
	defer destroy_genome(&genome)
	genes := encode_genome(&genome)
	// A short line the known-good car clears in a few sim seconds; two
	// cars so the all-stopped pack-end condition spans the whole pack.
	snap := Generation {
		index = 0,
		env = Env{seed = env.seed, line = 20.0},
		pop = make([]Genes, 2, context.allocator),
	}
	defer free_generation_copy(&snap)
	snap.pop[0] = genes
	snap.pop[1] = genes
	pop_viewer_build(&snap)

	race_over := false
	for _ in 0 ..< 3600 {
		if !pop_viewer_step(1.0 / 60.0) {
			race_over = true
			break
		}
	}
	if !race_over {
		fmt.eprintfln("smoke pack_line: pack did not end within the budget")
		pop_viewer_destroy()
		return false
	}
	for i in 0 ..< pop_viewer.n {
		car := &pop_viewer.cars[i]
		if !car.sim.finished || car.sim.failed {
			p := b3.Body_GetPosition(car.sim.bot.chassis)
			fmt.eprintfln(
				"smoke pack_line: car {} did not finish the line (finished={} failed={} x={:.2f})",
				i,
				car.sim.finished,
				car.sim.failed,
				p[0],
			)
			pop_viewer_destroy()
			return false
		}
		// A finisher scored exactly the line (its ratchet crossed it).
		if fit := rollout_score_m(car.sim.stall_best_x, car.sim.track_end);
		   fit != f64(car.sim.track_end) {
			fmt.eprintfln("smoke pack_line: car {} score not capped at the line ({})", i, fit)
			pop_viewer_destroy()
			return false
		}
	}
	// A finished car freezes at the line: step the (over) pack some more and
	// every car's world must not advance - no drive, no step, no fall off the
	// edge.
	pos_at_end := [VIEWER_N][3]f32{}
	t_at_end := [VIEWER_N]f32{}
	for i in 0 ..< pop_viewer.n {
		p := b3.Body_GetPosition(pop_viewer.cars[i].sim.bot.chassis)
		copy(pos_at_end[i][:], p[:])
		t_at_end[i] = pop_viewer.cars[i].sim.sim_time
	}
	for _ in 0 ..< 120 {
		if pop_viewer_step(1.0 / 60.0) {
			fmt.eprintfln("smoke pack_line: an over pack still reports live")
			pop_viewer_destroy()
			return false
		}
	}
	for i in 0 ..< pop_viewer.n {
		car := &pop_viewer.cars[i]
		p := b3.Body_GetPosition(car.sim.bot.chassis)
		if p[0] != pos_at_end[i][0] || p[1] != pos_at_end[i][1] || p[2] != pos_at_end[i][2] {
			fmt.eprintfln(
				"smoke pack_line: finished car {} kept moving after the line (x={:.2f} y={:.2f})",
				i,
				p[0],
				p[1],
			)
			pop_viewer_destroy()
			return false
		}
		if car.sim.sim_time != t_at_end[i] {
			fmt.eprintfln(
				"smoke pack_line: finished car {} world still ticking (t={:.2f})",
				i,
				car.sim.sim_time,
			)
			pop_viewer_destroy()
			return false
		}
	}
	// A finished car is out of the lead race: an over pack has no lead.
	if _, ok := pop_viewer_lead_pos(); ok {
		fmt.eprintfln("smoke pack_line: an over pack still reports a lead")
		pop_viewer_destroy()
		return false
	}
	pop_viewer_destroy()
	fmt.printfln(
		"smoke pack_line: OK (finishers freeze at the line; pack ends all-stopped; no lead)",
	)
	return true
}

// When TARGET_START_LEN is below the gen-0 random floor, a gen-0 car can
// clear the first line: the session doubles the line at the generation
// boundary while the display is still walking gen 0. A display car spawned
// AFTER that extension holds a snapshot whose Env is the generation's own
// (seed + the pre-extension line), even though the global env has already
// advanced - and must still be bit-identical to the GA rollout.
smoke_display_resim :: proc() -> bool {
	cfg := default_evo_config()
	seed := evo_terrain_seed(cfg)
	// Gen 0's car 2: the session's own init order (pop[0], pop[1], pop[2]).
	r := rng_init(cfg.seed)
	_ = random_genes(&r)
	_ = random_genes(&r)
	g2 := random_genes(&r)

	target := f32(math.min(f64(TARGET_START_LEN), f64(env_max_len)))
	save_len := env.line
	save_env_seed := env.seed
	save_profile := env_profile
	save_profile_seed := env_profile_seed
	save_profile_valid := env_profile_valid
	set_line(target)
	regenerate_terrain(seed)
	// The generation's own world (the snapshot the display re-runs from).
	gen_env := env

	// GA side: car 2's rollout exactly as the session runs it
	// (sensors → pid → step), on the generation's env.
	ga_g := decode_genes(&g2)
	defer destroy_genome(&ga_g)
	ga := spawn_rollout(&ga_g, gen_env)
	defer destroy_sim(&ga)
	buf := [N_SENSORS]f32{}
	for !ga.failed && !ga.finished {
		sensors(&ga, buf[:])
		pid_drive_car(&ga, PID_COEFF)
		step_sim(&ga)
	}
	ga_fit := rollout_score_m(ga.stall_best_x, ga.track_end)
	ga_time := ga.sim_time
	ga_out := outcome_of(&ga)

	// The boundary: the record reached the line, so the session doubles it.
	extended := 2.0 * target
	if extended > env_max_len {extended = env_max_len}

	// Display side: a car spawned AFTER the boundary - the snapshot's Env
	// is still the generation's, but the global env.line is already at the
	// extended value. Run it LOCKSTEP against a fresh GA-style world (same
	// genome, same Env) so the first diverging tick is visible.
	set_line(target)
	pg := decode_genes(&g2)
	defer destroy_genome(&pg)
	pga := spawn_rollout(&pg, gen_env)
	defer destroy_sim(&pga)
	set_line(extended)
	vg := decode_genes(&g2)
	defer destroy_genome(&vg)
	vsim := spawn_rollout(&vg, gen_env)
	defer destroy_sim(&vsim)
	div_tick := -1
	for t in 0 ..< 12000 {
		if pga.failed || pga.finished {break}
		pid_drive_car(&pga, PID_COEFF)
		step_sim(&pga)
		pid_drive_car(&vsim, PID_COEFF)
		step_sim(&vsim)
		pa := b3.Body_GetPosition(pga.bot.chassis)
		pv := b3.Body_GetPosition(vsim.bot.chassis)
		if div_tick < 0 && (pa[0] != pv[0] || pa[1] != pv[1] || pa[2] != pv[2]) {
			div_tick = t + 1
			fmt.eprintfln(
				"smoke display_resim: first diverge at tick {} ga=({:.6f},{:.6f},{:.6f}) vsim=({:.6f},{:.6f},{:.6f})",
				div_tick,
				pa[0],
				pa[1],
				pa[2],
				pv[0],
				pv[1],
				pv[2],
			)
		}
	}
	vfit := rollout_score_m(vsim.stall_best_x, vsim.track_end)
	vtime := vsim.sim_time
	vout := outcome_of(&vsim)
	pfit := rollout_score_m(pga.stall_best_x, pga.track_end)
	set_line(save_len)
	env.seed = save_env_seed
	env_profile = save_profile
	env_profile_seed = save_profile_seed
	env_profile_valid = save_profile_valid

	fail := vfit != ga_fit || vtime != ga_time || vout != ga_out
	if pfit != ga_fit {
		fmt.eprintfln(
			"smoke display_resim: CONTROL mismatch (ga={:.6f} vs ctrl={:.6f})",
			ga_fit,
			pfit,
		)
		fail = true
	}
	if fail {
		fmt.eprintfln(
			"smoke display_resim MISMATCH (first diverge tick {}): ga={:.6f}/{:.3f}/{} view(ext global={:.0f})={:.6f}/{:.3f}/{}",
			div_tick,
			ga_fit,
			ga_time,
			ga_out,
			extended,
			vfit,
			vtime,
			vout,
		)
		return false
	}
	fmt.printfln(
		"smoke display_resim: OK (line {} -> {} m, car2 {:.4f} m - re-sim after extension matches)",
		target,
		extended,
		ga_fit,
	)
	return true
}

// Two-point crossover: the block / tail / clone
// properties of the crossover core on KNOWN cuts (via crossover_two_cuts,
// so no RNG plumbing), plus breed_next's pairing - elites verbatim in their
// original slots, the other n - elite slots filled with children, and the
// whole result deterministic given seed + fits.
smoke_crossover :: proc() -> bool {
	rng := rng_init(0x51c3)
	a := random_genes(&rng)
	b := random_genes(&rng)
	va := [GENE_DIM]f64{}
	vb := [GENE_DIM]f64{}
	genes_to_vector(&a, va[:])
	genes_to_vector(&b, vb[:])

	W := N_VERTICES * 2 + 3 * max_axles

	// (local procs cannot capture locals - the parents + vectors are
	// passed in)
	check :: proc(pa, pb: ^Genes, va, vb: []f64, W, lo, hi: int) -> bool {
		c0, c1 := crossover_two_cuts(pa, pb, lo, hi)
		v0 := [GENE_DIM]f64{}
		v1 := [GENE_DIM]f64{}
		genes_to_vector(&c0, v0[:])
		genes_to_vector(&c1, v1[:])
		for i in 0 ..< GENE_DIM {
			inside := i >= lo && i <= hi
			want0 := inside ? vb[i] : va[i]
			want1 := inside ? va[i] : vb[i]
			if v0[i] != want0 || v1[i] != want1 {
				fmt.eprintfln(
					"smoke: crossover gene {} took the wrong parent (cuts {}, {})",
					i,
					lo,
					hi,
				)
				return false
			}
		}
		// Tail: genes ≥ W are never swapped, whatever the cuts.
		for i in W ..< GENE_DIM {
			if v0[i] != va[i] || v1[i] != vb[i] {
				fmt.eprintfln("smoke: crossover tail gene {} swapped (cuts {}, {})", i, lo, hi)
				return false
			}
		}
		return true
	}
	if !check(&a, &b, va[:], vb[:], W, 3, 9) ||
	   !check(&a, &b, va[:], vb[:], W, 5, 5) ||
	   !check(&a, &b, va[:], vb[:], W, 0, W - 1) ||
	   !check(&a, &b, va[:], vb[:], W, 7, W - 1) {
		return false
	}

	// Clone: identical parents → both children == parent (bitwise), cuts
	// included (the whole-window cuts are the worst case).
	c0, c1 := crossover_two_cuts(&a, &a, 0, W - 1)
	if c0 != a || c1 != a {
		fmt.eprintfln("smoke: crossover of identical parents is not a bitwise clone")
		return false
	}

	// breed_next: n slots, elite 2 - elites verbatim in their original
	// slots, every other slot filled with a child, and two calls with the
	// same seed + fits give identical populations.
	n := 10
	elite := 2
	pop := make([]Genes, n)
	for i in 0 ..< n {pop[i] = random_genes(&rng)}
	// The top-2 are slots 1 and 3 - pair-second positions, so a pairing
	// that walks raw consecutive indices (instead of the vacated slots)
	// clobbers both survivors.
	fits := [10]f64{1.0, 5.0, 0.5, 4.0, 2.0, 0.1, 3.0, 0.2, 2.5, 0.3}
	top := top_indices(fits[:], n)
	breed :: proc(pop: []Genes, fits: []f64, n, elite: int) -> []Genes {
		r := rng_init(0x51c3_11)
		cfg := Evo_Config {
			pop       = n,
			elite     = elite,
			mut_rate  = DEFAULT_EVO_MUT_RATE,
			mut_sigma = DEFAULT_EVO_MUT_SIGMA,
		}
		return breed_next(cfg, pop, fits, &r)
	}
	next1 := breed(pop[:], fits[:], n, elite)
	for i in 0 ..< n {
		is_elite := i == top[0] || i == top[1]
		if is_elite {
			if next1[i] != pop[i] {
				fmt.eprintfln("smoke: breed_next moved an elite out of slot {}", i)
				return false
			}
		} else if next1[i] == pop[i] {
			fmt.eprintfln("smoke: breed_next left slot {} unfilled (identical to before)", i)
			return false
		}
	}
	next2 := breed(pop[:], fits[:], n, elite)
	for i in 0 ..< n {
		if next1[i] != next2[i] {
			fmt.eprintfln(
				"smoke: breed_next not deterministic (slot {} differs across identical seeds)",
				i,
			)
			return false
		}
	}
	delete(next1)
	delete(next2)
	delete(top)
	delete(pop)
	fmt.printfln("smoke crossover: OK (block/tail/clone properties, {}-slot breed pairing)", n)
	return true
}

// The share link is lossy by design (12-bit genes, 4-bit colors). The
// receiver needs: bit-stable double round-trips (re-sharing a decoded link
// is byte-identical), env/tick within the quantization step, corrupted and
// truncated payloads rejected, and the 159-char payload the QR budget was
// sized against (~185-char URL → 53×53 code).
smoke_car_link :: proc() -> bool {
	// Angular genes: the decoded angle is normalized to [0, TAU), so compare
	// the wrap distance (an input within half a quantum of TAU decodes to 0
	// - the same angle).
	adist := proc(a, b: f32) -> f32 {
		d := math.abs(a - b)
		return math.min(d, TAU - d)
	}
	rng := rng_init(0xC0FFEE)
	for n in 0 ..< 64 {
		g := random_genes(&rng)
		tick := u32(n) * 1000
		line := 20.0 + f32(n) * 3.7
		if n == 63 { 	// boundaries: the tick clamp + the max line
			tick = 1 << 20
			line = COURSE_MAX_LEN
		}
		cl := Car_Link {
			genes = g,
			env = Env{seed = u64(n + 1) * 0x9E3779B97F4A7C15, line = line},
			tick = tick,
		}
		f1 := car_link_encode(cl)
		cl2, ok := car_link_decode(f1)
		if !ok {
			fmt.eprintfln("smoke car_link: decode failed (case {})", n)
			return false
		}
		// encode∘decode is a projection: a decoded car re-encodes to a
		// fixed point (one-time normalization of e.g. angle == TAU → 0).
		f2 := car_link_encode(cl2)
		cl3, ok3 := car_link_decode(f2)
		if !ok3 || car_link_encode(cl3) != f2 {
			fmt.eprintfln("smoke car_link: re-share not bit-stable (case {})", n)
			return false
		}
		if cl2.env.seed != cl.env.seed {
			fmt.eprintfln("smoke car_link: env seed mismatch (case {})", n)
			return false
		}
		step := COURSE_MAX_LEN / 4095
		if math.abs(cl2.env.line - cl.env.line) > step {
			fmt.eprintfln("smoke car_link: env line drifted (case {})", n)
			return false
		}
		want_tick := tick
		if want_tick > 1048575 {want_tick = 1048575}
		if cl2.tick != want_tick {
			fmt.eprintfln("smoke car_link: tick mismatch (case {})", n)
			return false
		}
		// Every gene is quantized to ≤ 12 bits, so one full quantum is a
		// safe drift bound on any gene; the widest span (wheel density,
		// 29.0) bounds them all.
		gstep := f32(29.0) / 4095
		for i in 0 ..< N_VERTICES {
			if adist(cl2.genes.vertices[i].angle, g.vertices[i].angle) > gstep {
				fmt.eprintfln("smoke car_link: vertex angle drifted (case {}, v{})", n, i)
				return false
			}
			if math.abs(cl2.genes.vertices[i].magnitude - g.vertices[i].magnitude) > gstep {
				fmt.eprintfln("smoke car_link: vertex magnitude drifted (case {}, v{})", n, i)
				return false
			}
		}
		for i in 0 ..< N_WHEELS {
			if cl2.genes.wheels[i].vertex != g.wheels[i].vertex {
				fmt.eprintfln("smoke car_link: wheel mount mismatch (case {}, w{})", n, i)
				return false
			}
			if adist(cl2.genes.wheels[i].axle_angle, g.wheels[i].axle_angle) > gstep {
				fmt.eprintfln("smoke car_link: wheel axle drifted (case {}, w{})", n, i)
				return false
			}
			if math.abs(cl2.genes.wheels[i].radius - g.wheels[i].radius) > gstep {
				fmt.eprintfln("smoke car_link: wheel radius drifted (case {}, w{})", n, i)
				return false
			}
			if math.abs(cl2.genes.wheels[i].density - g.wheels[i].density) > gstep {
				fmt.eprintfln("smoke car_link: wheel density drifted (case {}, w{})", n, i)
				return false
			}
		}
		if math.abs(cl2.genes.chassis_density - g.chassis_density) > gstep {
			fmt.eprintfln("smoke car_link: chassis density drifted (case {})", n)
			return false
		}
		for i in 0 ..< N_WIDTHS {
			if math.abs(cl2.genes.widths[i] - g.widths[i]) > gstep {
				fmt.eprintfln("smoke car_link: width drifted (case {}, i{})", n, i)
				return false
			}
		}
		for c in 0 ..< N_COLORS {
			for k in 0 ..< 3 {
				if int(math.abs(f32(cl2.genes.colors[c][k]) - f32(g.colors[c][k]))) > 9 {
					fmt.eprintfln("smoke car_link: color drifted (case {}, c{})", n, c)
					return false
				}
			}
		}
	}
	// Payload size (the QR budget) + corruption / truncation rejection.
	cl := Car_Link {
		genes = random_genes(&rng),
		env = Env{seed = 0xDEADBEEF, line = 250.0},
		tick = 123,
	}
	frag := car_link_encode(cl)
	body := frag[len("#car="):]
	if len(body) != 159 {
		fmt.eprintfln(
			"smoke car_link: payload is {} b64 chars (want 159 - QR budget)",
			len(body),
		)
		return false
	}
	raw, ok := b64url_decode(body)
	if !ok {
		fmt.eprintfln("smoke car_link: payload not base64url-decodable")
		return false
	}
	bad := make([]u8, len(raw))
	copy(bad, raw)
	bad[50] += 1
	_, okc := car_link_decode(strings.concatenate({"#car=", b64url_encode(bad)}))
	if okc {
		fmt.eprintfln("smoke car_link: corrupted payload accepted")
		return false
	}
	_, okt := car_link_decode(strings.concatenate({"#car=", body[:100]}))
	if okt {
		fmt.eprintfln("smoke car_link: truncated payload accepted")
		return false
	}
	_, oki := car_link_decode("#car=!!!not-base64!!!")
	if oki {
		fmt.eprintfln("smoke car_link: invalid alphabet accepted")
		return false
	}
	fmt.printfln(
		"smoke car_link: OK (64 round-trips, checksum rejects, {}-char payload)",
		len(body),
	)
	return true
}

// The #car= link opens a population-1 showcase (the GA is not stepped  - 
// the car is shown, not evolved) frozen at the sharer's frame. When the
// car's pinned run ends, the showcase must resolve into a live evolution:
// the view's finish path fires the die-glyph warm start - a full
// population from the shared car, head of a new lineage, on the pinned
// env. Headless end-to-end: boot the showcase, hand the car to the solo,
// step the view until the run ends.
// Runs LAST: session_init re-points the live frontier (the env global).
smoke_showcase_finish :: proc() -> bool {
	save_env := env
	ok := smoke_showcase_finish_body()
	// Single-exit cleanup: this smoke owns the session/view it booted (in
	// the app the boot is the only owner).
	if solo_is_ready() {solo_destroy()}
	session_destroy(&session)
	env = save_env
	return ok
}

smoke_showcase_finish_body :: proc() -> bool {
	genome := fixed_genome()
	defer destroy_genome(&genome)
	genes := encode_genome(&genome)
	wseed := env.seed

	// The showcase session (the wasm #car= boot's twin): pop 1, pinned to
	// the car's world (a short line the known-good car clears), the shared
	// car as the only genome.
	cfg := default_evo_config()
	cfg.pop = 1
	cfg.terrain_seed = wseed
	cfg.init_line = 20.0
	session_init(&session, &cfg, 2, &genes)

	showcase_mode = true
	showcase_car = Car_Link {
		genes = genes,
		env = Env{seed = wseed, line = 20.0},
		tick = 0, // no catch-up: the run starts from the spawn
	}
	showcase_ff_owed = 0
	reseed_min_gen = 0
	gen_base = 0
	view_mode = 1
	sim_paused = false
	viewer_speed = 1

	// The car to the view (the open edge's offer + the view's take).
	offer_provisional()
	if !view_advance() || !solo_is_ready() {
		fmt.eprintfln("smoke showcase: the shared car never reached the solo")
		return false
	}

	// Step the view at view speed until the run ends. Only the
	// evolve-from-here warm start can end the showcase here: the GA is
	// frozen, so there is no next snapshot to take.
	run_ticks := 0
	for _ in 0 ..< 20000 {
		if !showcase_mode {break}
		step_active_view()
		run_ticks += 1
	}
	if showcase_mode {
		fmt.eprintfln(
			"smoke showcase: the run ended but the showcase did not resolve (solo.active={})",
			solo.active,
		)
		return false
	}
	// The resolution: a full population on the pinned env, the shared car
	// head of the new lineage (index 1), the reseed gates on it.
	if session.cfg.pop != DEFAULT_EVO_POP || session.cfg.elite != DEFAULT_EVO_ELITE {
		fmt.eprintfln(
			"smoke showcase: population not restored (pop={} elite={})",
			session.cfg.pop,
			session.cfg.elite,
		)
		return false
	}
	if session.cur.env.seed != wseed || session.cur.env.line != 20.0 {
		fmt.eprintfln(
			"smoke showcase: env not pinned (seed={} line={})",
			session.cur.env.seed,
			session.cur.env.line,
		)
		return false
	}
	if session.cur.index != 1 {
		fmt.eprintfln("smoke showcase: new lineage at index {} (want 1)", session.cur.index)
		return false
	}
	if session.cur.pop[0] != genes {
		fmt.eprintfln("smoke showcase: the shared car is not head of the new population")
		return false
	}
	if reseed_min_gen != 1 || gen_base != 1 {
		fmt.eprintfln(
			"smoke showcase: reseed gates off (min_gen={} gen_base={})",
			reseed_min_gen,
			gen_base,
		)
		return false
	}
	fmt.printfln(
		"smoke showcase: OK (the run ends at tick {} - the warm start opens a {}-car cohort on the pinned env)",
		run_ticks,
		DEFAULT_EVO_POP,
	)
	return true
}


// Regression guard for the wheel-joint NaN blow-up: the 18th car of
// --seed 3 (idx 17) is a ~280 kg 2-wheel build that, launched off a bump
// at x≈-8.3 and re-contacting, pumped energy to 607 km/s / NaN at 16
// substeps. It must never NaN or exceed 100 m/s - with SUB_STEPS 32 it
// finishes the 200 m course.
smoke_no_blowup :: proc() -> bool {
	rng := rng_init(3)
	for _ in 0 ..< 17 {random_genes(&rng)}
	genes := random_genes(&rng)
	e := Env{seed = 0, line = 200.0}
	slot := Rollout_Slot{}
	slot_start(&slot, &genes, "", 0, 17, e)
	for _ in 0 ..< 3600 {
		if !slot_tick(&slot) {break}
	}
	res := Eval_Result{}
	slot_finish(&slot, &res)
	status := "OK"
	if res.outcome == Rollout_Outcome.NaN_ || res.max_speed >= 100.0 {status = "FAIL"}
	fmt.printfln(
		"smoke no_blowup: {} (outcome={}, max_speed={:.1f} m/s, best_x={:.1f} m)",
		status,
		res.outcome,
		res.max_speed,
		res.best_x,
	)
	return status == "OK"
}


run_smoke :: proc() -> int {
	ok := true
	ok = smoke_settle() && ok
	ok = smoke_scripted() && ok
	ok = smoke_terrain() && ok
	ok = smoke_stall() && ok
	ok = smoke_track_len() && ok
	ok = smoke_track_end() && ok
	ok = smoke_pack_line() && ok
	ok = smoke_display_resim() && ok
	ok = smoke_breaks() && ok
	ok = smoke_store_roundtrip() && ok
	ok = smoke_car_link() && ok
	ok = smoke_crossover() && ok
	ok = smoke_colors() && ok
	ok = smoke_sensors() && ok
	ok = smoke_no_blowup() && ok
	ok = smoke_showcase_finish() && ok
	if ok {
		fmt.printfln("boxcar3d smoke: ALL PASS")
		return 0
	}
	fmt.printfln("boxcar3d smoke: FAILED")
	return 1
}

// The fixed-car sim scaffold the smoke cases share: spawn the fixed genome
// at (x, 0) with the given roll (math.PI = belly down) on a fresh course.
// The genome is consumed by the spawn (body model + bot) and destroyed
// before return, so the caller owns only the returned sim (destroy_sim).
spawn_fixed_sim :: proc(x, roll: f32) -> Sim_State {
	g := fixed_genome()
	wps := generate_course()
	s := init_sim_pose(&g, wps, x, 0.0, 0.0, env, roll)
	destroy_genome(&g)
	return s
}
