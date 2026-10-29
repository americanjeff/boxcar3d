// Population viewer: the main display shows a real-time replay of the
// SHARED current generation - the WHOLE population in index order (car i =
// index i), each in its OWN dedicated Box3D world (bit-identical to the
// session's eval, no shared-solver cross-talk), all spawning at the same
// straight-on pose, camera following the CURRENT lead (re-selected every
// frame with hysteresis). Colors are gene-hash only - nothing on screen
// correlates with the (still-unknown) fitnesses, so no color predicts the
// outcome.
//
// The shared driver (loop.odin) publishes one shared generation snapshot
// (a Generation value copy - see solo.odin); the pack races it from its
// GENES ALONE (provisional) - the lineup needs no ranking, so it starts
// the generation the same frame it is offered. Both targets drive this
// viewer through the shared frame driver - single-threaded.
//
// GHOST FINISH (helix off / display-primary): the race IS the eval, so a
// pack skip (loop.odin's skip control) must still complete the rows before
// the boundary. pack_skip_ghost freezes the on-screen pack (every car
// stopped; the pack never moves again) and re-runs each skipped car FROM
// SPAWN in a throwaway world (ghost_start / ghost_step) - one car per
// frame, GHOST_TICKS_PER_FRAME backstop. The re-run is the same
// spawn_rollout the GA's slots use, so every row equals the GA's record
// for that generation (evolvetest gate B); stamping by index lets the
// cars finish in any order. View toggle / restart / re-seed cancel the
// ghost (pop_viewer_destroy disposes the throwaway world); the pack
// handoff to the next round starts when the last ghost row lands.

package main

import "core:math"
import gfx "engine:graphics"
import b3 "engine:physics"

// VIEWER_N: the FULL population - the pack races every car (car i = index
// i), so it must stay ≥ the session's pop. ~1.2 ms/frame for 16 steps
// (case 16), so 20 fits the budget comfortably.
VIEWER_N :: 20
// The camera keeps its lead while a challenger is within this many metres
// of it (stops the stutter as cars trade the lead).
LEAD_HYSTERESIS :: f32(0.75)

// One car in the viewer: its own dedicated world + per-genome body geometry
// (8 per-segment meshes, one slot color each), driven by the fixed PID
// (PID_COEFF, driving.odin).
Viewer_Car :: struct {
	sim:           Sim_State,
	segs:          [8]gfx.Mesh_Handle, // per-segment body mesh (sorted-ring index)
	seg_c:         [8][3]f32, // per-segment centroid (body frame) - centroid-local mesh draw offset + transparent-sort anchor
	caps:          [8]gfx.Mesh_Handle, // per-segment break cap (sentinel until broken)
	cap_c:         [8][3]f32, // per-cap centroid (body frame) - centroid-local cap draw offset + sort anchor
	caps_flags:    [8][2]bool, // the void flags frozen in the registered cap (refresh_car_caps)
	debris_mesh:   [8]gfx.Mesh_Handle, // per-segment shard (sentinel until that segment breaks)
	wheel_slot:    [N_WHEELS]int, // i-th enabled pair → genome wheel slot (palette slot 8+slot)
	failed:        bool,
	genes:         Genes, // the spawned genome (16-slot palette + shape-hash dedup)
	g:             Genome, // decoded `genes` (the cap + debris-shard builds at break time need it)
	last_n_breaks: int, // mesh refresh trigger
	frozen_pitch:  f32, // the run's final chassis tilt (rad), captured when the car stops
	stopped:       bool, // the run has ended (finished or failed) - the portrait keeps frozen_pitch
}

