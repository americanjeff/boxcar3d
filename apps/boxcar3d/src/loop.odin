// The shared frame driver (both targets): the co-evolution session
// (evolve.odin's Evo_Session) stepped cooperatively from the frame callback
// with a per-frame tick budget. The GA worker pool exists only in the
// headless `evolve` command; the windowed drivers never spawn threads.
// The per-frame policy is ONE implementation; the thin per-target shells
// (loop_native.odin / loop_wasm.odin) own the entry point, the tick budget,
// and the I/O hooks.
//
// Provisional start: at init, after a re-seed, and at every boundary the
// views begin the generation whose GENES EXIST NOW, before the session has
// evaluated a single car; each displayed row is later asserted equal to
// the eval's recorded result (the live determinism gate), and the pack
// starts the same frame it is offered (its lineup needs no ranking).
//
// Pacing (in-sync cap vs fast-forward lead over the displayed view, and
// generation offers): the canonical contracts are step_session +
// offer_provisional.

package main

import "core:math"
import "core:time"
import host "engine:apphost"

// The driver's camera: the input callbacks orbit it, the render procs follow it.
cam: Camera_State

// A frame that misses the 16.6 ms display deadline re-presents the
// previous frame (the pack-mode stutter). The pacing scale sheds the
// BACKGROUND session (the GA) until the frame fits; the VIEWS are never
// paced (a sub-1.0 view tick rate makes the cars pulse). Shed fast,
// recover slow (hysteresis). Tick SEQUENCES are untouched - only the
// wall-clock rate changes - so the determinism gates (live assert,
// cross-driver) are unaffected.
PACING_SHED_MS :: f32(13.0) // start shedding well under the 16.6 ms budget
PACING_RECOVER_MS :: f32(9.0) // comfortable headroom → start recovering
PACING_MIN_SCALE :: f32(0.25)

pacing_scale: f32 = 1.0

// The pacing controller, called once per frame with this frame's measured
// CPU cost (session + view + render, wall ms).
pace_update :: proc(cpu_ms: f32) {
	if sim_paused {
		pacing_scale = 1.0
		return
	}
	if cpu_ms > PACING_SHED_MS {
		pacing_scale = math.max(PACING_MIN_SCALE, pacing_scale * 0.7)
	} else if cpu_ms < PACING_RECOVER_MS {
		pacing_scale = math.min(1.0, pacing_scale * 1.03)
	}
}

// Per-frame cost breakdown (wall ms), filled by driver_frame each frame;
// the overrun probe against the 16.6 ms budget.
frame_ms_session: f32
frame_ms_view: f32
frame_ms_render: f32
frame_ns_t0: i64 // raw ns since epoch, for external span cross-checks
frame_ns_t3: i64

// The co-evolution session stepped in-frame (evolve.odin).
session: Evo_Session

// Top-bar state for this driver.
hud: Hud_Data

// Transport state (the controls strip drives these): pause freezes the
// session + viewer; viewer_speed = physics ticks per frame (1/frame at
// 60 Hz = wall-clock real-time; the default).
sim_paused := false
viewer_speed := 1

// "Re-seed cars" gate: while > 0, snapshots with generation below it are
// the OLD lineage (a rollout that finished after the click) and are
// dropped. 0 = no re-seed in flight.
reseed_min_gen := 0

// Score-panel hold text while no cars are on screen ("" = not held).
hold_reason := ""

// Displayed "gen" = session gen − gen_base. A car re-seed restarts the
// panel's generation counter at the re-rolled generation.
gen_base := 0

// Active windowed view: 0 = concurrent pack (whole generation, all cars at
// once), 1 = serial solo (whole generation, one car at a time). Both views
// replay the same shared generation (solo.last), so a toggle never surfaces
// a different set of cars. Default = serial solo (1).
view_mode := 1

// Fast-forward toggle (the "evolve in background" control): OFF = in-sync
// (the session runs at most one generation ahead of the displayed pack,
// pausing while a snapshot is buffered); ON = the session runs freely and
// the views take the newest offered generation at each transition.
bg_evolve := false

