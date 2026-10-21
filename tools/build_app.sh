#!/usr/bin/env bash
# Stage 2 — build one app: compile apphost_shim.c with that app's window
# title, build the app's own Odin, and link the matching engine archives.
#
#   build_app.sh native <app>   → apps/<app>/build/native/<APP>
#   build_app.sh wasm   <app>   → apps/<app>/build/wasm/index.html
#
# Sources apps/<app>/project.env for APP, TITLE, and ML_LIBS (the space-separated
# ML archives this app links; a subset of "kann cmaes neat", unset = all three).
# App-only changes recompile no engine C (physics + graphics are prebuilt by
# tools/build_engine.sh); only apphost_shim.c is recompiled per app (the title
# is a compile-time string).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET="${1:?usage: build_app.sh <native|wasm> <app>}"
APP_DIR_NAME="${2:?usage: build_app.sh <native|wasm> <app>}"
APP_ROOT="$ROOT/apps/$APP_DIR_NAME"

[ -d "$APP_ROOT" ] || { echo "Error: app $APP_DIR_NAME not found ($APP_ROOT)" >&2; exit 1; }
# shellcheck source=/dev/null
. "$APP_ROOT/project.env"
[ -n "${APP:-}" ]  || { echo "Error: APP not set in $APP_ROOT/project.env" >&2; exit 1; }
[ -n "${TITLE:-}" ] || { echo "Error: TITLE not set in $APP_ROOT/project.env" >&2; exit 1; }
BOX3D="$ROOT/vendor/box3d"
SOKOL="$ROOT/vendor/sokol"
FORK="$ROOT/engine/graphics/renderer"
ENGLIB="$ROOT/engine/lib"
INC_COMMON=(-I"$BOX3D/include" -I"$SOKOL" -I"$FORK" -I"$FORK/shaders/generated")
# ML archives are backend-agnostic (pure C, no sokol): one _<target> archive
# per lib serves both wasm flavors.
# No colon: an empty-but-set ML_LIBS (from project.env) means "no ML libs";
# the default applies only when the variable is unset.
ML_LIBS="${ML_LIBS-kann cmaes neat}"
ML_ARCHS=""
# shellcheck disable=SC2086  # intentional word-splitting of the lib list
for lib in $ML_LIBS; do ML_ARCHS="$ML_ARCHS $ENGLIB/lib${lib}_${TARGET}.a"; done

# ── Compile apphost_shim.c with this app's title ──
# Suffix selects the sokol backend flavor for the archive name (the sokol
# backend is a compile-time macro, so each flavor gets its own object +
# archive): "" = SOKOL_GLCORE native / SOKOL_WGPU wasm, "gl" = SOKOL_GLES3
# wasm (WebGL2 fallback; archive suffix matches libgraphics_wasmgl.a).
compile_apphost() {
	local suffix="$1"; shift
	local def=("$@")
	local archive="libapphost_${TARGET}${suffix}.a"
	local obj="apphost_shim${suffix:+_gl}.o"
	echo "── Compiling apphost_shim.c (title=\"$TITLE\") → $archive ──"
	BUILD="$ROOT/build/$TARGET"; mkdir -p "$BUILD"
	if [ "$TARGET" = native ]; then
		gcc -c -O2 -fPIC -std=c17 -Wall -Wextra "${def[@]}" "${INC_COMMON[@]}" \
			-DSHIM_WINDOW_TITLE="\"$TITLE\"" \
			"$ROOT/engine/apphost/apphost_shim.c" -o "$BUILD/$obj"
		ar rcs "$ENGLIB/$archive" "$BUILD/$obj"
	else
		local port=()
		[ -z "$suffix" ] && port=(--use-port=emdawnwebgpu)
		emcc -c -O3 -std=gnu17 "${def[@]}" "${port[@]}" "${INC_COMMON[@]}" \
			-DSHIM_WINDOW_TITLE="\"$TITLE\"" \
			"$ROOT/engine/apphost/apphost_shim.c" -o "$BUILD/$obj"
		emar rcs "$ENGLIB/$archive" "$BUILD/$obj"
	fi
}