Pop_Viewer :: struct {
	last:                Generation, // the generation being raced (pop_viewer_build's source; restart re-runs it)
	cars:                [VIEWER_N]Viewer_Car,
	n:                   int,
	lead_idx:            int,
	sim_time:            f32,
	ready:               bool,
	// Shared score-panel record for BOTH views (solo + pack): the furthest
	// progress any DISPLAYED car has reached - what the viewer demonstrated,
	// not the GA's ledger. RATCHETED, evolution-scoped: it persists across
	// generations and view toggles, resetting only on re-seed (track/cars) /
	// restart (pop_viewer_reset_record, all three).
	best_screen:         f64,
	// The champion that set best_screen (the trophy car): its genome, the
	// env it raced in, and its sim tick at the record moment (captured in
	// record_champion). The record is evolution-scoped: by share time the
	// champion's snapshot is long gone (ratcheted past), so the share popup
	// encodes THIS copy as the #car= link.
	champion:            Car_Link,
	champion_valid:      bool,
	// Frame bookkeeping for telemetry's pack age (pv_age): `frames` ticks
	// once per app_frame; `pack_frame` is stamped by pop_viewer_build.
	// In-frame only (the session never builds a pack).
	frames:              int,
	pack_frame:          int,
	// Two-phase generation handoff: on race end the finished pack stays on
	// screen (frozen) while the next generation stages a few cars per frame
	// into `staging`; on completion the buffers flip and the old pack's
	// worlds tear down a few per frame - no single frame pays 20 spawns +
	// 20 mesh builds + 20 destroys. `teardown_gen` keeps the old gen copy
	// alive until its teardown cars are freed (their genes pointers reach
	// into it).
	handoff:             bool,
	staging:             [VIEWER_N]Viewer_Car,
	stage_n:             int,
	stage_gen:           Generation,
	teardown_cars:       [VIEWER_N]Viewer_Car,
	teardown_n:          int,
	teardown_gen:        Generation,
	// The terrain MESH lags the pack flip by one render frame (the new
	// pack spawns far inside the old mesh's extent, so the one-frame hold
	// is invisible) - the env that displayed_env() reports while set.
	terrain_hold:        Env,
	terrain_hold_active: bool,
	// Forward-only camera target: the furthest x reached since the pack was
	// built - a lead death must not sweep the scene backwards (the next car
	// is tens of metres behind). Reset whenever the pack is (re)built.
	lead_ratchet_x:      f32,
	lead_ratchet_ok:     bool,
	// One-shot flag set by ratchet_cam_x when the hold ABORTS (the new lead
	// is too far behind to be worth waiting for): the camera target snaps
	// (cuts) to the new lead this frame instead of the 10% lerp. Cleared by
	// the render path after use.
	cam_cut:             bool,
	// Ghost finish (pack skip, helix off): the skipped cars' runs are
	// finishing headless - the pack stays on screen frozen (the dead-pack
	// look) while their runs re-run in the throwaway world below to their
	// natural terminals, so the row set completes and the next generation
	// can be bred.
	ghost:               bool,
	// The car currently running in the throwaway world (its index = the
	// row stamped when the re-run ends).
	ghost_i:             int,
	// The throwaway re-run's own world + genome (spawn_rollout - the same
	// one the GA's slots use, so the re-run is bit-identical to the GA's
	// rollout of the same genome on the same env). Never rendered.
	ghost_sim:           Sim_State,
	ghost_g:             Genome,
}

pop_viewer: Pop_Viewer

// Handoff pacing: cars staged (built) per frame, old worlds destroyed per
// frame - a handoff frame stays under the 16.6 ms budget with the render +
// a paced session in the same frame.
PACK_STAGES_PER_FRAME :: int(3)
PACK_TEARDOWN_PER_FRAME :: int(5)

// The camera hold is bounded: if the new lead is further behind the held
// point than this, the previous lead finished off the end (or crashed
// alone far ahead) - holding would park the camera on empty terrain.
PACK_HOLD_MAX_M :: f32(15.0)

// Main thread, once per app_frame: advance the frame bookkeeping counter.
pop_viewer_tick :: proc() {
	pop_viewer.frames += 1
}

pop_viewer_is_ready :: proc() -> bool {
	return pop_viewer.ready
}