// A shared link boots the app ON the shared car alone: a population-1
// session pinned to the car's recorded env (terrain seed + finish line),
// GA NOT stepped (the car is shown, not evolved), opened frozen at the
// sharer's frame. The showcase always resolves into a live evolution: the
// die-glyph warm start, on demand or automatically when the car's pinned
// run ends.
showcase_mode := false
showcase_car: Car_Link // the imported car + its env + the sharer's frame
// The open-at-tick fast-forward debt: ticks still owed to the solo before
// the freeze (0 = none / done). Spent on the first frame the car is live.
showcase_ff_owed := 0

// A shared link's tick can exceed any real car's life (the liveness gates
// end a rollout in a few thousand sim ticks); bound the one-shot catch-up
// so a pathological link cannot freeze the first frame for minutes. A car
// alive past this point is an anomaly - the freeze lands at the cap.
SHOWCASE_FF_CAP :: 20000

// Snap the camera to the canonical orbit (default angles/distance, target
// exactly on the car, +1 m) - no follow-damping history, so the framing
// carries no pre-freeze motion.
snap_canonical_orbit :: proc(p: [3]f32) {
	cam.azimuth = CAMERA_AZIMUTH
	cam.elevation = CAMERA_ELEVATION
	cam.distance = CAMERA_DISTANCE
	cam.target = {p[0], p[1] + 1.0, p[2]}
}

// Open the showcase frozen at the sharer's frame: on the first frame the
// imported car is live, fast-forward it the owed ticks (the same physics a
// GA rollout would run) and freeze, with the camera snapped to the canonical
// orbit. A car that ends mid-catch-up (the link's tick past its life)
// freezes at its terminal row instead.
showcase_open_frozen :: proc() {
	if !showcase_mode || showcase_ff_owed <= 0 {
		showcase_ff_owed = 0
		return
	}
	if view_mode != 1 || !solo_is_ready() || !solo.active {
		return // the car is not live yet - retry next frame
	}
	n := showcase_ff_owed
	if n > SHOWCASE_FF_CAP {n = SHOWCASE_FF_CAP}
	for _ in 0 ..< n {
		if !solo.active {break}
		solo_step(TIME_STEP)
	}
	showcase_ff_owed = 0
	sim_paused = true
	if solo.active {
		if p, ok := solo_lead_pos(); ok {
			snap_canonical_orbit(p)
		}
	}
}

// Share-popup freeze (the wasm DOM overlay, opened by the share button):
// while it is open the app freezes EVERYTHING (every consumer respects
// sim_paused), so pausing on the open edge is a full freeze; the pre-popup
// pause state is restored on the close edge. Native: the apphost shim's
// popup is always closed.
share_open_prev := false
share_prev_paused := false

// "Evolve from here" (the showcase's die glyph): a full population from the
// imported car on its pinned env. The head opens the new lineage at index 0
// (session_warm_start re-indexes it to 1), the rest random; the views drop
// the single-car showcase snapshot (the reseed_min_gen gate) and take the
// fresh population provisionally.
showcase_evolve_from_here :: proc() {
	n := len(session.slots)
	cfg := session.cfg
	cfg.pop = DEFAULT_EVO_POP
	cfg.elite = DEFAULT_EVO_ELITE
	// The pinned env: the warm start races the SHARED world (session_init
	// re-reads terrain_seed + init_line into the frontier).
	cfg.terrain_seed = session.cur.env.seed
	cfg.init_line = session.cur.env.line
	head := showcase_car.genes
	session_warm_start(&session, &cfg, n, &head)
	showcase_mode = false
	reseed_min_gen = session.cur.index
	gen_base = reseed_min_gen
	solo_clear_pending()
	if pop_viewer_is_ready() {pop_viewer_destroy()}
	if solo_is_ready() {solo_destroy()}
	pop_viewer_reset_record()
	hold_reason = "evolving..."
}

// Both shells, once: the driver's camera.
init_driver :: proc() {
	cam = init_camera()
}

