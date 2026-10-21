// GA core (both targets): the gene boundary (flat gene vector ↔ `Genome`), the
// classic body GA (selection/crossover/mutation), the steppable rollout slot
// + generational session (the wasm-split core), and the cooperative
// round-robin driver. Every car is driven by the fixed crafted PID
// (PID_COEFF) - the body evolves, the controller does not. The GA's CLI +
// test harness (headless CLI, worker-pool eval, evolvetest) live in
// evolve_cli.odin.
// NOTE: two-point crossover changed the seed→outcome mapping - expected;
// there are no golden outputs to match.

package main

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"

// ─── Gene bounds + dimension ──────────────────────────────────────────
// Headroom over the fixed car (mag ≤ 1.5, radius 0.5) so exploration can
// reach larger / heavier bodies without the decoder ever producing a
// NaN-able shape. All gene constraints are enforced at decode time (clamp,
// not penalize) so every candidate decodes to a buildable body.
MAX_MAG :: f32(3.0)
MAX_RADIUS :: f32(1.5) // wheel radius cap (RAD_LO is the floor)
N_VERTICES :: 8
// A wheel slot's vertex gene is -1 = disabled axle. Cars can thus have
// 0..max_axles axles (the generation-stage cap, default 3); a 0-axle car
// is stillborn by design (it stalls out).
WHEEL_PROB :: f32(0.5)
// 16 vertex + 24 wheel + 1 chassis density + 8 wheel densities + 9 widths
// = 58 (the wheel count tracks N_WHEELS).
// The density + width genes are appended at the vector END so older vectors
// keep their prefix stable.
GENE_DIM :: N_VERTICES * 2 + N_WHEELS * 3 + N_WHEELS + 1 + N_WIDTHS // 58
// Flat vector layout (genes_to_vector):
//   0-15   vertices (2 per vertex)
//   16-39  wheel triples (3 per wheel: vertex/axle/radius)
//   40     chassis density
//   41-48  wheel densities (1 per wheel)
//   49-57  widths (8 vertex + 1 center)
GENE_OFF_VERT :: 0
GENE_OFF_WHEEL :: N_VERTICES * 2
GENE_OFF_CHASSIS :: N_VERTICES * 2 + 3 * N_WHEELS
GENE_OFF_WHEEL_DENSITY :: GENE_OFF_CHASSIS + 1
GENE_OFF_WIDTH :: GENE_OFF_WHEEL_DENSITY + N_WHEELS
TAU :: f32(2.0 * math.PI)

// Per-gene ranges used by the decoder (clamps) and the GA (mutation step
// size + random seeding).
MAG_LO :: f32(0.05)
RAD_LO :: f32(0.1)
// Density gene ranges (Box3D kg/m³ - the 2-D kg/m² numbers do not
// transfer). The fixed-car values (0.5 / 12.0) sit interior; the span is
// ≈ 1/12×–2.5× around them, making relative mass an evolutionary axis.
CHASSIS_DENSITY_LO :: f32(0.05)
CHASSIS_DENSITY_HI :: f32(2.0)
WHEEL_DENSITY_LO :: f32(1.0)
WHEEL_DENSITY_HI :: f32(30.0)
// Width gene ranges (metres, lateral z half-widths): each genome vertex +
// the polygon center carries its own half-width (body_model.odin).
// WIDTH_HI = 2.0 m caps the envelope (full chassis width 4 m - the
// wheelbase coupling's theoretical max of 2·MAX_MAG is left off the
// table). WIDTH_LO keeps every hull tetrahedron off zero volume (5-cm
// floor - paper-thin but non-degenerate).
WIDTH_LO :: f32(0.05)
WIDTH_HI :: f32(2.0)
Vertex_Gene :: struct {
	angle:     f32, // radians, wrapped to [0, TAU)
	magnitude: f32, // distance from the center
}

Wheel_Gene :: struct {
	vertex:     int, // mount vertex index [0, N_VERTICES)
	axle_angle: f32, // axle orientation (radians)
	radius:     f32, // wheel radius (metres)
	density:    f32, // wheel density (kg/m³)
}

// 16 part-color slots: 0-7 = the 8 vertices, 8-15 = the 8 wheels.
// Stored on Genes (NOT Genome, NOT in the 58-f64 vector, NOT in genes_hash):
// the hash is the shape-identity dedup key - same shape, different paint is
// the same genome.
N_COLORS :: 16

Genes :: struct {
	vertices:        [N_VERTICES]Vertex_Gene,
	wheels:          [N_WHEELS]Wheel_Gene,
	chassis_density: f32, // chassis hull density (kg/m³)
	widths:          [N_WIDTHS]f32, // chassis half-widths (m); 0..7 = vertex, 8 = center
	colors:          [N_COLORS][3]u8,
}

// ─── Small deterministic PRNG (xorshift64*) ────────────────────────────
// Seeded once per run so the GA is fully deterministic given cfg.seed and the
// (fixed) eval order. Avoids core:math/rand global state.
Rng :: struct {
	state: u64,
}

rng_init :: proc(seed: u64) -> Rng {
	s := seed
	if s == 0 {s = 0x9a_b} 	// 0 is a degenerate xorshift state
	return Rng{state = s}
}

rng_u64 :: proc(r: ^Rng) -> u64 {
	s := r.state
	s ~= s >> 12
	s ~= s << 25
	s ~= s >> 27
	r.state = s
	return s * 0x2545_F491_4F6C_D_D1D
}

// Uniform in [0, 1).
rng_f32 :: proc(r: ^Rng) -> f32 {
	return f32(rng_u64(r) >> 40) * (1.0 / 16_777_216.0) // top 24 bits / 2^24
}

// Uniform in [lo, hi).
rng_range :: proc(r: ^Rng, lo, hi: f32) -> f32 {
	return lo + rng_f32(r) * (hi - lo)
}

// Approx standard normal (sum of 12 uniforms − 5.5, Irwin–Hall → ≈ N(0,1)).
rng_gauss :: proc(r: ^Rng) -> f32 {
	s := f32(0.0)
	for _ in 0 ..< 12 {s += rng_f32(r)}
	return s - 5.5
}

// ─── Gene ↔ Genome boundary ───────────────────────────────────────────
// Wrap an angle into [0, TAU) (mutation/crossover can push angles anywhere).
wrap_angle :: proc(a: f32) -> f32 {
	out := a
	for out >= TAU {out -= TAU}
	for out < 0.0 {out += TAU}
	return out
}

