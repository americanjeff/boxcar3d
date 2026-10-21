// Generic window/input host only. This shim forwards raw events; the app owns
// the policy.
//
// This TU provides the sokol_app + sokol_glue + sokol_log IMPLEMENTATIONS
// (with SOKOL_NO_ENTRY so Odin owns the entry), shim_run_app (builds sapp_desc,
// requests GL 4.5 native / WGPU wasm, window title via -DSHIM_WINDOW_TITLE),
// and the scalar event dispatch: an internal sapp_event_cb that translates a
// sapp_event into scalar on_move/on_scroll/on_resize/on_key/on_button/on_touch
// callbacks (plus the compat-mode synthesized-mouse drop, see
// ShimDropMouseButtons). The sokol_gfx impl is NOT here — it lives in the forked renderer
// (engine/graphics/renderer/gfx/sokol_impl.c, compiled into libgraphics).
//
// Compiled per app by tools/build_app.sh with -DSHIM_WINDOW_TITLE="<title>"
// (the title is an app-specific compile-time string, not logic, so apphost's
// source stays generic while each app gets its own title without a per-app
// rebuild of physics/graphics).

#if defined(__linux__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#ifndef SHIM_WINDOW_TITLE
#define SHIM_WINDOW_TITLE "odin3d"
#endif

/* --- sokol impls (app + glue + log; gfx impl is in the forked renderer) --- */
#define SOKOL_NO_ENTRY /* Odin owns main(); sokol_app exposes sapp_run() instead */
#define SOKOL_APP_IMPL
#define SOKOL_GLUE_IMPL
#define SOKOL_LOG_IMPL

/* sokol_gfx.h must be included before sokol_glue.h (glue uses sg_* types). */
#include "sokol_gfx.h" /* header only — impl is in libgraphics */
#include "sokol_app.h"
#include "sokol_glue.h"
#include "sokol_log.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*ShimInitCb)(void);
typedef void (*ShimFrameCb)(void);
typedef void (*ShimCleanupCb)(void);
typedef void (*ShimMoveCb)(float dx, float dy);
typedef void (*ShimScrollCb)(float dy);
typedef void (*ShimResizeCb)(int w, int h);
typedef void (*ShimKeyCb)(int keycode, int pressed);
typedef void (*ShimButtonCb)(int button, int pressed);
typedef void (*ShimTouchCb)(int phase, int ident, float x, float y);

static ShimMoveCb g_onMove = NULL;
static ShimScrollCb g_onScroll = NULL;
static ShimResizeCb g_onResize = NULL;
static ShimKeyCb g_onKey = NULL;
static ShimButtonCb g_onButton = NULL;
static ShimTouchCb g_onTouch = NULL;

/* Compat-mode browsers (Chrome/Android) synthesize a mouse event per touch,
   so drop mouse BUTTON events within SHIM_TOUCH_MOUSE_SUPPRESS_MS of the
   last touch (emscripten only; native never synthesizes) — otherwise the
   app's down/up state sees each physical input twice. Time-based, not
   event-count: an idle page delivers zero events, so a count window would
   never drain and would swallow the first real click after a touch. Cost:
   on a hybrid device a real click inside the window is lost (no flag marks
   the synthesized events). MOVE/SCROLL are never dropped — they keep
   shim_get_mouse_pos fresh. */
#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#define SHIM_TOUCH_MOUSE_SUPPRESS_MS 500.0
static double g_last_touch_ms = -1e9;
#endif

static int ShimDropMouseButtons(void) {
#ifdef __EMSCRIPTEN__
	if (emscripten_get_now() - g_last_touch_ms < SHIM_TOUCH_MOUSE_SUPPRESS_MS) {
		return 1;
	}
#endif
	return 0;
}

/* Tracked absolute pointer position (framebuffer pixels, origin top-left).
   Updated from MOUSE_MOVE events and the first point of each touch event so
   apps can query it for picking/hover without accumulating deltas (which
   desyncs on focus/enter/resize); a pure tap produces no MOUSE_MOVE, so the
   touch update is what makes tap picking work. */
static float g_mouseX = 0.0f;
static float g_mouseY = 0.0f;