// Build the viewer from a snapshot: one dedicated world per car, all
// spawning at the same point with the same pose - identical conditions, so
// their divergence is the race; the coincident spawns never collide (each
// has its own world).
pop_viewer_build :: proc(snap: ^Generation) {
	if pop_viewer.ready {pop_viewer_destroy()}

	n := min(VIEWER_N, len(snap.pop))
	for i in 0 ..< n {
		viewer_spawn_car(&pop_viewer.cars, i, &snap.pop[i], snap.env)
	}
	// Push the pack's portraits to the overlay's icon atlas in one upload.
	car_icon_flush()

	pop_viewer.n = n
	pop_viewer.lead_idx = 0
	pop_viewer.sim_time = 0.0
	pop_viewer.pack_frame = pop_viewer.frames
	pop_viewer.lead_ratchet_ok = false // the pack starts at the spawn point
	pop_viewer.ready = true
}

// "Restart" transport: re-run the CURRENT pack from spawn (same snapshot,
// no GA release - the same generation races again). No-op while held.
pop_viewer_restart :: proc() {
	if !pop_viewer.ready {return}
	pop_viewer_destroy()
	pop_viewer_build(&pop_viewer.last)
}

// Build the pack from the SHARED current generation (the same one the solo
// walks - toggling views never surfaces a different set of cars). `g` may
// be complete OR provisional: the index-order lineup needs no ranking, so
// the pack starts the generation the same frame it is offered. The pack's
// copy carries genes + env only (a provisional-shaped Generation) - the
// recorded results feed the solo's asserted rows, never the pack.
pack_build_from_solo :: proc(g: ^Generation) {
	generation_copy(&pop_viewer.last, g) // the gen being raced (the restart transport's source)
	pop_viewer_build(&pop_viewer.last)
}

// Copy `src` into `dst` (freeing dst's old copy): genes (VIEWER_N of them)
// + env only - a provisional-shaped Generation. Shared by the immediate
// build and the two-phase handoff's staging.
generation_copy :: proc(dst: ^Generation, src: ^Generation) {
	assert(len(src.pop) > 0, "pack built from an invalid snapshot")
	n := min(VIEWER_N, len(src.pop))
	free_generation_copy(dst)
	pop := make([]Genes, n, context.allocator)
	copy(pop[:], src.pop[:n])
	dst^ = Generation {
		index = src.index,
		env   = src.env,
		pop   = pop,
	}
}

// Spawn one car into slot `i` at the original spawn point + pose (the
// pack's shared conditions, so the divergence is the race). `e` = the
// snapshot's Env, same rollout conditions as the GA's slots (spawn_rollout):
// a displayed run is bit-identical to the GA's rollout of the same genome.
viewer_spawn_car :: proc(cars: ^[VIEWER_N]Viewer_Car, i: int, genes: ^Genes, e: Env) {
	// The slot may hold a previous (failed) car whose genome + meshes it
	// keeps - release them before the overwrite (idempotent on a fresh slot).
	destroy_genome(&cars[i].g)
	release_car_meshes(&cars[i].segs, &cars[i].caps, &cars[i].debris_mesh)
	g := decode_genes(genes)
	segs, seg_c := build_car_segments(&g)
	sim := spawn_rollout(&g, e)
	// Birth caps seal skipped (degenerate) wedges + the frozen void flags
	// refresh_car_caps compares against on later breaks.
	caps, caps_flags, cap_c := build_car_caps(&g)
	// The decoded genome stays with the car: the cap / debris-shard builds
	// need it at break time.
	cars[i] = Viewer_Car {
		sim         = sim,
		segs        = segs,
		seg_c       = seg_c,
		caps        = caps,
		cap_c       = cap_c,
		caps_flags  = caps_flags,
		debris_mesh = debris_cache_empty(), // fresh car: no segment shed yet
		wheel_slot  = wheel_slot_map(genes),
		failed      = false,
		genes       = genes^,
		g           = g,
	}
	// The score-panel portrait (the caller flushes the atlas - the pack
	// build batches all its spawns).
	car_icon_raster(i, &g, genes.colors, [8]bool{})
}

