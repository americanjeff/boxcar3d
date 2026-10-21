#+build !wasm32
// The GA's CLI tools + test harness (dispatched from main_native.odin): the
// worker-pool eval (the only OS threads in the app - the windowed session
// steps in-frame through the shared driver, loop.odin), `evalone`,
// `sharelink`, and evolvetest. The thread-free core is in evolve.odin (both
// targets compile it); the windowed app uses no code from this file. The GA
// loop (run_generations) writes nothing to disk - genome save/load
// round-trips are exercised by `smoke`.


package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import b3 "engine:physics"

// ─── Multithreaded population eval (worker pool) ───────────────────────
// Box3D's world pool holds at most B3_MAX_WORLDS concurrent worlds (the
// vendor constant). Each worker owns one world per rollout; create/destroy
// go through init_sim_pose/destroy_sim (which serialize on
// box3d_world_mutex), while World_Step on distinct worlds is safe in
// parallel.
B3_MAX_WORLDS :: 128


// Resolve the worker count: clamp cfg_workers to [1, min(pop, B3_MAX_WORLDS)]
// (0 → auto = one worker per population member).
resolve_workers :: proc(cfg_workers, pop: int) -> int {
	n := cfg_workers
	if n <= 0 {n = pop}
	if n > pop {n = pop}
	if n > B3_MAX_WORLDS {n = B3_MAX_WORLDS}
	if n < 1 {n = 1}
	return n
}


// Per-worker context: all workers draw indices from one shared atomic counter
// (w.next). Each worker owns one rollout slot at a time.
Worker_Ctx :: struct {
	pop:     []Genes,
	next:    ^int, // SHARED work index (atomic) into pop
	gen:     int, // for the tel CSV names
	tel_dir: string, // "" → off
	env:     Env, // the generation's world (seed + line, captured before the workers start)
	fits:    []f64,
	res:     []Eval_Result,
}


worker_proc :: proc(t: ^thread.Thread) {
	context = runtime.default_context()
	w := (^Worker_Ctx)(t.data)
	for {
		idx := sync.atomic_add(w.next, 1)
		if idx >= len(w.pop) {break}
		// One worker-local slot per rollout, no shared rollout state.
		slot := Rollout_Slot{}
		slot_start(&slot, &w.pop[idx], w.tel_dir, w.gen, idx, w.env)
		for {
			if !slot_tick(&slot) {break}
		}
		res := Eval_Result{}
		slot_finish(&slot, &res)
		w.fits[idx] = res.fitness
		w.res[idx] = res
	}
}


// Threaded population eval: n_workers threads cooperatively consume the
// population via a shared atomic index. fits[i] is written to a disjoint
// index, so no mutex is needed on the fitness array. Determinism is
// independent of n_workers (each candidate's rollout is deterministic; the
// breeding RNG runs post-eval).
eval_population_threaded :: proc(
	pop: []Genes,
	n_workers: int,
	gen: int,
	tel_dir: string,
	fits: []f64,
	res: []Eval_Result,
) {
	assert(len(pop) == len(fits) && len(pop) == len(res))

	shared_next := 0
	ctxs := make([]Worker_Ctx, n_workers)
	for i in 0 ..< n_workers {
		ctxs[i] = Worker_Ctx {
			pop     = pop,
			next    = &shared_next,
			gen     = gen,
			tel_dir = tel_dir,
			// The loop pins the global env to this generation's world
			// (seed + line) before calling us, and it is fixed for the
			// whole generation - the workers capture it instead of
			// reading the global mid-run.
			env     = env,
			fits    = fits,
			res     = res,
		}
	}

	threads := make([]^thread.Thread, n_workers)
	for i in 0 ..< n_workers {
		th := thread.create(worker_proc)
		th.data = &ctxs[i]
		th.user_index = i
		threads[i] = th
	}
	for th in threads {thread.start(th)}
	for th in threads {thread.destroy(th)}
	delete(threads)
}


// The world a fresh (non-resumed) run races in gen 0: the cfg-derived
// terrain seed + the adaptive start line - the same value session_init pins
// for the windowed session's gen 0.
run_cfg_env :: proc(cfg: Evo_Config) -> Env {
	return Env{seed = evo_terrain_seed(cfg), line = math.min(TARGET_START_LEN, env_max_len)}
}


// The single implementation of the GA loop (used by the evolvetest gate).
// Seeds pop[0] from `seed_from` when non-nil; nil → an all-random population.
// The rest of the population is always random. Gen 0 races `start_env`;
// later generations keep that ground (mutable floor re-rolls it) and extend
// the line. Then runs `gens` generations of eval → select (elite +
// tournament) → crossover → mutate (gens <= 0 → unlimited, until
// interrupted). Returns the per-generation best fitness (one entry per
// completed gen) - with elitism + deterministic eval this is
// non-decreasing, which the test asserts. Writes nothing to disk.
run_generations :: proc(
	cfg: Evo_Config,
	seed_from: ^Genes,
	start_env: Env,
	gens: int, // <= 0 → unlimited
) -> [dynamic]f64 {
	rng := rng_init(cfg.seed)
	n_workers := resolve_workers(cfg.workers, cfg.pop)

	pop := make([]Genes, cfg.pop)
	defer delete(pop)
	if seed_from != nil {
		pop[0] = seed_from^
	} else {
		pop[0] = random_genes(&rng)
	}
	for i in 1 ..< cfg.pop {pop[i] = random_genes(&rng)}
	fits := make([]f64, cfg.pop)
	defer delete(fits)
	res := make([]Eval_Result, cfg.pop)
	defer delete(res)

	bests := make([dynamic]f64, 0, 0)
	run_best_m := f64(0.0)

	for gen := 0;; gen += 1 {
		if gens > 0 && gen >= gens {break}
		// The world this generation races (the Env contract): gen 0 is
		// the START env - the run config's world for a fresh run, the
		// warm-start artifact's world for a resumed one; mutable floor
		// re-rolls the seed per gen from gen 1 on.
		if gen == 0 {
			regenerate_terrain(start_env.seed)
		} else if cfg.mutable_floor {
			regenerate_terrain(evo_terrain_seed(cfg) + u64(gen))
		}
		// Finish line for this generation (the start env's line for gen 0;
		// extends to 2× the ratcheted running best when the record
		// reaches it, capped at the terrain's reach). The line is the
		// rollout terminal - rollouts score distance and run to it or a
		// failure.
		if gen == 0 {
			set_line(start_env.line)
		} else {
			set_line(adapt_track_len(run_best_m, env))
		}
		if n_workers <= 1 {
			eval_population(pop[:], gen, cfg.tel_dir, fits[:], res[:])
		} else {
			eval_population_threaded(pop[:], n_workers, gen, cfg.tel_dir, fits[:], res[:])
		}

		// Gen boundary: rank first (the driver work below uses the
		// evaluated generation), breed last - shared with the session.
		ev := gen_report(fits[:])
		append(&bests, ev.best)
		// Advance the ratcheted best (metres from the spawn) for the next
		// generation's finish line.
		for r in res[:] {
			// Still this generation's line (the next set_line runs
			// next loop).
			m := rollout_score_m(r.best_x, env.line)
			if m > run_best_m {run_best_m = m}
		}
		fmt.printfln(
			"gen {}  line={:.0f}m  best={:.2f}  mean={:.2f}",
			gen,
			env.line,
			ev.best,
			ev.mean,
		)
		log_flip_events(gen, res[:])
		log_break_events(gen, res[:])
		if cfg.tel_dir != "" {
			tel_write_summary(cfg.tel_dir, gen, res[:])
		}

		gen_breed(&rng, cfg, &pop, fits[:])
	}
	return bests
}


