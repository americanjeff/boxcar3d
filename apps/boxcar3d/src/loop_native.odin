#+build !wasm32
// Native shell around the shared frame driver (loop.odin): the sokol_app
// callbacks (all `proc "c"` - each must set Odin's runtime context
// explicitly, it is not passed across the C ABI), the tick budget, and the
// native I/O hooks (per-frame telemetry + crash-ring flush, input-liveness
// notes). The per-frame policy is shared with the browser build - both
// targets step the same in-frame Evo_Session.

package main

import "base:runtime"
import crash "engine:crash"

// The windowed session's budget: concurrent rollout slots + physics ticks
// per frame, round-robined (each active slot's pace = budget/slots × 60
// ticks/s). Tuned for a 60 fps window (evolvetest 16 prints the measured
// ms/frame); the in-frame cost must stay well under one frame (16.6 ms),
// leaving room for render + UI.
NATIVE_SLOTS :: 8
NATIVE_TICKS_PER_FRAME :: 72

// Frame counter (telemetry + input-liveness ages).
frame_count := 0

// Input-event liveness for telemetry's `in` / `in_age`: bumped by the event
// callbacks, read by app_frame - both main thread, so no sync.
// `last_input_frame` = -1 until the first event.
input_events := 0
last_input_frame := -1

input_event_note :: proc() {
	input_events += 1
	last_input_frame = frame_count
}

// The finiteness checks shared with the smoke battery (smoke.odin).
is_finite3 :: proc(p: [3]f32) -> bool {
	return p[0] == p[0] && p[1] == p[1] && p[2] == p[2]
}

is_finite :: proc(x: f32) -> bool {return x == x}

render_init_cb :: proc "c" () {
	context = runtime.default_context()
	driver_render_init()
}

render_frame_cb :: proc "c" () {
	context = runtime.default_context()
	app_frame()
}

render_cleanup_cb :: proc "c" () {
	context = runtime.default_context()
	driver_render_cleanup()
}

// Per-frame dispatch: the shared driver (loop.odin) + the native hooks
// (telemetry, crash-ring flush, the UI overlay).
app_frame :: proc() {
	frame_count += 1
	pop_viewer_tick()
	driver_frame(NATIVE_TICKS_PER_FRAME)

	// Telemetry: record the state that's otherwise invisible (render
	// branch, camera NaN, sim/pack/GA/input liveness) into the crash ring
	// buffer.
	render_branch := "scene_idle"
	pv_live := -1
	pv_total := -1
	pv_age := -1
	if view_mode == 0 && pop_viewer_is_ready() {
		render_branch = "viewer"
		for i in 0 ..< pop_viewer.n {
			if !pop_viewer.cars[i].stopped {pv_live += 1}
		}
		pv_total = pop_viewer.n
		pv_age = (pop_viewer.frames - pop_viewer.pack_frame) / 60
	} else if view_mode == 1 && solo_is_ready() {
		render_branch = "solo"
		pv_total = solo.n
		pv_live = 0
		if solo.active {pv_live = 1}
	}
	ga_gen := -1
	ga_run := i32(0)
	ga_wait := i32(0)
	if len(session.cur.pop) > 0 {
		ga_gen = session.cur.index
		ga_run = i32(session.running)
		// "Parked" = the in-sync session is paused on a buffered snapshot.
		ga_wait = i32(session.running && !bg_evolve && solo_has_pending())
	}

	telemetry.frame = frame_count
	telemetry.render_branch = render_branch
	telemetry.ms_session = frame_ms_session
	telemetry.ms_view = frame_ms_view
	telemetry.ms_render = frame_ms_render
	telemetry.cam_target = cam.target
	telemetry.cam_finite = is_finite3(cam.target)
	telemetry.paused = sim_paused
	telemetry.speed = viewer_speed
	churn := 0
	for i in 0 ..< hud.n_cars {
		if tel_prev_n > i && tel_prev_ids[i] != hud.cars[i].id {
			churn += 1
		}
	}
	if hud.n_cars != tel_prev_n {churn = -1} 	// panel size changed (rebuild)
	telemetry.rows_churn = churn
	// Compact row-id string on the stack (ids are < 100: two digits max);
	// consumed by telemetry_record within this frame.
	idbuf: [64]byte
	np := 0
	for i in 0 ..< hud.n_cars {
		if i > 0 {
			idbuf[np] = ','
			np += 1
		}
		id := hud.cars[i].id
		if id >= 10 {
			idbuf[np] = byte('0' + id / 10)
			np += 1
			idbuf[np] = byte('0' + id % 10)
			np += 1
		} else {
			idbuf[np] = byte('0' + id)
			np += 1
		}
	}
	telemetry.row_ids = cast(string)idbuf[:np]
	if hud.n_cars > 0 {
		telemetry.top_score = hud.cars[0].score
	} else {
		telemetry.top_score = 0
	}
	telemetry.gen_disp = hud.prog.generation
	telemetry.gen_next = hud.prog.next_generation
	telemetry.best_screen = hud.best_screen
	for i in 0 ..< hud.n_cars {tel_prev_ids[i] = hud.cars[i].id}
	tel_prev_n = hud.n_cars
	telemetry.pv_live = pv_live
	telemetry.pv_total = pv_total
	telemetry.pv_age = pv_age
	telemetry.ga_gen = ga_gen
	telemetry.ga_run = ga_run
	telemetry.ga_wait = ga_wait
	telemetry.input_events = input_events
	telemetry.input_age = last_input_frame < 0 ? -1 : frame_count - last_input_frame
	telemetry_record()
	crash.telemetry_flush_tick(f32(1.0 / 60.0))

	// Overlay the microui command list on top, then the car portraits
	// (the icon-atlas quads - same overlay frame, same one-frame flush).
	render_ui_commands(&ui_ctx)
	car_icon_render(&hud)
}

left_down := false

// Keys are unused; run_app requires a handler. The note call still counts
// them - a key event processed is input-pump proof.
on_key_cb :: proc "c" (keycode, pressed: i32) {
	context = runtime.default_context()
	input_event_note()
}

on_move_cb :: proc "c" (dx, dy: f32) {
	context = runtime.default_context()
	input_event_note()
	driver_mouse_move(dx, dy)
}

on_scroll_cb :: proc "c" (dy: f32) {
	context = runtime.default_context()
	input_event_note()
	driver_mouse_scroll(dy)
}

on_resize_cb :: proc "c" (w, h: i32) {
	context = runtime.default_context()
}

on_button_cb :: proc "c" (button: i32, pressed: i32) {
	context = runtime.default_context()
	input_event_note()
	driver_button_event(button, pressed)
}

