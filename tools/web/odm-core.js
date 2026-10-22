/* odm-core.js — the bare-wasm web host layer.
 *
 * The web host layer for the odin-driver-linked wasm build.
 * The module's only imports are:
 *   odin_env: write, rand_bytes            (the odin runtime's env)
 *   env:      the backend table (the GL and WebGPU calls), the shim_js_*
 *             C->JS interop
 *             (debug params, car payload, share state, js_post), and the
 *             libc-shim symbols the odin driver resolves in-module
 *             (those are DEFINITIONS, not imports — never listed here).
 * and the exports are: memory, _start, _end, default_context_ptr, the
 * odin @(export) procs, and the apphost C procs (shim_js_frame etc.)
 * exported by name on the link line.
 *
 * Boot: the page probes the backend, loads the matching glue
 * (index.js = WebGPU, index-gles.js = WebGL2), which sets
 * window.__ODM_BACKEND__ = { name, imports(views), init(exports),
 * frame(), resize(w, h, dpi), cleanup() }, then calls odmCore.boot().
 *
 * Contract with the C shim (engine/apphost/apphost_shim.c, bare-wasm
 * section): frame/input flow in as scalar shim_js_* calls mirroring
 * sokol_app's callback shape; the renderer reads canvas
 * size through the sapp_* accessors the shim feeds from shim_js_resize.
 */
