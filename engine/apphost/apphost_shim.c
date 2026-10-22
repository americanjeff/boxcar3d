// Generic window/input host only. This shim forwards raw events; the app owns
// the policy.
//
// This TU provides the sokol_glue + sokol_log IMPLEMENTATIONS, shim_run_app
// (window title via -DSHIM_WINDOW_TITLE), and the scalar event dispatch into
// the on_move/on_scroll/on_resize/on_key/on_button/on_touch callbacks.
//
// Two event-loop worlds share this file (pick by target macro):
//   - native  (!__wasm__) — sokol_app (SOKOL_GLCORE) owns the loop; the
//     internal sapp_event_cb translates events to the scalar callbacks.
//   - bare    (__wasm__)  — the odin driver links the final wasm module and
//     a hand-rolled JS glue drives the module: it calls the exported
//     shim_js_* procs (frame/input/resize/wgpu handles) and the shim calls
//     the JS imports for the debug/interop params. No sokol_app.
//
// The sokol_gfx impl is NOT here — it lives in the forked renderer
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

/* sokol_app only where an event loop exists (native; the bare-wasm JS
   glue plays the loop role). */
#define SOKOL_NO_ENTRY /* Odin owns main(); sokol_app exposes sapp_run() instead */
#if !defined(__wasm__)
#define SOKOL_APP_IMPL
#endif
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

#if defined(__wasm__)
/* The bare-wasm JS glue drives the stored frame/cleanup callbacks
   (shim_js_frame / shim_js_cleanup); the sokol_app world calls them via
   the desc callbacks instead. */
static ShimInitCb g_initCb = NULL;
static ShimFrameCb g_frameCb = NULL;
static ShimCleanupCb g_cleanupCb = NULL;
#endif

/* Tracked absolute pointer position (framebuffer pixels, origin top-left).
   Updated from MOUSE_MOVE events (sokol_app worlds) and the first point of
   each touch event so apps can query it for picking/hover without
   accumulating deltas (which desyncs on focus/enter/resize); a pure tap
   produces no MOUSE_MOVE, so the touch update is what makes tap picking
   work. */
static float g_mouseX = 0.0f;
static float g_mouseY = 0.0f;

