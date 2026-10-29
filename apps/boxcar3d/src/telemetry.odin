#+build !wasm32
// Runtime telemetry + crash diagnostics.
//
// One line per frame into the shared crash ring (engine:crash); the ring is
// flushed ~1 Hz to data/tel.log and dumped to data/crash.log by the
// SIGSEGV/SIGABRT/SIGFPE/SIGILL handler (engine/crash/crash.odin).
//
// Stall diagnostics (field meanings are on the struct): t is wall seconds
// since boot (slope = fps probe); the render branch is viewer / scene_idle;
// a pack that never ends shows pv live flat + pv_age climbing (in FF the GA
// runs ahead meanwhile - ga_run=1, ga_gen climbs; in display-primary the
// GA is idle - the walk IS the eval); in_age climbing while the user works
// = events reaching the socket but never the UI.
//
// Native only.

package main

import "core:fmt"
import "core:time"
import crash "engine:crash"

// Runtime-resolved (cwd-independent) log paths, set by resolve_data_paths()
// (store.odin); DATA_DIR is defined there too.
TEL_LOG := ""
CRASH_LOG := ""

// Wall-clock anchor for the line's `t=` field (set in run_main, main thread).
tel_boot_time: time.Time

Telemetry :: struct {
	frame:         int,
	render_branch: string,
	cam_target:    [3]f32,
	cam_finite:    bool,
	// Stall diagnostics.
	paused:        bool, // sim_paused
	speed:         int, // physics ticks per frame (viewer_speed)
	// Per-frame cost breakdown (wall ms, filled by driver_frame): the
	// session step, the UI + active-view step, and the render - the
	// 16.6 ms budget / overrun-probe rationale lives in loop.odin.
	ms_session:    f32,
	ms_view:       f32,
	ms_render:     f32,
	pv_live:       int, // live cars in the pack (-1 when no pack)
	pv_total:      int,
	pv_age:        int, // seconds since the pack was built; -1 when none
	ga_gen:        int, // GA generation; -1 when the GA is reaped
	ga_run:        i32, // 1 while the GA driver's stop flag is not set
	ga_wait:       i32, // 1 while display-primary holds an offered-but-not-taken gen (same-frame only; FF never parks)
	input_events:  int, // input events processed since boot
	input_age:     int, // frames since the last input event; -1 when none
	// Score-panel churn probe (the list flicker): how many rows hold a
	// DIFFERENT car than last frame (row reordering under live scores),
	// plus the panel's key values so digit-boundary shifts (the decimal
	// column widening at 9.9 → 10.0) can be correlated with the churn.
	rows_churn:    int, // rows holding a different car than last frame
	row_ids:       string, // the sorted panel's row order, "a,b,c,..."
	top_score:     f64, // the top row's score (the widest-score digit probe)
	gen_disp:      int, // the displayed generation
	gen_next:      int, // the next (pending) generation
	best_screen:   f64, // the panel's ratcheted best
}

telemetry: Telemetry

// Previous frame's row ids, maintained by app_frame (loop_native); native only.
tel_prev_ids: [32]int
tel_prev_n: int = -1

telemetry_record :: proc() {
	if !crash.telemetry_on {return}
	// fmt.aprintf, not fmt.tprintf: tprintf allocates from
	// temp_allocator, so delete(line) would free with a mismatched
	// allocator → heap corruption.
	// `t` is real seconds since boot, not frame/60: the frame rate varies
	// with load (GA evals slow the loop), so a frame-derived clock would
	// drift under load - and its slope is the fps probe.
	t := f32(time.duration_seconds(time.since(tel_boot_time)))
	line := fmt.aprintf(
		"[tel] f={} t={:.1f} render={} paused={} speed={} ms={:.1f}/{:.1f}/{:.1f} pv={}/{} pv_age={} ga={} run={} wait={} in={} in_age={} cam_tgt=({:.1f},{:.1f},{:.1f}) finite={} churn={} rows={} top={:.1f} gen={}/{} best={:.1f} t0n={}/t3n={}\n",
		telemetry.frame,
		t,
		telemetry.render_branch,
		int(telemetry.paused),
		telemetry.speed,
		telemetry.ms_session,
		telemetry.ms_view,
		telemetry.ms_render,
		telemetry.pv_live,
		telemetry.pv_total,
		telemetry.pv_age,
		telemetry.ga_gen,
		telemetry.ga_run,
		telemetry.ga_wait,
		telemetry.input_events,
		telemetry.input_age,
		telemetry.cam_target[0],
		telemetry.cam_target[1],
		telemetry.cam_target[2],
		telemetry.cam_finite,
		telemetry.rows_churn,
		telemetry.row_ids,
		telemetry.top_score,
		telemetry.gen_disp,
		telemetry.gen_next,
		telemetry.best_screen,
		frame_ns_t0,
		frame_ns_t3,
	)
	crash.crash_record(line)
	delete(line)
}