// run_evalone: one genome against ONE pinned Env, run to its terminal  - 
// the end-to-end proof of the pure-function property (the same invocation
// twice prints identical numbers). Pins the Env from its arguments and
// spawns through the shared slot pipeline (slot_start/slot_tick/slot_finish
// - the same path the GA's rollouts take, per the Env contract in
// driving.odin).
//
//   boxcar3d evalone <genome> [terrain_seed] [line] [tel]
//     terrain_seed  0 (default) → evo_terrain_seed of the default config
//     line          0 (default) → the current env's line (200 m at boot)
//     tel           telemetry dir ("" = off)
run_evalone :: proc(args: []string) -> int {
	if len(args) < 1 {
		fmt.eprintfln("usage: boxcar3d evalone <genome> [terrain_seed] [line] [tel]")
		return 2
	}
	path := args[0]
	seed := u64(0)
	line := f32(0)
	tel_dir := ""
	if len(args) >= 2 {seed, _ = parse_u64(args[1])}
	if len(args) >= 3 {line, _ = parse_f32(args[2])}
	if len(args) >= 4 {tel_dir = args[3]}

	genes, meta, ok := load_genome(path)
	if !ok {
		fmt.eprintfln("evalone: could not load genome {}", path)
		return 1
	}
	e := Env {
		seed = seed,
		line = line,
	}
	if e.seed == 0 {e.seed = evo_terrain_seed(default_evo_config())}
	if e.line == 0 {e.line = env.line}

	slot := Rollout_Slot{}
	slot_start(&slot, &genes, tel_dir, 0, 0, e)
	for {
		if !slot_tick(&slot) {break}
	}
	res := Eval_Result{}
	slot_finish(&slot, &res)
	fmt.printfln(
		"evalone: {} gen={}  env seed=0x{:x} line={:.0f}m  fitness={:.4f}  time={:.2f}s  outcome={}",
		path,
		meta.gen,
		e.seed,
		e.line,
		res.fitness,
		f64(res.fail_time),
		outcome_name(res.outcome),
	)
	return 0
}


// Share-link CLI (the native twin of the in-game share button): a saved
// genome + its recorded run env (legacy files with no env fall back to the
// fixed default track) → a fragment-only URL that boots a showcase session
// on the same car, same track. Prints the URL (and the bare fragment with
// --frag) so it can be piped or pasted.
run_sharelink :: proc(args: []string) -> int {
	path := ""
	tick := u64(0)
	frag_only := false
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch a {
		case "--tick":
			if i + 1 < len(args) {
				t, _ := parse_u64(args[i + 1])
				tick = t
				i += 1
			}
		case "--frag":
			frag_only = true
		case:
			if path == "" {path = a}
		}
	}
	if path == "" {
		fmt.eprintfln("usage: boxcar3d sharelink <file.genome> [--tick N] [--frag]")
		return 2
	}
	genes, meta, ok := load_genome(path)
	if !ok {
		fmt.eprintfln("sharelink: could not load genome {}", path)
		return 1
	}
	env := Env {
		seed = TERRAIN_DEFAULT_SEED,
		line = math.min(TARGET_START_LEN, env_max_len),
	}
	if meta.env_seed != 0 {
		env.seed = meta.env_seed
		env.line = meta.env_line
	} else {
		fmt.eprintfln("sharelink: {} has no recorded env - using the default track", path)
	}
	frag := car_link_encode(Car_Link {
		genes = genes,
		env   = env,
		tick  = u32(tick),
	})
	out := frag
	if !frag_only {
		full := strings.concatenate({SHARELINK_BASE_URL, frag})
		delete(out)
		out = full
	}
	fmt.printfln(out)
	return 0
}

// ─── Evolvetest helpers ───────────────────────────────────────────────
// A decoded Genome and its source must produce the same Body_Model phenotype.
// Compare the fields the phenotype depends on: the width profile (ring
// order), chassis density, wheel count, each wheel's mount position + radius
// + density + z_half, and the face count.
body_model_equiv :: proc(a, b: ^Body_Model) -> bool {
	for i in 0 ..< N_WIDTHS {
		if a.heights[i] != b.heights[i] {return false}
	}
	if a.chassis_density != b.chassis_density {return false}
	if len(a.wheels) != len(b.wheels) {return false}
	if len(a.tris) != len(b.tris) {return false}
	for i in 0 ..< len(a.wheels) {
		wa, wb := a.wheels[i], b.wheels[i]
		if wa.pos[0] != wb.pos[0] ||
		   wa.pos[1] != wb.pos[1] ||
		   wa.pos[2] != wb.pos[2] {return false}
		if wa.radius != wb.radius {return false}
		if wa.density != wb.density {return false}
		if wa.z_half != wb.z_half {return false}
	}
	return true
}

// Case 21 helper: 0 when the phenotype skipped exactly the degenerate
// wedges - recomputed independently from the decoded positions (long chord
// with a tiny center→chord distance, OR a 180°+ angular span), not via the
// predicate under test. A mismatch is either a ring-ordering drift (segment
// k's flag vs ring edge k) or a threshold divergence.
fan_skip_errors :: proc(g: ^Genome, bm: ^Body_Model) -> int {
	ring := sorted_ring(g)
	errs := 0
	for k in 0 ..< 8 {
		a := ring[k]
		b := ring[(k + 1) % 8]
		dx := a[0] - b[0]
		dy := a[1] - b[1]
		L := math.sqrt(dx * dx + dy * dy)
		gap := math.atan2(b[1], b[0]) - math.atan2(a[1], a[0])
		if gap < 0 {gap += 2.0 * math.PI}
		wide := gap >= math.PI
		cross := math.abs(a[0] * b[1] - a[1] * b[0])
		ra := math.sqrt(a[0] * a[0] + a[1] * a[1])
		rb := math.sqrt(b[0] * b[0] + b[1] * b[1])
		thin := L > FAN_SHORT_LO && cross / L < fan_floor(math.max(ra, rb))
		if bm.degenerate[k] != (thin || wide) {errs += 1}
	}
	return errs
}

// Case-21 reseed-car fixture: the genome drawn at index 3 after 9 reseed
// clicks (next_reseed_seed advanced 9 times, then 4 car draws) - the
// needle-wedge car behind the degenerate-wedge skip rules.
case21_reseed_car :: proc() -> Genes {
	// u64-wrap: the seed is 9 reseed clicks through next_reseed_seed
	// (counter × constant mod 2^64).
	clicks := u64(9)
	rng := rng_init(clicks * 0x9e37_79b9_7f4a_7c15)
	g := Genes{}
	for _ in 0 ..< 4 {g = random_genes(&rng)}
	return g
}

// Gate-case teardown: reset the windowed view state (solo + pack) and the
// global session so each case starts from a clean slate.
teardown_gate_session :: proc() {
	solo_cleanup()
	pop_viewer_destroy()
	session_destroy(&session)
}