// decode_genes → Genome: the single place gene constraints are enforced.
// Every candidate decodes to a buildable body because the decoder clamps
// (and dedupes wheel mounts):
//	   1. magnitude → clamp [MAG_LO, MAX_MAG]; angle → wrap [0, TAU).
//	   2. radius → clamp [RAD_LO, MAX_RADIUS]; axle_angle → wrap.
//	   3. vertex → -1 stays disabled; valid → clamp [0, N_VERTICES-1].
//	   4. enabled wheels mount to distinct vertices (bump into a free one).
//	   5. densities → clamp to their [LO, HI] ranges.
//	   6. widths → clamp [WIDTH_LO, WIDTH_HI].
decode_genes :: proc(genes: ^Genes) -> Genome {
	widths := [N_WIDTHS]f32{}
	for i in 0 ..< N_WIDTHS {
		widths[i] = math.clamp(genes.widths[i], WIDTH_LO, WIDTH_HI)
	}
	g := Genome {
		wheels          = make([dynamic]Wheel_Def, 0, N_WHEELS),
		widths          = widths,
		chassis_density = math.clamp(
			genes.chassis_density,
			CHASSIS_DENSITY_LO,
			CHASSIS_DENSITY_HI,
		),
	}
	for i in 0 ..< N_VERTICES {
		v := genes.vertices[i]
		g.vertices[i].angle = wrap_angle(v.angle)
		g.vertices[i].magnitude = math.clamp(v.magnitude, MAG_LO, MAX_MAG)
	}
	for i in 0 ..< N_WHEELS {
		w := genes.wheels[i]
		vert := w.vertex
		if vert < 0 {vert = -1} 	// disabled slot
		if vert >= N_VERTICES {vert = N_VERTICES - 1}
		append(
			&g.wheels,
			Wheel_Def {
				vertex = vert,
				axle_angle = wrap_angle(w.axle_angle),
				radius = math.clamp(w.radius, RAD_LO, MAX_RADIUS),
				density = math.clamp(w.density, WHEEL_DENSITY_LO, WHEEL_DENSITY_HI),
			},
		)
	}
	// Enabled wheels mount to distinct vertices: bump a later slot into the
	// next free vertex (≤ N_WHEELS-1 prior wheels are taken, so one is free).
	for i in 1 ..< N_WHEELS {
		v := g.wheels[i].vertex
		if v < 0 {continue}
		for j in 0 ..< i {
			if g.wheels[j].vertex == v {
				for k := 0; k < N_VERTICES; k += 1 {
					v = (v + 1) % N_VERTICES
					free := true
					for h in 0 ..< i {
						if g.wheels[h].vertex == v {free = false}
					}
					if free {break}
				}
				break
			}
		}
		g.wheels[i].vertex = v
	}
	return g
}

// encode_genome → Genes: the inverse of decode. Reads the first N_WHEELS
// wheels; a missing slot encodes vertex = -1 (disabled) so the zero-value
// Genes stays consistent and the fixed 2-axle car round-trips without
// growing a 3rd axle. Exact for the fixed car (no loss).
encode_genome :: proc(g: ^Genome) -> Genes {
	genes := Genes{}
	for i in 0 ..< N_VERTICES {
		genes.vertices[i].angle = g.vertices[i].angle
		genes.vertices[i].magnitude = g.vertices[i].magnitude
	}
	for i in 0 ..< N_WIDTHS {
		genes.widths[i] = g.widths[i]
	}
	for i in 0 ..< N_WHEELS {
		if i < len(g.wheels) {
			genes.wheels[i].vertex = g.wheels[i].vertex
			genes.wheels[i].axle_angle = g.wheels[i].axle_angle
			genes.wheels[i].radius = g.wheels[i].radius
			genes.wheels[i].density = g.wheels[i].density
		} else {
			genes.wheels[i].vertex = -1
		}
	}
	genes.chassis_density = g.chassis_density
	return genes
}

// Flat f64 vector for GA crossover/mutation. Order:
//   v0.angle, v0.mag, …, v7.angle, v7.mag,
//   w0.vertex, w0.axle, w0.radius, w1.vertex, w1.axle, w1.radius,
//   chassis_density, w0.density, …, w7.density,
//   width0 (vertex 0), …, width7, width8 (center)
genes_to_vector :: proc(genes: ^Genes, out: []f64) {
	assert(len(out) == GENE_DIM)
	i := 0
	for v in genes.vertices {
		out[i] = f64(v.angle)
		out[i + 1] = f64(v.magnitude)
		i += 2
	}
	for w in genes.wheels {
		out[i] = f64(w.vertex)
		out[i + 1] = f64(w.axle_angle)
		out[i + 2] = f64(w.radius)
		i += 3
	}
	out[i] = f64(genes.chassis_density)
	i += 1
	for w in genes.wheels {
		out[i] = f64(w.density)
		i += 1
	}
	for x in genes.widths {
		out[i] = f64(x)
		i += 1
	}
}

vector_to_genes :: proc(v: []f64, out: ^Genes) {
	assert(len(v) == GENE_DIM)
	i := 0
	for k in 0 ..< N_VERTICES {
		out.vertices[k].angle = f32(v[i])
		out.vertices[k].magnitude = f32(v[i + 1])
		i += 2
	}
	for k in 0 ..< N_WHEELS {
		out.wheels[k].vertex = int(math.floor(v[i] + 0.5))
		out.wheels[k].axle_angle = f32(v[i + 1])
		out.wheels[k].radius = f32(v[i + 2])
		i += 3
	}
	out.chassis_density = f32(v[i])
	i += 1
	for k in 0 ..< N_WHEELS {
		out.wheels[k].density = f32(v[i])
		i += 1
	}
	for k in 0 ..< N_WIDTHS {
		out.widths[k] = f32(v[i])
		i += 1
	}
}

// genes_hash: a cheap fixed-width identity for a gene vector (the
// fitness-independent viewer colors). FNV-1a over the fields.
// FNV-1a fold of one f32: the sign is folded in so a bare magnitude does not
// identify ±values (2^24 scaling is the exact f32 mantissa).
fnv_f32 :: proc(h: u64, x: f32) -> u64 {
	o := h
	ax := x
	if ax < 0 {
		o += 0x9e3779b97f4a7c15
		ax = -ax
	}
	o += u64(ax * 16777216.0)
	o *= 0x100000001b3
	return o
}

genes_hash :: proc(g: ^Genes) -> u64 {
	h := u64(0xcbf29ce484222325)
	for v in g.vertices {
		h = fnv_f32(h, v.angle)
		h = fnv_f32(h, v.magnitude)
	}
	for w in g.wheels {
		h += u64(w.vertex + 2) // -1..7 → 1..9 (0 would be FNV's no-op)
		h *= 0x100000001b3
		h = fnv_f32(h, w.axle_angle)
		h = fnv_f32(h, w.radius)
		h = fnv_f32(h, w.density)
	}
	h = fnv_f32(h, g.chassis_density)
	for x in g.widths {
		h = fnv_f32(h, x)
	}
	return h
}

// max_axles: the cap on ENABLED wheel slots per car, enforced at the
// generation stage. N_WHEELS (8) is the genome's slot count; the cap keeps
// generation at the default 3 active slots. `--max-wheels N` overrides
// (clamped to 1..N_WHEELS).
max_axles := 3

// cap_axles: trim a genome down to the max_axles cap, disabling the
// highest-indexed enabled slots first (mutation re-enables and crossover
// can push a child past the cap).
cap_axles :: proc(g: ^Genes) {
	n := 0
	for i in 0 ..< N_WHEELS {
		if g.wheels[i].vertex >= 0 {n += 1}
	}
	for i := N_WHEELS - 1; i >= 0 && n > max_axles; i -= 1 {
		if g.wheels[i].vertex >= 0 {
			g.wheels[i].vertex = -1
			n -= 1
		}
	}
}