static void ShimEventCb(const sapp_event* ev) {
	// Add a new event case here only if it is a generic window/input event any
	// app would plausibly want, forwarded as a scalar callback (see the file
	// header for the separation rule).
	switch (ev->type) {
		case SAPP_EVENTTYPE_MOUSE_DOWN:
			if (ShimDropMouseButtons()) break;
			if (g_onButton) g_onButton((int)ev->mouse_button, 1);
			break;
		case SAPP_EVENTTYPE_MOUSE_UP:
			if (ShimDropMouseButtons()) break;
			if (g_onButton) g_onButton((int)ev->mouse_button, 0);
			break;
		case SAPP_EVENTTYPE_MOUSE_MOVE:
			g_mouseX = ev->mouse_x;
			g_mouseY = ev->mouse_y;
			if (g_onMove) g_onMove(ev->mouse_dx, ev->mouse_dy);
			break;
		case SAPP_EVENTTYPE_MOUSE_SCROLL:
			if (g_onScroll) g_onScroll(ev->scroll_y);
			break;
		case SAPP_EVENTTYPE_RESIZED:
			if (g_onResize) g_onResize(ev->window_width, ev->window_height);
			break;
		case SAPP_EVENTTYPE_KEY_DOWN:
			if (g_onKey) g_onKey((int)ev->key_code, 1);
			break;
		case SAPP_EVENTTYPE_KEY_UP:
			if (g_onKey) g_onKey((int)ev->key_code, 0);
			break;
		case SAPP_EVENTTYPE_TOUCHES_BEGAN:
		case SAPP_EVENTTYPE_TOUCHES_MOVED:
		case SAPP_EVENTTYPE_TOUCHES_ENDED:
		case SAPP_EVENTTYPE_TOUCHES_CANCELLED:
			{
				int phase;
				switch (ev->type) {
					case SAPP_EVENTTYPE_TOUCHES_BEGAN:  phase = 0; break; /* TOUCH_PHASE_BEGAN */
					case SAPP_EVENTTYPE_TOUCHES_MOVED:  phase = 1; break; /* TOUCH_PHASE_MOVED */
					case SAPP_EVENTTYPE_TOUCHES_ENDED:  phase = 2; break; /* TOUCH_PHASE_ENDED */
					default:                            phase = 3; break; /* TOUCH_PHASE_CANCELLED */
				}
				/* Forward every point of the event (sokol caps at
				   SAPP_MAX_TOUCHPOINTS); the app correlates a gesture by
				   ident. Track the pointer from the first point so
				   shim_get_mouse_pos returns the finger position (a pure
				   tap produces no MOUSE_MOVE; see g_mouseX). */
#ifdef __EMSCRIPTEN__
				/* Restart the compat-mode drop window (see
				   ShimDropMouseButtons). */
				g_last_touch_ms = emscripten_get_now();
#endif
				for (int i = 0; i < ev->num_touches; i++) {
					const sapp_touchpoint* tp = &ev->touches[i];
					if (i == 0) {
						g_mouseX = tp->pos_x;
						g_mouseY = tp->pos_y;
					}
					if (g_onTouch) g_onTouch(phase, (int)tp->identifier, tp->pos_x, tp->pos_y);
				}
			}
			break;
		default:
			break;
	}
}

static void ShimAppLog(const char* tag, uint32_t logLevel, uint32_t logItemId, const char* message,
                       uint32_t lineNumber, const char* filename, void* userData) {
	(void)tag; (void)logItemId; (void)filename; (void)userData; (void)lineNumber;
	const char* level = (logLevel == 0) ? "panic" : (logLevel == 1) ? "error" : (logLevel == 2) ? "warn" : "info";
	fprintf(stderr, "sokol(%s) %s\n", level, message ? message : "(no message)");
	/* A sokol panic (e.g. GL/WebGPU context creation failure) is fatal — do
	   not continue into a broken frame loop. Mirrors the smoke driver. */
	if (logLevel == 0) {
		exit(1);
	}
}

void shim_run_app(ShimInitCb initCb, ShimFrameCb frameCb, ShimCleanupCb cleanupCb,
                  ShimMoveCb onMove, ShimScrollCb onScroll, ShimResizeCb onResize,
                  ShimKeyCb onKey, ShimButtonCb onButton, ShimTouchCb onTouch) {
	g_onMove = onMove;
	g_onScroll = onScroll;
	g_onResize = onResize;
	g_onKey = onKey;
	g_onButton = onButton;
	g_onTouch = onTouch;

	sapp_desc desc;
	memset(&desc, 0, sizeof(desc));
	desc.init_cb = initCb;
	desc.frame_cb = frameCb;
	desc.cleanup_cb = cleanupCb;
	desc.event_cb = ShimEventCb;
	desc.logger.func = ShimAppLog;

	/* The renderer hard-requires glClipControl (GL 4.5 / ARB_clip_control) on
	   SOKOL_GLCORE for its reverse-Z depth pipeline. On the SOKOL_WGPU (wasm)
	   backend these gl fields are unused — sokol_app acquires the WebGPU
	   device/surface from the <canvas> via emdawnwebgpu automatically — so
	   setting them is harmless and keeps one shim for both targets. */
	desc.gl.major_version = 4;
	desc.gl.minor_version = 5;

	desc.width = 1280;
	desc.height = 720;
	desc.sample_count = 1; /* renderer runs MSAA in its own scene target */
	/* swap_interval=0: with vsync on, the GL swap waits on a driver signal
	   that can stall under Wayland/XWayland (esp. NVIDIA), freezing the whole
	   event/present loop (no input dispatch, no repaint). Cost: uncapped
	   render rate / possible tearing. */
	desc.swap_interval = 0;
	desc.window_title = SHIM_WINDOW_TITLE;

	sapp_run(&desc);
}

/* Absolute pointer position in framebuffer pixels (origin top-left, Y down).
   sokol_app has no mouse-position query, so the shim tracks it (see
   g_mouseX for the tracking rule). */
void shim_get_mouse_pos(float* x, float* y) {
	if (x) *x = g_mouseX;
	if (y) *y = g_mouseY;
}

