// The solo view: serial index-order runs - the windowed viewer shows the
// WHOLE generation - every member, in index order 0 -> n-1, stillborns
// included - ONE car at a time, each in its own dedicated Box3D world
// driven to its terminal by the fixed PID. The LIVE car is a running row in
// the score panel; rows sort live-first, then by score (hud_car_row_less) -
// solo.rows stays in walk order. The panel's "best" is EVOLUTION-scoped
// (see Pop_Viewer.best_screen).
//
// PROVISIONAL START: the view begins a generation from its GENES ALONE -
// at init, after a re-seed, and at every generation boundary - before the
// session has evaluated it. Each row finalizes to the DISPLAY RUN'S OWN
// terminal.
//
// DETERMINISM GATE: a displayed run is a bit-identical re-simulation of the
// session's rollout of the same genome (same course + finish line, spawn
// pose, PID, world - spawn_rollout in evolve.odin is the one copy). Rows
// are asserted EQUAL to the recorded results - solo_adopt_results (rows
// already finalized) and solo_finish_car (each row as it finalizes). A
// mismatch is a determinism bug and crashes.
//
// Both targets run it through the shared frame driver (loop.odin); the
// session publishes the snapshot in-frame (provisional at birth, completed
// in place at the eval boundary) and the pending/last handoff is
// single-threaded. The pack view races the same Generation, whole
// population, from a complete OR provisional snapshot (the lineup needs no
// ranking).

package main

import fmt "core:fmt"
import "core:math"
import gfx "engine:graphics"
import b3 "engine:physics"

// Bounds the fixed arrays; the windowed GA always runs DEFAULT_EVO_POP (20).
// Sized with headroom so a bumped population doesn't silently truncate.
SOLO_MAX :: 24

// One completed run's row (Car / Score / Time). Stamped from the display
// run's own terminal - equal to the GA's record (asserted when the record
// is available; see the header).
Solo_Row :: struct {
	car:     int, // population index (Flash's "Car")
	score:   f64, // distance driven (m) - the display run's rollout_score_m
	time:    f32, // run duration (s) - the display run's sim clock
	outcome: Rollout_Outcome,
	colors:  [N_COLORS][3]u8, // the car's 16-slot palette (matches the car on screen)
	pitch:   f32, // chassis pitch (rad) frozen at the run's end - the portrait keeps its last tilt
}

// The view's copy of the shared generation (evolve.odin's Generation) is a
// value copy that OWNS its data: `build_solo_provisional` copies the
// session's pop into a fresh slice, and `solo_snapshot_complete` copies the
// recorded fits/res at the eval boundary - the session re-rolls cur.pop in
// place at every boundary and reallocates its fits/res at a car re-seed, so
// the view must never alias its arrays. ALL members in index order (NOT
// best-first - Flash walks currentChrom 0 -> popSize-1). Born PROVISIONAL
// (genes + env, no results - the solo can start immediately) and completed
// IN PLACE when the session finishes evaluating the generation. An EMPTY
// copy (nil pop) means "no generation".

// Free a view's Generation copy's owned slices (idempotent on an empty
// copy). Shared by solo + pop_viewer (and the tests' local copies).
free_generation_copy :: proc(g: ^Generation) {
	if len(g.pop) > 0 {delete(g.pop)}
	if len(g.fits) > 0 {delete(g.fits)}
	if len(g.res) > 0 {delete(g.res)}
}