// random_genes: a uniform draw over the full exploration bounds (decode
// genes re-clamps at build time). Hull angles use normalized-cumulative
// weights (8 weights ~ U[0.05, 1.0], normalized so the octagon always winds
// the center exactly once - gaps ~30° ± 8°, no sliver hulls).
random_genes :: proc(r: ^Rng) -> Genes {
	g := Genes{}
	w := [N_VERTICES]f32{}
	s := f32(0.0)
	for i in 0 ..< N_VERTICES {
		w[i] = rng_range(r, 0.05, 1.0)
		s += w[i]
	}
	cum := f32(0.0)
	for i in 0 ..< N_VERTICES {
		cum += w[i] / s
		g.vertices[i].angle = cum * TAU
		g.vertices[i].magnitude = rng_range(r, MAG_LO, MAX_MAG)
	}
	// Wheel slots: pick max_axles random slots as the candidates (the rest
	// stay disabled), each candidate enabled with WHEEL_PROB; non-candidates
	// still draw axle/radius/density so a later re-enable mutation has live
	// genes.
	cand := [N_WHEELS]int{}
	for i in 0 ..< N_WHEELS {cand[i] = i}
	ncand := min(max_axles, N_WHEELS)
	for i := 0; i < ncand; i += 1 {
		j := i + int(rng_f32(r) * f32(N_WHEELS - i))
		cand[i], cand[j] = cand[j], cand[i]
	}
	for i in 0 ..< N_WHEELS {
		is_cand := false
		for k in 0 ..< ncand {
			if cand[k] == i {is_cand = true}
		}
		g.wheels[i].vertex =
			is_cand && rng_f32(r) < WHEEL_PROB ? int(rng_f32(r) * f32(N_VERTICES)) : -1
		g.wheels[i].axle_angle = rng_range(r, 0.0, TAU)
		g.wheels[i].radius = rng_range(r, RAD_LO, MAX_RADIUS)
		g.wheels[i].density = rng_range(r, WHEEL_DENSITY_LO, WHEEL_DENSITY_HI)
	}
	g.chassis_density = rng_range(r, CHASSIS_DENSITY_LO, CHASSIS_DENSITY_HI)
	// Width profile: uniform over the full exploration range.
	for i in 0 ..< N_WIDTHS {
		g.widths[i] = rng_range(r, WIDTH_LO, WIDTH_HI)
	}
	// One random RGB fills all 16 part-color slots.
	rgb := [3]u8{}
	for ch in 0 ..< 3 {rgb[ch] = u8(int(rng_f32(r) * 256))}
	for s in 0 ..< N_COLORS {g.colors[s] = rgb}
	return g
}

// ─── Config ───────────────────────────────────────────────────────
// Sentinel fitness
// progress (which is always > 0 from step 1) so argmax never picks it, and
// recognizable (below this floor) so it can be excluded from the pack mean.
FITNESS_NAN :: f64(-1e18)

Evo_Config :: struct {
	pop:           int,
	elite:         int, // carried over verbatim each gen
	mut_rate:      f32, // per-gene mutation probability
	mut_sigma:     f32, // gaussian std (fraction of gene range)
	seed:          u64,
	terrain_seed:  u64, // 0 → derive from seed (one fixed track per run)
	mutable_floor: bool, // fresh (seeded) track each generation (headless)
	workers:       int, // 0 → auto
	warm_start:    string, // "" → all-random. Reserved for an explicit
	// warm-start of the in-frame session; nothing sets it yet (the
	// windowed session never auto-loads a genome).
	tel_dir:       string, // "" → off; else per-rollout channel CSVs
	init_line:     f32, // 0 → the adaptive start (min(TARGET_START_LEN,
		// env_max_len)); >0 → pin gen 0's finish line to this (share-link
		// showcase + "evolve from here" - the car must race the line the
		// sharer raced, not a fresh TARGET_START_LEN).
}

DEFAULT_EVO_POP :: 20
DEFAULT_EVO_ELITE :: 2
// Mutation defaults: rate 5%; sigma = (hi-lo)/6 as a fraction of each gene's
// range (true Gaussian).
DEFAULT_EVO_MUT_RATE :: f32(0.05)
DEFAULT_EVO_MUT_SIGMA :: f32(1.0 / 6.0)
DEFAULT_EVO_SEED :: u64(0x9ab)
DEFAULT_EVO_WORKERS :: 0

default_evo_config :: proc() -> Evo_Config {
	return Evo_Config {
		pop = DEFAULT_EVO_POP,
		elite = DEFAULT_EVO_ELITE,
		mut_rate = DEFAULT_EVO_MUT_RATE,
		mut_sigma = DEFAULT_EVO_MUT_SIGMA,
		seed = DEFAULT_EVO_SEED,
		workers = DEFAULT_EVO_WORKERS,
	}
}

// The run's terrain seed: explicit (--terrain-seed / wasm ?terrain=) or
// derived from the GA seed so the whole run is deterministic from cfg.seed
// alone. One fixed track per run (the mutable floor is the opt-in).
evo_terrain_seed :: proc(cfg: Evo_Config) -> u64 {
	if cfg.terrain_seed != 0 {return cfg.terrain_seed}
	return cfg.seed ~ TERRAIN_SEED_SALT
}

// The windowed app's default track: the derived terrain (the track every
// windowed launch has shown). Pinned explicitly below regardless of the GA
// seed - the windowed GA seed defaults to the clock, and DERIVING the
// terrain from it would re-roll the ground every launch.
DEFAULT_WINDOW_TERRAIN_SEED :: DEFAULT_EVO_SEED ~ TERRAIN_SEED_SALT

// Windowed-session config (native window + wasm): the GA seed is the app's
// seed parameter (native --seed / wasm ?seed=), clock-derived when 0 - a
// fresh gen-0 population each launch instead of the fixed
// DEFAULT_EVO_SEED. The terrain keeps its fixed track unless the
// terrain-seed parameter (native --terrain-seed / wasm ?terrain=) is given.
windowed_evo_config :: proc(ga_seed, terrain_seed: u64) -> Evo_Config {
	cfg := default_evo_config()
	seed := ga_seed
	if seed == 0 {seed = u64(time.now()._nsec)}
	cfg.seed = seed
	cfg.terrain_seed = terrain_seed != 0 ? terrain_seed : DEFAULT_WINDOW_TERRAIN_SEED
	return cfg
}

// ─── Fitness: one deterministic rollout from the straight-on heading ─────
// Single rollout per candidate. No generation or time limits: every rollout
// is self-terminating - goal reached (the finish line), NaN, break cap, or
// the liveness gate (no ground contact for NO_GROUND_TIME, no movement in
// any direction for NO_MOVE_TIME, or no new max-x for NO_PROGRESS_TIME).
// NaN-safe: returns -1e18 when the rollout NaNs (would poison the mean /
// argmax).
// Terminal classification of a rollout.
Rollout_Outcome :: enum {
	Completed, // completed the course (goal waypoint)
	Stalled, // stalled out (pinned still for NO_MOVE_TIME, or no new max-x for NO_PROGRESS_TIME)
	OffTrack, // out of ground contact (airborne / off the map / past the line)
	NaN_, // solver blew up
}

