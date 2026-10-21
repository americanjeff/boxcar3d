// Driving core: hilly terrain, the waypoint course, the 28-sensor vector,
// the crafted PID controller, and the liveness gate.
// Shared by both targets (headless rollouts + the windowed view, native
// and wasm).

package main

import "core:math"
import "core:sync"
import b3 "engine:physics"

box3d_world_mutex: sync.Mutex // Box3D World create/destroy is not threadsafe

TIME_STEP :: f32(1.0 / 60.0)
SUB_STEPS :: 32 // 16 under-resolved the 120 Hz wheel-joint constraint for heavy cars - re-contact after a launch pumped energy to NaN; 32 (1920 Hz) resolves it.

// Gravity. Package var (not a const): the --gravity flag overrides it.
gravity := f32(15.0)
// Terrain fixture friction (combined against the chassis/wheels as
// √(f₁·f₂)). The `--mu` flag overrides it at startup.
terrain_friction := f32(10.0)

// Contact-solver tuning (defaults = Box3D's b3DefaultWorldDef).
CONTACT_HERTZ :: f32(30.0)
CONTACT_DAMPING_RATIO :: f32(10.0)
// Angular damping on every bot body, minus the wheels' spin axes (Box3D
// semantics: w *= max(0, 1 - d·dt) per step). The wobble modes (chassis
// yaw/roll) have almost no structural damping - sphere wheels give no
// tire-like lateral slip stiffness - so a P steering loop hunts into a
// yaw limit cycle; damping them kills the hunting without slowing the
// drive (the motor-owned spin is preserved). The wheels carry ~half the
// yaw inertia, so they must be in the damped set.
BODY_ANGULAR_DAMPING :: f32(8.0)
RESTITUTION_THRESHOLD :: f32(1.0)
CONTACT_SPEED :: f32(3.0)

// ─── Terrain ───────────────────────────────────────────────────────
// A track running along +x: a ribbon of fixed lateral width around the
// z=0 centerline. The centerline height is an integrated per-column pitch
// walk whose pitch ramps linearly from FLOOR·MAX_TILE_TILT at x=0 to
// MAX_TILE_TILT at the far end - one fixed full-length terrain per run, so
// a longer finish line exposes steeper territory (the ramp reaches its
// max only at the end). The cross-section is flat across the width;
// outside the ribbon the terrain ramps down from the local edge height so
// a bot that leaves the road falls off. Built as a custom heightfield
// (b3CreateHeightField).
TERRAIN_COLS :: 2401 // x grid lines (x = −1600..+3200; the finish line can extend to x = +3200)
TERRAIN_ROWS :: 60 // z grid lines (track width + drop-off ramps)
TERRAIN_CELL :: f32(2.0)
// The field is deliberately asymmetric in x: the west edge is fixed, so
// columns 0..1600 keep their world position and profile, and the 1600 m
// past +1600 continue the same walk at the saturated ramp - the hardest
// terrain the walk produces.
TERRAIN_X0 :: f32(-1600.0) // world x of column 0 (the field's west edge)
TERRAIN_RAMP_END :: f32(1600.0) // the ramp hits max tilt here and saturates past it
TERRAIN_HALF_Z :: TERRAIN_CELL * f32(TERRAIN_ROWS - 1) / 2.0
TERRAIN_OFFSET :: [3]f32{TERRAIN_X0, 0.0, -TERRAIN_HALF_Z}
TERRAIN_SCALE :: [3]f32{TERRAIN_CELL, 1.0, TERRAIN_CELL}
// Heightfield quantization: Box3D stores uint16 heights (65535 levels →
// ~12 mm/level here, ≈160 levels per 2 m cell). Profile spans across
// seeds reach several hundred metres; ±400 m keeps the observed span out
// of the compression path - compression would flatten the ramp and quietly
// undo the difficulty (smoke_terrain locks the scale).
TERRAIN_MIN_H :: f32(-400.0)
TERRAIN_MAX_H :: f32(400.0)

// Track geometry: a 2×TRACK_HALF_WIDTH-wide ribbon centred on z=0. Outside
// the ribbon the terrain ramps down TRACK_DROP over TRACK_SLOPE metres from
// the local edge height.
TRACK_HALF_WIDTH :: f32(10.0)
TRACK_DROP :: f32(10.0)
TRACK_SLOPE :: f32(5.0)

// ─── Env: the world a rollout races in ────────────────────────────────
// One value for the two halves the rollout's world bakes in at spawn  - 
// the GROUND (the terrain seed; the profile is a pure function of it)
// and the GOAL LINE (the finish line, capped by env_max_len) - with two
// narrow mutators (regenerate_terrain / set_line). No version token: a
// ground re-roll is a key change in the profile cache, and the render
// cache gates on the DISPLAYED (seed, line) pair, so a ground re-roll
// and a line move invalidate the mesh through the same channel.
//
// The global `env` below is the app's LIVE FRONTIER: it advances at the
// generation boundary, so a generation's own environment is pinned per
// Generation (Generation.env, evolve.odin) and per rollout
// (Sim_State.track_end + .profile).
//
// DETERMINISM CONTRACT - a rollout is a PURE FUNCTION of (genome, Env)
// (the generation side is on the Generation header, evolve.odin). Every
// world is built from ONE Env value passed as a parameter: spawn_rollout
// copies e's line and seed into the Sim_State (track_end + profile); the
// per-tick terrain reads and the score cap use those copies, never the
// live value. Any rollout reading the live env / env_profile is a bug.
// In single-owner modes (headless `evolve`, the single-run tools) this
// variable IS the line + terrain state.
Env :: struct {
	// Terrain seed: the profile is a pure function of it (profile_for
	// caches on the seed - same seed, same bytes, no re-roll on a hit).
	seed: u64,
	// Finish line = the current track end (m from the spawn). The hard-x
	// terminal, the score cap, the waypoint course, and the heightfield
	// all stop at it (a car crossing it falls - the liveness gate retires
	// it); a red end zone marks it. The mesh follows the displayed
	// generation's env, not this frontier. It moves only when REACHED: at
	// the boundary, if the ratcheted record reached it, the track extends
	// to 2× the record, capped at env_max_len. "Solved" = a full clear.
	line: f32,
}

// The live frontier (see the contract above).
env: Env = Env {
	seed = TERRAIN_DEFAULT_SEED,
	line = f32(TARGET_START_LEN),
}

// The finish line's cap: the default, or a pin from the --course flag
// (main_native).
env_max_len: f32 = f32(3200.0)

// The terrain profile: a derived cache of env.seed (profile_for
// materializes on a key miss, serves on a hit). The zero value is a flat
// track (valid before any materialization).
env_profile_seed: u64
env_profile: [TERRAIN_COLS]f32
env_profile_valid: bool
// Last range fit's diagnostics (profile_for): the raw (pre-fit) profile
// span in metres, and the scale applied when it overflowed the
// quantization range (1.0 = translate-only, no compression). The smoke
// test locks the scale at 1.0 - a compressed profile flattens the ramp.
env_span_raw: f32
env_fit_scale: f32