// The solo viewer: one car on screen at a time + the growing row grid.
Solo_State :: struct {
	pending:       Generation, // the session pushes in-frame (loop.odin)
	last:          Generation, // last consumed (the generation on screen)

	// active car (its own dedicated world):
	car:           Sim_State,
	segs:          [8]gfx.Mesh_Handle, // per-segment body mesh (sorted-ring index)
	seg_c:         [8][3]f32, // per-segment centroid (body frame) - centroid-local mesh draw offset + transparent-sort anchor
	caps:          [8]gfx.Mesh_Handle, // per-segment break cap (sentinel until broken)
	cap_c:         [8][3]f32, // per-cap centroid (body frame) - centroid-local cap draw offset + sort anchor
	caps_flags:    [8][2]bool, // the void flags frozen in the registered cap (refresh_car_caps)
	debris_mesh:   [8]gfx.Mesh_Handle, // per-segment shard (sentinel until that segment breaks)
	wheel_slot:    [N_WHEELS]int, // i-th enabled pair → genome wheel slot (palette slot 8+slot)
	g:             Genome, // the active car's decoded genome (kept for the break-time cap / debris-shard builds)
	last_n_breaks: int, // mesh refresh trigger
	colors:        [N_COLORS][3]u8, // the active car's palette (carried into its row)
	active:        bool,
	finish_now:    bool, // "next" mid-run: run the car to its natural terminal (loop.odin)
	cur:           int, // current solo index (0..n-1)
	n:             int, // cars in this generation's solo
	gen:           int, // generation being walked (index order)
	ready:         bool, // a generation's solo is in progress
	sim_time:      f32,

	// the growing row grid:
	rows:          [SOLO_MAX]Solo_Row,
	row_n:         int,
	rows_gen:      int, // the generation `rows` was walked for; rows from an
	// earlier walk are foreign (pack mode adopts without re-walking) and are never asserted
}

solo: Solo_State

// In-frame, one thread (loop.odin): the session publishes the full-
// generation snapshot; the copy owns its pop / fits / res (freed when
// overwritten).
solo_push :: proc(p: Generation) {
	free_generation_copy(&solo.pending)
	solo.pending = p
}

// Is a snapshot waiting? (the in-sync cap read)
solo_has_pending :: proc() -> bool {
	return len(solo.pending.pop) > 0
}

// Drop the pending snapshot (re-seed: the old lineage is gone).
solo_clear_pending :: proc() {
	free_generation_copy(&solo.pending)
	solo.pending = Generation{}
}

// Consume the latest snapshot into `last`.
solo_try_pop :: proc() -> bool {
	has := len(solo.pending.pop) > 0
	if has {
		free_generation_copy(&solo.last)
		solo.last = solo.pending
		solo.pending = Generation{}
	}
	return has
}

// The generation's snapshot at BIRTH: a value copy - genes + env, no
// results. The pop is copied (NOT aliased): the session re-rolls cur.pop in
// place at the next boundary, so the view must race the exact genes it was
// offered.
build_solo_provisional :: proc(src: ^Generation) -> Generation {
	assert(len(src.pop) <= SOLO_MAX)
	pop := make([]Genes, len(src.pop), context.allocator)
	copy(pop[:], src.pop[:])
	return Generation{index = src.index, env = src.env, pop = pop, complete = false}
}

// Fill a snapshot with the generation's recorded results (the session just
// finished evaluating it). The view's copy OWNS its fits / res (the
// session's are reallocated at a car re-seed); `src` holds one result per
// member of `p` (the session's cur at the boundary).
solo_snapshot_complete :: proc(p: ^Generation, src: ^Generation) {
	assert(len(src.fits) >= len(p.pop) && len(src.res) >= len(p.pop))
	if len(p.fits) > 0 {delete(p.fits)}
	if len(p.res) > 0 {delete(p.res)}
	p.fits = make([]f64, len(p.pop), context.allocator)
	p.res = make([]Eval_Result, len(p.pop), context.allocator)
	copy(p.fits[:], src.fits[:len(p.pop)])
	copy(p.res[:], src.res[:len(p.pop)])
	p.complete = true
}

// The solo snapshot for a FULLY-EVALUATED generation (index order) - the
// from-scratch complete form (tests; the driver completes provisionals in
// place).
build_solo_snapshot :: proc(src: ^Generation) -> Generation {
	p := build_solo_provisional(src)
	solo_snapshot_complete(&p, src)
	return p
}