// Step the session within this frame's budget. Fast-forward ON → the
// session runs freely (the pending slot tracks the newest generation,
// last-write-wins, and the view takes it at the next transition). OFF →
// in-sync: the session is at most ONE generation ahead of the display, and
// only while the active view is CONSUMING it: the next gen's eval overlaps
// the current run, and the view takes the completed snapshot at its end
// with no hold. The cap is the single pending slot (an offer is blocked
// while one is buffered, so a second next gen is unreachable) plus the gate
// below: one boundary past the buffered snapshot, the session pauses again
// until the view consumes. Holding also pauses. Paused (SPACE) → no ticks.
//
// A completed generation's recorded results are final: adopt them into the
// views' copy of it (adopt_completed_gen - the solo's rows must match the
// record, bit for bit), then offer the freshly-breed next generation from
// its genes alone (offer_provisional).
step_session :: proc(tick_budget: int) -> (Gen_Event, bool) {
	if sim_paused || !session.running {return Gen_Event{}, false}
	if showcase_mode {
		// Showcase: the GA is NOT stepped (the car is shown, not evolved  - 
		// its env is pinned, the population must not breed itself away);
		// the offer alone hands the car to the views.
		offer_provisional()
		return Gen_Event{}, false
	}
	if !bg_evolve && solo_has_pending() {
		consuming :=
			(view_mode == 1 && solo_is_ready()) || (view_mode == 0 && pop_viewer_is_ready())
		if !consuming || session.cur.index > solo.pending.index {
			return Gen_Event{}, false
		}
	}
	// The pacing scale sheds the background GA first (it is the larger CPU
	// consumer and the least visible); a floor keeps the evolution moving.
	ticks := int(f32(tick_budget) * pacing_scale)
	if ticks < 4 {ticks = 4}
	ev, done := session_step(&session, ticks)
	if done && ev.gen >= reseed_min_gen {
		adopt_completed_gen(ev.gen)
	}
	offer_provisional()
	return ev, done
}

// A generation just completed its eval (session_step consumed the boundary
// and already bred the next): the recorded results for `gen` are final.
// The views' copy of it - pending (not walked yet) or solo.last (being
// walked) - is completed in place; the solo's finalized rows are asserted
// equal to the record (the live determinism gate; the remaining rows are
// checked as they finalize). Old lineage is never adopted (the caller
// gates on reseed_min_gen).
adopt_completed_gen :: proc(gen: int) {
	if solo_has_pending() && solo.pending.index == gen && !solo.pending.complete {
		solo_snapshot_complete(&solo.pending, &session.cur)
	} else if len(solo.last.pop) > 0 && solo.last.index == gen && !solo.last.complete {
		solo_adopt_results(&session.cur)
	}
}

// Offer the generation whose genes exist now to the views - at init, after
// a re-seed, and at every boundary (the freshly-breed gen): BOTH views
// begin a generation from its genes alone (the solo walks it one car at a
// time; the pack races the whole population in index order), so a re-seed
// shows cars immediately instead of holding through the full eval. One
// pending slot, mode-dependent: IN-SYNC (FF off) an already-buffered
// snapshot holds the slot (the pacing cap); FF (background) is
// LAST-WRITE-WINS (a newer offer displaces the stale pending, so the
// view's next round starts at the newest generation reached). A stale
// offer never displaces a newer one (within a lineage session.cur.index
// only climbs; re-seeds gate on reseed_min_gen).
offer_provisional :: proc() {
	if !session.running {return}
	if session.cur.index < reseed_min_gen {return}
	if solo_has_pending() {
		if !bg_evolve {return}
		if solo.pending.index >= session.cur.index {return}
	}
	if len(solo.last.pop) > 0 && solo.last.index >= session.cur.index {return}
	solo_push(build_solo_provisional(&session.cur))
}

// The active view finished the current generation (or the user skipped):
// take the next shared snapshot into solo.last and rebuild the active view
// from it. BOTH views build from a snapshot at EITHER stage - provisional
// (genes alone) or complete - so neither holds for the eval. Old lineage
// (a re-seed in flight) is dropped: the hold stays up until the re-rolled
// population's snapshot arrives. Returns true if a new generation was built.
view_advance :: proc() -> bool {
	snap, ok := take_next_snapshot()
	if !ok {return false}
	if view_mode == 1 {
		solo_build()
		return true
	}
	pack_build_from_solo(snap)
	return true
}