// Difficulty-ramp amplitude floor (profile_for): the starting pitch at
// x=0, as a fraction of MAX_TILE_TILT; the ramp climbs linearly to
// MAX_TILE_TILT by the far end.
terrain_ramp_floor := f32(0.20)

// Per-tile max pitch (radians) at the far end of the ramp: < π/2 keeps
// the profile a single-valued function of x (a heightfield cannot
// represent overhangs). Up and down both reach 86° - uphills stop the
// car, downhills launch it (the jump gauntlet at the track end).
MAX_TILE_TILT :: f32(1.5)

// Deterministic track seeds: the window/smoke/diagnostic default track, and
// the salt that derives an evolve run's track seed from its GA seed.
TERRAIN_DEFAULT_SEED :: u64(0xc0ffee)
TERRAIN_SEED_SALT :: u64(0x7ea2d_caf8)

// Re-roll the live terrain (set env.seed + materialize) so the new ground
// is in force for the next rollout. seed 0 leaves the environment
// untouched.
regenerate_terrain :: proc(seed: u64) {
	if seed == 0 {return}
	env.seed = seed
	profile_for(seed)
}

// Sandbox re-seed seeds: one per click (monotonic counter - presentation
// only, no determinism claim).
reseed_counter: u64 = 0

next_reseed_seed :: proc() -> u64 {
	reseed_counter += 1
	return reseed_counter * 0x9e37_79b9_7f4a_7c15
}

// Materialize the terrain profile for `seed` into the seed-keyed cache
// (on a key miss) and return it: a per-column pitch walk with the
// difficulty ramp (pitch FLOOR·MAX_TILE_TILT at x=0 → MAX_TILE_TILT at
// the far end; per-tile tilt = U(−1,1)·pitch), flat on the spawn approach
// (x < 0). Range fit: compress affinely into [TERRAIN_MIN_H,
// TERRAIN_MAX_H] when the span overflows (shape preserved, flat stays
// flat; no upscale), else translate when one edge overflows (only one can
// then). A key hit returns the cache without re-rolling - same seed →
// same bytes.
profile_for :: proc(seed: u64) -> [TERRAIN_COLS]f32 {
	if env_profile_valid && seed == env_profile_seed {return env_profile}
	env_profile_seed = seed
	r := rng_init(seed)
	h := f32(0.0)
	lo := f32(0.0)
	hi := f32(0.0)
	for j in 0 ..< TERRAIN_COLS {
		env_profile[j] = h
		lo = math.min(lo, h)
		hi = math.max(hi, h)
		x := TERRAIN_X0 + TERRAIN_CELL * f32(j)
		if x >= 0.0 {
			// Difficulty ramp: pitch climbs FLOOR·MAX → MAX linearly to
			// TERRAIN_RAMP_END and saturates past it; per-tile tilt is
			// SYMMETRIC U(−1,1) about it (zero mean - uphills and downhills
			// grow together, what makes the far end genuinely hard).
			ramp := terrain_ramp_floor + (1.0 - terrain_ramp_floor) * math.min(x, TERRAIN_RAMP_END) / TERRAIN_RAMP_END
			tilt := rng_range(&r, -1.0, 1.0) * MAX_TILE_TILT * ramp
			h += math.tan(tilt) * TERRAIN_CELL
		}
	}
	// Fit the profile into the heightfield quantization range: compress when
	// the span overflows, otherwise translate when it overflows one edge.
	span := hi - lo
	avail := TERRAIN_MAX_H - TERRAIN_MIN_H
	scale := f32(1.0)
	if span > avail {
		scale = avail / span
		// Clamp: the affine map can round a hair outside the range at f32 precision.
		for &v in env_profile {
			v = math.clamp(TERRAIN_MIN_H + (v - lo) * scale, TERRAIN_MIN_H, TERRAIN_MAX_H)
		}
	} else if hi > TERRAIN_MAX_H {
		d := hi - TERRAIN_MAX_H
		for &v in env_profile {v -= d}
	} else if lo < TERRAIN_MIN_H {
		d := lo - TERRAIN_MIN_H
		for &v in env_profile {v -= d}
	}
	// Publish the last fit's diagnostics + the new profile (the render gate
	// sees the seed change through terrain_mesh_seed, render.odin).
	env_span_raw = span
	env_fit_scale = scale
	env_profile_valid = true
	return env_profile
}

// Centerline height at world x: linear interpolation of `profile`
// (clamped at the ends).
terrain_centerline_p :: proc(profile: []f32, x: f32) -> f32 {
	f := (x - TERRAIN_X0) / TERRAIN_CELL
	// NaN-safe (total): the GA runs degenerate bodies that can leave the
	// chassis at NaN, and callers query with live chassis x every tick.
	// `f > 0.0` is false for NaN, so this guard catches it - int(NaN)
	// would be an OOB index.
	if !(f > 0.0) {return profile[0]}
	last := f32(TERRAIN_COLS - 1)
	if f >= last {return profile[TERRAIN_COLS - 1]}
	i := int(f)
	fr := f - f32(i)
	return profile[i] * (1.0 - fr) + profile[i + 1] * fr
}

// The live materialized profile (profile_for(env.seed)).
terrain_centerline :: proc(x: f32) -> f32 {
	return terrain_centerline_p(env_profile[:], x)
}

// The surface height at (x, z): the centerline profile, flat across the
// ribbon's fixed width. Outside the ribbon the surface drops TRACK_DROP over
// TRACK_SLOPE metres from the local edge height, then runs flat.
terrain_height_p :: proc(profile: []f32, x, z: f32) -> f32 {
	h := terrain_centerline_p(profile, x)
	az := math.abs(z)
	if az > TRACK_HALF_WIDTH {
		t := (az - TRACK_HALF_WIDTH) / TRACK_SLOPE
		if t > 1.0 {t = 1.0}
		return h - t * TRACK_DROP
	}
	return h
}

// The live materialized profile (profile_for(env.seed)).
terrain_height :: proc(x, z: f32) -> f32 {
	return terrain_height_p(env_profile[:], x, z)
}

// The last grid column of a track ending at `track_len` m from the spawn
// (snapped to the grid, clamped to the terrain's reach). The east edge of
// the visible track - shared by the visual mesh and the physics
// heightfield, so what you see is what you drive on: no ground exists
// past the line.
track_end_col_len :: proc(track_len: f32) -> int {
	x_line := S_SPAWN_X + track_len
	c := int(math.floor((x_line - TERRAIN_X0) / TERRAIN_CELL + 0.5))
	if c > TERRAIN_COLS - 1 {c = TERRAIN_COLS - 1}
	if c < 1 {c = 1}
	return c
}