// Free one car slot's resources (world + genome + car-owned meshes) - the
// per-car half of a pack destroy, shared by the immediate destroy and the
// staged teardown.
viewer_destroy_car :: proc(slot: ^Viewer_Car) {
	destroy_sim(&slot.sim)
	destroy_genome(&slot.g)
	// Car-owned: release the car's meshes + caps + shards now - the slots
	// are freed at refcount 0, and a car's geometry never outlives its
	// teardown.
	release_car_meshes(&slot.segs, &slot.caps, &slot.debris_mesh)
}

pop_viewer_destroy :: proc() {
	// A ghost finish is cancelled with the pack (the re-seed / restart /
	// toggle paths all destroy: their abandon of the eval supersedes it) -
	// the throwaway run goes with it.
	if pop_viewer.ghost {
		destroy_sim(&pop_viewer.ghost_sim)
		destroy_genome(&pop_viewer.ghost_g)
	}
	pop_viewer.ghost = false
	// An in-flight handoff is aborted first: its staged cars + gen copy
	// are freed now (the caller is taking over the pack immediately).
	if pop_viewer.handoff {
		for i in 0 ..< pop_viewer.stage_n {
			viewer_destroy_car(&pop_viewer.staging[i])
		}
		free_generation_copy(&pop_viewer.stage_gen)
		pop_viewer.stage_gen = Generation{}
		pop_viewer.handoff = false
		pop_viewer.stage_n = 0
	}
	// A teardown already in flight finishes NOW (the caller rebuilds
	// immediately - its user-caused frame absorbs the cost): its gen copy
	// goes with it.
	if pop_viewer.teardown_n > 0 {
		for i in 0 ..< pop_viewer.teardown_n {
			viewer_destroy_car(&pop_viewer.teardown_cars[i])
		}
		free_generation_copy(&pop_viewer.teardown_gen)
		pop_viewer.teardown_gen = Generation{}
		pop_viewer.teardown_n = 0
	}
	for i in 0 ..< pop_viewer.n {
		viewer_destroy_car(&pop_viewer.cars[i])
	}
	pop_viewer.n = 0
	pop_viewer.ready = false
}

// The immediate destroy/rebuild paths above remain for user-caused
// actions (restart / skip / view toggle), whose single frame may absorb
// the full cost; race end takes the staged handoff instead.

// Begin staging the next pack. `allow_current`: the IDLE path (boot /
// rebuild) builds the shared current generation (solo.last - the same one
// the solo walks) and falls back to the next pending snapshot when
// solo.last is empty or old lineage; the RACE-END path must never take
// solo.last (it IS the dead pack - re-staging it would re-race the same
// generation forever). No source: the dead pack stays on screen, the
// caller retries next frame.
pack_handoff_begin :: proc(allow_current: bool) {
	snap, ok := (^Generation)(nil), false
	if allow_current {
		// The shared current generation FIRST (the pack races the same one
		// the solo walks - a newer pending waits for the race end).
		if len(solo.last.pop) > 0 && solo.last.index >= reseed_min_gen {
			snap, ok = &solo.last, true
		}
	}
	if !ok {
		snap, ok = take_next_snapshot()
	}
	if !ok {return}
	generation_copy(&pop_viewer.stage_gen, snap)
	pop_viewer.handoff = true
	pop_viewer.stage_n = 0
}

// One frame of the handoff: stage up to PACK_STAGES_PER_FRAME cars; flip
// when the staging is complete.
pack_handoff_step :: proc() {
	built := 0
	for built < PACK_STAGES_PER_FRAME && pop_viewer.stage_n < len(pop_viewer.stage_gen.pop) {
		i := pop_viewer.stage_n
		viewer_spawn_car(
			&pop_viewer.staging,
			i,
			&pop_viewer.stage_gen.pop[i],
			pop_viewer.stage_gen.env,
		)
		pop_viewer.stage_n += 1
		built += 1
	}
	if built > 0 {car_icon_flush()}
	if pop_viewer.stage_n == len(pop_viewer.stage_gen.pop) {
		pack_handoff_flip()
	}
}