outcome_name :: proc(o: Rollout_Outcome) -> string {
	switch o {
	case Rollout_Outcome.Completed:
		return "completed"
	case Rollout_Outcome.Stalled:
		return "stalled"
	case Rollout_Outcome.OffTrack:
		return "offtrack"
	case Rollout_Outcome.NaN_:
		return "nan"
	}
	return "nan"
}

// Per-car rollout result: fitness + flip log + terminal info. Threaded
// workers write disjoint indices (no sync). `fitness` alone drives
// selection; the rest is observability.
Eval_Result :: struct {
	fitness:      f64,
	outcome:      Rollout_Outcome,
	best_x:       f32,
	fail_time:    f32, // sim time at the terminal event
	flip_steps:   int, // steps with uy < FLIP_UP_T
	flip_events:  [FLIP_EVENT_CAP]Flip_Event, // entry events, first n_flips valid
	n_flips:      int,
	break_events: [BREAK_EVENT_CAP]Break_Event, // shed segments, first n_breaks valid
	n_breaks:     int,
	// Stability maxima (copied from Sim_State - see the stability log
	// comment there).
	max_speed:    f32, // max chassis speed (m/s)
	max_jump:     f32, // max per-step chassis displacement (m)
	max_height:   f32, // max chassis height above local terrain (m)
	max_impulse:  f32, // max chassis–terrain normal impulse (N·s)
}

// rollout_score_m: the GA score - metres driven from the spawn. The
// ratcheted best
// chassis x, so a car that bounces backwards still credits its farthest
// point. Finite by construction (the ratchet only accepts finite
// improvements); the NaN path is defensive for the selection code. Capped
// at the run's OWN finish line (`line`): a line clear scores exactly the
// line - the hard-x test in step_sim makes that the true value, not a slab
// short-landing. The line is a parameter, not the live env (the Env
// contract, driving.odin): a finishing car ratchets slightly past its line
// before the terminal fires, and a re-simulated row stamped after a
// boundary extension must cap at the line the GA evaluated against.
rollout_score_m :: proc(best_x: f32, line: f32) -> f64 {
	m := f64(best_x - S_SPAWN_X)
	if m != m {return FITNESS_NAN}
	if m < 0 {m = 0}
	if m > f64(line) {m = f64(line)}
	return m
}

// ─── Steppable rollout core (one core, two drivers) ────────────────────
// One in-flight rollout as explicit state: `slot_start` → `slot_tick`* →
// `slot_finish`. `slot_tick` is the single copy of the per-step pipeline
// (sensors → tel → pid_drive_car → step), so every driver - native worker
// pool, cooperative round-robin (the wasm frame callback), smoke tools  - 
// produces bit-identical rollouts. Thread-free and I/O-free (the tel
// boundary is a no-op on wasm). Owned by the rollout's slot; only `lines`
// is heap, and it is defined here so Rollout_Slot compiles for both
// targets (writers: rollout_telemetry.odin, rollout_tel_wasm.odin).
Tel_Writer :: struct {
	lines:  [dynamic]string,
	_steps: int,
	dir:    string,
	gen:    int,
	car:    int,
}

// One rollout's in-flight state - a pool slot, reusable across generations.
Rollout_Slot :: struct {
	g:      Genome, // decoded body (owned while active)
	env:    Env, // the world this rollout races in (pinned at slot_start)
	sim:    Sim_State, // world + car (owned while active)
	s_buf:  [N_SENSORS]f32,
	tel:    Tel_Writer, // heap part (tel.lines) only when tel_dir != ""
	tel_on: bool,
	idx:    int, // population index this slot is driving
	active: bool,
}

// The rollout's spawn conditions, one copy for both sides of the
// determinism gate (the contract: the Env header, driving.odin, and the
// Generation header below): the course to the Env's finish line (waypoint
// y's from profile_for(seed)) + the fixed spawn pose + the track-end
// terminal set to the same line. The GA's slots and the views'
// re-simulation (solo/pack) both call spawn_rollout(g, gen.env);
// anything else is a bug.
spawn_rollout :: proc(g: ^Genome, e: Env) -> Sim_State {
	prof := profile_for(e.seed)
	wps := generate_course_len(e.line, prof[:])
	sim := init_sim_pose(g, wps, S_SPAWN_X, 0.0, 0.0, e)
	return sim
}

// Begin a rollout of pop[idx] in an idle slot. The slot owns the decoded
// genome + world from here until slot_finish; a non-idle slot is
// in-flight - drivers never restart it.
slot_start :: proc(slot: ^Rollout_Slot, genes: ^Genes, tel_dir: string, gen, idx: int, e: Env) {
	slot.g = decode_genes(genes)
	// No goal terminal: the rollout runs to failure or the line (set in
	// spawn_rollout); the score is the distance driven. e is the caller's
	// Env, never the live global read at tick time (the Env contract) - the
	// session passes cur.env, the headless pool the global it just pinned.
	slot.env = e
	slot.sim = spawn_rollout(&slot.g, e)
	slot.tel_on = tel_dir != ""
	if slot.tel_on {tel_init(&slot.tel, tel_dir, gen, idx)}
	slot.idx = idx
	slot.active = true
}

// One physics tick of the standard pipeline. Returns false once the
// rollout has terminated (failed/finished): call slot_finish next.
slot_tick :: proc(slot: ^Rollout_Slot) -> bool {
	sensors(&slot.sim, slot.s_buf[:])
	if slot.tel_on {tel_sample(&slot.tel, &slot.sim, slot.s_buf[:])}
	pid_drive_car(&slot.sim, PID_COEFF)
	step_sim(&slot.sim)
	return !slot.sim.failed && !slot.sim.finished
}

// The rollout's terminal classification, straight off the sim's terminal
// state. One copy for both sides of the determinism gate: the GA records
// it in slot_finish; the views' re-simulation re-derives it when a
// displayed car ends (the two must agree, bit for bit).
outcome_of :: proc(state: ^Sim_State) -> Rollout_Outcome {
	// progress() is retained as the NaN probe only: a NaN chassis makes its
	// leg fraction NaN, while the fitness (the ratcheted distance) never
	// does - the ratchet only accepts finite improvements.
	p := progress(state)
	if state.finished {return .Completed}
	if p != p {return .NaN_}
	if state.stalled {return .Stalled}
	return .OffTrack
}

// Close out a finished rollout: compute the result, teardown inline in
// reverse setup order (NOT via defer - a deferred tel_finish would run from
// the proc's epilogue against the just-freed tel.lines buffer), and return
// the slot to idle.
slot_finish :: proc(slot: ^Rollout_Slot, res: ^Eval_Result) {
	res^ = Eval_Result{}
	res.best_x = slot.sim.stall_best_x
	res.fitness = rollout_score_m(res.best_x, slot.env.line)
	res.outcome = outcome_of(&slot.sim)
	res.fail_time = slot.sim.sim_time
	res.flip_steps = slot.sim.flip_steps
	res.n_flips = slot.sim.n_flip_events
	for j in 0 ..< res.n_flips {
		res.flip_events[j] = slot.sim.flip_events[j]
	}
	res.n_breaks = slot.sim.bot.n_breaks
	for j in 0 ..< res.n_breaks {
		res.break_events[j] = slot.sim.break_events[j]
	}
	res.max_speed = slot.sim.max_speed
	res.max_jump = slot.sim.max_jump
	res.max_height = slot.sim.max_height
	res.max_impulse = slot.sim.max_impulse
	if slot.tel_on {tel_finish(&slot.tel)}
	destroy_sim(&slot.sim)
	destroy_genome(&slot.g)
	slot^ = {}
}