/* Render-debug URL parameters (wasm only): the JS shell
   (tools/web/index_template.html) parses location.search once at boot and
   exposes the parsed query params (pause, mode, gen, pack, ff) as
   window.__odm_debug_arr; this reads one element as a plain scalar so the
   app side never touches JS. 0 = default; native always returns 0. */
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
EMSCRIPTEN_KEEPALIVE
int shim_debug_param(int which) {
	if (which < 0 || which > 4) {
		return 0;
	}
	char script[128];
	snprintf(script, sizeof(script), "(window.__odm_debug_arr || [0,0,0,0,0])[%d] | 0", which);
	return emscripten_run_script_int(script);
}
#else
int shim_debug_param(int which) {
	(void)which;
	return 0;
}
#endif

/* u64 render-debug URL parameters (wasm only): the JS shell (see
   shim_debug_param) exposes [seed, terrainSeed] — ?seed=N and ?terrain=N,
   as decimal strings — as window.__odm_debug_seed_arr, because a u64 does
   not fit the 32-bit int channel. This strtoull's one element (base 0:
   decimal or 0x-hex) so the app side never touches JS. 0 = default;
   native always returns 0. */
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
EMSCRIPTEN_KEEPALIVE
uint64_t shim_debug_seed_param(int which) {
	uint64_t v = 0;
	if (which == 0 || which == 1) {
		char script[160];
		snprintf(script, sizeof(script),
			"(window.__odm_debug_seed_arr || ['0','0'])[%d]", which);
		/* No free: this emscripten's run_script_string returns a static
		   reused buffer, and the value is consumed before any other call
		   can overwrite it. */
		char* val = emscripten_run_script_string(script);
		if (val) {
			v = strtoull(val, NULL, 0);
		}
	}
	return v;
}
#else
uint64_t shim_debug_seed_param(int which) {
	(void)which;
	return 0;
}
#endif

/* Shared-car payload (wasm only): the JS shell exposes the page's
   #car=... URL fragment (window.__odm_car_payload, set by
   index_template.html from location.hash). Returns the emscripten
   run_script_string static reused buffer (no free — see
   shim_debug_seed_param); the app must consume (copy) the bytes before
   any other call that could overwrite the buffer. "" = no shared car;
   native always returns "". */
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
EMSCRIPTEN_KEEPALIVE
char* shim_debug_car_param(void) {
	char* val = emscripten_run_script_string("(window.__odm_car_payload || '')");
	if (val) {
		return val;
	}
	return "";
}
#else
char* shim_debug_car_param(void) {
	return "";
}
#endif

/* Share-popup state (wasm only): the JS overlay reports its open/closed
   state to window.__odm_share_open (0/1). Native always returns 0. */
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
EMSCRIPTEN_KEEPALIVE
int shim_debug_share_open(void) {
	return emscripten_run_script_int("(window.__odm_share_open | 0)");
}
#else
int shim_debug_share_open(void) {
	return 0;
}
#endif

/* Shared-car selector (wasm only): the tile index the user tapped in the
   share popup (window.__odm_share_car, -1 = none). Read-and-clear: the shim
   resets the JS value to -1 after reading, so each tap is delivered exactly
   once. Native always returns -1. */
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
EMSCRIPTEN_KEEPALIVE
int shim_debug_share_car(void) {
	int idx = emscripten_run_script_int("(window.__odm_share_car | 0)");
	emscripten_run_script("(window.__odm_share_car = -1)");
	return idx;
}
#else
int shim_debug_share_car(void) {
	return -1;
}
#endif

/* App→JS JSON post (wasm only): deliver a JSON string to a registered JS
   handler (window.__odm_js_handlers[which]). The bytes are copied through a
   static HEAP buffer and decoded with TextDecoder — no quote/escape path
   from the C string to a JS string literal. `len` bytes must fit the buffer
   (oversized posts are dropped). No-op native. */
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define ODM_JS_POST_BUF_CAP (2 * 1024 * 1024)
static char odm_js_post_buf[ODM_JS_POST_BUF_CAP];
EMSCRIPTEN_KEEPALIVE
void shim_js_post(int which, const char* json, int len) {
	char script[192];
	if (which < 0 || which > 1 || !json || len <= 0 || len > ODM_JS_POST_BUF_CAP) {
		return;
	}
	memcpy(odm_js_post_buf, json, (size_t)len);
	/* HEAPU8: the glue's linear-memory view — emscripten_run_script is a
	   direct eval inside the glue, so its closure-scope vars are visible
	   to the script (there is no global `heaps` object). */
	snprintf(script, sizeof(script),
		"(window.__odm_js_handlers && window.__odm_js_handlers[%d]) && "
		"window.__odm_js_handlers[%d](new TextDecoder().decode(HEAPU8.subarray("
		"%lu, %lu + %d)))",
		which, which,
		(unsigned long)(uintptr_t)odm_js_post_buf,
		(unsigned long)(uintptr_t)odm_js_post_buf,
		(unsigned int)len);
	emscripten_run_script(script);
}
#else
void shim_js_post(int which, const char* json, int len) {
	(void)which;
	(void)json;
	(void)len;
}
#endif