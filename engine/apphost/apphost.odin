// Generic window/input host only. This shim forwards raw events; the app owns
// the policy.
//
// The Odin side of apphost: run_app + the C-callback types for the scalar
// event dispatch + mouse-button, key, and touch-phase constants (mirroring
// sapp_mousebutton / SAPP_KEYCODE_* / SAPP_EVENTTYPE_TOUCHES_*), so apps
// use named constants instead of raw keycode ints.
//
// Imported from the app as:  import host "engine:apphost"

package apphost

import "core:strings"

Init_CB :: proc "c" ()
Frame_CB :: proc "c" ()
Cleanup_CB :: proc "c" ()
Move_CB :: proc "c" (dx, dy: f32)
Scroll_CB :: proc "c" (dy: f32)
Resize_CB :: proc "c" (w, h: i32)
Key_CB :: proc "c" (keycode: i32, pressed: i32)
Button_CB :: proc "c" (button: i32, pressed: i32)
Touch_CB :: proc "c" (phase, ident: i32, x, y: f32)

// on_touch fires once per touch point in each sokol TOUCHES_* event (x, y
// in framebuffer pixels, the same space as Get_Mouse_Pos). A gesture is
// correlated by ident (stable for a finger while it is down). .Cancelled
// arrives when the browser aborts the gesture — treat it like .Ended
// (release). In compat-mode browsers the shim drops the synthesized mouse
// BUTTON events that follow each touch, so the app's down/up state sees
// each physical input once.
TOUCH_PHASE_BEGAN :: i32(0)
TOUCH_PHASE_MOVED :: i32(1)
TOUCH_PHASE_ENDED :: i32(2)
TOUCH_PHASE_CANCELLED :: i32(3)

// ─── Mouse button ids (mirror sapp_mousebutton) ──────────────────────

MOUSE_BUTTON_LEFT :: i32(0x0)
MOUSE_BUTTON_RIGHT :: i32(0x1)
MOUSE_BUTTON_MIDDLE :: i32(0x2)

// ─── Key codes (mirror SAPP_KEYCODE_*) ────────────────────────────────

