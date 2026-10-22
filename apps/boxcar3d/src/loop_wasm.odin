#+build wasm32
// WASM shell around the shared frame driver (loop.odin): the browser
// session IS the app - a cooperative, single-threaded evolution session
// stepped from the frame callback. No files, no threads (only the headless
// `evolve` CLI checkpoints genomes). This file owns web_boot (the session's
// boot sequence), the render-debug URL parameters, and the tick budget; the
// entry point (main) lives in loop_wasm_main.odin.

package main

import "base:runtime"
import "core:math"
import "core:mem"
import host "engine:apphost"

// Saved on entry; restored in every proc "c" callback sokol_app invokes.
@(private = "file")
web_context: runtime.Context

// The browser session's budget: 4 worlds concurrent, 48 ticks/frame TOTAL,
// round-robined over the slots (12/frame/slot → ~3.9 s per 47-sim-s
// rollout at 60 fps).
WASM_SLOTS :: 4
WASM_TICKS_PER_FRAME :: 48

// Render-debug URL parameters (?gen=G&pause=N&mode=M): stop background
// evolve when generation G completes; freeze the sim when the lead car's
// OWN sim clock reaches N ticks (fixed TIME_STEP per tick) - not a frame
// count: frames vary under browser rAF throttling, the car clock does
// not, so the same N lands on the same car state in every load. 0 = off.
wasm_stop_gen := 0
wasm_pause_set := false
wasm_pause_ticks := 0

// Left mouse button down (camera orbit drag).
left_down := false

// ?pause=N freeze: stop the sim + snap the camera to the canonical orbit
// (snap_canonical_orbit - the showcase's open-at-tick freeze shares it)
// aimed at the frozen lead car.
wasm_freeze_orbit :: proc(p: [3]f32) {
	sim_paused = true
	wasm_pause_set = false
	snap_canonical_orbit(p)
}

wasm_frame :: proc() {
	ev, done := driver_frame(WASM_TICKS_PER_FRAME)
	// The share popup's DOM overlay owns the mouse while it is open: the
	// canvas's mouse listeners do not fire underneath it. Mouse events are
	// hit-tested per event (unlike touch), so the opening click's mouseup
	// can land on the overlay and orphan left_down=true - the first move
	// after the dismiss would then orbit the camera as if a drag were in
	// progress. Hold the drag latch clear for the popup's whole life.
	if host.Debug_Share_Open() {
		left_down = false
	}
	// #car= showcase: on the first frame the imported car is live, catch it
	// up to the sharer's frame and open frozen.
	showcase_open_frozen()
	// ?gen=G: stop fast-forwarding once generation G completes.
	if done && wasm_stop_gen > 0 && ev.gen >= wasm_stop_gen {
		bg_evolve = false
	}

	// ?pause=N: freeze when the lead car's OWN clock of the active view
	// reaches N ticks (wasm_freeze_orbit snaps the camera at the freeze).
	if wasm_pause_set && !sim_paused {
		if view_mode == 1 {
			if solo_is_ready() &&
			   solo.active &&
			   solo.car.sim_time >= f32(wasm_pause_ticks) * TIME_STEP {
				if p, ok := solo_lead_pos(); ok {
					wasm_freeze_orbit(p)
				}
			}
		} else if pop_viewer_is_ready() && pop_viewer.lead_idx >= 0 {
			lead := &pop_viewer.cars[pop_viewer.lead_idx]
			if lead.sim.sim_time >= f32(wasm_pause_ticks) * TIME_STEP {
				if p, ok := pop_viewer_lead_pos(); ok {
					wasm_freeze_orbit(p)
				}
			}
		}
	}

	// The car portraits (icon-atlas quads) join the same overlay frame.
	render_ui_commands(&ui_ctx)
	car_icon_render(&hud)
	// Pause-time console dump of the on-screen car (genome + geometry + sim),
	// fired on the rising edge of sim_paused.
	maybe_pause_dump()
}

render_init_cb :: proc "c" () {
	context = web_context
	driver_render_init()
}

render_frame_cb :: proc "c" () {
	context = web_context
	wasm_frame()
}

render_cleanup_cb :: proc "c" () {
	context = web_context
	driver_render_cleanup()
}