// Build the track heightfield from `profile`: a grid of heights over
// (x, z), row-major (index = z·countX + x), spanning only the track to
// `track_len` - no ground exists past the line (a car crossing it falls;
// step_sim's drop check retires it). Caller owns the returned
// HeightField.
//
// The line and the profile are PARAMETERS, not the live env /
// env_profile (the Env contract above): a re-simulated generation's world
// must match the GA's bit for bit (smoke_display_resim pins it).
create_track_heightfield_len :: proc(track_len: f32, profile: []f32) -> b3.HeightField {
	cols := track_end_col_len(track_len) + 1
	heights := make([]f32, TERRAIN_ROWS * cols)
	defer delete(heights)
	for i in 0 ..< TERRAIN_ROWS {
		for j in 0 ..< cols {
			k := i * cols + j
			wx := TERRAIN_X0 + TERRAIN_CELL * f32(j)
			wz := TERRAIN_CELL * f32(i) - TERRAIN_HALF_Z
			heights[k] = terrain_height_p(profile, wx, wz)
		}
	}
	return b3.CreateHeightFieldFromData(
		heights[:],
		i32(cols),
		TERRAIN_ROWS,
		TERRAIN_SCALE[0],
		TERRAIN_SCALE[1],
		TERRAIN_SCALE[2],
		TERRAIN_MIN_H,
		TERRAIN_MAX_H,
	)
}

// ─── Drive controls ────────────────────────────────────────────────
// Wheel spin-motor target speed (rad/s).
SPIN_SPEED :: f32(20.0)

// ─── Straight-track waypoint course (deterministic) ─────────────────
// Waypoints at 1 m intervals on the centerline (z=0), from the spawn to
// the track end, following the terrain. Each trigger is a 1 m (x) ×
// track-width (z) slab ending just BEFORE the waypoint's x-plane - the
// slabs tile the track, so a car crosses exactly one new slab per metre
// of forward driving. The 1 m lattice gives severe centering: the bearing
// aims at a waypoint at most 1 m ahead on the centerline, so a car off
// the track gets a saturated steering signal. Sequential activation; the
// terminal is the track end (or a goal waypoint when a tool sets one);
// the lateral bound is the track half-width.
S_SPAWN_X :: f32(-10.0) // spawn x: a flat approach for a stable start
// Start line (m from the spawn): deliberately below the gen-0 random
// floor, so gen 0 usually clears it and the line doubles at the gen-0
// boundary (adapt_track_len).
TARGET_START_LEN :: f32(200.0)
// The live finish line + its cap live in env / env_max_len (see Env above);
// this const only sets the line at startup (env's initializer).
// Red end zone: the last END_ZONE_LEN metres of the visible track render
// red (the finish face).
END_ZONE_LEN :: f32(20.0)
S_SPACING :: f32(1.0) // waypoint spacing along x - 1 m = the score unit
DIST_NORM :: f32(40.0) // distance-normalization scale for sensors

// Hard cap on a rollout (seconds). Used by the smoke/diagnostic tools.
DEFAULT_TIME_LIMIT :: f32(47.0)

// ─── Liveness gate (the unified end conditions) ───────────────────────
// A run stays live only while the car is (a) in ground contact,
// (b) making forward progress, and (c) moving in some direction. Letting
// any condition lapse for its window fails the run:
//   • launched / airborne        → out of ground contact → no_ground window
//   • fell off the map / the line → out of ground contact → no_ground window
//   • pinned exactly still (wedged, braked against a wall) → no movement
//     in any direction → no_move window
//   • stuck / shuffling / crawling → below the progress rate floor → no_progress window
//
// All windows are measured in SIM TIME (TIME_STEP per tick) - never wall
// clock - so a view running at any speed and the GA agree tick for tick.
//
// Ground contact is |chassis_y − ground_y| ≤ GROUND_TOL, local-ground-
// relative (terrain_height_p over this world's own profile copy). It must
// exceed the car's resting height above the ground (~1 m) plus the largest
// legitimate hop (~3.6 m crest clearance at the joint-safe ramp floor); a
// launched body (a degenerate shape that can't stand at spawn) or a car
// fallen into the void sits well outside that band. Brief airtime (a hop
// that re-contacts within NO_GROUND_TIME) is fine - only sustained loss of
// contact fails.
//
// Progress is a max-x ratchet (stall_best_x) with a
// RATE FLOOR: the ratchet must gain PROGRESS_MIN_V · NO_PROGRESS_TIME
// metres of new ground within the window (progress_base_x is the budget
// reference) before no_progress resets - a new max alone is not enough,
// so an inching shoulder crawler cannot run forever. PROGRESS_MIN_V sits
// below the median mover (3-D cars cruise 1.3–9 m/s), so a car grinding up
// terrain at real speed survives; only one crawling below the floor for
// the whole window dies. The GA worker has no separate time cap, so
// NO_PROGRESS_TIME is the effective bound on a slow car (the evolvetest/
// smoke loops also cap at DEFAULT_TIME_LIMIT).
//
// Stillness: the chassis counts as "not moving" while it stays within
// NO_MOVE_EPS of the reference position (move_ref, set at spawn and
// refreshed to the current position whenever the chassis leaves the ball);
// no_move accrues for the whole ball stay and fails the run at NO_MOVE_TIME.
// It catches a car pinned exactly still - a strict subset of the no-progress
// window, failed sooner (3 s vs NO_PROGRESS_TIME) so the GA does not burn a
// whole progress window on a car that is not even shuffling. Any sustained
// motion, however slow and in whatever direction, refreshes the reference
// and survives here; a creeping car that never gains ground is the
// no-progress window's job.
GROUND_TOL :: f32(5.0) // |chassis_y − ground_y| at/below this = "in contact"
NO_GROUND_TIME :: f32(3.0) // out of ground contact this long -> fail
NO_MOVE_TIME :: f32(3.0) // no movement in any direction this long -> fail (stalled)
NO_MOVE_EPS :: f32(0.05) // m: within this of the reference = "not moving"
NO_PROGRESS_TIME :: f32(10.0) // below the progress rate floor this long -> fail (stuck)
PROGRESS_MIN_V :: f32(0.25) // m/s: the ratchet's required average gain per window

Waypoint :: struct {
	index:     int,
	pos:       [3]f32,
	activated: bool,
}

// Generate the straight-track course to a given finish line (m from the
// spawn): one waypoint per metre. The waypoints are the bot's steering
// line (sequential activation); the score is the ratcheted distance
// (rollout_score_m, evolve.odin). Caller owns the returned [dynamic]; the
// goal index (if a tool sets a goal terminal) is len(out) - 1. The line
// and the profile are parameters, not the live env (the Env contract).
generate_course_len :: proc(track_len: f32, profile: []f32) -> [dynamic]Waypoint {
	n := int(math.floor(track_len + 0.5))
	out := make([dynamic]Waypoint, 0, n)
	for i in 0 ..< n {
		x := S_SPAWN_X + S_SPACING * f32(i + 1)
		append(&out, Waypoint{index = i, pos = {x, terrain_height_p(profile, x, 0.0), 0.0}})
	}
	return out
}

// The course for the CURRENT live track length (headless evals, tools).
generate_course :: proc() -> [dynamic]Waypoint {
	return generate_course_len(env.line, env_profile[:])
}