// One finalized row vs the generation's recorded results (bit-for-bit
// equality - the display re-simulates the rollout, so any mismatch is a
// determinism bug, not a rounding difference). Rows fill in walk order, so
// row i is car i.
check_solo_row :: proc(i: int) {
	r := solo.rows[i]
	if r.car != i {
		fmt.eprintfln("solo determinism: row order broke (row {} is car {})\n", i, r.car)
		assert(false, "solo row order broke")
	}
	if r.score != solo.last.fits[i] {
		fmt.eprintfln(
			"solo determinism: display score {} != GA record {} (gen {} car {})\n",
			r.score,
			solo.last.fits[i],
			solo.last.index,
			i,
		)
		assert(false, "solo determinism: score mismatch")
	}
	if r.time != solo.last.res[i].fail_time {
		fmt.eprintfln(
			"solo determinism: display time {} != GA record {} (gen {} car {})\n",
			r.time,
			solo.last.res[i].fail_time,
			solo.last.index,
			i,
		)
		assert(false, "solo determinism: time mismatch")
	}
	if r.outcome != solo.last.res[i].outcome {
		fmt.eprintfln(
			"solo determinism: display outcome {} != GA record {} (gen {} car {})\n",
			r.outcome,
			solo.last.res[i].outcome,
			solo.last.index,
			i,
		)
		assert(false, "solo determinism: outcome mismatch")
	}
}

// The session just completed the generation the solo is showing (or holds
// in `last`): adopt the recorded results from the session's cur (still
// holding that generation's fits/res at the boundary). Rows already
// finalized are checked NOW; the rest as they finalize (solo_finish_car).
solo_adopt_results :: proc(src: ^Generation) {
	if len(solo.last.pop) == 0 || solo.last.complete {return}
	solo_snapshot_complete(&solo.last, src)
	// Only rows walked for THIS generation assert: in pack mode a
	// generation is adopted while the pack races (no solo re-walk), so the
	// old rows must not be checked against the new record.
	if solo.rows_gen == solo.last.index {
		for i in 0 ..< solo.row_n {
			check_solo_row(i)
		}
	}
}

outcome_to_hud_state :: proc(o: Rollout_Outcome) -> Hud_Car_State {
	if o == .Completed {return .Finished}
	return .Failed
}

// Tear down the active car's world (if any) and clear the solo.
solo_destroy :: proc() {
	if solo.active {
		destroy_sim(&solo.car)
		destroy_genome(&solo.g)
		release_car_meshes(&solo.segs, &solo.caps, &solo.debris_mesh)
		solo.active = false
	}
	solo.ready = false
	solo.cur = 0
	solo.n = 0
	solo.row_n = 0
}

// Spawn the car at solo index i from the consumed snapshot: the SAME
// rollout conditions the GA's slot used (spawn_rollout), so the run is
// bit-identical.
solo_spawn_car :: proc(i: int) {
	// A just-finished car's genome is still held - destroy it before the
	// overwrite (idempotent on a fresh slot).
	destroy_genome(&solo.g)
	g := decode_genes(&solo.last.pop[i])
	solo.segs, solo.seg_c = build_car_segments(&g)
	sim := spawn_rollout(&g, solo.last.env)
	solo.car = sim
	solo.caps, solo.caps_flags, solo.cap_c = build_car_caps(&g) // birth caps seal skipped (degenerate) wedges
	solo.debris_mesh = debris_cache_empty() // fresh car: no segment shed yet
	solo.wheel_slot = wheel_slot_map(&solo.last.pop[i])
	solo.g = g // stays: the cap / debris-shard builds at break time need it
	solo.last_n_breaks = 0
	copy(solo.colors[:], solo.last.pop[i].colors[:])
	solo.active = true
	solo.cur = i
	// The score-panel portrait: the car's side view, intact (broken
	// segments' wedges drop out of the silhouette at break time).
	car_icon_raster(i, &g, solo.colors, [8]bool{})
	car_icon_flush()
}