on_move_cb :: proc "c" (dx, dy: f32) {
	context = web_context
	driver_mouse_move(dx, dy)
}

on_scroll_cb :: proc "c" (dy: f32) {
	context = web_context
	driver_mouse_scroll(dy)
}

on_resize_cb :: proc "c" (w, h: i32) {
	context = web_context
	// No-op: the shim recomputes aspect from sapp_width/height each frame.
}

on_key_cb :: proc "c" (keycode: i32, pressed: i32) {
	context = web_context
	// The share popup is open: it owns the keyboard (its DOM overlay closes
	// on Esc) and the sim is frozen for its whole life - app key handling
	// would just fight the popup's close/restore edges.
	if host.Debug_Share_Open() {return}
	if pressed == 1 && keycode == host.KEY_V {
		// Cycle the depth-debug view (lit → view-depth → cascade → depth-dump).
		view_debug_mode = (view_debug_mode + 1) % 4
	}
	if pressed == 1 && keycode == host.KEY_SPACE {
		sim_paused = !sim_paused
	}
	if pressed == 1 && keycode == host.KEY_P {
		// Toggle the solo/pack view - the control-strip button's keyboard
		// twin (browser sessions can't aim at the canvas button).
		hud.view_requested = true
	}
	if pressed == 1 && keycode == host.KEY_N {
		// Skip to the next unit - the control-strip button's keyboard
		// twin (same reason as P).
		hud.skip_requested = true
	}
}

on_button_cb :: proc "c" (button: i32, pressed: i32) {
	context = web_context
	driver_button_event(button, pressed)
}

// Touch policy: the FIRST finger is the left mouse button (tap the strip,
// drag to orbit - same UI-hover gate as the mouse); a SECOND finger pinches
// to zoom (camera distance scales with finger distance, through the orbit
// path, so its clamp applies). Deltas come from the absolute points (the
// shim forwards raw points; a gesture is correlated by ident, stable per
// finger while down). Second finger lifts: the first resumes its gesture; a
// third finger is ignored. .Cancelled releases like .Ended.
touch_id := i32(-1)
touch_x, touch_y := f32(0), f32(0)
pinch_id := i32(-1)
pinch_x, pinch_y := f32(0), f32(0)
pinch_finger_base, pinch_cam_base := f32(0), f32(0)

// Scale the camera distance by the ratio of the current finger distance to
// its value when the pinch started (spread = zoom in); the orbit path's
// clamp applies.
pinch_zoom :: proc() {
	d := math.hypot(pinch_x - touch_x, pinch_y - touch_y)
	if d < 8 {d = 8}
	target := pinch_cam_base * pinch_finger_base / d
	update_camera_orbit(&cam, 0.0, 0.0, cam.distance - target)
}

on_touch_cb :: proc "c" (phase, ident: i32, x, y: f32) {
	context = web_context
	switch phase {
	case host.TOUCH_PHASE_BEGAN:
		if ident == touch_id {return} 	// duplicate begin (some browsers)
		if touch_id == -1 {
			touch_id = ident
			touch_x, touch_y = x, y
			left_down = true
			ui_mouse_x = i32(x)
			ui_mouse_y = i32(y)
			// Queue the press - feed_ui_input delivers it two frames later,
			// once microui's hover has settled on the landing control.
			ui_touch_down_pending = 1
		} else if pinch_id == -1 && left_down {
			// Second finger: pinch-zoom supersedes the in-flight gesture.
			pinch_id = ident
			pinch_x, pinch_y = x, y
			if ui_touch_down_pending != 0 {
				ui_touch_down_pending = 0 // a queued tap loses to the pinch
			}
			pinch_finger_base = math.hypot(touch_x - x, touch_y - y)
			if pinch_finger_base < 8 {pinch_finger_base = 8}
			pinch_cam_base = cam.distance
		}
	case host.TOUCH_PHASE_MOVED:
		if ident == pinch_id {
			pinch_x, pinch_y = x, y
		} else if ident == touch_id {
			dx, dy := x - touch_x, y - touch_y
			touch_x, touch_y = x, y
			ui_mouse_x = i32(x)
			ui_mouse_y = i32(y)
			if left_down && pinch_id == -1 && !mouse_over_ui() {
				update_camera_orbit(&cam, dx, dy, 0.0)
			}
		} else {
			return
		}
		if pinch_id != -1 {
			pinch_zoom()
		}
	case host.TOUCH_PHASE_ENDED, host.TOUCH_PHASE_CANCELLED:
		if ident == pinch_id {
			// Second finger lifted: the first finger resumes its gesture.
			pinch_id = -1
		} else if ident == touch_id {
			touch_id = -1
			left_down = false
			pinch_id = -1
			ui_mouse_x = i32(x)
			ui_mouse_y = i32(y)
			if ui_touch_down_pending != 0 {
				// The press was never delivered (the finger lifted within two
				// frames) - nothing to release.
				ui_touch_down_pending = 0
			} else {
				ui_mouse_up(.LEFT)
			}
		}
	case:
	}
}