// The snapshot gate shared by view_advance and the pack's two-phase
// handoff: pop the pending snapshot into solo.last, dropping old lineage
// (a re-seed in flight) while the hold stays up. Returns solo.last while
// it holds the next generation, or false to keep waiting.
take_next_snapshot :: proc() -> (^Generation, bool) {
	if !solo_try_pop() {return nil, false}
	if solo.last.index < reseed_min_gen {
		free_generation_copy(&solo.last)
		solo.last = Generation{} // old lineage (post-reseed): drop
		return nil, false
	}
	reseed_min_gen = 0
	hold_reason = ""
	return &solo.last, true
}

// The newly-active view (view toggle) replays the SAME current generation
// (solo.last) - never a different one - so toggling never surfaces a
// different set of cars, at either snapshot stage. A no-op until the first
// generation has loaded (or while a re-seed is still owed its new lineage).
view_replay :: proc() {
	if len(solo.last.pop) == 0 || solo.last.index < reseed_min_gen {return}
	if view_mode == 1 {
		solo_build()
	} else {
		pack_build_from_solo(&solo.last)
	}
}

// The env the VISIBLE terrain + the displayed generation's rollouts race:
// the displayed generation's OWN env (its pinned `Generation.env`), not the
// live frontier - a mid-walk env change must not reshape the track under a
// running car, so the mesh keeps the walked env until the next generation
// (the change becomes visible at the transition). Idle scene → the frontier
// is what is shown.
displayed_env :: proc() -> Env {
	if view_mode == 0 && pop_viewer_is_ready() {
		// The handoff's one-frame terrain lag: the pack just flipped to a
		// new env; the mesh keeps the old env's one more render frame so
		// the flip frame does not also rebuild it.
		if pop_viewer.terrain_hold_active {return pop_viewer.terrain_hold}
		return pop_viewer.last.env
	}
	if view_mode == 1 && solo_is_ready() {
		return solo.last.env
	}
	return env
}

// HUD data for the driver (Evo_Session → Hud_Data); `show_pack` fills the
// panel from the pack view, otherwise from the solo per-run grid.
hud_fill :: proc(hud: ^Hud_Data, show_pack: bool) {
	shown_gen := session.cur.index
	if len(solo.last.pop) > 0 {shown_gen = solo.last.index}
	next_gen := session.cur.index
	if solo_has_pending() {next_gen = solo.pending.index}
	hud.prog = Evo_Progress {
		generation      = max(0, shown_gen - gen_base),
		next_generation = max(0, next_gen - gen_base),
		best_fitness    = session.best_fit,
		// The frontier (in-frame: env and cur.env are mirrored in the same
		// thread).
		target_len      = session.cur.env.line,
		running         = session.running,
		bg_evolve       = bg_evolve,
	}
	hud.paused = sim_paused
	hud.ff = bg_evolve
	hud.speed = viewer_speed
	hud.view = view_mode
	hud.showcase = showcase_mode
	ready := false
	if show_pack {
		pop_viewer_fill_cars(hud)
		ready = pop_viewer_is_ready()
	} else {
		solo_fill_cars(hud)
		ready = solo_is_ready()
	}
	hud.hold = ""
	if !ready {
		if hold_reason != "" {
			hud.hold = hold_reason
		} else {
			hud.hold = "next generation..."
		}
	}
}