// The flip: the staged pack becomes live; the finished pack moves to the
// staged teardown buffer (its gen copy with it - the teardown cars' genes
// pointers reach into it); the terrain mesh lags one render frame (see
// terrain_hold).
pack_handoff_flip :: proc() {
	copy(pop_viewer.teardown_cars[:], pop_viewer.cars[:])
	pop_viewer.teardown_n = pop_viewer.n
	pop_viewer.teardown_gen = pop_viewer.last
	for i in 0 ..< pop_viewer.stage_n {
		pop_viewer.cars[i] = pop_viewer.staging[i]
		// The staging slot keeps a shallow copy of the moved car (shared
		// genome/mesh handles) - zero it so the next handoff's spawn does
		// not release the LIVE car's resources when it overwrites it.
		pop_viewer.staging[i] = Viewer_Car{}
	}
	pop_viewer.n = pop_viewer.stage_n
	pop_viewer.stage_n = 0
	pop_viewer.last = pop_viewer.stage_gen
	pop_viewer.stage_gen = Generation{}
	pop_viewer.handoff = false
	pop_viewer.lead_idx = 0
	pop_viewer.sim_time = 0.0
	pop_viewer.pack_frame = pop_viewer.frames
	pop_viewer.lead_ratchet_ok = false // the pack starts at the spawn point
	pop_viewer.ready = true
	// The terrain lag applies only when an old pack existed (a real env to
	// lag behind); the idle path (boot) has no old env.
	if pop_viewer.teardown_n > 0 {
		pop_viewer.terrain_hold = pop_viewer.teardown_gen.env
		pop_viewer.terrain_hold_active = true
	}
	// Instant camera cut to the new pack (the new lead sits at the spawn
	// point) - no lerp sweep back from the finished line.
	if p, ok := pop_viewer_lead_pos(); ok {
		cam.target = [3]f32{p[0], p[1] + 1.0, p[2]}
	}
}

// The staged teardown, PACK_TEARDOWN_PER_FRAME worlds per frame (runs on
// every pack frame, paused or not - it only frees the off-screen old pack).
pack_teardown_step :: proc() {
	if pop_viewer.teardown_n == 0 {return}
	// Destroy from the TAIL: teardown_n counts the not-yet-freed cars (the
	// first ones in the buffer) - a car freed in an earlier frame is zeroed
	// (destroy_sim clears its Sim_State), and destroying it again would
	// call b3DestroyWorld(nil) → SIGSEGV.
	did := min(PACK_TEARDOWN_PER_FRAME, pop_viewer.teardown_n)
	for i in 0 ..< did {
		viewer_destroy_car(&pop_viewer.teardown_cars[pop_viewer.teardown_n - 1 - i])
	}
	pop_viewer.teardown_n -= did
	if pop_viewer.teardown_n == 0 {
		free_generation_copy(&pop_viewer.teardown_gen)
		pop_viewer.teardown_gen = Generation{}
	}
}

// ── Ghost finish (pack skip, helix off) ─────────────────────────────────
// A skipped race cannot be thrown away: in display-primary the race IS the
// eval, and its rows are what breed the next generation. The still-live
// cars' runs re-run to their natural terminals in a THROWAWAY world
// (spawn_rollout - the same one the GA's slots use, so the re-run is
// bit-identical to the GA's rollout of the same genome on the same env;
// re-running from spawn instead of continuing the on-screen sim keeps the
// visible pack truly frozen - render_bot_mesh reads live body poses).
// One car at a time, the same 4096-tick-per-frame backstop as the solo's
// finish_now (a pause holds the step). The pack on screen stays frozen
// (the dead-pack look; `stopped` also drops the cars from lead selection),
// under a "finishing..." hold. Rows are stamped BY INDEX (the stopped cars
// at skip time, the re-run cars as their terminals land - in any order);
// when the last row lands the grid is complete and the boundary advances
// the generation, handing off over the frozen pack as a normal race end.
GHOST_TICKS_PER_FRAME :: 4096