// Next track end (m from the spawn) from the ratcheted running best: the
// line extends only when the record has REACHED the current line, then
// doubles (2× the record), capped at the terrain's reach. Monotone by
// construction (the record is non-decreasing, and when it has reached the
// line, 2× the record > the line). Pure: reads only `e` and the
// env_max_len cap - the caller owns writing the result back.
adapt_track_len :: proc(run_best_m: f64, e: Env) -> f32 {
	if f32(run_best_m) < e.line {return e.line}
	next := 2.0 * f32(run_best_m)
	if next > env_max_len {next = env_max_len}
	return next
}

// Move the finish line (the track end). No invalidation machinery: the
// render cache gates on the displayed (seed, line) pair, and the GA
// passes the line to every rollout as a parameter.
set_line :: proc(v: f32) {
	env.line = v
}


// Spawn pose for one starting heading (radians, physical), at
// (S_SPAWN_X, 0): yaw = −heading so the car's nose points along `heading`
// (Box3D's +Y rotation by α drives along heading − α). heading 0 = straight
// at wp0 (dead ahead).
spawn_pose :: proc(start_heading: f32) -> (x, z, yaw: f32) {
	return S_SPAWN_X, 0.0, -start_heading
}

// ─── Sensor vector ──────────────────────────────────────────────────
// N_WHEELS: axle slots (the full slot count, 8); the GENERATION stage
// limits the ENABLED axles to max_axles (default 3, `--max-wheels N`  - 
// evolve.odin) so the default car profile is unchanged while 8-slot
// support is in place. Each slot is ~50% enabled (WHEEL_PROB). Sizes the
// per-wheel sensors. A wheel slot's vertex gene is -1 = disabled axle, so
// a car has 0..N_WHEELS axles (a 0-axle car is stillborn by design - it
// stalls out).
N_WHEELS :: 8
// N_SENSORS = 12 + 2 × N_WHEELS (slots). The first 12 are body-level; per
// wheel i, indices 12+2i (suspension travel LEFT) and 13+2i (RIGHT). The
// wheel index runs over Body_Model.wheels order. Sized to the full N_WHEELS
// axle slots (12 + 2×8 = 28); a car with fewer enabled axles leaves the
// unused slots at zero.
N_SENSORS :: 12 + 2 * N_WHEELS // 28 (full slot count)

// ─── Flip logging ──────────────────────────────────────────────────
// Chassis attitude vs world up, to detect flips *in the sense that matters*:
// the waypoint-bearing frame's handedness is sign(uy), where uy =
// chassis-up·Ŷ and up U = left×forward (rigid, from chassis_axes). A pure
// yaw (tail-first) flips forward without flipping uy - the bearing reading
// stays correct - while roof/somersault flips flip uy and mirror the
// reading. Logging only: no fitness effect.
//
// Threshold: uy < −0.7 (chassis up ≥ 134.4° from world up). −0.7 still
// catches the near-side states (a 90° roll is uy = 0) and only misses an
// on-its-side rest with the nose pointing straight down (uy → 0 again via
// pitch); the event's fy/ly are logged, so those are visible in the data
// either way.
FLIP_UP_T :: f32(-0.7) // below this the car counts as inverted
FLIP_EVENT_CAP :: 16 // entry events kept per rollout

Flip_Event :: struct {
	t:  f32, // sim time of entry into the inverted state
	fy: f32, // forward·Ŷ
	ly: f32, // left·Ŷ
	uy: f32, // up·Ŷ (bearing-frame handedness)
}

// ─── Breakable chassis ─────────────────────────────────────────────
// A contact whose max normal impulse exceeds BREAK_K × the hit segment's
// mass splits that segment off as debris; the 7th break ends the run at
// the max position reached (the ratcheted stall_best_x). Box3D's
// per-point normalImpulse is the warm-started + accumulated total over
// the full step (N·s), so impulse / segment mass has units of m/s - the
// effective impact velocity - and K needs no rescaling. Sweepable
// (--break-k).
BREAK_K := f32(50.0)
MAX_BREAKS :: 7
BREAK_EVENT_CAP :: 8 // break events kept per rollout (MAX_BREAKS + 1)

Break_Event :: struct {
	t:       f32, // sim time of the break
	seg:     int, // the segment that broke (sorted-ring vertex index)
	impulse: f32, // max normal impulse on that segment (N·s, full step)
	ratio:   f32, // impulse / segment mass (m/s, the threshold-relative read)
}

// Max normal impulse (N·s, full step) on each of the 8 segments in the
// CURRENT chassis - the raw signal before the break threshold. The
// contact→segment map is the packed shape ids recorded at build time.
// Cap-limited: a chassis touching more than 16 bodies in one step is
// pathological; the excess simply does not fire the threshold
// (deterministic either way). Used by check_breaks.
seg_impulse_max :: proc(bot: ^Bot) -> [8]f32 {
	cds := [16]b3.Contact_Info{}
	n := b3.Body_GetContacts(bot.chassis, cds[:])
	seg_max := [8]f32{}
	for i in 0 ..< n {
		c := cds[i]
		seg := -1
		found := false
		s := 0
		for ; s < 8 && !found; s += 1 {
			for id in bot.seg_shapes[s] {
				if c.shape_a == id || c.shape_b == id {
					seg = s
					found = true
					break
				}
			}
		}
		if seg < 0 || bot.broken[seg] {continue}
		for m in 0 ..< c.manifold_count {
			mf := c.manifolds[m]
			for p in 0 ..< mf.point_count {
				imp := mf.points[p].normal_impulse
				if imp > seg_max[seg] {seg_max[seg] = imp}
			}
		}
	}
	return seg_max
}

// Check whether the chassis breaks this step: per segment, the max normal
// impulse over its hulls this step vs BREAK_K × the segment's analytical
// mass. Breaking segments are shed (apply_breaks: debris + rebuild +
// wheel recreation + torque recompute), events are logged, and the run
// fails at the MAX_BREAKS-th break. A pure function of the just-stepped
// contact state → bit-identical across every step_sim path. One frame can
// exceed the threshold on several segments at once (a tumbling belly hit),
// so the batch is capped at the remaining budget: the run ends at exactly
// the 7th break and ≥1 segment always survives - an 8/8 shed would leave
// a mass-0, never-drawn chassis.
check_breaks :: proc(state: ^Sim_State) {
	bot := &state.bot
	if state.failed || state.finished || bot.n_breaks >= MAX_BREAKS {return}

	seg_max := seg_impulse_max(bot)
	// Stability log: the largest impulse seen this rollout (any segment).
	for s in 0 ..< 8 {
		if seg_max[s] > state.max_impulse {state.max_impulse = seg_max[s]}
	}
	budget := MAX_BREAKS - bot.n_breaks
	segs := [8]int{}
	nsegs := 0
	for s in 0 ..< 8 {
		if nsegs == budget {break}
		// Only wedge-bearing segments can break: a skipped (degenerate)
		// segment carries at most its wheel's strut boxes - a few grams  - 
		// whose impulse/mass ratio would shed the wheel on trivial contact.
		if !bot.broken[s] && bot.seg_wedge[s] && seg_max[s] > BREAK_K * bot.seg_mass[s] {
			segs[nsegs] = s
			nsegs += 1
		}
	}
	if nsegs == 0 {return}
	apply_breaks(state.world, &state.body_model, bot, segs[:nsegs])
	for i in 0 ..< nsegs {
		s := segs[i]
		bot.n_breaks += 1
		if state.n_break_events < BREAK_EVENT_CAP {
			state.break_events[state.n_break_events] = Break_Event {
				t       = state.sim_time,
				seg     = s,
				impulse = seg_max[s],
				ratio   = seg_max[s] / bot.seg_mass[s],
			}
			state.n_break_events += 1
		}
	}
	// The 7th break ends the run (the score ratchet already holds the max
	// position reached).
	if bot.n_breaks >= MAX_BREAKS {state.failed = true}
}