// Consume the controls strip' request flags (the strip only sets them).
handle_controls :: proc(hud: ^Hud_Data) {
	if hud.toggle_pause {
		sim_paused = !sim_paused
		hud.toggle_pause = false
	}
	if hud.restart {
		// Re-run the active view's current generation from its start. The
		// panel's "best" record resets with the run - it is otherwise
		// evolution-scoped (a new generation does NOT clear it).
		pop_viewer_reset_record()
		if view_mode == 1 && solo_is_ready() {
			solo_build()
		} else {
			pop_viewer_restart()
		}
		hud.restart = false
	}
	if hud.reseed_track {
		// New track. Displayed rows must match the GA record (the
		// determinism contract), so the terrain change invalidates the
		// in-flight eval: the session re-runs its current generation on
		// the new profile (session_invalidate_eval), a pending snapshot
		// that already carries a record is dropped, and the on-screen
		// generation is re-walked while its eval is still in flight  - 
		// once its record has been adopted it belongs to the old terrain,
		// so the walk stops and the next generation, evaluated fresh,
		// takes the view.
		// Re-roll the frontier's seed (the line is untouched - the track
		// only extends at a boundary) and materialize the profile.
		env.seed = next_reseed_seed()
		profile_for(env.seed)
		if session.running {session_invalidate_eval(&session)}
		if solo_has_pending() && solo.pending.complete {solo_clear_pending()}
		// The surviving pending snapshot's record is re-scored on the new
		// terrain (its eval was reset above) - repin it so the mesh gate
		// (displayed_env) rebuilds on the new ground at once.
		if solo_has_pending() {solo.pending.env.seed = env.seed}
		rewalk :=
			len(solo.last.pop) > 0 &&
			!solo.last.complete &&
			session.running &&
			solo.last.index == session.cur.index
		// Only the RE-WALKED generation is repinned to the new seed: its
		// record is re-scored fresh and its cars spawn on the new profile.
		// A COMPLETE snapshot keeps the seed its record was scored on - any
		// later re-walk of it (view toggle / restart) must race ITS OWN
		// terrain, or the rows would assert against the old-terrain record.
		if rewalk {
			solo.last.env.seed = env.seed
			if pop_viewer_is_ready() {pop_viewer.last.env.seed = env.seed}
		}
		if view_mode == 1 {
			if solo_is_ready() {
				if rewalk {solo_build()} else {solo_destroy()}
			}
		} else {
			if pop_viewer_is_ready() {
				if rewalk {pop_viewer_restart()} else {pop_viewer_destroy()}
			}
		}
		pop_viewer_reset_record()
		hud.reseed_track = false
	}
	if hud.reseed_cars {
		// Fresh random population: re-roll in place (the current terrain is
		// kept - Track is a separate control). The gen counter keeps
		// counting, so the re-rolled population is evaluated as the NEXT
		// generation; old-lineage rollouts finishing after the click are
		// dropped via reseed_min_gen. The re-rolled genes exist immediately,
		// so the next frame's offer_provisional starts the active view on
		// them (the hold clears in 1–2 frames in BOTH views: the pack's
		// index-order lineup needs no ranking).
		reseed_min_gen = session.cur.index + 1
		gen_base = reseed_min_gen // the panel's gen counter restarts here
		session_reseed(&session, next_reseed_seed())
		// Both views are showing the OLD lineage: clear their pending
		// snapshots + active worlds so a view toggle can't surface stale
		// cars.
		solo_clear_pending()
		if pop_viewer_is_ready() {pop_viewer_destroy()}
		if solo_is_ready() {solo_destroy()}
		pop_viewer_reset_record()
		hold_reason = "re-seeding cars..."
		hud.reseed_cars = false
	}
	if hud.view_requested {
		view_mode = 1 - view_mode
		hold_reason = ""
		hud.view_requested = false
		// The newly-active view replays the SAME current generation.
		view_replay()
	}
	if hud.evolve_from_here {
		hud.evolve_from_here = false
		// The showcase's die glyph: a full population from the shared car
		// on its pinned env (the showcase ends - the GA takes over).
		if showcase_mode {
			showcase_evolve_from_here()
		}
	}
	if hud.ff_requested {
		bg_evolve = hud.ff
		hud.ff_requested = false
	}
	if hud.skip_requested {
		// Skip to the next unit of the active view. Solo: run the current
		// car to its natural terminal now (finish_now - the row MUST be
		// stamped from a natural finish: a mid-run kill stamps a partial
		// row that trips the determinism assert) and start the next car  - 
		// or, on the last car, let the next frame's step branch take the
		// pending next generation. Pack: destroy the race and consume the
		// next snapshot (the in-sync session is always 1 gen ahead).
		// Paused, the next unit waits for the pause to lift.
		hud.skip_requested = false
		if view_mode == 1 {
			if solo.active {solo.finish_now = true}
		} else {
			if pop_viewer_is_ready() {
				pop_viewer_destroy()
				view_advance()
			}
		}
	}
	viewer_speed = hud.speed
}