// Start the throwaway re-run of car `i` on the pack's env.
ghost_start :: proc(i: int) {
	pop_viewer.ghost_i = i
	g := decode_genes(&pop_viewer.cars[i].genes)
	pop_viewer.ghost_g = g
	pop_viewer.ghost_sim = spawn_rollout(&pop_viewer.ghost_g, pop_viewer.last.env)
}

// Enter the ghost: stamp the already-stopped cars' rows (the grid is
// reset - this race owns the generation's record) and freeze the live
// ones; the first of them starts its throwaway re-run. A skip that lands
// on the race's last frame (nobody live) completes immediately.
pack_skip_ghost :: proc() {
	if pop_viewer.ghost {return} // a finish is already in flight
	solo.rows = {}
	solo.rows_gen = pop_viewer.last.index
	solo.row_n = 0
	first := -1
	for i in 0 ..< pop_viewer.n {
		car := &pop_viewer.cars[i]
		if car.sim.failed || car.sim.finished {
			solo.rows[i] = row_from_run(i, &car.sim, car.genes.colors)
		} else {
			// Frozen on screen (never stepped again - the re-run happens in
			// the throwaway world).
			car.frozen_pitch = chassis_pitch(car.sim.bot.chassis)
			car.stopped = true
			if first < 0 {first = i}
		}
	}
	if first < 0 {
		solo.row_n = len(solo.last.pop)
		display_primary_boundary()
		hold_reason = ""
		pack_handoff_begin(false)
		return
	}
	ghost_start(first)
	pop_viewer.ghost = true
	hold_reason = "finishing..."
}

// One frame of the ghost: run the throwaway car to its terminal (bounded),
// stamp its row, and move to the next live car - or close out.
ghost_step :: proc() {
	if sim_paused {return}
	i := pop_viewer.ghost_i
	for _ in 0 ..< GHOST_TICKS_PER_FRAME {
		pid_drive_car(&pop_viewer.ghost_sim, PID_COEFF)
		step_sim(&pop_viewer.ghost_sim)
		if pop_viewer.ghost_sim.failed || pop_viewer.ghost_sim.finished {break}
	}
	if !pop_viewer.ghost_sim.failed && !pop_viewer.ghost_sim.finished {
		return // the re-run continues next frame
	}
	// Terminal: stamp the row from the throwaway run's terminal (the on-
	// screen car is frozen mid-run - its row comes from the re-run, which
	// is bit-identical to what the display run would have produced), and
	// let the terminal's score feed the evolution-scoped record.
	car := &pop_viewer.cars[i]
	row := row_from_run(i, &pop_viewer.ghost_sim, car.genes.colors)
	solo.rows[i] = row
	bump_best_screen(row.score, &car.genes, pop_viewer.last.env,
		u32(math.round(pop_viewer.ghost_sim.sim_time / TIME_STEP)))
	destroy_sim(&pop_viewer.ghost_sim)
	destroy_genome(&pop_viewer.ghost_g)
	nxt := -1
	for j := i + 1; j < pop_viewer.n; j += 1 {
		c := &pop_viewer.cars[j]
		if !c.sim.failed && !c.sim.finished {
			nxt = j
			break
		}
	}
	if nxt < 0 {
		ghost_done()
		return
	}
	ghost_start(nxt)
}

// The last row is in: the grid is complete - breed the next generation
// (the shared boundary) and begin the handoff over the frozen dead pack,
// exactly as a normal race end.
ghost_done :: proc() {
	pop_viewer.ghost = false
	solo.row_n = len(solo.last.pop)
	display_primary_boundary()
	hold_reason = ""
	pack_handoff_begin(false)
}