run_evolve_test :: proc(fast: bool) -> int {
	// 1. Round-trip: fixed → genes → decoded must reproduce the fixed body.
	fixed := fixed_genome()
	defer destroy_genome(&fixed)
	fixed_body := genome_to_body(&fixed)
	defer destroy_body_model(&fixed_body)

	genes := encode_genome(&fixed)
	decoded := decode_genes(&genes)
	defer destroy_genome(&decoded)
	decoded_body := genome_to_body(&decoded)
	defer destroy_body_model(&decoded_body)

	if !body_model_equiv(&fixed_body, &decoded_body) {
		fmt.eprintfln("evolvetest: round-trip mismatch (fixed vs decoded body)")
		return 1
	}

	// Vector round-trip too (the GA's working representation).
	vec := make([]f64, GENE_DIM)
	defer delete(vec)
	genes_to_vector(&genes, vec[:])
	back := Genes{}
	vector_to_genes(vec[:], &back)
	back_genome := decode_genes(&back)
	back_body := genome_to_body(&back_genome)
	defer destroy_genome(&back_genome)
	if !body_model_equiv(&fixed_body, &back_body) {
		fmt.eprintfln("evolvetest: vector round-trip mismatch")
		return 1
	}
	destroy_body_model(&back_body)

	// 2. Drive: the decoded fixed car simulates under the fixed PID without
	//    NaN. (Completion is NOT asserted: the PID stalls at the crest for the
	//    fixed M1 geometry - the evolve gate is on the population, not the
	//    seed.)
	{
		wps := generate_course()
		sx, sz, yaw := spawn_pose(0.0)
		sim := init_sim_pose(&decoded, wps, sx, sz, yaw, env)
		sim.goal = len(wps) - 1
		for {
			pid_drive_car(&sim, PID_COEFF)
			step_sim(&sim)
			if sim.failed || sim.finished || sim.sim_time >= DEFAULT_TIME_LIMIT {break}
		}
		prog := progress(&sim)
		if prog != prog {
			fmt.eprintfln("evolvetest: decoded car left NaN (prog={})", prog)
			destroy_sim(&sim)
			return 1
		}
		fmt.printfln(
			"evolvetest: decoded fixed car finite (progress={:.2f}, failed={})",
			prog,
			sim.failed,
		)
		destroy_sim(&sim)
	}

	// 2b. Slot-preserving elitism: the survivors keep their slot verbatim,
	//     so the solo's index order is a stable car identity - NOT a fitness
	//     sort.
	{
		lrng := rng_init(0xbe0)
		lpop := [6]Genes{}
		for i in 0 ..< 6 {lpop[i] = random_genes(&lrng)}
		lfits := [6]f64{5, 1, 1, 100, 2, 3} // lpop[3] best, lpop[0] 2nd
		cfg := default_evo_config()
		cfg.elite = 2
		lrng2 := rng_init(0xcafe)
		lnext := breed_next(cfg, lpop[:], lfits[:], &lrng2)
		// The two survivors keep their slots verbatim:
		if lnext[3] != lpop[3] || lnext[0] != lpop[0] {
			fmt.eprintfln(
				"evolvetest: slot-preserving elitism broken (survivor not kept at its slot)",
			)
			delete(lnext)
			return 1
		}
		// And the best is NOT front-loaded to index 0:
		if lnext[0] == lpop[3] {
			fmt.eprintfln("evolvetest: breed_next front-loaded the winner (elite-first layout)")
			delete(lnext)
			return 1
		}
		delete(lnext)
		fmt.printfln(
			"evolvetest: slot-preserving elitism (survivors keep their slot, best not front-loaded)",
		)
	}

	// 2d. Unified views: the pack IS the SAME population the solo
	//     shows - the whole generation in INDEX order (car i = index i), so
	//     toggling views never surfaces a different set of cars. The
	//     fitnesses are deliberately NON-MONOTONIC: index order must NOT
	//     collapse to best-first. A provisional snapshot (genes only, zero
	//     fitnesses) builds identically - the lineup needs no ranking.
	{
		un := 20
		upop := make([]Genes, un)
		ufits := make([]f64, un)
		ures := make([]Eval_Result, un)
		ur := rng_init(0x21a)
		for i in 0 ..< un {
			upop[i] = random_genes(&ur)
			ufits[i] = f64((i * 7) % un + 1) // non-monotonic: index order != best-first
		}
		src := Generation {
			index = 0,
			env = Env{seed = env.seed, line = env.line},
			pop = upop[:],
			fits = ufits[:],
			res = ures[:],
		}
		par := build_solo_snapshot(&src)
		pack_build_from_solo(&par)
		ok := pop_viewer.n == un
		if ok {
			for i in 0 ..< un {
				if pop_viewer.cars[i].genes != upop[i] {
					ok = false
					break
				}
			}
		}
		if !ok {
			fmt.eprintfln(
				"evolvetest: pack != solo population in index order (n={})",
				pop_viewer.n,
			)
			pop_viewer_destroy()
			free_generation_copy(&par)
			delete(upop)
			delete(ufits)
			delete(ures)
			return 1
		}
		pop_viewer_destroy()
		free_generation_copy(&par)
		pro := build_solo_provisional(&src)
		pack_build_from_solo(&pro)
		if pop_viewer.n != un {
			fmt.eprintfln("evolvetest: provisional pack did not build (n={})", pop_viewer.n)
			pop_viewer_destroy()
			free_generation_copy(&pro)
			delete(upop)
			delete(ufits)
			delete(ures)
			return 1
		}
		pop_viewer_destroy()
		free_generation_copy(&pro)
		delete(upop)
		delete(ufits)
		delete(ures)
		fmt.printfln(
			"evolvetest: unified views (pack == solo population, index order, provisional too)",
		)
	}

	// 2e. Liveness gate (the unified end conditions): pure liveness_update,
	//     no physics (grounded is passed explicitly, so only the window
	//     under test can fire). The rate floor: the ratchet must gain
	//     PROGRESS_MIN_V · NO_PROGRESS_TIME metres per window to reset.
	{
		// (route through a runtime variable - Odin's const evaluator can't do an
		// f32→int cast at compile time)
		nop_win_f := NO_PROGRESS_TIME / TIME_STEP
		nop_win_steps := int(nop_win_f)
		// (a) Shuffles in place: oscillates between two x's, never gaining
		//     the rate-floor budget, so the no-progress window fires.
		sh := Sim_State{}
		sh.stall_best_x = S_SPAWN_X + 0.5
		sh.progress_base_x = S_SPAWN_X + 0.5
		stalled_step := -1
		for i := 0; i < 2 * nop_win_steps; i += 1 {
			x := S_SPAWN_X + 0.5
			if i % 2 == 0 {x = S_SPAWN_X + 0.3}
			liveness_update(&sh, [3]f32{x, 0.0, 0.0}, true)
			if sh.stalled {
				stalled_step = i
				break
			}
		}
		if !sh.stalled || sh.no_progress <= NO_PROGRESS_TIME || stalled_step < nop_win_steps {
			fmt.eprintfln(
				"evolvetest: no-progress window misfired (stalled={} step={} nop={})",
				sh.stalled,
				stalled_step,
				sh.no_progress,
			)
			return 1
		}
		// (b) Steady forward drive (3 m/s, far above the floor): the budget
		//     resets well inside every window, so no window fires.
		adv := Sim_State{}
		adv.stall_best_x = S_SPAWN_X
		adv.progress_base_x = S_SPAWN_X
		for i := 0; i < 2 * nop_win_steps; i += 1 {
			liveness_update(&adv, [3]f32{S_SPAWN_X + f32(i) * 0.05, 0.0, 0.0}, true)
		}
		if adv.stalled || adv.failed {
			fmt.eprintfln("evolvetest: a progressing car was failed (best_x={})", adv.stall_best_x)
			return 1
		}
		// (c) Out of ground contact while advancing: only the no-ground
		//     window can fire - the car must fail there, NOT as stalled.
		ng := Sim_State{}
		ng.stall_best_x = S_SPAWN_X
		ng.progress_base_x = S_SPAWN_X
		ng_win_f := NO_GROUND_TIME / TIME_STEP
		ng_win_steps := int(ng_win_f)
		ng_fail_step := -1
		for i := 0; i < 2 * ng_win_steps; i += 1 {
			liveness_update(&ng, [3]f32{S_SPAWN_X + f32(i) * 0.05, 0.0, 0.0}, false)
			if ng.failed {
				ng_fail_step = i
				break
			}
		}
		if !ng.failed ||
		   ng.stalled ||
		   ng.no_ground <= NO_GROUND_TIME ||
		   ng_fail_step < ng_win_steps {
			fmt.eprintfln(
				"evolvetest: no-ground window misfired (failed={} stalled={} step={} ng={})",
				ng.failed,
				ng.stalled,
				ng_fail_step,
				ng.no_ground,
			)
			return 1
		}
		// (d) The rate floor itself: a crawler BELOW PROGRESS_MIN_V sets a
		//     new max every step but never earns the per-window budget, so it
		//     must stall; one ABOVE the floor resets on schedule and survives.
		crawl_lo := f32(0.1) // m/s: 1.0 m per 10 s window < 2.5 m budget
		crawl_hi := f32(0.4) // m/s: 4.0 m per 10 s window > 2.5 m budget
		slow := Sim_State{}
		slow.stall_best_x = S_SPAWN_X
		slow.progress_base_x = S_SPAWN_X
		for i := 0; i < 2 * nop_win_steps; i += 1 {
			liveness_update(&slow, [3]f32{S_SPAWN_X + f32(i) * crawl_lo / 60.0, 0.0, 0.0}, true)
		}
		if !slow.stalled || !slow.failed {
			fmt.eprintfln(
				"evolvetest: a {:.2f} m/s crawler was not stalled (best_x={})",
				crawl_lo,
				slow.stall_best_x,
			)
			return 1
		}
		fast := Sim_State{}
		fast.stall_best_x = S_SPAWN_X
		fast.progress_base_x = S_SPAWN_X
		for i := 0; i < 2 * nop_win_steps; i += 1 {
			liveness_update(&fast, [3]f32{S_SPAWN_X + f32(i) * crawl_hi / 60.0, 0.0, 0.0}, true)
		}
		if fast.stalled || fast.failed {
			fmt.eprintfln(
				"evolvetest: a {:.2f} m/s crawler was stalled (best_x={})",
				crawl_hi,
				fast.stall_best_x,
			)
			return 1
		}
		// (e) The stillness window: a car pinned exactly still (in any
		//     direction) must stall at NO_MOVE_TIME; a lateral shuffler
		//     (real movement, zero x progress) must NOT fire it - the
		//     reference refreshes on every step and the no-progress window
		//     is its backstop.
		no_move_win_f := NO_MOVE_TIME / TIME_STEP
		no_move_win_steps := int(no_move_win_f)
		still := Sim_State{}
		still.stall_best_x = S_SPAWN_X
		still.progress_base_x = S_SPAWN_X
		still_fail_step := -1
		for i := 0; i < 2 * no_move_win_steps; i += 1 {
			liveness_update(&still, [3]f32{S_SPAWN_X, 0.0, 0.0}, true)
			if still.failed {
				still_fail_step = i
				break
			}
		}
		if !still.stalled ||
		   !still.failed ||
		   still.no_move <= NO_MOVE_TIME ||
		   still_fail_step < no_move_win_steps {
			fmt.eprintfln(
				"evolvetest: no-move window misfired (stalled={} step={} nm={})",
				still.stalled,
				still_fail_step,
				still.no_move,
			)
			return 1
		}
		shuf := Sim_State{}
		shuf.stall_best_x = S_SPAWN_X
		shuf.progress_base_x = S_SPAWN_X
		for i := 0; i < 2 * no_move_win_steps; i += 1 {
			z := f32(0.0)
			if i % 2 == 1 {z = 0.2}
			liveness_update(&shuf, [3]f32{S_SPAWN_X, 0.0, z}, true)
		}
		if shuf.stalled || shuf.failed || shuf.no_move > 0 {
			fmt.eprintfln(
				"evolvetest: a laterally shuffling car fired the no-move window (nm={})",
				shuf.no_move,
			)
			return 1
		}
		fmt.printfln(
			"evolvetest: liveness gate (no-ground window; stillness window; progress rate floor; ground/progress never fail)",
		)
	}

	// 3. Random sample builds: 16 random bodies must not NaN the solver, and
	//    the density genes must move the assembled mass across a real band
	//    (not collapse to the fixed-car value).
	rng := rng_init(0x7)
	mass_min, mass_max := f32(1e9), f32(-1e9)
	for i in 0 ..< 16 {
		rg := random_genes(&rng)
		rg_genome := decode_genes(&rg)
		wps := generate_course()
		sim := init_sim_pose(&rg_genome, wps, S_SPAWN_X, 0.0, 0.0, env)
		sim.goal = len(wps) - 1
		for _ in 0 ..< 10 {
			pid_drive_car(&sim, PID_COEFF)
			step_sim(&sim)
			if sim.failed {break}
		}
		p := b3.Body_GetPosition(sim.bot.chassis)
		if p[0] != p[0] || p[1] != p[1] || p[2] != p[2] {
			fmt.eprintfln("evolvetest: random body {} left chassis at NaN", i)
			destroy_sim(&sim)
			destroy_genome(&rg_genome)
			return 1
		}
		if sim.bot.total_mass < mass_min {mass_min = sim.bot.total_mass}
		if sim.bot.total_mass > mass_max {mass_max = sim.bot.total_mass}
		destroy_sim(&sim)
		destroy_genome(&rg_genome)
	}
	fmt.printfln(
		"evolvetest: random-sample total mass band {:.2f}–{:.2f} kg",
		mass_min,
		mass_max,
	)
	if mass_min <= 0.0 || mass_max > 1000.0 || mass_max / mass_min < 2.0 {
		fmt.eprintfln(
			"evolvetest: density genes did not spread mass (min={:.2f} max={:.2f})",
			mass_min,
			mass_max,
		)
		return 1
	}

	// 3b. Strut-axis gene: the axle_angle gene is now live (the strut axis).
	//     Cars with θ=0 (wheel hanging straight down) and θ=90° (wheel out to
	//     the side) must both build and drive without NaNing the solver.
	strut_thetas := [2]f32{0.0, math.PI / 2.0}
	for si in 0 ..< 2 {
		theta := strut_thetas[si]
		sg := fixed_genome()
		sg.wheels[0].axle_angle = theta
		sg.wheels[1].axle_angle = theta
		swps := generate_course()
		sim3 := init_sim_pose(&sg, swps, S_SPAWN_X, 0.0, 0.0, env)
		sim3.goal = len(swps) - 1
		for _ in 0 ..< 60 {
			pid_drive_car(&sim3, PID_COEFF)
			step_sim(&sim3)
			if sim3.failed {break}
		}
		p3 := b3.Body_GetPosition(sim3.bot.chassis)
		if p3[0] != p3[0] || p3[1] != p3[1] || p3[2] != p3[2] {
			fmt.eprintfln("evolvetest: strut θ={:.2f} left chassis at NaN", theta)
			destroy_sim(&sim3)
			destroy_genome(&sg)
			return 1
		}
		fmt.printfln("evolvetest: strut θ={:.2f} drives finite (t={:.1f})", theta, sim3.sim_time)
		destroy_sim(&sim3)
		destroy_genome(&sg)
	}

	// 3c. Mass-scaled spin torque: the per-wheel torque is total_mass ·
	//     mass_mult · g / n_on, giving mass_mult·g/r of aggregate wheel force
	//     (≈ 3 g at the fixed car's r = 0.5); capability stays neutralized
	//     with respect to the density/size genes.
	{
		f := fixed_genome()
		defer destroy_genome(&f)
		fbody := genome_to_body(&f)
		defer destroy_body_model(&fbody)
		fwps := generate_course()
		fsim := init_sim_pose(&f, fwps, S_SPAWN_X, 0.0, 0.0, env)
		w0 := fsim.bot.wheels[0]
		want := fsim.bot.total_mass * mass_mult * gravity / f32(2 * len(fsim.bot.wheels))
		if math.abs(w0.spin_torque - want) > 1e-3 {
			fmt.eprintfln(
				"evolvetest: spin torque not mass-scaled (got {:.2f}, want {:.2f})",
				w0.spin_torque,
				want,
			)
			destroy_sim(&fsim)
			return 1
		}
		n_phys := 2 * len(fsim.bot.wheels)
		force_g := f32(n_phys) * w0.spin_torque / w0.radius / (fsim.bot.total_mass * gravity)
		fmt.printfln(
			"evolvetest: torque {:.2f} N·m (m={:.2f} kg, r={:.2f}) ≈ {:.2f} g aggregate",
			w0.spin_torque,
			fsim.bot.total_mass,
			w0.radius,
			force_g,
		)
		if force_g < 2.8 || force_g > 3.2 {
			fmt.eprintfln(
				"evolvetest: aggregate wheel force {:.2f} g, want ≈3 g (mass_mult·g/r)",
				force_g,
			)
			destroy_sim(&fsim)
			return 1
		}
		destroy_sim(&fsim)
	}
	// Full-spin rollout on the flat spawn approach; returns max forward
	// velocity. `gm` is not mutated or owned.
	top_speed := proc(gm: ^Genome) -> f32 {
		wps := generate_course()
		sim := init_sim_pose(gm, wps, S_SPAWN_X, 0.0, 0.0, env)
		defer destroy_sim(&sim)
		max_v := f32(0.0)
		for _ in 0 ..< 300 {
			for w in sim.bot.wheels {
				set_wheel_spin_speed(w.joint_l, -SPIN_SPEED)
				set_wheel_spin_speed(w.joint_r, -SPIN_SPEED)
			}
			b3.World_Step(sim.world, TIME_STEP, SUB_STEPS)
			v := b3.Body_GetLinearVelocity(sim.bot.chassis)[0]
			if v > max_v {max_v = v}
		}
		return max_v
	}
	light := fixed_genome()
	light.chassis_density = CHASSIS_DENSITY_LO
	for &w in light.wheels {w.density = WHEEL_DENSITY_LO}
	heavy := fixed_genome()
	heavy.chassis_density = CHASSIS_DENSITY_HI
	for &w in heavy.wheels {w.density = WHEEL_DENSITY_HI}
	vl := top_speed(&light)
	vh := top_speed(&heavy)
	fmt.printfln("evolvetest: same-shape top speed light={:.2f} m/s heavy={:.2f} m/s", vl, vh)
	if vl <= 0.0 || vh <= 0.0 || vl / vh < 0.5 || vl / vh > 2.0 {
		fmt.eprintfln("evolvetest: mass scaling not neutral (light={:.2f} heavy={:.2f})", vl, vh)
		destroy_genome(&light)
		destroy_genome(&heavy)
		return 1
	}
	destroy_genome(&light)
	destroy_genome(&heavy)

	// 4. Tiny GA: elitism + deterministic eval ⇒ non-decreasing best per gen.
	//    (The genome save/load round-trip is covered by `smoke`.)
	test_cfg := default_evo_config()
	test_cfg.pop = 8
	test_cfg.elite = 1
	test_cfg.seed = 0x42
	test_seed := encode_genome(&fixed)
	bests := run_generations(test_cfg, &test_seed, run_cfg_env(test_cfg), 4)
	for i in 1 ..< len(bests) {
		if bests[i] + 1e-6 < bests[i - 1] {
			fmt.eprintfln(
				"evolvetest: best fitness decreased gen {}→{} ({:.4f}→{:.4f})",
				i - 1,
				i,
				bests[i - 1],
				bests[i],
			)
			delete(bests)
			return 1
		}
	}
	delete(bests)
	fmt.printfln("evolvetest: tiny GA bests non-decreasing")

	// 5. Determinism: auto workers (cfg1.workers = 0 → one per pop member)
	//    vs workers=4 give identical per-gen best (eval is order-
	//    independent; the breeding RNG runs sequentially).
	cfg1 := default_evo_config()
	cfg1.elite = 1
	cfg1.seed = 0x77
	b1 := run_generations(cfg1, &test_seed, run_cfg_env(cfg1), 3)
	cfg4 := cfg1
	cfg4.workers = 4
	b4 := run_generations(cfg4, &test_seed, run_cfg_env(cfg4), 3)
	for i in 0 ..< min(len(b1), len(b4)) {
		if b1[i] != b4[i] {
			fmt.eprintfln(
				"evolvetest: determinism broken at gen {} (auto={:.6f} w4={:.6f})",
				i,
				b1[i],
				b4[i],
			)
			delete(b1)
			delete(b4)
			return 1
		}
	}
	delete(b1)
	delete(b4)
	fmt.printfln("evolvetest: worker-count equivariance holds (auto == w4 best-per-gen)")

	// 6. Pop viewer: separate-worlds replay. Build a snapshot, build the
	//    viewer (one dedicated world per car, same spawn), step it, assert every
	//    car stays finite + the lead position resolves, then tear down.
	snap := Generation {
		index = 0,
		env = Env{seed = env.seed, line = env.line},
		pop = make([]Genes, 2, context.allocator),
	}
	snap.pop[0] = test_seed // the known-good fixed car (drives stably)
	snap.pop[1] = test_seed
	pop_viewer_build(&snap)
	for _ in 0 ..< 60 {
		if !pop_viewer_step(1.0 / 60.0) {break}
	}
	all_finite := true
	for i in 0 ..< pop_viewer.n {
		p := b3.Body_GetPosition(pop_viewer.cars[i].sim.bot.chassis)
		if p[0] != p[0] || p[1] != p[1] || p[2] != p[2] {all_finite = false}
	}
	_, lead_ok := pop_viewer_lead_pos()
	if !all_finite || !lead_ok {
		fmt.eprintfln(
			"evolvetest: pop_viewer NaN (finite={}) or no lead (lead_ok={})",
			all_finite,
			lead_ok,
		)
		pop_viewer_destroy()
		free_generation_copy(&snap)
		return 1
	}
	pop_viewer_destroy()
	free_generation_copy(&snap)
	fmt.printfln("evolvetest: pop_viewer separate worlds finite + lead resolves")

	// 7. Windowed lifecycle: the shared driver procs (step_session →
	//    solo_push → view_advance) over a short session - the in-frame
	//    windowed loop (app_frame's branch) without rendering. Verifies the
	//    snapshot hand-off (to the shared solo snapshot - the pack now
	//    derives from it), the in-sync pacing (the session pauses while a
	//    snapshot is buffered), and clean teardown.
	//    PROVISIONAL START: the first build must happen while the
	//    session is still evaluating the displayed generation (the view
	//    began from genes alone - session.cur.index == solo.last.index at
	//    build time). Rows the solo finalizes after the eval completes are
	//    asserted equal to the GA's records in-frame (solo_finish_car /
	//    solo_adopt_results) - a determinism mismatch crashes the test.
	{
		tc := default_evo_config()
		tc.pop = 4
		tc.elite = 1
		tc.seed = 0x9e
		session_init(&session, &tc, 2, nil)
		built := 0
		provisional := false
		for frames := 0; frames < 10000 && built < 2; frames += 1 {
			step_session(48)
			// Mirror the driver's step branch (loop.odin): a generation
			// completes when solo_step reports the last car done - solo_is_ready
			// only flips on destroy, so the advance rides the step return.
			if solo_is_ready() {
				gen_done := false
				// Display the car at the driver's speed (8 ticks/frame).
				for _ in 0 ..< 8 {
					if !solo_step(1.0 / 60.0) {
						gen_done = true
						break
					}
				}
				if gen_done {
					built += view_advance() ? 1 : 0
					if built > 0 && solo.last.index == session.cur.index {
						provisional = true // the session is still on this gen
					}
				}
			} else {
				built += view_advance() ? 1 : 0
				if built > 0 && solo.last.index == session.cur.index {
					provisional = true // the session is still on this gen
				}
			}
		}
		if built < 2 {
			solo_destroy()
			session_destroy(&session)
			fmt.eprintfln(
				"evolvetest: windowed in-frame session produced no generations (built={})",
				built,
			)
			return 1
		}
		if !provisional {
			solo_destroy()
			session_destroy(&session)
			fmt.eprintfln(
				"evolvetest: no provisional start (the view never began a gen before its eval completed)",
			)
			return 1
		}
		// RE-SEED: re-roll the
		// population mid-walk - the solo must be on the NEW lineage within a
		// couple of frames (provisional start from the re-rolled genes), not
		// after the new generation's full eval. Mirrors the window's
		// reseed_cars handler (handle_controls in loop.odin).
		reseed_min_gen = session.cur.index + 1
		gen_base = reseed_min_gen
		min_gen := reseed_min_gen
		session_reseed(&session, 0x5eed)
		solo_clear_pending()
		if pop_viewer_is_ready() {pop_viewer_destroy()}
		if solo_is_ready() {solo_destroy()}
		pop_viewer_reset_record()
		hold_reason = "re-seeding cars..."
		reseeded := false
		for frames := 0; frames < 8 && !reseeded; frames += 1 {
			step_session(48)
			if solo_is_ready() {
				for _ in 0 ..< 8 {
					if !solo_step(1.0 / 60.0) {
						view_advance()
						break
					}
				}
			} else {
				view_advance()
			}
			if solo_is_ready() && solo.gen >= min_gen {reseeded = true}
		}
		solo_destroy()
		session_destroy(&session)
		if !reseeded {
			fmt.eprintfln(
				"evolvetest: re-seed did not start the solo on the new lineage within 8 frames (gen={}, min={})",
				solo.gen,
				min_gen,
			)
			return 1
		}
		fmt.printfln(
			"evolvetest: windowed in-frame session + provisional start + re-seed OK (built={})",
			built,
		)
	}

	// 8. Windowed session config (main_native: default_evo_config): NO
	//    warm-start, ever - the windowed session never auto-loads (or
	//    auto-saves) genomes; it evolves from zero and never writes
	//    artifacts (the config's out_dir is unused on that path). The only
	//    warm-start today is headless `--warm-start`.
	{
		wc := default_evo_config()
		if wc.warm_start != "" {
			fmt.eprintfln("evolvetest: windowed config misconfigured (warm={})", wc.warm_start)
			return 1
		}
		fmt.printfln("evolvetest: windowed session config (all-random, no auto-load)")
	}

	// 14. Cross-driver determinism: the 4-worker pool and the cooperative
	//     session (3 slots, tick budget 7 - deliberately awkward
	//     scheduling) must produce the identical per-gen best sequence for
	//     the same seed. Scheduling is not part of a rollout.
	{
		cfg := default_evo_config()
		cfg.pop = 6
		cfg.seed = 0xd00d
		cfg.terrain_seed = 0x42
		cfg.workers = 4
		pool_bests := run_generations(cfg, nil, run_cfg_env(cfg), 3)
		coop_bests := run_session_coop(&cfg, 3, 7, nil, 3)
		match := len(pool_bests) == len(coop_bests)
		if match {
			for i in 0 ..< len(pool_bests) {
				if pool_bests[i] != coop_bests[i] {match = false}
			}
		}
		if match {
			fmt.printfln(
				"evolvetest: cross-driver determinism (pool 4w vs coop 3s x 7t, 3 gens, bests={})",
				coop_bests[:],
			)
		} else {
			fmt.eprintfln(
				"evolvetest: cross-driver MISMATCH pool={} coop={}",
				pool_bests[:],
				coop_bests[:],
			)
			return 1
		}
		delete(pool_bests)
		delete(coop_bests)
	}

	// 16. Windowed frame-budget cost: session_step at the driver's native
	//     budget (NATIVE_SLOTS × NATIVE_TICKS_PER_FRAME, loop_native.odin),
	//     measured in a headless frame loop over the default population.
	//     Print-only tuning readout - keep it well under one 60 fps frame
	//     (16.6 ms) when adjusting the budget; machine speed varies, so this
	//     is not a gate.
	{
		bcfg := default_evo_config()
		bcfg.seed = 0x4f4a
		bs := Evo_Session{}
		session_init(&bs, &bcfg, NATIVE_SLOTS, nil)
		nframes := 300
		t0 := time.now()
		for _ in 0 ..< nframes {
			session_step(&bs, NATIVE_TICKS_PER_FRAME)
		}
		ms_per_frame := time.duration_milliseconds(time.since(t0)) / f64(nframes)
		session_destroy(&bs)
		fmt.printfln(
			"evolvetest: windowed session_step ({} slots × {} ticks/frame, pop {}) = {:.2f} ms/frame",
			NATIVE_SLOTS,
			NATIVE_TICKS_PER_FRAME,
			bcfg.pop,
			ms_per_frame,
		)
	}

	// 17. Windowed PACK lifecycle: the pack starts PROVISIONAL  - 
	//     the whole population in index order needs no ranking, so it builds
	//     the generation the same frame it is offered, before its own eval
	//     has finished. Headless mirror of the driver's pack branch
	//     (loop.odin): build from solo.last at either stage, race, advance.
	//     The first build is checked to have happened while the session was
	//     still evaluating that generation (snapshot incomplete, session
	//     not bred past it) - the pack waited for nothing.
	{
		view_mode = 0
		teardown_gate_session()
		kc := default_evo_config()
		kc.pop = 4
		kc.elite = 1
		kc.seed = 0x77
		session_init(&session, &kc, 2, nil)
		races := 0
		first_gen := -1
		first_build_session_gen := -1
		first_build_complete := true
		for frames := 0; frames < 10000 && races < 2; frames += 1 {
			step_session(48)
			was_ready := pop_viewer_is_ready()
			if was_ready {
				for _ in 0 ..< 8 {
					if !pop_viewer_step(1.0 / 60.0) {
						races += 1 // the race just ended
						pop_viewer_destroy()
						view_advance()
						break
					}
				}
			} else {
				// The driver's pack idle branch: build from the shared
				// current generation at either snapshot stage; otherwise
				// consume the offered one into solo.last.
				if len(solo.last.pop) > 0 && solo.last.index >= reseed_min_gen {
					pack_build_from_solo(&solo.last)
				} else {
					view_advance()
				}
			}
			// The next pack can rebuild in the SAME frame the previous race
			// ends (no hold), so the build is captured here, not as a
			// cross-frame ready transition.
			if pop_viewer_is_ready() && !was_ready && first_gen < 0 {
				first_gen = pop_viewer.last.index
				first_build_session_gen = session.cur.index
				first_build_complete = solo.last.complete
			}
		}
		solo_cleanup()
		session_destroy(&session)
		if races < 2 {
			fmt.eprintfln("evolvetest: windowed pack produced no generations (races={})", races)
			return 1
		}
		if first_build_complete || first_build_session_gen != first_gen {
			fmt.eprintfln(
				"evolvetest: pack did not start gen {} provisionally (complete={}, session gen={})",
				first_gen,
				first_build_complete,
				first_build_session_gen,
			)
			view_mode = 1
			return 1
		}
		// (G) The in-sync pacing gate (loop.odin step_session): the session
		//     may eval the pending generation only WHILE the active view is
		//     consuming the current one; one boundary past the buffered
		//     snapshot it pauses again, and a holding view always pauses it.
		{
			teardown_gate_session()
			gc := default_evo_config()
			gc.pop = 4
			gc.elite = 1
			gc.seed = 0x77
			session_init(&session, &gc, 2, nil)
			// Run to the gen-0 boundary: fresh gen 1, nothing started.
			for i := 0; i < 20000 && session.cur.index < 1; i += 1 {
				_, done := session_step(&session, 48)
				if done {break}
			}
			if session.cur.index < 1 {
				fmt.eprintfln(
					"evolvetest: gate: gen 0 did not complete (gen={})",
					session.cur.index,
				)
				view_mode = 1
				return 1
			}
			// pending = the offered provisional gen 1; the session sits on
			// gen 1 with no car started.
			solo_push(build_solo_provisional(&session.cur))
			// (A) the pack "consuming" (ready) → the session may eval gen 1
			//     (a step must land: a car starts, or - for an
			//     all-instantly-failing pop - the whole gen completes).
			pop_viewer.ready = true
			gen_before := session.cur.index
			step_session(48)
			if session.cur.index == gen_before && session.cur.next == 0 {
				fmt.eprintfln(
					"evolvetest: gate (A): no eval while the pack races (gen={}, next={})",
					session.cur.index,
					session.cur.next,
				)
				view_mode = 1
				return 1
			}
			// (B) run to the gen-1 boundary: adopt completes the pending in
			//     place, the gen-2 offer is blocked (the pending slot is
			//     held), and one boundary past it the session must pause.
			for i := 0; i < 20000 && session.cur.index < 2; i += 1 {
				step_session(48)
			}
			if session.cur.index < 2 || !solo.pending.complete {
				fmt.eprintfln(
					"evolvetest: gate (B): gen 1 did not complete in place (gen={}, complete={})",
					session.cur.index,
					solo.pending.complete,
				)
				view_mode = 1
				return 1
			}
			step_session(48)
			if session.cur.next != 0 {
				fmt.eprintfln(
					"evolvetest: gate (B): session ran past the buffered snapshot (next={})",
					session.cur.next,
				)
				view_mode = 1
				return 1
			}
			// (C) the pack holding (not ready) → the session pauses.
			pop_viewer.ready = false
			step_session(48)
			if session.cur.next != 0 {
				fmt.eprintfln(
					"evolvetest: gate (C): session stepped while the pack holds (next={})",
					session.cur.next,
				)
				view_mode = 1
				return 1
			}
			teardown_gate_session()
		}
		view_mode = 1
		fmt.printfln(
			"evolvetest: windowed pack starts provisional + pacing gate (races={})",
			races,
		)
	}

	// 18. View-sequence gate: pack → solo → restart → next, driven through
	//     the REAL driver procs (handle_controls + step_active_view +
	//     step_session - driver_frame minus UI/render) with the browser's
	//     budget (4 slots × 48 ticks, pop 20). "Next" must run the solo's
	//     car to its natural terminal (finish_now) - every stamped row is a
	//     natural finish, never a partial row against a completed eval.
	//     The toggle is swept across session phases (mid-eval, post-
	//     boundary) so the click lands on a complete snapshot.
	if fast {
		fmt.printfln("evolvetest: case 18 (view sequence) skipped - fast tier")
	} else {
		sim_paused = false
		for toggle_frame := 10; toggle_frame < 600; toggle_frame += 50 {
			teardown_gate_session()
			vc := default_evo_config()
			vc.tel_dir = ""
			session_init(&session, &vc, 4, nil)
			view_mode = 0 // pack first, like the browser session
			hud = Hud_Data{}
			hud.speed = 2
			for frame := 0; frame < 3000; frame += 1 {
				step_session(48)
				if frame == toggle_frame {hud.view_requested = true}
				if frame == toggle_frame + 50 {hud.restart = true}
				if frame == toggle_frame + 100 {hud.skip_requested = true}
				handle_controls(&hud)
				step_active_view()
			}
			teardown_gate_session()
		}
		view_mode = 1
		fmt.printfln("evolvetest: view sequence (pack→solo→restart→next) OK")
	}

	// 19. Track re-seed determinism (the mid-generation re-seed hole): a
	//     terrain re-roll invalidates the current generation's eval - the
	//     session re-runs it from scratch on the new profile (cur.env
	//     re-pinned to the fresh frontier), a pending snapshot carrying an
	//     old-terrain record is dropped, and the generation on screen is
	//     re-walked (eval still in flight) or stopped (record already
	//     adopted). A stale record against a new-terrain display row trips
	//     the solo determinism assert (process crash = nonzero exit), so
	//     SURVIVING both re-seeds with evolution still progressing is the
	//     gate.
	if fast {
		fmt.printfln("evolvetest: case 19 (track reseed) skipped - fast tier")
	} else {
		sim_paused = false
		reseed_min_gen = 0
		teardown_gate_session()
		vc := default_evo_config()
		vc.pop = 4
		vc.tel_dir = ""
		session_init(&session, &vc, 2, nil)
		view_mode = 1
		hud = Hud_Data{}
		hud.speed = 2
		early, late := false, false
		for frame := 0; frame < 40000 && !(early && late); frame += 1 {
			step_session(48)
			// (A) re-seed EARLY in a walk: the on-screen generation's eval
			//     is still in flight -> the re-walk branch (both sides
			//     re-run on the new terrain).
			if !early && solo_is_ready() && !solo.last.complete {
				hud.reseed_track = true
				early = true
			}
			// (B) re-seed LATE in a walk: the on-screen record is adopted
			//     (complete) and the next generation is pending -> the
			//     stop-walk branch.
			if early && !late && solo_is_ready() && solo.last.complete && solo_has_pending() {
				hud.reseed_track = true
				late = true
			}
			handle_controls(&hud)
			// After the mid-walk re-seed (A), the in-flight re-eval races
			// the NEW ground: the session's current env mirrors the
			// frontier (fresh seed, same line) for the rest of the run.
			if early && session.cur.env.seed != env.seed {
				fmt.eprintfln(
					"evolvetest: track reseed: re-eval did not take the new ground (cur={} env={})",
					session.cur.env.seed,
					env.seed,
				)
				return 1
			}
			step_active_view()
		}
		if !early || !late {
			fmt.eprintfln(
				"evolvetest: track reseed: did not reach both re-seed states (early={} late={})",
				early,
				late,
			)
			return 1
		}
		// Run on: generations must keep completing after both re-seeds.
		gen_before := session.cur.index
		for frame := 0; frame < 20000; frame += 1 {
			step_session(48)
			handle_controls(&hud)
			step_active_view()
		}
		if session.cur.index <= gen_before {
			fmt.eprintfln(
				"evolvetest: track reseed: evolution stalled (gen={})",
				session.cur.index,
			)
			return 1
		}
		teardown_gate_session()
		view_mode = 1
		fmt.printfln("evolvetest: track reseed (early + late mid-walk) OK")
	}

	// 20. FF-mode determinism:
	//     (C) re-seeding the track while the pack races an ADOPTED
	//     generation must not re-pin that snapshot to the new seed - the
	//     later re-walk (view toggle) races the terrain its record was
	//     scored on, and every row must match.
	//     (D) rows stamped by a solo walk belong to that generation only:
	//     a generation adopted while the PACK is on screen must not assert
	//     the old rows against the new record.
	if fast {
		fmt.printfln("evolvetest: case 20 (ff re-seed) skipped - fast tier")
	} else {
		sim_paused = false
		reseed_min_gen = 0
		teardown_gate_session()
		vc := default_evo_config()
		vc.pop = 4
		vc.tel_dir = ""
		session_init(&session, &vc, 2, nil)
		hud = Hud_Data{}
		hud.speed = 2
		// (C) FF pack: drive until the pack races a generation whose record
		//     is adopted and the session has raced ahead.
		view_mode = 0
		bg_evolve = true
		reached := false
		for frame := 0; frame < 40000; frame += 1 {
			step_session(48)
			handle_controls(&hud)
			step_active_view()
			if pop_viewer_is_ready() && solo.last.complete && session.cur.index > solo.last.index {
				reached = true
				break
			}
		}
		if !reached {
			fmt.eprintfln(
				"evolvetest: ff reseed (C): ahead-state not reached (ready={} complete={} cur={} last={})",
				pop_viewer_is_ready(),
				solo.last.complete,
				session.cur.index,
				solo.last.index,
			)
			return 1
		}
		old_seed := env.seed
		hud.reseed_track = true
		handle_controls(&hud)
		// The adopted generation keeps the seed its record was scored on.
		if solo.last.env.seed != old_seed {
			fmt.eprintfln(
				"evolvetest: ff reseed (C): adopted gen env re-pinned ({} != {})",
				solo.last.env.seed,
				old_seed,
			)
			return 1
		}
		// Toggle to solo: the replay re-walks the adopted gen on its own
		// terrain; every finalized row asserts against its record.
		hud.view_requested = true
		for frame := 0; frame < 30000; frame += 1 {
			step_session(48)
			handle_controls(&hud)
			step_active_view()
		}
		// (D) foreign rows: stamp some rows in a solo walk, toggle to pack
		//     (replays the same generation), and let the pack's NEXT
		//     generation be adopted - the old rows must not be checked
		//     against the new record.
		view_mode = 1
		teardown_gate_session()
		vd := default_evo_config()
		vd.pop = 4
		vd.tel_dir = ""
		session_init(&session, &vd, 2, nil)
		hud = Hud_Data{}
		hud.speed = 2
		for frame := 0; frame < 20000 && solo.row_n == 0; frame += 1 {
			step_session(48)
			handle_controls(&hud)
			step_active_view()
		}
		if solo.row_n == 0 {
			fmt.eprintfln("evolvetest: ff reseed (D): no solo row stamped")
			return 1
		}
		rows_gen := solo.last.index
		hud.view_requested = true
		handle_controls(&hud) // pack, replaying the same generation
		for frame := 0; frame < 40000; frame += 1 {
			step_session(48)
			handle_controls(&hud)
			step_active_view()
			if solo.last.index > rows_gen && solo.last.complete {
				break
			}
		}
		if solo.last.index <= rows_gen || !solo.last.complete {
			fmt.eprintfln(
				"evolvetest: ff reseed (D): pack never adopted a newer gen (last={} rows_gen={})",
				solo.last.index,
				rows_gen,
			)
			return 1
		}
		bg_evolve = false
		teardown_gate_session()
		view_mode = 1
		fmt.printfln("evolvetest: ff re-seed keeps adopted env; foreign rows never assert")
	}

	// 21. Degenerate-wedge skip (fan_wedge_degenerate): two failure modes
	// the phenotype refuses to build (no hulls, no mesh, no mass). A PAPER
	// BLADE - a long ring edge whose fan triangle is thinner than its tip's
	// per-substep travel at the design tumble (fan_floor) - tunnels through
	// the heightfield instead of making a real contact. A WIDE GAP - an
	// edge whose 180°+ span leaves the fan center off the ring polygon  - 
	// makes the ring a bowtie: the wedge's fan triangle has reversed
	// winding over its neighbors', so the culler drops a body face at some
	// angles and the shadow pass lets light through. Gate: the skip
	// decision matches the rules exactly - 200 random draws, the 9-click
	// reseed car, a near-antipodal adversarial pair, a wide-gap car - plus
	// the reseed car's rollout (its degenerate segment carries wheel 0, so
	// a hull-less segment with a wheel must stay sane).
	{
		fan_n_check := 0
		fan_n_bad := 0
		// Nested procs don't capture locals - counters passed by pointer.
		fan_check :: proc(genes: ^Genes, n_check, n_bad: ^int) {
			fg := decode_genes(genes)
			fbm := genome_to_body(&fg)
			n_check^ += 1
			if e := fan_skip_errors(&fg, &fbm); e > 0 {
				n_bad^ += 1
				fmt.eprintfln(
					"evolvetest case 21: {} segment(s) with a wrong fan-skip decision",
					e,
				)
			}
			destroy_body_model(&fbm)
			destroy_genome(&fg)
		}
		// (a) 200 random draws.
		fan_rng := rng_init(0xF1A0)
		for _ in 0 ..< 200 {
			fan_genes := random_genes(&fan_rng)
			fan_check(&fan_genes, &fan_n_check, &fan_n_bad)
		}
		// (b) The 9-click reseed car (index 3).
		fan_genes := case21_reseed_car()
		fan_check(&fan_genes, &fan_n_check, &fan_n_bad)
		// (c) Adversarial near-antipodal pair: the chord passes within
		// ~2 cm of the center - the classic blade over a long chord.
		fan_adv := Genes{}
		fan_adv.vertices[0] = Vertex_Gene {
			angle     = 0.0,
			magnitude = 2.5,
		}
		fan_adv.vertices[1] = Vertex_Gene {
			angle     = f32(179.0 * math.PI / 180.0),
			magnitude = 2.5,
		}
		fan_adv.vertices[2] = Vertex_Gene {
			angle     = f32(220.0 * math.PI / 180.0),
			magnitude = 1.2,
		}
		fan_adv.vertices[3] = Vertex_Gene {
			angle     = f32(250.0 * math.PI / 180.0),
			magnitude = 1.0,
		}
		fan_adv.vertices[4] = Vertex_Gene {
			angle     = f32(280.0 * math.PI / 180.0),
			magnitude = 1.2,
		}
		fan_adv.vertices[5] = Vertex_Gene {
			angle     = f32(310.0 * math.PI / 180.0),
			magnitude = 1.5,
		}
		fan_adv.vertices[6] = Vertex_Gene {
			angle     = f32(330.0 * math.PI / 180.0),
			magnitude = 1.5,
		}
		fan_adv.vertices[7] = Vertex_Gene {
			angle     = f32(350.0 * math.PI / 180.0),
			magnitude = 2.0,
		}
		for fan_i in 0 ..< N_WHEELS {fan_adv.wheels[fan_i].vertex = -1}
		fan_check(&fan_adv, &fan_n_check, &fan_n_bad)
		// (c2) Wide-gap car: seven vertices within a 120° arc + one at 310°.
		// The closing edge spans 190° - the ring is a bowtie and the fan
		// center sits off the polygon, so exactly that one segment must be
		// skipped. Its chord is far from the center, so only the gap rule
		// fires (the blade floor does not).
		fan_wide := Genes{}
		for fan_i in 0 ..< 7 {
			fan_wide.vertices[fan_i] = Vertex_Gene {
				angle     = f32(fan_i) * 20.0 * math.PI / 180.0,
				magnitude = 1.0,
			}
		}
		fan_wide.vertices[7] = Vertex_Gene {
			angle     = f32(310.0 * math.PI / 180.0),
			magnitude = 2.0,
		}
		for fan_i in 0 ..< N_WHEELS {fan_wide.wheels[fan_i].vertex = -1}
		fan_check(&fan_wide, &fan_n_check, &fan_n_bad)
		{
			fw := decode_genes(&fan_wide)
			fwbm := genome_to_body(&fw)
			n_wide := 0
			for s in 0 ..< 8 {if fwbm.degenerate[s] {n_wide += 1}}
			if n_wide != 1 {
				fmt.eprintfln(
					"evolvetest case 21: wide-gap car skipped {} segments (want exactly 1)",
					n_wide,
				)
				return 1
			}
			destroy_body_model(&fwbm)
			destroy_genome(&fw)
		}
		// (d) The reseed car's rollout: both needle wedges are degenerate
		// and one of them carries wheel 0 - a hull-less segment WITH a
		// wheel. 900 ticks must stay finite and the car must actually move.
		{
			fan_car := case21_reseed_car()
			fslot := Rollout_Slot{}
			slot_start(&fslot, &fan_car, "", 0, 3, env)
			for _ in 0 ..< 900 {
				if !slot_tick(&fslot) {break}
			}
			fp := b3.Body_GetPosition(fslot.sim.bot.chassis)
			if fp[0] != fp[0] || fp[1] != fp[1] || fp[2] != fp[2] {
				fmt.eprintfln("evolvetest case 21: reseed car rollout left NaN (pos={})", fp)
				return 1
			}
			if fp[0] < S_SPAWN_X + 1.0 {
				fmt.eprintfln("evolvetest case 21: reseed car did not move (x={:.2f})", fp[0])
				return 1
			}
			fres := Eval_Result{}
			slot_finish(&fslot, &fres)
		}
		if fan_n_bad > 0 {
			fmt.eprintfln(
				"evolvetest case 21: {} of {} decoded genomes had a wrong fan-skip decision",
				fan_n_bad,
				fan_n_check,
			)
			return 1
		}
		fmt.printfln(
			"evolvetest: degenerate-wedge skip holds ({} genomes checked: 200 random, the 9-click reseed car, 1 adversarial, 1 wide-gap, reseed-car rollout)",
			fan_n_check,
		)
	}

	// 22. Adjacent-missing cap rule (cap_refresh_decision, the pure core of
	// refresh_car_caps): a cap's void flags freeze into the mesh at build
	// time, and breaks only ACCUMULATE (a missing segment never comes back),
	// so the viewer re-runs the decision on every break tick and each cap's
	// frozen flags must track the current missing set. Invariant: whenever
	// two ADJACENT wedges are missing, the shared-spoke quad is dropped on
	// BOTH sides - one side keeping it is a floating interior wall in the
	// merged pocket (a face from one side, an exposed backface culled from
	// the other). Gate: every missing mask
	// applied as a staggered break sequence in both ring orders, the
	// invariant checked after the full sequence.
	{
		stale_violations := 0
		for mask := 0; mask < 256; mask += 1 {
			final := [8]bool{}
			for s in 0 ..< 8 {final[s] = (mask & (1 << u32(s))) != 0}
			for dir := 0; dir < 2; dir += 1 {
				cf_flags := [8][2]bool{}
				cf_current := [8]bool{}
				for s := 0; s < 8; s += 1 {
					seg := s
					if dir == 1 {seg = 7 - s}
					if !final[seg] {continue}
					// The missing set after THIS segment's break: the run of
					// already-broken segments (the sequence is monotone).
					missing := [8]bool{}
					for k in 0 ..< 8 {
						if !final[k] {continue}
						if dir == 0 {
							if k <= seg {missing[k] = true}
						} else if k >= seg {missing[k] = true}
					}
					// refresh_car_caps runs the decision over ALL segments.
					for k in 0 ..< 8 {
						rebuild, now := cap_refresh_decision(missing, k, cf_current[k], cf_flags)
						if !rebuild {continue}
						cf_current[k] = !(now[0] && now[1])
						cf_flags[k] = now
					}
				}
				for s in 0 ..< 8 {
					prev := (s + 7) % 8
					if !final[prev] || !final[s] {continue}
					if !cf_flags[prev][1] || !cf_flags[s][0] {stale_violations += 1}
				}
			}
		}
		if stale_violations > 0 {
			fmt.eprintfln(
				"evolvetest case 22: {} adjacent-missing cap states kept a shared-spoke quad",
				stale_violations,
			)
			return 1
		}
		fmt.printfln(
			"evolvetest: adjacent-missing cap rule holds (256 masks × 2 staggered break orders)",
		)
	}

	if fast {
		fmt.printfln(
			"evolvetest: OK (fast tier - in-frame lifecycle cases 18/19/20 are the full-run gate)",
		)
	} else {
		fmt.printfln("evolvetest: OK")
	}
	return 0
}