// Step the active view (N ticks/frame at speed; 0 when paused); a finished
// generation takes the next shared snapshot (or holds).
step_active_view :: proc() {
	frame_dt := f32(1.0 / 60.0)
	if view_mode == 1 {
		// ── Serial solo: one car at a time, index order. ──
		// The solo and the pack share ONE current generation (solo.last);
		// the finish takes the latest pending snapshot, so with Fast-forward
		// ON the solo fast-forwards through skipped generations.
		if solo_is_ready() {
			// "Next" mid-run (finish_now): the row must be stamped from a
			// natural finish (the determinism gate), so the car is run to
			// its terminal NOW. The stall check caps any run; the 4096
			// per-frame bound is a backstop for a pathological crawl (the
			// flag persists until the car ends), and a pause still holds
			// the step. The boost ends the moment
			// the owed car ends (finish_now clears in solo_step, which
			// spawns its successor) - otherwise the budget would bleed
			// into the next car's run in the same frame, and one click
			// would silently skip several cars.
			steps := sim_paused ? 0 : viewer_speed
			fast := solo.finish_now && !sim_paused
			if fast {steps = 4096}
			for _ in 0 ..< steps {
				if !solo_step(frame_dt) {
					if showcase_mode {
						// The shared car's pinned run is over: the showcase
						// resolves into a live evolution - the die-glyph
						// warm start, automatic.
						showcase_evolve_from_here()
					} else {
						view_advance()
					}
					break
				}
				if fast && !solo.finish_now {break}
			}
		} else {
			view_advance()
		}
		if solo_is_ready() {hold_reason = ""}
	} else {
		// ── Concurrent pack: the FULL population of the SAME generation, lockstep. ──
		if pop_viewer.handoff {
			// Two-phase generation handoff (the stutter fix): the finished
			// pack stays on screen frozen while the next generation's cars
			// are staged a few per frame, then the buffers flip.
			pack_handoff_step()
		} else if pop_viewer_is_ready() {
			steps := sim_paused ? 0 : viewer_speed
			for _ in 0 ..< steps {
				if !pop_viewer_step(frame_dt) {
					if showcase_mode {
						// Same as the solo path: the showcase's run is over
						// (P is the pack view's only showcase entrance  - 
						// the strip hides the toggle there).
						showcase_evolve_from_here()
					} else {
						// Race over: begin the handoff - keep the dead pack
						// on screen, retrying each frame until the next
						// snapshot is offered. No same-frame destroy +
						// build. The dead pack's own generation is never
						// re-staged (allow_current = false).
						pack_handoff_begin(false)
					}
					break
				}
			}
		} else {
			// Idle (boot / rebuild): stage the pack through the two-phase
			// handoff - the first pack costs a few ms per frame instead of
			// one ~120 ms frame. The source is the shared current generation
			// (solo.last) or the next pending snapshot; the pack never
			// starts a generation the solo has not seen.
			pack_handoff_begin(true)
		}
		// The staged teardown of the previous pack (a few worlds per frame)
		// runs on every pack frame, paused or not - it only frees the
		// off-screen old pack's resources.
		pack_teardown_step()
		if pop_viewer_is_ready() {hold_reason = ""}
	}
}

render_active_view :: proc() {
	if view_mode == 0 && pop_viewer_is_ready() {
		render_pop_viewer(&cam)
	} else if view_mode == 1 && solo_is_ready() {
		render_solo(&cam)
	} else {
		render_scene(&cam)
	}
}