// Step every live car's own world. A car is DONE when its run ends -
// finished at the line (the SAME terminal the GA's slot_tick and the solo
// take: the rollout stops there, so a finisher freezes at the line instead
// of being driven off the truncated heightfield) or failed (goal / break
// cap / liveness gate) - and a stopped car is never stepped again. The
// pack is over when every car is stopped; no time limit (self-terminating).
pop_viewer_step :: proc(frame_dt: f32) -> bool {
	if !pop_viewer.ready {return false}

	for i in 0 ..< pop_viewer.n {
		car := &pop_viewer.cars[i]
		if car.stopped {continue}
		pid_drive_car(&car.sim, PID_COEFF)
		step_sim(&car.sim)
		if car.sim.bot.n_breaks != car.last_n_breaks {
			// Segments shed this tick: NO body rebuild - the broken segment
			// stops being drawn as body, its shard rides the debris body,
			// and its hole gets a cap mesh so the chassis stays a sealed
			// solid. refresh_car_caps also re-caps earlier-frozen caps (a
			// neighbor's shed makes the shared spoke quad interior: a
			// floating wall).
			refresh_car_caps(&car.g, &car.sim.bot, &car.caps, &car.caps_flags, &car.cap_c)
			for s in 0 ..< 8 {
				if !car.sim.bot.broken[s] {continue}
				if !gfx.Is_Mesh_Handle_Valid(car.debris_mesh[s]) {
					car.debris_mesh[s] = build_debris_mesh(&car.g, s)
				}
			}
			// The portrait shows the car's current shape: the shed
			// segments' wedges are missing from the silhouette.
			car_icon_raster(i, &car.g, car.genes.colors, car.sim.bot.broken)
			car_icon_flush()
			car.last_n_breaks = car.sim.bot.n_breaks
		}
		// Capture the run's final tilt the frame the car stops: the
		// portrait keeps it for the rest of the pack's life.
		if !car.stopped && (car.sim.finished || car.sim.failed) {
			car.frozen_pitch = chassis_pitch(car.sim.bot.chassis)
			car.stopped = true
		}
		if car.sim.failed {car.failed = true}
	}
	pop_viewer.sim_time += frame_dt
	for i in 0 ..< pop_viewer.n {
		if !pop_viewer.cars[i].stopped {return true}
	}
	return false
}

// The forward-only camera target: the target's x never retreats below the
// pack's furthest point so far (y/z still follow the car - only x is
// ratcheted). The hold is BOUNDED (PACK_HOLD_MAX_M): a new lead further
// behind than that finished off the end, so the hold aborts - the ratchet
// resets to the new lead and the render path SNAPs the camera (see cam_cut).
ratchet_cam_x :: proc(p: [3]f32) -> [3]f32 {
	q := p
	if !pop_viewer.lead_ratchet_ok || q[0] > pop_viewer.lead_ratchet_x {
		pop_viewer.lead_ratchet_x = q[0]
		pop_viewer.lead_ratchet_ok = true
	} else if pop_viewer.lead_ratchet_x - q[0] > PACK_HOLD_MAX_M {
		// Too far behind to be worth waiting for: cut to the new lead.
		pop_viewer.lead_ratchet_x = q[0]
		pop_viewer.cam_cut = true
	} else {
		q[0] = pop_viewer.lead_ratchet_x
	}
	return q
}