(function () {
	"use strict";

	/* ── memory views ──
	   The module owns its memory; the views must track growth (the odin
	   runtime grows it under load). sync() is called before every import
	   that touches a
	   view; JS->C calls never hand out views (bytes are copied out). */
	var E = null; /* wasm instance exports */
	var canvas = null; /* set in boot(); read by the frame/input helpers */
	var backend = null; /* window.__ODM_BACKEND__, set in boot() */
	var memBuf = null;
	var U8 = null, I32 = null, F32 = null;
	function syncViews() {
		var b = E.memory.buffer;
		if (b !== memBuf) {
			memBuf = b;
			U8 = new Uint8Array(b);
			I32 = new Int32Array(b);
			F32 = new Float32Array(b);
		}
	}

	/* ── odin_env ── */
	var decoder = new TextDecoder();
	var odinEnv = {
		write: function (fd, ptr, len) {
			syncViews();
			var s = decoder.decode(U8.subarray(ptr, ptr + len));
			/* fd 1/2 both go to the JS console (the app's fmt output
			   is diagnostic only). */
			if (fd === 2) { console.warn(s); } else { console.log(s); }
		},
		rand_bytes: function (ptr, len) {
			syncViews();
			var n = 0;
			while (n < len) {
				var chunk = Math.min(65536, len - n);
				var b = new Uint8Array(chunk);
				crypto.getRandomValues(b);
				U8.set(b, ptr + n);
				n += chunk;
			}
		},
		/* The odin runtime's f64 math + clock are JS-backed on this target
		   (core:math / core:time foreign "odin_env" shims — the libc-shim's
		   C sin/cos/exp/... funnel into these). Plain JS numbers in/out. */
		sin: Math.sin,
		cos: Math.cos,
		exp: Math.exp,
		ln: Math.log,
		pow: Math.pow,
		time_now: function () { return BigInt(Date.now()); }
	};

	/* ── C->JS interop (the shim's extern imports) ──
	   The window.__odm_* variables are set by index_template.html's boot
	   script BEFORE boot (URL params, #car= payload, share overlay state).
	   */
	var interop = {
		shim_js_get_debug_param: function (which) {
			/* a[5] = ?ao= — -1 when the param is absent (0/1 explicit). */
			var a = window.__odm_debug_arr || [0, 0, 0, 0, 0, -1];
			return a[which] | 0;
		},
		/* returns u64: i64 crosses the boundary as a BigInt, and the seed
		   is a full 64-bit decimal (parseInt would truncate at 2^53). */
		shim_js_get_debug_seed: function (which) {
			var a = window.__odm_debug_seed_arr || ["0", "0"];
			try {
				return BigInt(a[which]);
			} catch (e) {
				return 0n;
			}
		},
		shim_js_get_car_payload: function (buf, cap) {
			syncViews();
			var s = window.__odm_car_payload || "";
			var b = new TextEncoder().encode(s);
			var n = Math.min(b.length, cap - 1);
			U8.set(b.subarray(0, n), buf);
			U8[buf + n] = 0;
			return n;
		},
		shim_js_get_share_open: function () {
			return window.__odm_share_open | 0;
		},
		/* read-and-clear: each tapped tile is delivered exactly once
		   (the template sets __odm_share_car to the tile index). */
		shim_js_get_share_car: function () {
			var i = window.__odm_share_car | 0;
			window.__odm_share_car = -1;
			return i;
		},
		/* the shim passes the JSON pointer/len straight in; decode from
		   wasm memory (no static C buffer on the bare path). */
		shim_js_post: function (which, ptr, len) {
			syncViews();
			var h = window.__odm_js_handlers && window.__odm_js_handlers[which];
			if (h) {
				h(decoder.decode(U8.subarray(ptr, ptr + len)));
			}
		}
	};

	/* ── keyboard: DOM e.code -> SAPP_KEYCODE (GLFW values) ──
	   Physical-key mapping, layout-independent, like GLFW. The apphost
	   forwards only the keycodes in apphost.odin; unknowns (modifiers,
	   media keys) are dropped. */
	var KEY = {
		"KeyA": 65, "KeyB": 66, "KeyC": 67, "KeyD": 68, "KeyE": 69,
		"KeyF": 70, "KeyG": 71, "KeyH": 72, "KeyI": 73, "KeyJ": 74,
		"KeyK": 75, "KeyL": 76, "KeyM": 77, "KeyN": 78, "KeyO": 79,
		"KeyP": 80, "KeyQ": 81, "KeyR": 82, "KeyS": 83, "KeyT": 84,
		"KeyU": 85, "KeyV": 86, "KeyW": 87, "KeyX": 88, "KeyY": 89,
		"KeyZ": 90,
		"Digit0": 48, "Digit1": 49, "Digit2": 50, "Digit3": 51,
		"Digit4": 52, "Digit5": 53, "Digit6": 54, "Digit7": 55,
		"Digit8": 56, "Digit9": 57,
		"Quote": 39, "Comma": 44, "Minus": 45, "Period": 46, "Slash": 47,
		"Semicolon": 59, "Equal": 61, "BracketLeft": 91, "Backslash": 92,
		"BracketRight": 93, "Backquote": 96,
		"Escape": 256, "Enter": 257, "Tab": 258, "Backspace": 259,
		"Insert": 260, "Delete": 261, "ArrowRight": 262, "ArrowLeft": 263,
		"ArrowDown": 264, "ArrowUp": 265, "PageUp": 266, "PageDown": 267,
		"Home": 268, "End": 269, "F1": 290, "F2": 291, "F3": 292, "F4": 293,
		"F5": 294, "F6": 295, "F7": 296, "F8": 297, "F9": 298, "F10": 299
	};

	function boot(opts) {
		var wasmUrl = opts.wasmUrl;
		var fail = opts.fail;
		canvas = opts.canvas;

		backend = window.__ODM_BACKEND__;
		if (!backend) {
			fail("backend glue missing (window.__ODM_BACKEND__)");
			return;
		}

		/* Backend prepare BEFORE _start: the app's init (inside _start ->
		   shim_run_app) already creates GPU resources, so the WebGL2
		   context / WebGPU device must exist by then. GL resolves
		   immediately; WebGPU awaits requestAdapter/requestDevice. */
		Promise.resolve(backend.prepare(canvas)).then(function () {
			return WebAssembly.instantiateStreaming(fetch(wasmUrl), {
				odin_env: odinEnv,
				env: Object.assign({}, backend.imports(), interop)
			});
		}).then(function (result) {
			E = result.instance.exports;
			if (typeof E.shim_js_frame !== "function") {
				fail("wasm exports shim_js_frame missing — wrong link line?");
				return;
			}
			/* Backend hook AFTER the instance exists, BEFORE _start:
			   the WGPU glue pushes its device handle in (the app's init
			   inside _start queries sglue_environment for it); the GL
			   glue's context was already created in prepare(). */
			backend.init && backend.init(E);
			/* _start() runs main() -> ... -> shim_run_app() (the bare
			   section stores the callbacks and runs init once). */
			E._start();
			wireInput();
			initialResize();
			requestAnimationFrame(tick);
			opts.ready && opts.ready();
		}).catch(function (err) {
			fail("boot failed: " + err);
		});
	}

	function dpr() { return window.devicePixelRatio || 1; }

	/* Canvas pixel size = CSS size * devicePixelRatio (the canvas is
	   100vw/100vh in the template); matches sokol_app's surface sizing. */
	function measure() {
		var s = dpr();
		return {
			w: Math.max(1, Math.round(canvas.clientWidth * s)),
			h: Math.max(1, Math.round(canvas.clientHeight * s)),
			dpi: s
		};
	}
	var lastW = 0, lastH = 0, lastDpi = -1;
	function resizeCanvas() {
		var m = measure();
		if (m.w !== lastW || m.h !== lastH || m.dpi !== lastDpi) {
			canvas.width = m.w;
			canvas.height = m.h;
			backend.resize(m.w, m.h, m.dpi);
			E.shim_js_resize(m.w, m.h, m.dpi);
			lastW = m.w; lastH = m.h; lastDpi = m.dpi;
			return true;
		}
		return false;
	}
	function initialResize() {
		/* The app's init (already run inside _start) may have measured
		   0x0; the first frame must see a real size (see the shim's
		   sapp_* comment). */
		resizeCanvas();
	}

	function tick() {
		requestAnimationFrame(tick);
		if (document.hidden) { return; }
		resizeCanvas();
		backend.frame();      /* per-frame GPU prep (WGPU: fresh surface) */
		E.shim_js_frame();
	}

	/* ── input ── */
	function fbXY(e) {
		var r = canvas.getBoundingClientRect();
		var s = dpr();
		return {
			x: (e.clientX - r.left) * s,
			y: (e.clientY - r.top) * s
		};
	}

	/* Compat-mode browsers synthesize a mouse event per touch; drop mouse
	   BUTTON events within this window of the last touch (the loop is
	   JS-owned, so the drop lives here). */
	var TOUCH_MOUSE_SUPPRESS_MS = 500;
	var lastTouchMs = -1e9;

	var pressed = {};
	function wireInput() {
		window.addEventListener("keydown", function (e) {
			var k = KEY[e.code];
			if (k === undefined || pressed[e.code]) { return; }
			pressed[e.code] = 1;
			E.shim_js_key(k, 1);
		});
		window.addEventListener("keyup", function (e) {
			var k = KEY[e.code];
			if (k === undefined || !pressed[e.code]) { return; }
			delete pressed[e.code];
			E.shim_js_key(k, 0);
		});

		canvas.addEventListener("mousedown", function (e) {
			if (performance.now() - lastTouchMs < TOUCH_MOUSE_SUPPRESS_MS) { return; }
			var b = e.button === 0 ? 0 : (e.button === 1 ? 2 : (e.button === 2 ? 1 : -1));
			if (b < 0) { return; }
			e.preventDefault();
			var p = fbXY(e);
			E.shim_js_set_mouse(p.x, p.y);
			E.shim_js_button(b, 1);
		});
		canvas.addEventListener("mouseup", function (e) {
			if (performance.now() - lastTouchMs < TOUCH_MOUSE_SUPPRESS_MS) { return; }
			var b = e.button === 0 ? 0 : (e.button === 1 ? 2 : (e.button === 2 ? 1 : -1));
			if (b < 0) { return; }
			var p = fbXY(e);
			E.shim_js_set_mouse(p.x, p.y);
			E.shim_js_button(b, 0);
		});
		window.addEventListener("mousemove", function (e) {
			if (e.target !== canvas) { return; }
			var s = dpr();
			var p = fbXY(e);
			E.shim_js_set_mouse(p.x, p.y);
			E.shim_js_move(e.movementX * s, e.movementY * s);
		});
		canvas.addEventListener("wheel", function (e) {
			e.preventDefault();
			var scale;
			switch (e.deltaMode) {
				case 1: scale = -1.33; break;  /* DOM_DELTA_LINE  */
				case 2: scale = -10.0; break;  /* DOM_DELTA_PAGE  */
				default: scale = -0.01; break; /* DOM_DELTA_PIXEL */
			}
			E.shim_js_scroll(scale * e.deltaY);
		}, { passive: false });

		/* Touch: forward every point of the event in order (the shim
		   dispatches them in sequence); the first point also updates the
		   tracked pointer position, so a pure tap picks at the finger
		   (matches sokol_app's rule). */
		function touchPhase(t) {
			return t === "touchstart" ? 0 : t === "touchmove" ? 1
				: t === "touchend" ? 2 : 3;
		}
		["touchstart", "touchmove", "touchend", "touchcancel"].forEach(function (t) {
			canvas.addEventListener(t, function (e) {
				e.preventDefault();
				lastTouchMs = performance.now();
				var ph = touchPhase(t);
				var s = dpr();
				for (var i = 0; i < e.changedTouches.length; i++) {
					var tc = e.changedTouches[i];
					var p = fbXY(tc);
					if (i === 0 && (ph === 0 || ph === 1)) {
						E.shim_js_set_mouse(p.x, p.y);
					}
					E.shim_js_touch(ph, tc.identifier, p.x, p.y);
				}
			}, { passive: false });
		});

		/* Teardown: the app's cleanup_cb (release GPU resources) runs on
		   page hide (bfcache/refresh/close). */
		window.addEventListener("pagehide", function () {
			try {
				E.shim_js_cleanup();
				backend.cleanup();
			} catch (err) { /* best effort */ }
		});
	}

	/* ── shared with the backend glue ──
	   The backend's import functions are CONSTRUCTED before the instance
	   exists (they are part of the import object) but CALLED after
	   instantiation, so they fetch the memory views lazily through
	   views(). A call that returns null views is a programming error in
	   the glue (an import invoked before boot finished). */
	function views() {
		if (!E) { return null; }
		syncViews();
		return { U8: U8, I32: I32, F32: F32 };
	}

	/* Data exports (e.g. shim_gl_scratch): numeric byte offsets into the
	   module's memory. */
	function data(name) {
		return E ? E[name] : 0;
	}

	window.odmCore = { boot: boot, views: views, data: data };
})();