KEY_SPACE :: i32(32)
KEY_APOSTROPHE :: i32(39)
KEY_COMMA :: i32(44)
KEY_MINUS :: i32(45)
KEY_PERIOD :: i32(46)
KEY_SLASH :: i32(47)
KEY_0 :: i32(48)
KEY_1 :: i32(49)
KEY_2 :: i32(50)
KEY_3 :: i32(51)
KEY_4 :: i32(52)
KEY_5 :: i32(53)
KEY_6 :: i32(54)
KEY_7 :: i32(55)
KEY_8 :: i32(56)
KEY_9 :: i32(57)
KEY_SEMICOLON :: i32(59)
KEY_EQUAL :: i32(61)
KEY_A :: i32(65)
KEY_B :: i32(66)
KEY_C :: i32(67)
KEY_D :: i32(68)
KEY_E :: i32(69)
KEY_F :: i32(70)
KEY_G :: i32(71)
KEY_H :: i32(72)
KEY_I :: i32(73)
KEY_J :: i32(74)
KEY_K :: i32(75)
KEY_L :: i32(76)
KEY_M :: i32(77)
KEY_N :: i32(78)
KEY_O :: i32(79)
KEY_P :: i32(80)
KEY_Q :: i32(81)
KEY_R :: i32(82)
KEY_S :: i32(83)
KEY_T :: i32(84)
KEY_U :: i32(85)
KEY_V :: i32(86)
KEY_W :: i32(87)
KEY_X :: i32(88)
KEY_Y :: i32(89)
KEY_Z :: i32(90)
KEY_LEFT_BRACKET :: i32(91)
KEY_BACKSLASH :: i32(92)
KEY_RIGHT_BRACKET :: i32(93)
KEY_GRAVE_ACCENT :: i32(96)
KEY_WORLD_1 :: i32(161)
KEY_WORLD_2 :: i32(162)
KEY_ESCAPE :: i32(256)
KEY_ENTER :: i32(257)
KEY_TAB :: i32(258)
KEY_BACKSPACE :: i32(259)
KEY_INSERT :: i32(260)
KEY_DELETE :: i32(261)
KEY_RIGHT :: i32(262)
KEY_LEFT :: i32(263)
KEY_DOWN :: i32(264)
KEY_UP :: i32(265)
KEY_PAGE_UP :: i32(266)
KEY_PAGE_DOWN :: i32(267)
KEY_HOME :: i32(268)
KEY_END :: i32(269)
KEY_CAPS_LOCK :: i32(280)
KEY_SCROLL_LOCK :: i32(281)
KEY_NUM_LOCK :: i32(282)
KEY_PRINT_SCREEN :: i32(283)
KEY_PAUSE :: i32(284)
KEY_F1 :: i32(290)
KEY_F2 :: i32(291)
KEY_F3 :: i32(292)
KEY_F4 :: i32(293)
KEY_F5 :: i32(294)
KEY_F6 :: i32(295)
KEY_F7 :: i32(296)
KEY_F8 :: i32(297)
KEY_F9 :: i32(298)
KEY_F10 :: i32(299)
KEY_F11 :: i32(300)
KEY_F12 :: i32(301)
KEY_F13 :: i32(302)
KEY_F14 :: i32(303)
KEY_F15 :: i32(304)
KEY_F16 :: i32(305)
KEY_F17 :: i32(306)
KEY_F18 :: i32(307)
KEY_F19 :: i32(308)
KEY_F20 :: i32(309)
KEY_F21 :: i32(310)
KEY_F22 :: i32(311)
KEY_F23 :: i32(312)
KEY_F24 :: i32(313)
KEY_F25 :: i32(314)
KEY_KP_0 :: i32(320)
KEY_KP_1 :: i32(321)
KEY_KP_2 :: i32(322)
KEY_KP_3 :: i32(323)
KEY_KP_4 :: i32(324)
KEY_KP_5 :: i32(325)
KEY_KP_6 :: i32(326)
KEY_KP_7 :: i32(327)
KEY_KP_8 :: i32(328)
KEY_KP_9 :: i32(329)
KEY_KP_DECIMAL :: i32(330)
KEY_KP_DIVIDE :: i32(331)
KEY_KP_MULTIPLY :: i32(332)
KEY_KP_SUBTRACT :: i32(333)
KEY_KP_ADD :: i32(334)
KEY_KP_ENTER :: i32(335)
KEY_KP_EQUAL :: i32(336)
KEY_LEFT_SHIFT :: i32(340)
KEY_LEFT_CONTROL :: i32(341)
KEY_LEFT_ALT :: i32(342)
KEY_LEFT_SUPER :: i32(343)
KEY_RIGHT_SHIFT :: i32(344)
KEY_RIGHT_CONTROL :: i32(345)
KEY_RIGHT_ALT :: i32(346)
KEY_RIGHT_SUPER :: i32(347)
KEY_MENU :: i32(348)

// The apphost archive (libapphost_<target>.a, compiled per app by
// tools/build_app.sh with the app's window title) is passed to the linker via
// -extra-linker-flags. sokol_app owns the event loop: it invokes the
// init/frame/cleanup callbacks and dispatches input to the scalar on_*
// callbacks (on_touch is nil on desktop-only apps; touch events only arrive
// on targets sokol_app receives them from — the web canvas, or a native
// touchscreen).