// `tel_dir` "" → no channel logging; else the worker samples this car's
// CSV there. Determinism: logging never touches the RNG stream. The car is
// driven by the fixed PID (PID_COEFF) - there is no net.
eval_individual :: proc(genes: ^Genes, gen, idx: int, tel_dir: string) -> Eval_Result {
	slot := Rollout_Slot{}
	slot_start(&slot, genes, tel_dir, gen, idx, env)
	for {
		if !slot_tick(&slot) {break}
	}
	res := Eval_Result{}
	slot_finish(&slot, &res)
	return res
}

// Print the flip log at the generation boundary: workers accumulate per-car
// events in their Eval_Result; the main thread owns the run log. Silent when
// no car flipped (the expected case).
log_flip_events :: proc(gen: int, res: []Eval_Result) {
	for i in 0 ..< len(res) {
		if res[i].flip_steps == 0 {continue}
		parts := make([dynamic]string, 0, 8)
		append(
			&parts,
			fmt.aprintf(
				"  flips: gen {} car {} - {} steps inverted, {} entr",
				gen,
				i,
				res[i].flip_steps,
				res[i].n_flips,
			),
		)
		for j in 0 ..< res[i].n_flips {
			e := res[i].flip_events[j]
			append(
				&parts,
				fmt.aprintf(" @t={:.1f}(fy={:.2f},ly={:.2f},uy={:.2f})", e.t, e.fy, e.ly, e.uy),
			)
		}
		line := strings.concatenate(parts[:])
		fmt.printfln(line)
		delete(line)
		delete(parts)
	}
}

// Print the break log at the generation boundary: which cars shed chassis
// segments and when. Silent when no car broke (the expected case at the
// default K - routine driving stays far below the threshold).
log_break_events :: proc(gen: int, res: []Eval_Result) {
	for i in 0 ..< len(res) {
		if res[i].n_breaks == 0 {continue}
		parts := make([dynamic]string, 0, 8)
		append(
			&parts,
			fmt.aprintf("  breaks: gen {} car {} - {} segment(s) shed", gen, i, res[i].n_breaks),
		)
		for j in 0 ..< res[i].n_breaks {
			e := res[i].break_events[j]
			append(&parts, fmt.aprintf(" @t={:.1f}(seg={},v≈{:.0f}m/s)", e.t, e.seg, e.ratio))
		}
		line := strings.concatenate(parts[:])
		fmt.printfln(line)
		delete(line)
		delete(parts)
	}
}

// Single-threaded population eval (one world at a time). Writes fits[i]
// + res[i]. Every car is driven by the fixed PID (PID_COEFF).
eval_population :: proc(pop: []Genes, gen: int, tel_dir: string, fits: []f64, res: []Eval_Result) {
	assert(len(pop) == len(fits) && len(pop) == len(res))
	for i in 0 ..< len(pop) {
		res[i] = eval_individual(&pop[i], gen, i, tel_dir)
		fits[i] = res[i].fitness
	}
}

// ─── GA operators (pure; take an RNG for determinism) ─────────────────
// Tournament selection, two-point crossover, and per-gene gaussian
// mutation - each documented on its proc below.
tournament_select :: proc(r: ^Rng, fits: []f64, k: int) -> int {
	best := -1
	best_fit := f64(0)
	for i in 0 ..< k {
		j := int(rng_f32(r) * f32(len(fits)))
		if j >= len(fits) {j = len(fits) - 1}
		if i == 0 || fits[j] > best_fit {
			best = j
			best_fit = fits[j]
		}
	}
	return best
}

// Two-point crossover. Window W = 16 + 3·max_axles over the flat gene
// vector; both cuts are drawn EVERY time (even for identical parents).
// Inside the inclusive [a_, b_] interval child 0 takes parent B's gene and
// child 1 parent A's; outside it is the reverse. Genes are copied verbatim
// (vertex ints included - no blend, no coin), so the tail (i ≥ W: slots
// 4–7's wheel genes + densities + widths) is never swapped: child 0 keeps
// A's tail, child 1 keeps B's. Two children per pair (the AB/BA
// complementarity). Only the two cuts consume the RNG.
crossover_two :: proc(r: ^Rng, a, b: ^Genes) -> (Genes, Genes) {
	W := N_VERTICES * 2 + 3 * max_axles
	c1 := int(rng_f32(r) * f32(W))
	c2 := int(rng_f32(r) * f32(W))
	return crossover_two_cuts(a, b, min(c1, c2), max(c1, c2))
}

// The pure core of crossover_two with the cuts fixed (a_ ≤ b_, both in
// [0, W)) - no RNG, so the block/tail/clone properties are testable without
// RNG plumbing. The f64 vector encoding is an exact round-trip for Genes
// (f32→f64→f32 is identity; the vertex int is recovered by rounding), so
// "verbatim per gene" holds bitwise.
crossover_two_cuts :: proc(a, b: ^Genes, a_, b_: int) -> (Genes, Genes) {
	va := [GENE_DIM]f64{}
	vb := [GENE_DIM]f64{}
	genes_to_vector(a, va[:])
	genes_to_vector(b, vb[:])
	for i in a_ ..< b_ + 1 {
		va[i], vb[i] = vb[i], va[i]
	}
	c0 := Genes{}
	c1 := Genes{}
	vector_to_genes(va[:], &c0)
	vector_to_genes(vb[:], &c1)
	// A part-color slot follows the donor of its group's FIRST gene
	// (vertex k → gene 2k; wheel j → gene 16+3j); the window swap decides
	// the donor per gene index (inside [a_, b_] the children swap sides).
	for k in 0 ..< N_VERTICES {
		gi := 2 * k
		from_b := a_ <= gi && gi <= b_
		c0.colors[k] = from_b ? b.colors[k] : a.colors[k]
		c1.colors[k] = from_b ? a.colors[k] : b.colors[k]
	}
	for j in 0 ..< N_WHEELS {
		gi := N_VERTICES * 2 + 3 * j
		from_b := a_ <= gi && gi <= b_
		c0.colors[8 + j] = from_b ? b.colors[8 + j] : a.colors[8 + j]
		c1.colors[8 + j] = from_b ? a.colors[8 + j] : b.colors[8 + j]
	}
	return c0, c1
}

// Re-roll one part-color slot to a fresh random RGB (3 draws).
reroll_color :: proc(r: ^Rng, g: ^Genes, slot: int) {
	for ch in 0 ..< 3 {
		g.colors[slot][ch] = u8(int(rng_f32(r) * 256))
	}
}