// Begin a generation's solo from a consumed snapshot: reset the grid and
// spawn car 0.
solo_build :: proc() {
	if solo.active {
		destroy_sim(&solo.car)
		destroy_genome(&solo.g)
		release_car_meshes(&solo.segs, &solo.caps, &solo.debris_mesh)
		solo.active = false
	}
	solo.gen = solo.last.index
	solo.n = len(solo.last.pop)
	solo.cur = 0
	solo.row_n = 0
	solo.rows_gen = solo.last.index
	solo.finish_now = false
	solo.rows = {}
	// The panel's "best" record is NOT reset here - it is evolution-scoped
	// (only re-seed / restart clear it; see Pop_Viewer.best_screen).
	solo.sim_time = 0
	solo.ready = true
	solo_spawn_car(0)
}

// The active car's chassis position, for the follow camera.
solo_lead_pos :: proc() -> ([3]f32, bool) {
	if solo.active {
		return b3.Body_GetPosition(solo.car.bot.chassis), true
	}
	return {}, false
}

// Step the active car one physics tick. Appends the row and spawns the next
// car the moment the current one terminates. Returns false once the whole
// generation's solo is complete (every car run); true while a car is live.
solo_step :: proc(frame_dt: f32) -> bool {
	if !solo.active {return false}
	solo.sim_time += frame_dt
	pid_drive_car(&solo.car, PID_COEFF)
	step_sim(&solo.car)
	if solo.car.bot.n_breaks != solo.last_n_breaks {
		// Segments shed this tick: NO body rebuild - the broken segment
		// stops being drawn as body, its shard rides the debris body, and
		// its hole gets a cap mesh so the chassis stays a sealed solid.
		// refresh_car_caps also re-caps earlier-frozen caps (a neighbor's
		// shed makes the shared spoke quad interior: a floating wall).
		refresh_car_caps(&solo.g, &solo.car.bot, &solo.caps, &solo.caps_flags, &solo.cap_c)
		for s in 0 ..< 8 {
			if !solo.car.bot.broken[s] {continue}
			if !gfx.Is_Mesh_Handle_Valid(solo.debris_mesh[s]) {
				solo.debris_mesh[s] = build_debris_mesh(&solo.g, s)
			}
		}
		// The portrait shows the car's current shape: the shed segments'
		// wedges are missing from the silhouette.
		car_icon_raster(solo.cur, &solo.g, solo.colors, solo.car.bot.broken)
		car_icon_flush()
		solo.last_n_breaks = solo.car.bot.n_breaks
	}
	if solo.car.failed || solo.car.finished {
		solo_finish_car()
		solo.finish_now = false // the car its "next" was owed has ended naturally
	}
	return solo.active
}

// A car just ended: stamp its row from the DISPLAY RUN'S OWN terminal
// (derived exactly as slot_finish derives the GA's: rollout_score_m on the
// ratcheted best, the sim's clock, outcome_of), check it against the record
// when available, tear down, and start the next car.
solo_finish_car :: proc() {
	i := solo.cur
	solo.rows[solo.row_n] = Solo_Row {
		car     = i,
		score   = rollout_score_m(solo.car.stall_best_x, solo.car.track_end),
		time    = solo.car.sim_time,
		outcome = outcome_of(&solo.car),
		colors  = solo.colors,
		pitch   = chassis_pitch(solo.car.bot.chassis), // frozen before teardown
	}
	if solo.last.complete {check_solo_row(i)}
	solo.row_n += 1
	destroy_sim(&solo.car)
	destroy_genome(&solo.g)
	release_car_meshes(&solo.segs, &solo.caps, &solo.debris_mesh)
	solo.active = false
	if i + 1 < solo.n {
		solo_spawn_car(i + 1)
	}
}

// A generation's solo is in progress (a car is live, or rows are shown).
solo_is_ready :: proc() -> bool {
	return solo.ready
}