// ─── Sim state ────────────────────────────────────────────────────
Sim_State :: struct {
	world:           b3.WorldId,
	terrain:         b3.HeightField,
	profile:         [TERRAIN_COLS]f32, // this world's own ground (copied at init from profile_for(e.seed)); the per-tick terrain reads use it, never the live profile
	body_model:      Body_Model, // derived from the genome (owned; cloned per sim)
	bot:             Bot,
	waypoints:       [dynamic]Waypoint, // OWNED (no aliasing)
	next_target:     int,
	sim_time:        f32,
	step_count:      int,
	finished:        bool, // track end reached (full clear) or goal waypoint activated
	failed:          bool, // NaN / break cap (MAX_BREAKS) / liveness gate (no ground contact / no move / no progress)
	stalled:         bool, // failed by the liveness gate's no-move or no-progress window (diagnostic)
	stall_best_x:    f32, // farthest chassis x reached (the score ratchet)
	no_ground:       f32, // sim time out of ground contact (liveness gate, window 1)
	no_move:         f32, // sim time within NO_MOVE_EPS of move_ref (liveness gate, window 3)
	move_ref:        [3]f32, // no-move reference position; refreshed when the chassis leaves the NO_MOVE_EPS ball
	no_progress:     f32, // sim time below the progress rate floor (liveness gate, window 2)
	progress_base_x: f32, // stall_best_x when no_progress last reset (the rate-floor budget reference)
	goal:            int, // goal waypoint index; -1 = no goal terminal
	track_end:       f32, // this rollout's finish line (m from the spawn) - the hard-x terminal AND the heightfield's extent; a line extension during a run does not move a racing car's goalposts
	leg_start_dist:  f64, // distance to the current target at leg start (dense reward)
	prev_steer:      [dynamic]f32, // per-wheel achieved steer (the tel 'steer' channel)

	// Flip log (filled by step_sim): steps inverted + entry events.
	flip_steps:      int,
	flip_events:     [FLIP_EVENT_CAP]Flip_Event,
	n_flip_events:   int,
	_inverted:       bool,
	// Break log (filled by check_breaks): the shed segments.
	break_events:    [BREAK_EVENT_CAP]Break_Event,
	n_break_events:  int,

	// Stability log: per-rollout maxima (speed, per-step position jump  - 
	// a healthy step moves ≤ v·TIME_STEP, so a jump is the teleport
	// signature of a solver blow-up; height above local terrain; max
	// chassis–terrain normal impulse from check_breaks). Pure logging  - 
	// rollouts stay bit-identical.
	max_speed:       f32, // max chassis |v| (m/s)
	max_jump:        f32, // max per-step chassis displacement (m)
	max_height:      f32, // max chassis height above local terrain (m)
	max_impulse:     f32, // max chassis–terrain normal impulse (N·s, full step)
	max_prev:        [3]f32, // chassis position at the previous step (max_jump)
}

// ─── Sim query helpers ────────────────────────────────────────────
dist_to_target :: proc(state: ^Sim_State, idx: int) -> f32 {
	if idx < 0 || idx >= len(state.waypoints) {return 0.0}
	wp := state.waypoints[idx]
	cp := b3.Body_GetPosition(state.bot.chassis)
	dx := cp[0] - wp.pos[0]
	dz := cp[2] - wp.pos[2]
	return math.sqrt(dx * dx + dz * dz)
}

count_activated :: proc(state: ^Sim_State) -> int {
	n := 0
	for wp in state.waypoints {if wp.activated {n += 1}}
	return n
}

// Dense progress: waypoints activated + normalized distance-closed toward the
// current target relative to where the bot started this leg. Nonzero from step
// 1 - the gradient the GA needs.
progress :: proc(state: ^Sim_State) -> f64 {
	N := len(state.waypoints)
	total := f64(count_activated(state))
	if state.next_target < 0 || state.next_target >= N {return total}
	nearest := dist_to_target(state, state.next_target)
	leg := state.leg_start_dist
	if leg <= 0 {leg = 1.0}
	frac := 1.0 - f64(nearest) / leg
	if frac < 0 {frac = 0}
	return total + frac
}