// The part-color slots that repaint when the gene at flat vector index `gi`
// mutates. Vertices (0-15) → slot gi/2; wheel triples (16-39) and
// wheel densities (41-48) → slot 8+wheel (any of a wheel's 4 genes
// repaints the wheel slot - the paint follows the part, enabled or not);
// chassis_density (40) and the center width (57, a global hull gene) →
// all 8 triangle slots 0-7; widths 49-56 → slot gi-49.
gene_color_slots :: proc(gi: int) -> [N_COLORS]bool {
	out := [N_COLORS]bool{}
	switch {
	case gi < GENE_OFF_WHEEL:
		out[gi / 2] = true
	case gi < GENE_OFF_CHASSIS:
		out[N_VERTICES + (gi - GENE_OFF_WHEEL) / 3] = true
	case gi == GENE_OFF_CHASSIS:
		for k in 0 ..< N_VERTICES {out[k] = true}
	case gi < GENE_OFF_WIDTH:
		out[N_VERTICES + (gi - GENE_OFF_WHEEL_DENSITY)] = true
	case gi - GENE_OFF_WIDTH < N_VERTICES:
		out[gi - GENE_OFF_WIDTH] = true
	case:
		for k in 0 ..< N_VERTICES {out[k] = true}
	}
	return out
}

// Per-gene gaussian mutation (in place). Bounds are re-applied at decode time,
// so overshooting here is safe. A gene that mutates also re-rolls its
// part-color slots (gene_color_slots) - the paint follows the part.
mutate :: proc(r: ^Rng, g: ^Genes, rate, sigma: f32) {
	for i in 0 ..< N_VERTICES {
		if rng_f32(r) < rate {
			g.vertices[i].angle += rng_gauss(r) * sigma * TAU
			repaint := gene_color_slots(2 * i)
			for s in 0 ..< N_COLORS {if repaint[s] {reroll_color(r, g, s)}}
		}
		if rng_f32(r) < rate {
			g.vertices[i].magnitude += rng_gauss(r) * sigma * MAX_MAG
			repaint := gene_color_slots(2 * i + 1)
			for s in 0 ..< N_COLORS {if repaint[s] {reroll_color(r, g, s)}}
		}
	}
	for i in 0 ..< N_WHEELS {
		// Vertex gene: re-roll the enable/disable coin + vertex.
		base := N_VERTICES * 2 + 3 * i
		if rng_f32(r) < rate {
			g.wheels[i].vertex = rng_f32(r) < WHEEL_PROB ? int(rng_f32(r) * f32(N_VERTICES)) : -1
			repaint := gene_color_slots(base)
			for s in 0 ..< N_COLORS {if repaint[s] {reroll_color(r, g, s)}}
		}
		if rng_f32(r) < rate {
			g.wheels[i].axle_angle += rng_gauss(r) * sigma * TAU
			repaint := gene_color_slots(base + 1)
			for s in 0 ..< N_COLORS {if repaint[s] {reroll_color(r, g, s)}}
		}
		if rng_f32(r) < rate {
			g.wheels[i].radius += rng_gauss(r) * sigma * MAX_RADIUS
			repaint := gene_color_slots(base + 2)
			for s in 0 ..< N_COLORS {if repaint[s] {reroll_color(r, g, s)}}
		}
		if rng_f32(r) < rate {
			g.wheels[i].density += rng_gauss(r) * sigma * (WHEEL_DENSITY_HI - WHEEL_DENSITY_LO)
			repaint := gene_color_slots(GENE_OFF_WHEEL_DENSITY + i)
			for s in 0 ..< N_COLORS {if repaint[s] {reroll_color(r, g, s)}}
		}
	}
	if rng_f32(r) < rate {
		g.chassis_density += rng_gauss(r) * sigma * (CHASSIS_DENSITY_HI - CHASSIS_DENSITY_LO)
		repaint := gene_color_slots(GENE_OFF_CHASSIS)
		for s in 0 ..< N_COLORS {if repaint[s] {reroll_color(r, g, s)}}
	}
	for i in 0 ..< N_WIDTHS {
		if rng_f32(r) < rate {
			g.widths[i] += rng_gauss(r) * sigma * (WIDTH_HI - WIDTH_LO)
			repaint := gene_color_slots(GENE_OFF_WIDTH + i)
			for s in 0 ..< N_COLORS {if repaint[s] {reroll_color(r, g, s)}}
		}
	}
}

// The m indices into `fits` with the highest value, best first. Partial
// selection sort - O(m·n), fine for n ≤ 128. Used for elitism + best tracking.
top_indices :: proc(fits: []f64, m: int) -> [dynamic]int {
	count := len(fits)
	idx := make([dynamic]int, count)
	for i in 0 ..< count {idx[i] = i}
	mm := min(m, count)
	for i in 0 ..< mm {
		best := i
		for j := i + 1; j < count; j += 1 {
			if fits[idx[j]] > fits[idx[best]] {best = j}
		}
		if best != i {tmp := idx[i];idx[i] = idx[best];idx[best] = tmp}
	}
	if mm < count {
		out := make([dynamic]int, mm)
		for i in 0 ..< mm {out[i] = idx[i]}
		delete(idx)
		return out
	}
	return idx
}

// ─── Generational loop ────────────────────────────────────────────────
// Breed the next generation in place of `pop`. The top-`elite` (by fitness)
// are SURVIVORS: each keeps its current slot verbatim, so a slot is a
// stable car identity across generations (the windowed solo walks slots in
// this order - it must not read as a fitness sort). The vacated (non-elite)
// slots are paired in ascending order; each pair runs two k=3 tournaments
// into one two-point crossover, and each child is then mutated +
// axle-capped. RNG order per pair, in order: tournament A (3 draws),
// tournament B (3 draws), cut 1, cut 2; then child 0's mutate draws, then
// child 1's. gen_breed remains the single site where the RNG advances
// between evals. Returns the new population (caller copies it back + frees
// the old); deterministic given fits + rng (top_indices consumes no RNG).
// When n - elite is ODD (the evolvetest gates: pop 8/elite 1, pop 4/elite
// 1), the last vacated slot is child 0 of one pair alone - child 1 is
// discarded UNMUTATED so it consumes no extra RNG.
breed_next :: proc(cfg: Evo_Config, pop: []Genes, fits: []f64, rng: ^Rng) -> []Genes {
	n := len(pop)
	elite := min(cfg.elite, n)
	top := top_indices(fits, n)
	kept := make([]bool, n) // the survivors keep their slot
	for i in 0 ..< elite {kept[top[i]] = true}
	next := make([]Genes, n)
	for i in 0 ..< n {
		if kept[i] {next[i] = pop[i]}
	}
	// Pair the VACATED slots (non-elite only, ascending) - never raw
	// consecutive indices: a pair's second child must not land on an elite
	// slot (it would clobber the survivor).
	vac := make([]int, n - elite)
	vn := 0
	for i in 0 ..< n {
		if !kept[i] {
			vac[vn] = i
			vn += 1
		}
	}
	j := 0
	for j < vn {
		pa := tournament_select(rng, fits, 3)
		pb := tournament_select(rng, fits, 3)
		c0, c1 := crossover_two(rng, &pop[pa], &pop[pb])
		mutate(rng, &c0, cfg.mut_rate, cfg.mut_sigma)
		cap_axles(&c0) // crossover + re-enable mutations can exceed the cap
		next[vac[j]] = c0
		j += 1
		if j >= vn {
			// Odd n - elite: the last vacated slot is child 0 alone;
			// discard child 1 unmutated (no extra RNG draws).
			break
		}
		mutate(rng, &c1, cfg.mut_rate, cfg.mut_sigma)
		cap_axles(&c1)
		next[vac[j]] = c1
		j += 1
	}
	delete(vac)
	delete(kept)
	delete(top)
	return next
}