@(default_calling_convention = "c")
foreign _ {
	@(link_name = "shim_run_app")
	run_app :: proc(init_cb: Init_CB, frame_cb: Frame_CB, cleanup_cb: Cleanup_CB, on_move: Move_CB, on_scroll: Scroll_CB, on_resize: Resize_CB, on_key: Key_CB, on_button: Button_CB, on_touch: Touch_CB) ---

	// Absolute pointer position in framebuffer pixels (origin top-left): the
	// last mouse move or the first point of the last touch event (a pure tap
	// produces no move, so touch picking needs it).
	@(link_name = "shim_get_mouse_pos")
	get_mouse_pos_raw :: proc(x, y: ^f32) ---

	// Render-debug URL parameters (wasm shell; see index_template.html):
	// one per query param the template parses — pause, mode, gen, pack, ff.
	// Deterministic reproducible frames for render debugging; native always
	// returns 0.
	@(link_name = "shim_debug_param")
	debug_param_raw :: proc(which: i32) -> i32 ---

	// u64 render-debug URL parameters (wasm shell; see index_template.html):
	// 0 = ?seed=N, 1 = ?terrain=N. 0 = default; native always returns 0.
	@(link_name = "shim_debug_seed_param")
	debug_seed_param_raw :: proc(which: i32) -> u64 ---

	// The page's #car= share fragment (wasm shell; the template exposes
	// window.__odm_car_payload from location.hash). The shim returns a
	// static reused buffer (no free); the app copies it before the next
	// shim call can overwrite it. "" = no shared car (native: always "").
	@(link_name = "shim_debug_car_param")
	debug_car_param_raw :: proc() -> cstring ---

	// The share popup's JS→app channel (wasm shell): the overlay's open
	// state (read each frame) and the tapped tile index (read-and-clear,
	// -1 = none). Native: always 0 / -1.
	@(link_name = "shim_debug_share_open")
	debug_share_open_raw :: proc() -> i32 ---

	@(link_name = "shim_debug_share_car")
	debug_share_car_raw :: proc() -> i32 ---

	// App→JS JSON post: the shim copies `len` bytes of `json` through a
	// static HEAP buffer and hands the decoded string to
	// window.__odm_js_handlers[which] (the app's string need only outlive
	// the call). No-op native.
	@(link_name = "shim_js_post")
	js_post_raw :: proc(which: i32, json: cstring, len: int) ---
}

// Debug_Pause_Frame / Debug_Initial_View / Debug_Stop_Gen /
// Debug_Initial_Pack / Debug_Background_Evolve — the wasm shell's
// render-debug URL parameters (?pause=N&mode=M&gen=G&pack=1&ff=1). Read
// once at app start; 0 = default; native always returns 0.
Debug_Pause_Frame :: proc() -> int {
	return int(debug_param_raw(0))
}

Debug_Initial_View :: proc() -> int {
	return int(debug_param_raw(1))
}

Debug_Stop_Gen :: proc() -> int {
	return int(debug_param_raw(2))
}

Debug_Initial_Pack :: proc() -> int {
	return int(debug_param_raw(3))
}

Debug_Background_Evolve :: proc() -> int {
	return int(debug_param_raw(4))
}

// Debug_Seed / Debug_Terrain_Seed — the wasm shell's seed URL parameters
// (?seed=N and ?terrain=N). Read once at app start; 0 = default; native
// always returns 0.
Debug_Seed :: proc() -> u64 {
	return debug_seed_param_raw(0)
}

Debug_Terrain_Seed :: proc() -> u64 {
	return debug_seed_param_raw(1)
}

// Debug_Car_Param — the page's #car= share fragment (wasm shell; the
// template exposes window.__odm_car_payload from location.hash). Read once
// at app start; "" = no shared car (native: always ""). The shim's static
// buffer is cloned out before it can be reused.
Debug_Car_Param :: proc() -> string {
	p := debug_car_param_raw()
	if p == nil {return ""}
	s, _ := strings.clone_from_cstring(p)
	return s
}

// Debug_Share_Open / Debug_Share_Car — the share popup's JS→app channel:
// the overlay's open state (read each frame) and the tapped tile index
// (read-and-clear; -1 = none). Native: always false / -1.
Debug_Share_Open :: proc() -> bool {
	return debug_share_open_raw() != 0
}

Debug_Share_Car :: proc() -> int {
	return int(debug_share_car_raw())
}

// JS_Post — app→JS: deliver a JSON string to the registered handler
// (window.__odm_js_handlers[which]). The shim copies the bytes through a
// static HEAP buffer (TextDecoder — no escape path), so the string need
// only outlive the (synchronous) call — a zero-copy cstring view is safe.
// No-op native.
JS_Post :: proc(which: int, s: string) {
	if len(s) == 0 {return}
	js_post_raw(i32(which), strings.unsafe_string_to_cstring(s), len(s))
}

// Absolute pointer position in framebuffer pixels (origin top-left, Y down):
// the shim tracks it (see get_mouse_pos_raw). on_move forwards only relative
// deltas, and accumulating them desyncs on focus/enter/resize, so call this
// each frame (or on click) for picking.
Get_Mouse_Pos :: proc() -> (x, y: f32) {
	x, y = 0.0, 0.0
	get_mouse_pos_raw(&x, &y)
	return
}