// Feed the score panel: one row per finished car (the grid, filling in) +
// the LIVE car as a running row (see hud_car_row_less in ui.odin for the
// order), and the EVOLUTION-scoped best (see Pop_Viewer.best_screen).
solo_fill_cars :: proc(hud: ^Hud_Data) {
	hud.n_cars = 0
	best := pop_viewer.best_screen
	// The car that owns `best` (the trophy champion's identity when the
	// record moves): the live car, or its row (the row's terminal tick).
	best_row := -1
	best_live := false
	for i in 0 ..< solo.row_n {
		r := solo.rows[i]
		h := &hud.cars[i]
		h.id = r.car
		copy(h.colors[:], r.colors[:])
		h.score = r.score
		h.state = outcome_to_hud_state(r.outcome)
		h.pitch = r.pitch // done: keep the run's last tilt (frozen at the end)
		if r.score > best {
			best = r.score
			best_row = i
			best_live = false
		}
		hud.n_cars += 1
	}
	if solo.active {
		// The live car's running row: its demonstrated distance (ratcheted
		// best, capped at the finish line).
		dist := f64(solo.car.stall_best_x - S_SPAWN_X)
		if dist < 0 {dist = 0}
		cap := f64(solo.car.track_end - S_SPAWN_X)
		if dist > cap {dist = cap}
		if dist > best {
			best = dist
			best_live = true
		}
		live := &hud.cars[hud.n_cars]
		live.id = solo.cur
		copy(live.colors[:], solo.colors[:])
		live.score = dist
		live.state = .Live
		live.pitch = chassis_pitch(solo.car.bot.chassis)
		hud.n_cars += 1
	}
	// The trophy champion for a moved record: the live car, or the
	// record-setting row's car when it belongs to the generation on screen  - 
	// a foreign row (an adopted generation's walk, its genome no longer
	// addressable) moves the record without attribution.
	genes: ^Genes
	env: Env
	tick: u32
	if best_live {
		genes = &solo.last.pop[solo.cur]
		env = solo.last.env
		tick = u32(math.round(solo.car.sim_time / TIME_STEP))
	} else if best_row >= 0 &&
		solo.rows_gen == solo.last.index &&
		solo.rows[best_row].car < len(solo.last.pop) {
		r := solo.rows[best_row]
		genes = &solo.last.pop[r.car]
		env = solo.last.env
		tick = u32(math.round(r.time / TIME_STEP))
	}
	bump_best_screen(best, genes, env, tick)
	hud.best_screen = pop_viewer.best_screen
}

// Draw the active solo car (terrain + one car), camera following it.
render_solo :: proc(cam: ^Camera_State) {
	ensure_terrain_mesh(displayed_env())
	gfx.Reset_Frame_Arena()
	gfx.Set_Edge_Overlay(
		true,
		show_hulls = true,
		show_meshes = false,
		show_heightfields = false,
		hull_color = BODY_EDGE_COLOR,
	)
	append_terrain()
	if solo.active {
		render_bot_mesh(
			&solo.car.bot,
			solo.segs[:],
			solo.caps[:],
			solo.debris_mesh[:],
			solo.seg_c,
			solo.cap_c,
			solo.last.pop[solo.cur].colors,
			solo.wheel_slot,
		)
	}
	lead_pos, ok := solo_lead_pos()
	if ok {follow_camera(cam, lead_pos)}
	right, up, forward, eye := camera_basis(cam^)
	gfx.Render_Frame(
		right,
		up,
		forward,
		eye,
		CAMERA_FOV_RAD,
		CAMERA_NEAR,
		CAMERA_FAR,
		solo.sim_time,
		view_debug_mode,
		false,
		!ao_enabled,
	)
}

// Cleanup on app exit: destroy the active world + free the copies.
solo_cleanup :: proc() {
	if solo.ready {solo_destroy()}
	free_generation_copy(&solo.pending)
	solo.pending = Generation{}
	free_generation_copy(&solo.last)
	solo.last = Generation{}
}