// ─── Gen boundary (shared by every driver) ────────────────────────────
// The boundary is split into a pure report and an in-place breed (rank →
// driver work → breed): drivers log/save the EVALUATED generation before
// breeding replaces pop.
// gen_breed is the single site where the GA RNG advances between evals  - 
// which is what makes the per-gen best sequence identical across runners
// (native pool, cooperative session, wasm frame callback).
Gen_Event :: struct {
	gen:    int, // the gen that just completed (set by the caller)
	best:   f64,
	mean:   f64,
	argmax: int,
}

// Rank the just-evaluated generation: best + pack mean (NaN sentinels
// excluded, so an exploded body doesn't drag the mean to -1e17).
// Pure - consumes no RNG.
gen_report :: proc(fits: []f64) -> Gen_Event {
	top := top_indices(fits, len(fits))
	argmax := top[0]
	best := fits[argmax]
	sum := f64(0)
	n_valid := 0
	for i in 0 ..< len(fits) {
		if fits[i] > FITNESS_NAN / 10 {
			sum += fits[i]
			n_valid += 1
		}
	}
	mean := f64(0)
	if n_valid > 0 {mean = sum / f64(n_valid)}
	return Gen_Event{best = best, mean = mean, argmax = argmax}
}

// Breed the next generation in place: elites verbatim + tournament +
// crossover + mutation.
gen_breed :: proc(rng: ^Rng, cfg: Evo_Config, pop: ^[]Genes, fits: []f64) {
	next := breed_next(cfg, pop[:], fits[:], rng)
	copy(pop[:], next[:])
	delete(next)
}

// ─── Steppable session (cooperative driver; the wasm frame callback) ────
// The generational loop as resumable state: the current generation
// (Generation - the population, its env, and the work cursor) + a pool of
// rollout slots. session_step starts idle slots for pending individuals,
// ticks each active slot once per round until the tick budget is spent,
// and consumes a completed generation (report + breed + next-gen env).
// Scheduling (slot count, budget) never affects results: every world sees
// the same tick sequence in every driver, and the RNG only advances in
// gen_breed.
//
// DETERMINISM CONTRACT, generation side (environment side: the Env header,
// driving.odin). A Generation is the first-class unit of evolution; its
// env (ground seed + finish line) is PINNED AT BIRTH - immutable for the
// generation's lifetime, and every rollout it spawns races exactly the
// env it was born with. The line advances WITH the generation swap: the
// boundary is reached only when every rollout has finished (all slots
// idle), and the new generation (bred population, extended line, re-rolled
// floor when mutable_floor) is swapped into cur BEFORE any slot of it
// spawns - no in-flight rollout ever races a line that moved after it
// started. A view's snapshot IS a value copy of a Generation
// (solo.odin / pop_viewer.odin), so the display re-sim races gen.env  - 
// the same value the GA's rollouts raced. The one mid-generation env
// change is an explicit track re-seed: it replaces cur.env with the fresh
// frontier AND resets the in-flight eval (session_invalidate_eval), so the
// generation re-runs from scratch on the new ground and no result scored
// on the old ground survives the click.
Generation :: struct {
	index:    int,
	env:      Env, // pinned at birth: the world this generation races in (a re-seed replaces it + resets the eval)
	pop:      []Genes,
	fits:     []f64, // partial until the eval completes
	res:      []Eval_Result,
	next:     int, // work cursor into pop (rollouts started this generation)
	done:     int, // rollouts finished this generation
	// Set only by the views (the solo / pending snapshot copies) - never by
	// session code.
	complete: bool,
}

Evo_Session :: struct {
	cfg:        Evo_Config,
	rng:        Rng,
	cur:        Generation,
	slots:      []Rollout_Slot,
	run_best_m: f64, // ratcheted best metres from the spawn
	best_fit:   f64,
	running:    bool, // the driver's stop flag (set true by session_init)
}

// Begin a session: the same population init as run_generations (car 0 = the
// warm-start genome when given). n_slots = concurrent rollouts (the driver's
// world pool size; clamped to >= 1). Rolls gen 0's track.
session_init :: proc(s: ^Evo_Session, cfg: ^Evo_Config, n_slots: int, seed_from: ^Genes) {
	s^ = {}
	s.running = true
	s.cfg = cfg^
	s.rng = rng_init(cfg.seed)
	n := n_slots
	if n < 1 {n = 1}
	// Finish line for gen 0: the adaptive start (TARGET_START_LEN  - 
	// deliberately below the gen-0 random floor, see the const), capped at
	// the terrain's reach (--course M may pin a short track). A pinned
	// init_line (share-link showcase) overrides the adaptive start, capped
	// the same way.
	line := f32(math.min(TARGET_START_LEN, env_max_len))
	if cfg.init_line > 0 {
		line = cfg.init_line
		if line > env_max_len {line = env_max_len}
	}
	s.cur.env = Env {
		seed = evo_terrain_seed(cfg^),
		line = line,
	}
	env = s.cur.env // the live frontier mirrors the current generation
	s.cur.pop = make([]Genes, cfg.pop, context.allocator)
	if seed_from != nil {
		s.cur.pop[0] = seed_from^
	} else {
		s.cur.pop[0] = random_genes(&s.rng)
	}
	for i in 1 ..< cfg.pop {s.cur.pop[i] = random_genes(&s.rng)}
	s.cur.fits = make([]f64, cfg.pop, context.allocator)
	s.cur.res = make([]Eval_Result, cfg.pop, context.allocator)
	s.slots = make([]Rollout_Slot, n, context.allocator)
	s.best_fit = f64(-1e18)
	profile_for(s.cur.env.seed)
}

session_destroy :: proc(s: ^Evo_Session) {
	if len(s.cur.pop) > 0 {delete(s.cur.pop)}
	if len(s.cur.fits) > 0 {delete(s.cur.fits)}
	if len(s.cur.res) > 0 {delete(s.cur.res)}
	if len(s.slots) > 0 {delete(s.slots)}
	s^ = {}
}

// Re-roll the population with a fresh RNG - the "Re-seed cars" sandbox
// control. In-flight slots are closed out properly (their worlds return to
// the pool; a slice delete alone would leak them per click), the gen counter
// keeps counting (the re-rolled population is evaluated as the next
// generation), and the CURRENT terrain is kept (cur.env - the track
// re-seed is a separate control). The all-time best_fit is kept (session
// record).
session_reseed :: proc(s: ^Evo_Session, seed: u64) {
	if len(s.cur.pop) == 0 {return}
	scratch := Eval_Result{}
	for i in 0 ..< len(s.slots) {
		if !s.slots[i].active {continue}
		slot_finish(&s.slots[i], &scratch)
	}
	s.rng = rng_init(seed)
	// Re-roll cur.pop in place (Genes is a plain value - nothing to free);
	// the environment is NOT touched.
	for i in 0 ..< len(s.cur.pop) {s.cur.pop[i] = random_genes(&s.rng)}
	if len(s.cur.fits) > 0 {delete(s.cur.fits)}
	if len(s.cur.res) > 0 {delete(s.cur.res)}
	s.cur.fits = make([]f64, s.cfg.pop, context.allocator)
	s.cur.res = make([]Eval_Result, s.cfg.pop, context.allocator)
	s.cur.index += 1
	s.cur.next = 0
	s.cur.done = 0
}