// Lead position (NaN-guarded) for the camera: returns false if no car is
// alive + finite (a degenerate body can leave the chassis at NaN; never
// feed that to follow_camera). The lead is the live car furthest along +x,
// re-selected every frame; a car whose run has ENDED is out of the race
// (its handoff takes the same ratchet bounds). Hysteresis: a challenger
// within LEAD_HYSTERESIS does not change the lead. Main-thread only (render
// path); re-selects lead_idx in place.
pop_viewer_lead_pos :: proc() -> ([3]f32, bool) {
	if !pop_viewer.ready {return [3]f32{}, false}
	finite_pos :: proc(i: int) -> ([3]f32, bool) {
		p := b3.Body_GetPosition(pop_viewer.cars[i].sim.bot.chassis)
		if p[0] != p[0] || p[1] != p[1] || p[2] != p[2] {return [3]f32{}, false}
		return p, true
	}
	best_idx := -1
	best_x := f32(-1e30)
	for j in 0 ..< pop_viewer.n {
		if pop_viewer.cars[j].stopped {continue}
		p, ok := finite_pos(j)
		if !ok {continue}
		if p[0] > best_x {
			best_x = p[0]
			best_idx = j
		}
	}
	if best_idx < 0 {return [3]f32{}, false}
	cur := pop_viewer.lead_idx
	if cur >= 0 && cur < pop_viewer.n && !pop_viewer.cars[cur].stopped {
		cp, cok := finite_pos(cur)
		if cok && (cur == best_idx || best_x <= cp[0] + LEAD_HYSTERESIS) {
			return ratchet_cam_x(cp), true
		}
	}
	pop_viewer.lead_idx = best_idx
	p, ok := finite_pos(best_idx)
	if !ok {return [3]f32{}, false}
	return ratchet_cam_x(p), true
}

// Score panel fill: the on-screen cars' LIVE scores = distance driven
// (the ratcheted chassis x from the spawn) - keeps growing while the car
// drives, stopping only at the track end or a failure (a failed car keeps
// its last value flagged .Failed).
pop_viewer_fill_cars :: proc(hud: ^Hud_Data) {
	hud.n_cars = 0
	hud.best_screen = pop_viewer.best_screen
	if !pop_viewer.ready {return}
	for i in 0 ..< pop_viewer.n {
		car := &pop_viewer.cars[i]
		h := &hud.cars[i]
		h.id = i
		copy(h.colors[:], car.genes.colors[:])
		m := car.sim.stall_best_x - S_SPAWN_X
		if m < 0 {m = 0}
		// The car's OWN line (captured at its spawn): a fast step can
		// cross the line x by a fraction of a metre, and a line extension
		// during the run must not retro-inflate the displayed score.
		if m > car.sim.track_end {m = car.sim.track_end}
		h.score = f64(m)
		if bump_best_screen(h.score, &car.genes, pop_viewer.last.env,
			u32(math.round(car.sim.sim_time / TIME_STEP))) {
			hud.best_screen = pop_viewer.best_screen
		}
		if car.failed {
			h.state = .Failed
			h.pitch = car.frozen_pitch
		} else if car.sim.finished {
			h.state = .Finished
			h.pitch = car.frozen_pitch
		} else {
			h.state = .Live
			h.pitch = chassis_pitch(car.sim.bot.chassis)
		}
		hud.n_cars += 1
	}
}

// Called by both drivers for the actions that genuinely start a new
// evolution line: re-seed track, re-seed cars, and Restart (re-run the
// current generation). A new GENERATION boundary does NOT call this - the
// record is evolution-scoped.
pop_viewer_reset_record :: proc() {
	pop_viewer.best_screen = 0
	pop_viewer.champion_valid = false
}

// The shared best_screen ratchet (both views' fills): `score` moves the
// record forward and, when `genes` is non-nil, records the car that set it
// (the trophy - see record_champion). Returns true when the record moved.
bump_best_screen :: proc(score: f64, genes: ^Genes, env: Env, tick: u32) -> bool {
	if score <= pop_viewer.best_screen {return false}
	pop_viewer.best_screen = score
	if genes != nil {record_champion(genes^, env, tick)}
	return true
}

// Record the champion that just broke best_screen (see Pop_Viewer.champion).
record_champion :: proc(genes: Genes, env: Env, tick: u32) {
	pop_viewer.champion = Car_Link {
		genes = genes,
		env   = env,
		tick  = tick,
	}
	pop_viewer.champion_valid = true
}

// Cleanup on app exit: destroy the current worlds + free the copies.
pop_viewer_cleanup :: proc() {
	if pop_viewer.ready {pop_viewer_destroy()}
	pop_viewer.best_screen = 0
	pop_viewer.champion_valid = false
	free_generation_copy(&pop_viewer.last)
	pop_viewer.last = Generation{}
}