build_native() {
	compile_apphost "" -DSOKOL_GLCORE -DNDEBUG
	OUT="$APP_ROOT/build/native"
	mkdir -p "$OUT"
	# Optional per-app build hook: if apps/<app>/build_hook.sh exists, run it
	# with (target, APP_ROOT, ROOT) and append its stdout (extra archive paths /
	# linker flags) to -extra-linker-flags. A generic mechanism any app with
	# extra vendored C can use — the app-specific content lives in the hook.
	HOOK_FLAGS=""
	if [ -f "$APP_ROOT/build_hook.sh" ]; then
		HOOK_FLAGS="$(bash "$APP_ROOT/build_hook.sh" native "$APP_ROOT" "$ROOT")"
	fi
	echo "── Building Odin binary (native) → $OUT/$APP ──"
	odin build "$APP_ROOT/src" -collection:engine="$ROOT/engine" \
		-out:"$OUT/$APP" -o:speed \
		-vet -strict-style -vet-tabs -disallow-do -warnings-as-errors \
		-extra-linker-flags:"$ENGLIB/libphysics_native.a $ENGLIB/libgraphics_native.a $ENGLIB/libapphost_native.a $ML_ARCHS $HOOK_FLAGS -lGL -ldl -lm -lpthread -lX11 -lXi -lXcursor"
	echo ""
	echo "✓ Native build complete: $OUT/$APP"
	echo "  Run with: ./$OUT/$APP"
}