// Re-evaluate the CURRENT generation from scratch: close out the in-flight
// slots (their worlds return to the pool; a slice delete alone would leak
// them) and reset the work cursor - same population, same generation index,
// no breeding. Every result the GA has accumulated for the current
// generation belongs to the world it was scored in, so it is discarded and
// the population re-runs. A generation whose eval has already completed is
// untouched (its breeding is final - the invalidation cannot un-breed; the
// display side drops the stale snapshot instead).
//
// Re-pins cur.env to the live frontier: the track re-seed re-rolls the
// GROUND, so the generation must pick up its env from the frontier  - 
// otherwise the display hand-off (offer_provisional) would carry the old
// seed and re-materialize the old profile into the shared cache.
session_invalidate_eval :: proc(s: ^Evo_Session) {
	if len(s.cur.pop) == 0 {return}
	scratch := Eval_Result{}
	for i in 0 ..< len(s.slots) {
		if !s.slots[i].active {continue}
		slot_finish(&s.slots[i], &scratch)
	}
	s.cur.env = env
	s.cur.next = 0
	s.cur.done = 0
}

// "Evolve from here" (the share-link showcase's die glyph): re-begin the
// session as a FULL cfg.pop population with `head` (the imported lineage
// head) at index 0 and the rest random, on the env `cfg` pins
// (cfg.terrain_seed + cfg.init_line - the world the shared car raced). The
// old session is destroyed first (its population/slots freed - a bare
// session_init would leak them). The pinned env becomes the live frontier
// (session_init mirrors s.cur.env into `env`).
session_warm_start :: proc(s: ^Evo_Session, cfg: ^Evo_Config, n_slots: int, head: ^Genes) {
	session_destroy(s)
	session_init(s, cfg, n_slots, head)
	// The head's generation opens the NEW lineage at index 1 (the old
	// lineage's generations were 0..k): the offer/adopt gates
	// (reseed_min_gen) key on the index, so the fresh population is offered
	// and the views' old-lineage snapshots are dropped - exactly the car
	// re-seed's gate convention (session_reseed bumps the index too).
	s.cur.index = 1
}

// Advance the session: start pending rollouts into idle slots, then give
// each active slot one tick per round until `tick_budget` is spent. A
// just-completed generation is consumed (report + breed + next-gen env)
// and its event returned; otherwise (zero, false). Every car is driven by
// the fixed PID (PID_COEFF).
//
// The generation swap is the ONLY place the line (and the floor, when
// mutable_floor) advances - the boundary is reached with all slots idle,
// so the new env is in force before any slot of the new generation exists.
// The per-frame slot-start cap spreads a fresh generation's starts across
// frames (one frame otherwise takes ~8 world allocations + rollout files
// at every gen start); the start ORDER is unchanged (slot order, then
// rollout order), so each rollout still receives the same tick sequence  - 
// results untouched, only wall-clock pacing.
SESSION_STARTS_PER_FRAME :: int(2)

session_step :: proc(s: ^Evo_Session, tick_budget: int) -> (Gen_Event, bool) {
	ev := Gen_Event{}
	budget := tick_budget
	for budget > 0 {
		started := false
		starts := 0
		for i in 0 ..< len(s.slots) {
			if s.slots[i].active {continue}
			if s.cur.next >= len(s.cur.pop) {break}
			if starts >= SESSION_STARTS_PER_FRAME {break}
			idx := s.cur.next
			s.cur.next += 1
			slot := &s.slots[i]
			slot_start(slot, &s.cur.pop[idx], s.cfg.tel_dir, s.cur.index, idx, s.cur.env)
			starts += 1
			started = true
		}
		active := 0
		for i in 0 ..< len(s.slots) {
			slot := &s.slots[i]
			if !slot.active {continue}
			active += 1
			if budget <= 0 {break}
			budget -= 1
			if slot_tick(slot) {continue}
			// Capture idx BEFORE slot_finish: it returns the slot to idle
			// (zeroed), and the fits write must use the real index.
			idx := slot.idx
			slot_finish(slot, &s.cur.res[idx])
			s.cur.fits[idx] = s.cur.res[idx].fitness
			s.cur.done += 1
		}
		if s.cur.done == len(s.cur.pop) {
			ev = gen_report(s.cur.fits[:])
			ev.gen = s.cur.index
			if ev.best > s.best_fit {
				s.best_fit = ev.best
			}
			// The track extends (2× doubling, when reached): advance the
			// ratcheted best (metres from the spawn) and, if the record has
			// reached the line, grow the track for the next generation  - 
			// the line is the rollout terminal, not a display horizon.
			for r in s.cur.res[:] {
				// s.cur.env.line is still this generation's line (the
				// swap below resets it).
				m := rollout_score_m(r.best_x, s.cur.env.line)
				if m > s.run_best_m {s.run_best_m = m}
			}
			// The new generation is born WITH its env pinned: the line is
			// the ratcheted extension, the floor re-rolled when
			// mutable_floor. It takes over cur before any slot of it
			// spawns - the line advances with the generation swap.
			nidx := s.cur.index + 1
			nenv := s.cur.env
			if s.cfg.mutable_floor {
				nenv.seed = evo_terrain_seed(s.cfg) + u64(nidx)
			}
			nenv.line = adapt_track_len(s.run_best_m, s.cur.env)
			env = nenv
			gen_breed(&s.rng, s.cfg, &s.cur.pop, s.cur.fits[:])
			s.cur.index = nidx
			s.cur.env = nenv
			s.cur.next = 0
			s.cur.done = 0
			if s.cfg.mutable_floor {
				regenerate_terrain(nenv.seed)
			}
			return ev, true
		}
		if active == 0 && !started {break}
	}
	return ev, false
}

// Single-threaded driver over the session: the exact code the wasm frame
// callback uses (session_step with a per-frame tick budget), available
// natively for the cross-driver determinism gate. gens <= 0 → unlimited
// (the caller must stop it). Returns one best fitness per completed gen.
run_session_coop :: proc(
	cfg: ^Evo_Config,
	n_slots: int,
	tick_per_step: int,
	seed_from: ^Genes,
	gens: int,
) -> [dynamic]f64 {
	s := Evo_Session{}
	session_init(&s, cfg, n_slots, seed_from)
	bests := make([dynamic]f64, 0, 0)
	n_done := 0
	for gens <= 0 || n_done < gens {
		ev, ok := session_step(&s, tick_per_step)
		if ok {
			n_done += 1
			append(&bests, ev.best)
		}
	}
	session_destroy(&s)
	return bests
}

// ─── Driver progress (the frame driver fills this for the UI) ───────────
// The GA's progress for the score panel; the shared in-frame driver
// (loop.odin) fills it from the session on both targets.
Evo_Progress :: struct {
	generation:      int, // the generation the view is showing (solo.last)
	next_generation: int, // what the view will show next (the pending snapshot)
	best_fitness:    f64,
	target_len:      f32, // the GA's current target / finish line (m from the spawn)
	running:         bool,
	bg_evolve:       bool, // the "evolve in background" checkbox state
}