// ─── Init / destroy ────────────────────────────────────────────────
// `genome` is read to derive the Body_Model (each sim owns its derived body
// model so a training thread's many short-lived sims don't alias the source).
// `waypoints` ownership transfers to the returned state (freed by destroy_sim).
init_sim_pose :: proc(
	genome: ^Genome,
	waypoints: [dynamic]Waypoint, // ownership transferred to the returned state
	spawn_x, spawn_z, yaw: f32,
	e: Env, // the world the rollout races in (ground seed + finish line)
	roll: f32 = 0.0, // spawn roll about the forward axis
) -> Sim_State {
	sync.mutex_lock(&box3d_world_mutex)
	world_def := b3.DefaultWorldDef()
	b3.WorldDef_SetGravity(world_def, 0, -gravity, 0)
	b3.WorldDef_SetContactHertz(world_def, CONTACT_HERTZ)
	b3.WorldDef_SetContactDampingRatio(world_def, CONTACT_DAMPING_RATIO)
	b3.WorldDef_SetRestitutionThreshold(world_def, RESTITUTION_THRESHOLD)
	b3.WorldDef_SetContactSpeed(world_def, CONTACT_SPEED)
	world := b3.CreateWorld(world_def)
	sync.mutex_unlock(&box3d_world_mutex)
	b3.FreeWorldDef(world_def)

	state := Sim_State {
		world       = world,
		waypoints   = waypoints,
		next_target = 0,
		goal        = -1,
		track_end   = e.line,
		// This world's own ground: the per-tick terrain reads use this
		// copy, never the live profile (the Env contract).
		profile     = profile_for(e.seed),
	}

	// Track terrain: static body carrying the hilly heightfield, centred on origin.
	ground_def := b3.DefaultBodyDef()
	b3.BodyDef_SetPosition(ground_def, TERRAIN_OFFSET[0], TERRAIN_OFFSET[1], TERRAIN_OFFSET[2])
	ground := b3.CreateBody(world, ground_def)
	b3.FreeBodyDef(ground_def)

	hf := create_track_heightfield_len(e.line, state.profile[:])
	hf_sd := b3.DefaultShapeDef()
	b3.ShapeDef_SetDensity(hf_sd, 0)
	b3.ShapeDef_SetFriction(hf_sd, terrain_friction)
	b3.CreateHeightFieldShape(ground, hf_sd, hf)
	b3.FreeShapeDef(hf_sd)
	state.terrain = hf

	// Spawn: the car's lowest point (wheel bottoms) sits SPAWN_GAP above
	// ground; a rolled spawn drops from a fixed height instead (the
	// upright lowest_point_of is meaningless for a rolled car).
	SPAWN_GAP :: f32(0.05)
	TIP_SPAWN_HEIGHT :: f32(2.0)
	state.body_model = genome_to_body(genome)
	spawn_y := f32(0.0)
	if roll == 0.0 {
		spawn_y =
			terrain_height_p(state.profile[:], spawn_x, spawn_z) -
			lowest_point_of(&state.body_model) +
			SPAWN_GAP
	} else {
		spawn_y = terrain_height_p(state.profile[:], spawn_x, spawn_z) + TIP_SPAWN_HEIGHT
	}

	state.bot = build_bot(world, &state.body_model, spawn_x, spawn_y, spawn_z, yaw, roll)
	state.prev_steer = make([dynamic]f32, len(state.bot.wheels))
	// Score ratchet + rate-floor budget references: the actual settled
	// spawn position.
	spawn_pos := b3.Body_GetPosition(state.bot.chassis)
	state.stall_best_x = spawn_pos[0]
	state.progress_base_x = spawn_pos[0]
	// No-move reference: the same spawn position.
	state.move_ref = spawn_pos
	// Dense reward reference: distance to the first target from the spawn.
	if len(waypoints) > 0 {
		state.leg_start_dist = f64(dist_to_target(&state, 0))
	}
	return state
}

destroy_sim :: proc(state: ^Sim_State) {
	destroy_bot(&state.bot)
	destroy_body_model(&state.body_model)
	if len(state.waypoints) > 0 {delete(state.waypoints)}
	if len(state.prev_steer) > 0 {delete(state.prev_steer)}
	// Destroy the WORLD before the heightfield (CreateHeightFieldShape stores
	// the b3HeightFieldData* by pointer, no clone - docs/FFI_WASM.md §2).
	sync.mutex_lock(&box3d_world_mutex)
	b3.DestroyWorld(state.world)
	sync.mutex_unlock(&box3d_world_mutex)
	b3.DestroyHeightField(state.terrain)
	state^ = {}
}

// ─── Body transform / axis helpers ──────────────────────────────────
// Chassis-local axes in world space from the rotation quaternion (x,y,z,w):
// forward = rot·(1,0,0) (the nose), left = rot·(0,0,1).
chassis_axes :: proc(q: [4]f32) -> (forward, left: [3]f32) {
	qx, qy, qz, qw := q[0], q[1], q[2], q[3]
	forward = {1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy + qw * qz), 2 * (qx * qz - qw * qy)}
	left = {2 * (qx * qz + qw * qy), 2 * (qy * qz - qw * qx), 1 - 2 * (qx * qx + qy * qy)}
	return
}

// The chassis's apparent nose angle in the track's side-view plane
// (radians): forward projected onto the world x-y plane, measured from
// the track direction (+x); >0 = nose up (the 2-D rotation the side-view
// portrait tilts by). atan2(fy, fx) rather than an elevation form: the
// elevation form's denominator is always positive, so it folded
// tail-first (fx < 0) cars into the front half.
chassis_pitch :: proc(chassis: b3.BodyId) -> f32 {
	q := b3.Body_GetRotation(chassis)
	forward, _ := chassis_axes(q)
	fx, fy := forward[0], forward[1]
	if math.abs(fx) < 1e-6 && math.abs(fy) < 1e-6 {return 0}
	return math.atan2(fy, fx)
}

// ─── Crafted PID steering (hand-crafted policy; the sole controller) ───────
// The sole controller on every path - the headless rollouts and every
// GA/viewer car drive with the exact same one, so the native window and
// the browser match.
//
// Error: the bearing to a centerline (z=0) point `lookahead` m ahead - NOT
// the 1 m waypoint bearing (sensors[0]), which swings through ±90° as the
// car passes each waypoint and makes a naive PID weave; the longer aim point
// maps a lateral offset to a small, near-linear angle (fast + stable).
//
//   e          = bearing to the lookahead point (radians, clamped ±90°); >0 = LEFT
//   base_steer = clamp(-kp·e − kd·yaw_rate, −steer_max, +steer_max)
//   steer[i]   = clamp(base_steer + bias[i], −steer_max, +steer_max)
//   left[i]    = (base_spin − steer[i]) · −SPIN_SPEED   (inside wheel when steer>0)
//   right[i]   = (base_spin + steer[i]) · −SPIN_SPEED
// Sign: +steer = more power to the RIGHT wheel = RIGHT turn, so a
// positive-bearing (left) aim takes NEGATIVE steer.
Pid_Coeff :: struct {
	kp:        f32, // proportional gain on the lookahead bearing
	kd:        f32, // derivative gain on yaw rate
	base_spin: f32, // straight-ahead spin (fraction of SPIN_SPEED); 1.0 = full
	steer_max: f32, // max |steer| (fraction of SPIN_SPEED): 1.0 = inside to 0; >1 = reverse
	lookahead: f32, // meters ahead on the centerline to aim at (smoother error)
	bias:      [N_WHEELS]f32, // per-axle steer bias (differential across the slots)
}

// Bearing (radians, clamped to ±90°) to a lookahead point on the centerline
// (z=0) `la` meters ahead of the bot, in the body frame. >0 = aim to the LEFT.
// The profile is the caller's: the rollout's own copy (Sim_State.profile) on
// the driving path, the live materialized profile on the display gauges.
pid_lookahead_bearing :: proc(cp: [3]f32, quat: [4]f32, la: f32, profile: []f32) -> f32 {
	forward, left := chassis_axes(quat)
	ax := cp[0] + la
	dx := ax - cp[0]
	dy := terrain_height_p(profile, ax, 0.0) - cp[1]
	dz := 0.0 - cp[2]
	fc := dx * forward[0] + dy * forward[1] + dz * forward[2]
	lc := dx * left[0] + dy * left[1] + dz * left[2]
	e := f32(math.atan2(lc, fc))
	if e > f32(math.PI) / 2 {return f32(math.PI) / 2}
	if e < -f32(math.PI) / 2 {return -f32(math.PI) / 2}
	return e
}