#if !defined(__wasm__)
static void ShimEventCb(const sapp_event* ev) {
	// Add a new event case here only if it is a generic window/input event any
	// app would plausibly want, forwarded as a scalar callback (see the file
	// header for the separation rule).
	switch (ev->type) {
		case SAPP_EVENTTYPE_MOUSE_DOWN:
			if (g_onButton) g_onButton((int)ev->mouse_button, 1);
			break;
		case SAPP_EVENTTYPE_MOUSE_UP:
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
#endif

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

#if !defined(__wasm__)
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
#else
/* Bare-wasm: the JS glue owns the loop. Registration just stores the
   callbacks and runs init; the glue then drives shim_js_frame() per rAF
   tick and shim_js_cleanup() on page teardown. */
void shim_run_app(ShimInitCb initCb, ShimFrameCb frameCb, ShimCleanupCb cleanupCb,
                  ShimMoveCb onMove, ShimScrollCb onScroll, ShimResizeCb onResize,
                  ShimKeyCb onKey, ShimButtonCb onButton, ShimTouchCb onTouch) {
	g_initCb = initCb;
	g_frameCb = frameCb;
	g_cleanupCb = cleanupCb;
	g_onMove = onMove;
	g_onScroll = onScroll;
	g_onResize = onResize;
	g_onKey = onKey;
	g_onButton = onButton;
	g_onTouch = onTouch;

	if (initCb) {
		initCb();
	}
}
#endif

/* Absolute pointer position in framebuffer pixels (origin top-left, Y down).
   sokol_app has no mouse-position query, so the shim tracks it (see
   g_mouseX for the tracking rule). */
void shim_get_mouse_pos(float* x, float* y) {
	if (x) *x = g_mouseX;
	if (y) *y = g_mouseY;
}

#if defined(__wasm__)
/* JS glue import (see the JS glue for the mapping to URL params). */
extern int shim_js_get_debug_param(int which);
int shim_debug_param(int which) {
	if (which < 0 || which > 5) {
		return 0;
	}
	return shim_js_get_debug_param(which);
}
#else
int shim_debug_param(int which) {
	(void)which;
	return 0;
}
#endif

#if defined(__wasm__)
/* JS glue import; the glue parses ?seed=N / ?terrain=N once at boot. */
extern uint64_t shim_js_get_debug_seed(int which);
uint64_t shim_debug_seed_param(int which) {
	if (which != 0 && which != 1) {
		return 0;
	}
	return shim_js_get_debug_seed(which);
}
#else
uint64_t shim_debug_seed_param(int which) {
	(void)which;
	return 0;
}
#endif

/* Shared-car payload: returns a static reused buffer (no free); the app
   must consume (copy) the bytes before the next shim call can overwrite
   them. "" = no shared car; native always returns "". */
#if defined(__wasm__)
#define SHIM_CAR_BUF_CAP 4096
static char g_car_buf[SHIM_CAR_BUF_CAP];
/* JS glue import: copies the #car= payload into buf (NUL-terminated),
   returns the byte count written (0 = none). */
extern int shim_js_get_car_payload(char* buf, int cap);
char* shim_debug_car_param(void) {
	shim_js_get_car_payload(g_car_buf, SHIM_CAR_BUF_CAP);
	return g_car_buf;
}
#else
char* shim_debug_car_param(void) {
	return "";
}
#endif

/* Share-popup state (wasm only): the JS overlay reports its open/closed
   state (0/1). Native always returns 0. */
#if defined(__wasm__)
extern int shim_js_get_share_open(void);
int shim_debug_share_open(void) {
	return shim_js_get_share_open();
}
#else
int shim_debug_share_open(void) {
	return 0;
}
#endif

/* Shared-car selector (wasm only): the tile index the user tapped in the
   share popup (-1 = none). Read-and-clear: the glue resets the value after
   reading, so each tap is delivered exactly once. Native always returns -1. */
#if defined(__wasm__)
extern int shim_js_get_share_car(void);
int shim_debug_share_car(void) {
	return shim_js_get_share_car();
}
#else
int shim_debug_share_car(void) {
	return -1;
}
#endif

/* App→JS JSON post: deliver a JSON string to a registered JS handler
   (window.__odm_js_handlers[which]). No-op native. */
#if defined(__wasm__)
/* JS glue import: the glue decodes the bytes straight from wasm memory
   (TextDecoder over a Uint8Array view — no copy through a static buffer,
   no escape path from the C string to a JS string literal). */
extern void shim_js_post(int which, const char* json, int len);
#else
void shim_js_post(int which, const char* json, int len) {
	(void)which;
	(void)json;
	(void)len;
}
#endif

/* ── Bare-wasm exports (the JS glue drives the module through these) ──────
   All are exported by name on the wasm link line (see tools/build_app.sh);
   the odin side never calls them. */
#if defined(__wasm__)

/* Canvas size in framebuffer pixels + device pixel ratio. The JS glue
   pushes them on resize (an initial resize before the first frame, so the
   app never sees zeros); the renderer C reads them through the sapp_*
   accessor functions (sokol_app.h declares them; the sokol_app worlds
   define them, this bare path does). */
static int g_sapp_width = 0;
static int g_sapp_height = 0;
static float g_sapp_dpi_scale = 1.0f;

int sapp_width(void) { return g_sapp_width; }
int sapp_height(void) { return g_sapp_height; }
float sapp_dpi_scale(void) { return g_sapp_dpi_scale; }

/* WebGPU handles (wgpu flavor reads them; the GL flavor leaves them 0).
   The JS glue owns the real objects behind its own handle table (small
   int indices, so uint32 crosses as a plain JS number — no BigInt) and
   pushes them in: the device via backend.init() between instantiation
   and _start (the app's init queries sglue_environment for it), the two
   swapchain views via shim_js_set_swapchain before every shim_js_frame
   call (WebGPU gives a fresh canvas texture per frame). */
static uint32_t g_wgpu_device = 0;
static uint32_t g_wgpu_render_view = 0;
static uint32_t g_wgpu_depth_view = 0;

void shim_js_set_wgpu_device(uint32_t device) {
	g_wgpu_device = device;
}

void shim_js_set_swapchain(uint32_t render_view, uint32_t depth_view) {
	g_wgpu_render_view = render_view;
	g_wgpu_depth_view = depth_view;
}


void shim_js_frame(void) {
	if (g_frameCb) {
		g_frameCb();
	}
}

void shim_js_cleanup(void) {
	if (g_cleanupCb) {
		g_cleanupCb();
	}
}

void shim_js_key(int keycode, int pressed) {
	if (g_onKey) {
		g_onKey(keycode, pressed);
	}
}

void shim_js_button(int button, int pressed) {
	if (g_onButton) {
		g_onButton(button, pressed);
	}
}

void shim_js_move(float dx, float dy) {
	if (g_onMove) {
		g_onMove(dx, dy);
	}
}

void shim_js_set_mouse(float x, float y) {
	g_mouseX = x;
	g_mouseY = y;
}

void shim_js_scroll(float dy) {
	if (g_onScroll) {
		g_onScroll(dy);
	}
}

void shim_js_resize(int w, int h, float dpi) {
	g_sapp_width = w;
	g_sapp_height = h;
	g_sapp_dpi_scale = dpi;
	if (g_onResize) {
		g_onResize(w, h);
	}
}

void shim_js_touch(int phase, int ident, float x, float y) {
	/* Pure dispatch; the glue pushes the event's first point through
	   shim_js_set_mouse so shim_get_mouse_pos returns the finger position
	   (a pure tap produces no mouse move; see g_mouseX). */
	if (g_onTouch) {
		g_onTouch(phase, ident, x, y);
	}
}

/* Scratch buffer for GL string returns (glGetString/glGetStringi): the JS
   glue copies the string here and returns this buffer's address; the
   renderer treats it like any GL string (read-only, valid until the next
   string call). Exported as data by name (see tools/build_app.sh). */
#define SHIM_GL_STRING_CAP 2048
char shim_gl_scratch[SHIM_GL_STRING_CAP];

/* sokol_glue's two getters (the glue impl in sokol_glue.h calls these
   instead of sokol_app's on the bare path). */
sapp_environment sapp_get_environment(void) {
	sapp_environment env;
	memset(&env, 0, sizeof(env));
	env.defaults.color_format = SAPP_PIXELFORMAT_RGBA8;
	env.defaults.depth_format = SAPP_PIXELFORMAT_DEPTH;
	env.defaults.sample_count = 1; /* renderer runs MSAA in its own scene target */
	env.wgpu.device = (const void*)(uintptr_t)g_wgpu_device;
	return env;
}

sapp_swapchain sapp_acquire_swapchain(void) {
	sapp_swapchain sc;
	memset(&sc, 0, sizeof(sc));
	sc.invalid = false;
	sc.width = g_sapp_width;
	sc.height = g_sapp_height;
	sc.sample_count = 1;
	sc.color_format = SAPP_PIXELFORMAT_RGBA8;
	sc.depth_format = SAPP_PIXELFORMAT_DEPTH;
	sc.wgpu.render_view = (const void*)(uintptr_t)g_wgpu_render_view;
	sc.wgpu.depth_stencil_view = (const void*)(uintptr_t)g_wgpu_depth_view;
	return sc;
}

#endif /* bare-wasm exports */
