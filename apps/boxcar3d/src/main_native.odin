#+build !wasm32
// Native-only entry helpers + app lifecycle: run_main resolves data paths,
// starts the in-frame evolution session, and launches the window
// (run_native → host.run_app). The app always starts in evolve mode.

package main

import "core:fmt"
import "core:os"
import "core:time"
import host "engine:apphost"
import crash "engine:crash"
import b3 "engine:physics"

run_main :: proc() -> int {
	// Resolve the cwd-independent data paths (telemetry/crash) before any are
	// used - anchors to the app root via the executable, not the cwd.
	resolve_data_paths()
	// Install crash handlers (dump the telemetry ring to data/crash.log on
	// SIGSEGV/SIGABRT/SIGFPE/SIGILL, then re-raise for a core dump) before
	// any world is created.
	crash.crash_install(TEL_LOG, CRASH_LOG, DATA_DIR)
	// One-shot boot line: identifies this process in tel.log - wall clock
	// (anchors every line's `t=`), pid, the BINARY's mtime, subcommand.
	// Flushed immediately: headless subcommands never tick the 1 Hz flusher,
	// so an unflushed line would only reach disk on a crash.
	mode := "run"
	if len(os.args) >= 2 {mode = os.args[1]}
	// The BINARY's mtime via /proc/self/exe (the on-disk file, not this
	// process's start): a superseded build shows its own build time.
	exe := ""
	if mt, err := os.last_write_time_by_name("/proc/self/exe"); err == nil {
		exe = time_stamp(mt)
	}
	boot := time.now()
	stamp := time_stamp(boot)
	boot_line := fmt.aprintf(
		"[boot] {} pid={} exe={} mode={}\n",
		stamp,
		os.get_pid(),
		exe == "" ? "-" : exe,
		mode,
	)
	crash.crash_record(boot_line)
	crash.telemetry_flush()
	tel_boot_time = boot
	// Single-exit section: clean up inline. (No block-level defer: this Odin
	// build scopes defer to the innermost block, so a defer inside the `if`
	// above would free `exe` before the aprintf reads it.)
	delete(boot_line)
	delete(stamp)
	if exe != "" {delete(exe)}
	// Silence Box3D's diagnostic flood (the solver "unstable: NULL" line per
	// NaN body per step) before any world is created; the handler is a
	// process-global in Box3D's core.c, so one call covers every world.
	b3.Set_Log_Sink(.Silent)
	// Generate the default terrain track (the evolve paths re-roll it from
	// their own seeds).
	regenerate_terrain(TERRAIN_DEFAULT_SEED)
	// Global flags (may appear anywhere on the command line). The flag
	// tokens are STRIPPED from os.args so subcommand positional parsing
	// never mistakes them for arguments; the `evolve` subcommand owns its
	// own same-named --seed/--terrain-seed, so those two are stripped only
	// outside evolve mode.
	n := 0
	skip_next := false
	ga_seed := u64(0)
	terrain_seed := u64(0)
	for a, i in os.args {
		if skip_next {
			skip_next = false
			continue
		}
		switch a {
		case "--gravity":
			if i + 1 < len(os.args) {gravity = parse_f32_arg(os.args[i + 1])}
			skip_next = true
			continue
		case "--mass-mult":
			if i + 1 < len(os.args) {mass_mult = parse_f32_arg(os.args[i + 1])}
			skip_next = true
			continue
		case "--mu":
			// Uniform fixture friction (one μ on every fixture, combined
			// √(f₁·f₂)). Difficulty-exploration sweep.
			if i + 1 < len(os.args) {
				m := parse_f32_arg(os.args[i + 1])
				chassis_friction = m
				wheel_friction = m
				terrain_friction = m
			}
			skip_next = true
			continue
		case "--ramp-floor":
			if i + 1 < len(os.args) {terrain_ramp_floor = parse_f32_arg(os.args[i + 1])}
			skip_next = true
			continue
		case "--course":
			// Cap the track at M metres from the spawn for every mode:
			// the finish line cannot extend past it (probes/window run the
			// terrain up to the line, evolve optimizes distance on the
			// prefix).
			if i + 1 < len(os.args) {
				m := parse_f32_arg(os.args[i + 1])
				if m > 0 {env_max_len = m}
			}
			skip_next = true
			continue
		case "--max-wheels":
			// Generation-stage cap on enabled wheel slots (default 3;
			// N_WHEELS = 8 is the genome's slot capacity).
			if i + 1 < len(os.args) {
				mx := int(parse_u64_arg(os.args[i + 1]))
				if mx < 1 {mx = 1}
				if mx > N_WHEELS {mx = N_WHEELS}
				max_axles = mx
			}
			skip_next = true
			continue
		case "--break-k":
			// Breakable-chassis impact threshold (impulse per unit segment
			// mass, m/s of effective impact velocity).
			if i + 1 < len(os.args) {
				k := parse_f32_arg(os.args[i + 1])
				if k > 0 {BREAK_K = k}
			}
			skip_next = true
			continue
		case "--seed":
			// The windowed GA seed (gen-0 population).
			if i + 1 < len(os.args) {ga_seed = parse_u64_arg(os.args[i + 1])}
			skip_next = true
			continue
		case "--terrain-seed":
			// The windowed track (0 = the fixed default track).
			if i + 1 < len(os.args) {terrain_seed = parse_u64_arg(os.args[i + 1])}
			skip_next = true
			continue
		case "--pack":
			// Boot in the concurrent pack view (the wasm ?pack=1 URL param's
			// native twin).
			view_mode = 0
			continue
		case "--ff":
			// Boot with "evolve in background" ON (the wasm ?ff=1 twin).
			bg_evolve = true
			continue
		case "--tel-log":
			// Opt-in tel.log: flush the telemetry ring to data/tel.log ~1 Hz.
			// Off by default - the ring still records, so crash.log keeps the
			// last-second trail on a crash.
			crash.tel_flush_on = true
			continue
		case "--legacy-physics":
			gravity = f32(10.0)
			chassis_friction = f32(0.5)
			wheel_friction = f32(1.2)
			terrain_friction = f32(0.7)
			mass_mult = f32(0.625)
			chassis_restitution = f32(0.0)
			wheel_restitution = f32(0.0)
			continue
		}
		os.args[n] = a
		n += 1
	}
	os.args = os.args[:n]
	// Headless smoke tests (the gates that need no GUI).
	if len(os.args) >= 2 && os.args[1] == "smoke" {
		return run_smoke()
	}
	// GA gene-boundary + rollout gate (validates the evolve pipeline needs no
	// GUI). `fast` skips the in-frame session lifecycle cases (18/19/20)
	// for iteration; the bare form runs the full battery.
	if len(os.args) >= 2 && os.args[1] == "evolvetest" {
		fast := len(os.args) >= 3 && os.args[2] == "fast"
		return run_evolve_test(fast)
	}
	// One genome against a pinned Env (the pure-function property proof).
	if len(os.args) >= 2 && os.args[1] == "evalone" {
		return run_evalone(os.args[2:])
	}
	// Headless exposed-backface probe (diagnostic, not a gate).
	if len(os.args) >= 2 && os.args[1] == "backfaceprobe" {
		return probe_backface(os.args[2:])
	}
	// Share link from a saved genome (the native twin of the share button):
	// prints the fragment-only URL that boots a showcase of the car.
	if len(os.args) >= 2 && os.args[1] == "sharelink" {
		return run_sharelink(os.args[2:])
	}

	init_driver()
	// Start straight in evolve mode: the in-frame session creates the first
	// generation (step mode by default - the UI checkbox opts into
	// continuous background evolution). The session evolves bodies only;
	// every car races under the fixed PID. A fresh session starts all-random
	// (warm_start empty: no auto-load, no artifacts). GA seed = the --seed
	// flag (clock-derived when absent); track = the fixed default unless
	// --terrain-seed pins one (windowed_evo_config).
	cfg := windowed_evo_config(ga_seed, terrain_seed)
	session_init(&session, &cfg, NATIVE_SLOTS, nil)

	run_native()
	return 0
}

run_native :: proc() {
	host.run_app(
		init_cb = render_init_cb,
		frame_cb = render_frame_cb,
		cleanup_cb = render_cleanup_cb,
		on_move = on_move_cb,
		on_scroll = on_scroll_cb,
		on_resize = on_resize_cb,
		on_key = on_key_cb,
		on_button = on_button_cb,
		// Desktop window: no touch.
		on_touch = nil,
	)
}

// Local wall-clock stamp for the boot line. This Odin build's time package
// has no Format - the components come from time.date +
// time.clock_from_time (local time, matching system logs).
time_stamp :: proc(t: time.Time) -> string {
	y, m, d := time.date(t)
	h, mi, s := time.clock_from_time(t)
	return fmt.aprintf("%04d-%02d-%02d %02d:%02d:%02d", y, int(m), d, h, mi, s)
}

parse_f32_arg :: proc(s: string) -> f32 {
	v, _ := parse_f32(s)
	return v
}

parse_u64_arg :: proc(s: string) -> u64 {
	v, _ := parse_u64(s)
	return v
}

main :: proc() {
	os.exit(run_main())
}