// The web session's boot sequence: init the driver + session, read the URL
// parameters, hand control to the apphost shim (which stores the callbacks;
// the rAF loop then drives shim_js_frame). Runs on the driver's own
// (libc-shim) heap — the entry point (loop_wasm_main.odin's main) is the
// only one.
web_boot :: proc(ctx: runtime.Context) {
	runtime.init_global_temporary_allocator(1 * mem.Megabyte)
	web_context = ctx

	init_driver()
	// A #car=<base64url> fragment (the share card's link) boots ON that
	// car: a population-1 session pinned to the car's recorded env, opened
	// frozen at the sharer's frame (showcase_open_frozen). A damaged link
	// falls back to a normal boot. The link's world wins over
	// ?terrain=/?seed= (the GA seed only matters if the user later
	// "evolves from here").
	frag := host.Debug_Car_Param()
	showcase_boot := false
	if frag != "" {
		if cl, ok := car_link_decode(frag); ok {
			showcase_car = cl
			showcase_mode = true
			view_mode = 1
			showcase_ff_owed = int(cl.tick)
			showcase_boot = true
		} else {
			hold_reason = "damaged shared car link - starting fresh"
		}
	}
	// Browser session config: no files (the in-frame session never writes
	// artifacts; tel is a native debug tool). Population = the shared
	// DEFAULT_EVO_POP (same default as the native window); GA seed = ?seed=
	// (clock-derived when absent); track = the fixed default unless
	// ?terrain= pins one (windowed_evo_config, the native window's twin).
	cfg := windowed_evo_config(host.Debug_Seed(), host.Debug_Terrain_Seed())
	cfg.tel_dir = ""
	if showcase_boot {
		cfg.pop = 1
		cfg.terrain_seed = showcase_car.env.seed
		cfg.init_line = showcase_car.env.line
		session_init(&session, &cfg, WASM_SLOTS, &showcase_car.genes)
	} else {
		session_init(&session, &cfg, WASM_SLOTS, nil)
	}

	// Render-debug URL parameters (?gen=G&pause=N&mode=M&pack=1&ff=1&ao=0;
	// ?seed=/terrain= went through windowed_evo_config above). N = the
	// lead car's sim-tick count at which to freeze (see wasm_pause_ticks).
	view_debug_mode = i32(host.Debug_Initial_View())
	wasm_stop_gen = host.Debug_Stop_Gen()
	if p := host.Debug_Pause_Frame(); p > 0 {
		wasm_pause_set = true
		wasm_pause_ticks = p
	}
	if host.Debug_Initial_Pack() != 0 {
		// ?pack=1 - boot on the full-population lineup, not solo.
		view_mode = 0
	}
	if host.Debug_Background_Evolve() != 0 {
		// ?ff=1 - boot with "evolve in background" ON.
		bg_evolve = true
	}
	if v := host.Debug_Initial_AO(); v >= 0 {
		// ?ao=0 boots with ambient occlusion OFF (-1 = absent = on).
		ao_enabled = v != 0
	}

	host.run_app(
		init_cb = render_init_cb,
		frame_cb = render_frame_cb,
		cleanup_cb = render_cleanup_cb,
		on_move = on_move_cb,
		on_scroll = on_scroll_cb,
		on_resize = on_resize_cb,
		on_key = on_key_cb,
		on_button = on_button_cb,
		on_touch = on_touch_cb,
	)
}