// Apply the crafted per-axle differential (full range: each inside wheel can
// reach 0 or reverse). steer[i] is the per-axle command (clamped by caller).
pid_drive :: proc(bot: ^Bot, base_spin: f32, steer: []f32) {
	for i in 0 ..< len(bot.wheels) {
		if bot.broken[bot.wheels[i].mount_vertex] {continue} 	// dead pair: jointless
		j := bot.wheels[i]
		set_wheel_spin_speed(j.joint_l, (base_spin - steer[i]) * -SPIN_SPEED)
		set_wheel_spin_speed(j.joint_r, (base_spin + steer[i]) * -SPIN_SPEED)
	}
}

// One crafted-PID step for a live sim. Memoryless P+D. Reads the pose
// directly, no sensor vector. Returns the base steer.
pid_drive_car :: proc(sim: ^Sim_State, c: Pid_Coeff) -> f32 {
	cp := b3.Body_GetPosition(sim.bot.chassis)
	quat := b3.Body_GetRotation(sim.bot.chassis)
	e := pid_lookahead_bearing(cp, quat, c.lookahead, sim.profile[:])
	yaw_rate := b3.Body_GetAngularVelocity(sim.bot.chassis)[1]
	base := -c.kp * e - c.kd * yaw_rate
	if base > c.steer_max {base = c.steer_max}
	if base < -c.steer_max {base = -c.steer_max}
	steers := [N_WHEELS]f32{}
	for i in 0 ..< len(sim.bot.wheels) {
		s := base + c.bias[i]
		if s > c.steer_max {s = c.steer_max}
		if s < -c.steer_max {s = -c.steer_max}
		steers[i] = s
	}
	// Record the commanded steer (the tel 'steer' channel); this path fills
	// prev_steer.
	if len(sim.prev_steer) == len(sim.bot.wheels) {
		for i in 0 ..< len(sim.bot.wheels) {
			sim.prev_steer[i] = steers[i]
		}
	}
	pid_drive(&sim.bot, c.base_spin, steers[:])
	return base
}

// The fixed steering policy (hand-tuned, frozen): the GA's rollouts and the
// live viewer both drive with pid_drive_car(sim, PID_COEFF).
PID_COEFF :: Pid_Coeff {
	kp        = 1.0,
	kd        = 0.3,
	base_spin = 1.0,
	steer_max = 0.8,
	lookahead = 10.0,
}

// ─── Sensors ───────────────────────────────────────────────────────
// Layout:
//   0-1  sin/cos(bearing) to next waypoint       (body frame)
//   2    normalized distance to next waypoint
//   3-4  sin/cos(bearing) to waypoint after next (body frame)
//   5    normalized distance to waypoint after next
//   6    forward speed (linear velocity ⋅ nose)
//   7    yaw rate (angular velocity about world up)
//   8    roll / lean angle
//   9    roll rate (angular velocity about nose)
//   10   pitch angle
//   11   pitch rate (angular velocity about lateral)
//   12+2i  suspension travel from rest, wheel i LEFT (m, along strut axis)
//   13+2i  suspension travel from rest, wheel i RIGHT (m)
bearing_dist :: proc(pos, forward, left, wp_pos: [3]f32) -> (sb, cb, dn: f32) {
	d := [3]f32{wp_pos[0] - pos[0], wp_pos[1] - pos[1], wp_pos[2] - pos[2]}
	fc := d[0] * forward[0] + d[1] * forward[1] + d[2] * forward[2]
	lc := d[0] * left[0] + d[1] * left[1] + d[2] * left[2]
	hd := math.sqrt(fc * fc + lc * lc)
	bearing := f32(math.atan2(lc, fc))
	return f32(math.sin(bearing)), f32(math.cos(bearing)), hd / DIST_NORM
}

// SHARED sensor computation: the Sim_State path (sensors) and the pop
// viewer use one implementation - no drift.
sensors_core :: proc(
	bot: ^Bot,
	waypoints: []Waypoint,
	next_target: int,
	finished: bool,
	out: []f32,
) {
	assert(len(out) == N_SENSORS)
	pos, quat := b3.Body_GetPosition(bot.chassis), b3.Body_GetRotation(bot.chassis)
	forward, left := chassis_axes(quat)

	t0 := next_target
	if t0 >= len(waypoints) {t0 = len(waypoints) - 1}
	t1 := next_target + 1
	// Last leg: no "waypoint after the current" - clamp to the target
	// instead of wrapping to wp0 (behind the bot: a bogus steering signal).
	if t1 >= len(waypoints) {t1 = t0}
	if finished {t1 = t0}

	wp0 := waypoints[t0]
	sb0, cb0, dn0 := bearing_dist(pos, forward, left, wp0.pos)
	out[0] = sb0;out[1] = cb0;out[2] = dn0

	wp1 := waypoints[t1]
	sb1, cb1, dn1 := bearing_dist(pos, forward, left, wp1.pos)
	out[3] = sb1;out[4] = cb1;out[5] = dn1

	lin_vel := b3.Body_GetLinearVelocity(bot.chassis)
	ang_vel := b3.Body_GetAngularVelocity(bot.chassis)

	out[6] = lin_vel[0] * forward[0] + lin_vel[1] * forward[1] + lin_vel[2] * forward[2]
	out[7] = ang_vel[1]
	out[8] = math.asin(math.clamp(left[1], -1.0, 1.0))
	out[9] = ang_vel[0] * forward[0] + ang_vel[1] * forward[1] + ang_vel[2] * forward[2]
	out[10] = math.asin(math.clamp(forward[1], -1.0, 1.0))
	out[11] = ang_vel[0] * left[0] + ang_vel[1] * left[1] + ang_vel[2] * left[2]

	// Per-wheel suspension travel from rest (m): left in 12+2i, right in
	// 13+2i. Dead pairs (their segment broke) read zero - the same
	// no-signal a disabled axle slot gives.
	for i in 0 ..< len(bot.wheels) {
		if bot.broken[bot.wheels[i].mount_vertex] {continue}
		out[12 + 2 * i + 0] = suspension_travel(bot, i, -1.0)
		out[12 + 2 * i + 1] = suspension_travel(bot, i, +1.0)
	}
}

sensors :: proc(state: ^Sim_State, out: []f32) {
	sensors_core(&state.bot, state.waypoints[:], state.next_target, state.finished, out)
}

// ─── Waypoint trigger ──────────────────────────────────────────────
// SHARED predicate (training and the pop viewer, both via step_sim - one
// path, no drift): the chassis is inside the waypoint's slab - the
// S_SPACING x-band ending just before the waypoint's x-plane, the full
// track width in z, UNBOUNDED in height (no y test here - step_sim's
// ground-contact test keeps a launched car from activating slabs in
// flight, so airtime never accrues progress). The slabs tile the track:
// one activation per metre.
waypoint_slab_hit :: proc(pos, wp_pos: [3]f32) -> bool {
	dx := pos[0] - wp_pos[0]
	dz := math.abs(pos[2] - wp_pos[2])
	// The slab spans the ribbon width (the fixed TRACK_HALF_WIDTH).
	return dx > -S_SPACING && dx <= 0.0 && dz <= TRACK_HALF_WIDTH
}