build_wasm() {
	# Locate Emscripten
	if ! command -v emcc &>/dev/null; then
		for c in "${EMSDK_HOME:-}" "$HOME/dev/upstream/toolchain/emsdk" "$HOME/dev/clone/emsdk" "$HOME/emsdk" /opt/emsdk; do
			if [ -n "$c" ] && [ -f "$c/emsdk_env.sh" ]; then source "$c/emsdk_env.sh" >/dev/null 2>&1; break; fi
		done
	fi
	command -v emcc >/dev/null || { echo "Error: emcc not found." >&2; exit 1; }
	compile_apphost "" -DSOKOL_WGPU -DNDEBUG
	compile_apphost "gl" -DSOKOL_GLES3 -DNDEBUG
	OUT="$APP_ROOT/build/wasm"
	mkdir -p "$OUT"
	ODIN_ROOT="$(odin root)"
	echo "── Building Odin object (js_wasm32) ──"
	odin build "$APP_ROOT/src" -target:js_wasm32 -build-mode:obj \
		-collection:engine="$ROOT/engine" \
		-out:"$OUT/$APP.wasm.obj" -o:speed \
		-vet -strict-style -vet-tabs -disallow-do -warnings-as-errors

	# One Odin object, two emcc links: sokol's backend is a compile-time
	# macro, so the WebGPU (SOKOL_WGPU) and WebGL2 (SOKOL_GLES3) flavors
	# are separate wasm artifacts sharing the Odin + physics + ml archives.
	# Each link emits a standalone Emscripten glue + wasm pair
	# (index.js/index.wasm, index-gles.js/index-gles.wasm). The single web
	# entry (tools/web/index_template.html) probes the browser at boot and
	# loads the matching glue as an external script, so the URL is stable
	# and a shared link runs the best available backend on the recipient's
	# machine.
	link_wasm_variant() {
		local variant="$1"
		local arch_graphics arch_apphost js_out em_extra
		case "$variant" in
			webgpu)
				arch_graphics="$ENGLIB/libgraphics_wasm.a"
				arch_apphost="$ENGLIB/libapphost_wasm.a"
				js_out="$OUT/index.js"
				em_extra=(--use-port=emdawnwebgpu)
				;;
			webgl2)
				arch_graphics="$ENGLIB/libgraphics_wasmgl.a"
				arch_apphost="$ENGLIB/libapphost_wasmgl.a"
				js_out="$OUT/index-gles.js"
				# sokol's GLES3 backend speaks the WebGL2 ES 3.0 API; no
				# emdawnwebgpu port (Dawn is the WebGPU-only dependency).
				em_extra=(-sUSE_WEBGL2=1)
				;;
		esac
		echo "── Linking with emcc ($variant) → $(basename "$js_out") ──"
		# Emscripten 6.0 EXPORTED_FUNCTIONS are C symbols (leading '_'); Odin's
		# runtime exports `_start` and our entry is `main_start`.
		#
		# `-sWARN_ON_UNDEFINED_SYMBOLS=0` is REQUIRED, not a sloppy relaxation:
		# the Odin wasm runtime imports `cos`/`sin`/`write`/`rand_bytes`/… from
		# `odin_env`, which is supplied at instantiation by odin.js (merged with
		# Emscripten's imports in tools/web/index_template.html's
		# instantiateWasm). Emscripten's link-time symbol resolution cannot see
		# those JS-side imports, so they are legitimately "undefined" to the
		# linker. Do NOT remove this flag without first routing those imports
		# through a mechanism the linker can see. The native build (tools/test.sh)
		# links with no such relaxation and is the regression guard for the
		# C-shim symbol surface.
		# 2 MiB stack (-sSTACK_SIZE): emscripten's 64 KiB default overflows in
		# b3CreateHull (deep odin→C call chain in slot_start/init_sim_pose), and
		# the overflow writes past the stack bottom INTO THE HEAP — silently
		# corrupting malloc metadata (later OOB trap in malloc) and, with the
		# renderer live, sokol's WebGPU state (the Waterfox GPU-thread crash).
		emcc -O3 \
			"$OUT/$APP.wasm.obj" \
			"$ENGLIB/libphysics_wasm.a" "$arch_graphics" "$arch_apphost" \
			$ML_ARCHS \
			"${em_extra[@]}" \
			-sALLOW_MEMORY_GROWTH=1 \
			-sSTACK_SIZE=2097152 \
			-sEXPORTED_FUNCTIONS=['__start','_main_start'] \
			-sEXPORTED_RUNTIME_METHODS=['wasmExports'] \
			-sASSERTIONS=1 \
			-sWARN_ON_UNDEFINED_SYMBOLS=0 \
			-o "$js_out"
	}
	cp "$ODIN_ROOT/core/sys/wasm/js/odin.js" "$OUT/odin.js"
	link_wasm_variant webgpu
	link_wasm_variant webgl2
	rm -f "$OUT/$APP.wasm.obj"
	# The single web entry: static HTML with no Emscripten shell
	# substitution — its boot script probes the browser and loads
	# index.js or index-gles.js (see tools/web/index_template.html).
	sed "s#@TITLE@#$TITLE#g; s#@PROJECT@#$APP#g; s#@OG_URL@#${SITE_URL:-}#g; s#@OG_DESCRIPTION@#${OG_DESCRIPTION:-}#g; s#@OG_IMAGE@#${SITE_URL:-}/${OG_IMAGE:-}#g" \
		"$ROOT/tools/web/index_template.html" > "$OUT/index.html"
	# Apps without a published site (no SITE_URL) ship no og: tags at all —
	# empty og:url/og:image would be worse than absent.
	if [ -z "${SITE_URL:-}" ]; then
		grep -v 'property="og:' "$OUT/index.html" > "$OUT/index.html.tmp" \
			&& mv "$OUT/index.html.tmp" "$OUT/index.html"
	fi

	# The entry's vendored web assets (tools/web/vendor/ — the QR generator
	# for the share overlay's card); they live in tools/ because they are
	# web-shell content, not app content (see the apphost.sh header).
	if [ -d "$ROOT/tools/web/vendor" ] && [ -n "$(ls -A "$ROOT/tools/web/vendor")" ]; then
		mkdir -p "$OUT/vendor"
		cp -rf "$ROOT/tools/web/vendor/"* "$OUT/vendor/"
	fi

	# The entry's About button links to about.html, hosted alongside the
	# entry: the app's own apps/<app>/web/about.html when present, else the
	# shared default (tools/publish_web.sh stages the same set for the
	# publish dir). Other files under apps/<app>/web/ ship too.
	if [ -d "$APP_ROOT/web" ] && [ -n "$(ls -A "$APP_ROOT/web")" ]; then
		cp -rf "$APP_ROOT/web/"* "$OUT/"
	fi
	[ -f "$OUT/about.html" ] || cp -f "$ROOT/tools/web/about_default.html" "$OUT/about.html"

	# Regression guard for the export-name contract: the web shell
	# (tools/web/index_template.html) boots Odin by calling
	# wasmExports._start() then wasmExports.main_start(), so the linked wasm
	# MUST export exactly those two symbols. A future Emscripten or Odin
	# runtime change that renames/drops them would otherwise produce a blank
	# canvas; fail the build here instead.
	verify_wasm_exports() {
		local wasm="$1"
		[ -f "$wasm" ] || { echo "Error: $wasm not produced" >&2; exit 1; }
		local nm=""
		for c in llvm-nm wasm-objdump; do command -v "$c" >/dev/null 2>&1 && { nm="$c"; break; }; done
		if [ -z "$nm" ]; then
			echo "  warn: llvm-nm/wasm-objdump not found; skipping export check" >&2
			return
		fi
		missing=0
		for sym in _start main_start; do
			if ! "$nm" --defined-only --extern-only "$wasm" 2>/dev/null | grep -qw "$sym"; then
				echo "Error: $wasm does not export '$sym' (web shell boot depends on it)" >&2
				missing=1
			fi
		done
		[ "$missing" -eq 0 ] || exit 1
	}
	verify_wasm_exports "$OUT/index.wasm"
	verify_wasm_exports "$OUT/index-gles.wasm"
	echo ""
	echo "✓ WASM build complete: $OUT/"
	echo "  index.html          (single entry; WebGPU with WebGL2 fallback)"
	echo "  index.js/.wasm      (WebGPU) · index-gles.js/.wasm (WebGL2)"
	echo "  Serve with:  python3 -m http.server -d $OUT 8000"
}

case "$TARGET" in
	native) build_native ;;
	wasm)   build_wasm   ;;
	*) echo "usage: build_app.sh <native|wasm> <app>" >&2; exit 1 ;;
esac