// One frame of the shared driver. The shells wrap this with their own
// hooks (native: telemetry; wasm: the ?pause=N freeze) and draw the UI
// overlay last.
driver_frame :: proc(tick_budget: int) -> (Gen_Event, bool) {
	t0 := time.now()
	ev, done := step_session(tick_budget)
	t1 := time.now()
	feed_ui_input()
	hud_fill(&hud, view_mode == 0)
	build_ui(&hud)
	handle_controls(&hud)
	// Share handoff (wasm JS overlay; the shims no-op native): the glyph
	// opens the popup (the JS side sets __odm_share_open synchronously in
	// the post), and a tile tap re-posts the tapped car's hero image.
	if hud.share_requested {
		hud.share_requested = false
		share_open_popup()
	}
	if ci := host.Debug_Share_Car(); ci >= 0 && ci < share_tile_n {
		share_post_hero(ci)
	}
	// The share popup's full freeze - read AFTER handle_controls, so a
	// popup opened this frame freezes this frame's step_active_view too:
	// the shared tick (captured at the open) IS the displayed frame.
	// Close edge restores the pre-popup pause state.
	share_open := host.Debug_Share_Open()
	if share_open && !share_open_prev {
		share_prev_paused = sim_paused
		sim_paused = true
	} else if !share_open && share_open_prev {
		sim_paused = share_prev_paused
	}
	share_open_prev = share_open
	step_active_view()
	t2 := time.now()
	render_active_view()
	frame_ms_session = f32(time.duration_milliseconds(time.since(t0)))
	frame_ms_view = f32(time.duration_milliseconds(time.since(t1)))
	frame_ms_render = f32(time.duration_milliseconds(time.since(t2)))
	t3 := time.now()
	frame_ns_t0 = t0._nsec
	frame_ns_t3 = t3._nsec
	pace_update(frame_ms_session + frame_ms_view + frame_ms_render)
	return ev, done
}

// The callback bodies shared by both shells' proc "c" callbacks: the
// callbacks are the sokol registration hooks (one pair per target) and stay
// in their shell, where they set the runtime context first, then call these.

// The render-init sequence: renderer, then the overlay + UI on top of it.
driver_render_init :: proc() {
	init_render()
	init_overlay()
	init_ui()
}

// The render-cleanup teardown order: the viewers (their worlds) and the
// session (its slot worlds) go before the renderer; the overlay's handles
// live in the renderer's sokol_gfx instance, and close_render calls
// Shutdown_Renderer → sg_shutdown - so the overlay must go first, or its
// sg_destroy_* calls fault on the already-freed pools.
driver_render_cleanup :: proc() {
	pop_viewer_cleanup()
	solo_cleanup()
	session_destroy(&session)
	shutdown_overlay()
	close_render()
}

// Mouse move: refresh the UI hover, then orbit while a drag is down. The
// share-open guard is a no-op native (the apphost shim's popup is always
// closed there).
driver_mouse_move :: proc(dx, dy: f32) {
	mx, my := host.Get_Mouse_Pos()
	ui_mouse_x = i32(mx)
	ui_mouse_y = i32(my)
	if left_down && !mouse_over_ui() && !host.Debug_Share_Open() {
		update_camera_orbit(&cam, dx, dy, 0.0)
	}
}

// Mouse scroll: UI wheel over the strip, else camera zoom (the share-open
// guard above applies too).
driver_mouse_scroll :: proc(dy: f32) {
	if mouse_over_ui() {
		ui_scroll_delta = i32(dy) * 30
	} else if !host.Debug_Share_Open() {
		update_camera_orbit(&cam, 0.0, 0.0, dy)
	}
}

// The button switch: left = drag latch + UI press, right = UI press only.
driver_button_event :: proc(button: i32, pressed: i32) {
	is_down := pressed == 1
	mx, my := host.Get_Mouse_Pos()
	ui_mouse_x = i32(mx)
	ui_mouse_y = i32(my)
	switch button {
	case host.MOUSE_BUTTON_LEFT:
		left_down = is_down
		if is_down {ui_mouse_down(.LEFT)} else {ui_mouse_up(.LEFT)}
	case host.MOUSE_BUTTON_RIGHT:
		if is_down {ui_mouse_down(.RIGHT)} else {ui_mouse_up(.RIGHT)}
	case:
	}
}