// ─── Liveness gate (one sim tick) ───────────────────────────────────
// Advance the score ratchet + the end-condition windows from one chassis
// position `cp`: the ratchet runs every step (it feeds the score + the
// rate-floor budget), the windows only while the run is live. `grounded`
// is the caller's ground-contact test (|chassis_y − ground_y| ≤ GROUND_TOL).
// NaN-safe (every comparison is false for NaN); mutates the state's window
// fields in place.
liveness_update :: proc(state: ^Sim_State, cp: [3]f32, grounded: bool) {
	// Score ratchet: the farthest point reached (a plain max, no eps gate).
	if cp[0] > state.stall_best_x {
		state.stall_best_x = cp[0]
	}
	if state.failed {return}
	// Window (1) - ground contact: out of contact for the whole window
	// (launch, fall off the map, past the line). A brief hop that
	// re-contacts within it survives.
	if grounded {
		state.no_ground = 0
	} else {
		state.no_ground += TIME_STEP
	}
	if state.no_ground > NO_GROUND_TIME {
		state.failed = true
		return
	}
	// Window (2) - progress: a RATE FLOOR, not just a new max - the ratchet
	// must gain PROGRESS_MIN_V · NO_PROGRESS_TIME metres past
	// progress_base_x before the timer resets and the budget reference
	// advances (catches stalls, shuffling, and sub-floor crawling). Sim
	// time, like window (1).
	if state.stall_best_x >= state.progress_base_x + PROGRESS_MIN_V * NO_PROGRESS_TIME {
		state.no_progress = 0
		state.progress_base_x = state.stall_best_x
	} else {
		state.no_progress += TIME_STEP
	}
	if state.no_progress > NO_PROGRESS_TIME {
		state.stalled = true
		state.failed = true
		return
	}
	// Window (3) - stillness: the chassis stays within NO_MOVE_EPS of
	// move_ref - a strict subset of window (2)'s no-progress, failed
	// sooner (NO_MOVE_TIME < NO_PROGRESS_TIME) so the GA does not burn a
	// whole progress window on a car that is not even shuffling. Leaving
	// the ball refreshes the reference and restarts the timer. Sim time;
	// NaN-safe (a NaN displacement never refreshes the reference).
	dmx := cp[0] - state.move_ref[0]
	dmy := cp[1] - state.move_ref[1]
	dmz := cp[2] - state.move_ref[2]
	if dmx * dmx + dmy * dmy + dmz * dmz > NO_MOVE_EPS * NO_MOVE_EPS {
		state.move_ref = cp
		state.no_move = 0
	} else {
		state.no_move += TIME_STEP
	}
	if state.no_move > NO_MOVE_TIME {
		state.stalled = true
		state.failed = true
	}
}

step_sim :: proc(state: ^Sim_State) {
	damp_wobble(&state.bot)
	b3.World_Step(state.world, TIME_STEP, SUB_STEPS)
	state.sim_time += TIME_STEP
	state.step_count += 1

	// Flip log: sign(uy) is the bearing frame's handedness; uy < FLIP_UP_T
	// = inverted in the sense that matters. Count the steps, record one
	// event per entry - pure logging (no RNG/fitness), rollouts stay
	// bit-identical.
	q := b3.Body_GetRotation(state.bot.chassis)
	fwd, left := chassis_axes(q)
	uy := left[2] * fwd[0] - left[0] * fwd[2]
	if uy == uy { 	// NaN-safe: a degenerate body reports NaN attitude
		if uy < FLIP_UP_T {
			state.flip_steps += 1
			if !state._inverted && state.n_flip_events < FLIP_EVENT_CAP {
				state.flip_events[state.n_flip_events] = Flip_Event {
					t  = state.sim_time,
					fy = fwd[1],
					ly = left[1],
					uy = uy,
				}
				state.n_flip_events += 1
			}
			state._inverted = true
		} else {
			state._inverted = false
		}
	}

	cp := b3.Body_GetPosition(state.bot.chassis)
	// NaN bail: a degenerate body can trip Box3D's solver and leave the chassis
	// at NaN. NaN != NaN.
	if cp[0] != cp[0] || cp[1] != cp[1] || cp[2] != cp[2] {state.failed = true}
	// Break check (after the NaN guard: a NaN chassis's contacts are
	// meaningless, and the check itself is NaN-inert).
	check_breaks(state)
	// Local ground under the chassis (this world's own profile copy - the
	// Env contract). NaN-safe: a NaN chassis reads back a finite height,
	// so `grounded` is false for it (the bail above already failed it).
	ground := terrain_height_p(state.profile[:], cp[0], cp[2])
	// Stability log: per-step maxima - speed, position jump (a healthy step
	// moves ≤ v·TIME_STEP, so a jump is the teleport signature of a solver
	// blow-up), height above local terrain. NaN-inert; pure logging.
	v := b3.Body_GetLinearVelocity(state.bot.chassis)
	sp := math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
	if sp > state.max_speed {state.max_speed = sp}
	if cp[0] == cp[0] && cp[1] == cp[1] && cp[2] == cp[2] {
		h := cp[1] - ground
		if h > state.max_height {state.max_height = h}
		if state.step_count > 1 {
			dx := cp[0] - state.max_prev[0]
			dy := cp[1] - state.max_prev[1]
			dz := cp[2] - state.max_prev[2]
			jump := math.sqrt(dx * dx + dy * dy + dz * dz)
			if jump > state.max_jump {state.max_jump = jump}
		}
	}
	copy(state.max_prev[:], cp[:])
	// Ground contact (window (1) of the liveness gate, shared with
	// liveness_update): local-ground-relative - the profile spans hundreds
	// of metres, so an absolute band would misfire. Before the waypoint
	// pass, so it blocks waypoint accrual (a launched car never accrues
	// progress in flight), the goal slab included. NaN-safe.
	grounded := math.abs(cp[1] - ground) <= GROUND_TOL
	for i in 0 ..< len(state.waypoints) {
		if state.waypoints[i].activated {continue}
		overlap := waypoint_slab_hit(cp, state.waypoints[i].pos)
		predecessor_ok := i == 0 || state.waypoints[i - 1].activated
		if overlap && predecessor_ok && grounded {
			state.waypoints[i].activated = true
			if i == state.next_target {
				state.next_target = i + 1
				// New leg: reference is the distance to the new target from here.
				state.leg_start_dist = f64(dist_to_target(state, state.next_target))
			}
			if i == state.goal {state.finished = true}
		}
	}

	// Track end = the finish line (state.track_end, captured at init - the
	// Env contract: a mid-run line extension does not move a racing car's
	// goalposts). A hard x test (not a waypoint slab), so a line clear
	// scores exactly the line - no short landing; .finished just marks
	// "made it to the end".
	if !state.failed && cp[0] > S_SPAWN_X + state.track_end {
		state.finished = true
	}
	// Liveness gate: score ratchet + the end-condition windows - see
	// liveness_update.
	liveness_update(state, cp, grounded)
}
