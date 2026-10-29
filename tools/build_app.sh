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
# Box3D lives in the Odin toolchain (vendor/box3d in the toolchain tree) on
# both targets: the engine C compiles against its headers, and `odin build`
# links the toolchain's prebuilt (libbox3d.a native / box3d_wasm.o wasm)
# from the app object's `foreign import lib`.
ODIN_ROOT="$(odin root)"
B3INC="$ODIN_ROOT/vendor/box3d/src/include"
# The native final link names libbox3d.a directly: the renderer C references
# b3* symbols even in apps that never import the physics package,
# so the archive must be on every native link line.
case "$(uname -s)" in
	Darwin) B3LIB="$ODIN_ROOT/vendor/box3d/lib/darwin/libbox3d.a" ;;
	*)      B3LIB="$ODIN_ROOT/vendor/box3d/lib/linux-amd64/libbox3d.a" ;;
esac
SOKOL="$ROOT/vendor/sokol"
FORK="$ROOT/engine/graphics/renderer"
ENGLIB="$ROOT/engine/lib"
INC_COMMON=(-I"$B3INC" -I"$SOKOL" -I"$FORK" -I"$FORK/shaders/generated")
# Bare-wasm header roots (mirrors build_engine.sh): libc-shim headers, the
# cext fills, and the vendored backend API headers (vendor/webgpu-headers,
# vendor/gles3-headers).
SHIM_INC="$ODIN_ROOT/vendor/libc-shim/include"
CXT="$ROOT/engine/cext"
WGPU_INC="$ROOT/vendor/webgpu-headers"
GL_INC="$ROOT/vendor/gles3-headers"
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
		# Bare wasm: libc-shim headers + cext fills. The GLES3
		# flavor force-includes the GL API header (bare wasm matches none
		# of sokol's GL platform branches; see build_engine.sh).
		local hdr=()
		if [ -n "$suffix" ]; then
			hdr=(-I"$GL_INC" -include "$GL_INC/GLES3/gl3.h")
		else
			hdr=(-I"$WGPU_INC")
		fi
		clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -c "${def[@]}" \
			-I"$CXT" -I"$SHIM_INC" "${hdr[@]}" "${INC_COMMON[@]}" \
			-DSHIM_WINDOW_TITLE="\"$TITLE\"" \
			"$ROOT/engine/apphost/apphost_shim.c" -o "$BUILD/$obj"
		ar rcs "$ENGLIB/$archive" "$BUILD/$obj"
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
		-extra-linker-flags:"$ENGLIB/libphysics_native.a $ENGLIB/libgraphics_native.a $ENGLIB/libapphost_native.a $B3LIB $ML_ARCHS $HOOK_FLAGS -lGL -ldl -lm -lpthread -lX11 -lXi -lXcursor"
	echo ""
	echo "✓ Native build complete: $OUT/$APP"
	echo "  Run with: ./$OUT/$APP"
}

build_wasm() {
	# Bare-wasm build: clang compiles the apphost C, and
	# `odin build` does the full compile + final wasm-ld link per flavor.
	# Sokol's backend is a compile-time macro, so the WebGPU (SOKOL_WGPU)
	# and WebGL2 (SOKOL_GLES3) flavors are separate wasm artifacts sharing
	# the Odin + physics + ml archives; the single web entry
	# (tools/web/index_template.html) probes the browser at boot and loads
	# the matching glue (index.js / index-gles.js) as an external script,
	# so the URL is stable and a shared link runs the best available
	# backend on the recipient's machine.
	command -v clang >/dev/null || { echo "Error: clang not found (need wasm32 target support)." >&2; exit 1; }
	compile_apphost "" -DSOKOL_WGPU -DNDEBUG
	compile_apphost "gl" -DSOKOL_GLES3 -DNDEBUG
	OUT="$APP_ROOT/build/wasm"
	mkdir -p "$OUT"

	# box3d_wasm.a: the toolchain's prebuilt box3d object as a single-member
	# archive, so every app's final link can resolve the renderer's b3*
	# references even when the app's package graph never reaches
	# vendor:box3d. Physics apps already link the object via the
	# package, and an archive member is pulled only for still-undefined
	# symbols, so they are unaffected.
	B3ARCH="$ENGLIB/libbox3d_wasm.a"
	ar rcs "$B3ARCH" "$ODIN_ROOT/vendor/box3d/lib/box3d_wasm.o"

	# The C-side export surface the JS glue (tools/web/odm-core.js) drives:
	# the apphost shim procs (frame/input/resize) + the GL string scratch
	# buffer (data export). Forwarded to the odin driver's wasm-ld line.
	# main_start is gone: _start() runs the app's main() (the driver's odin
	# runtime entry), which reaches shim_run_app.
	EXPORTS="--export=shim_js_frame --export=shim_js_cleanup --export=shim_js_key --export=shim_js_button --export=shim_js_move --export=shim_js_set_mouse --export=shim_js_scroll --export=shim_js_resize --export=shim_js_touch --export=shim_js_set_wgpu_device --export=shim_js_set_swapchain --export=shim_gl_scratch"

	# Optional per-app build hook (same contract as the native build).
	HOOK_FLAGS=""
	if [ -f "$APP_ROOT/build_hook.sh" ]; then
		HOOK_FLAGS="$(bash "$APP_ROOT/build_hook.sh" wasm "$APP_ROOT" "$ROOT")"
	fi

	link_wasm_variant() {
		local variant="$1"
		local gfx apphost out
		case "$variant" in
			webgpu)
				gfx="$ENGLIB/libgraphics_wasm.a"
				apphost="$ENGLIB/libapphost_wasm.a"
				out="$OUT/index"
				;;
			webgl2)
				gfx="$ENGLIB/libgraphics_wasmgl.a"
				apphost="$ENGLIB/libapphost_wasmgl.a"
				out="$OUT/index-gles"
				;;
		esac
		echo "── odin build → $(basename "$out").wasm ($variant) ──"
		# Box3D (b3*): the renderer C references b3* symbols, so the module
		# must define them. Apps whose package graph reaches vendor:box3d
		# (physics) get the toolchain's prebuilt box3d_wasm.o linked by the
		# odin driver; apps that never import physics need the
		# same object as an archive on the link line ($B3ARCH) — the
		# linker pulls its members only if the symbols are still undefined,
		# so physics apps link it in exactly once either way. The libc-shim
		# @require (wasm target only, in apphost.odin) resolves the C
		# objects' libc undefineds in-module.
		odin build "$APP_ROOT/src" -target:js_wasm32 \
			-collection:engine="$ROOT/engine" \
			-out:"$out" -o:speed \
			-vet -strict-style -vet-tabs -disallow-do -warnings-as-errors \
			-extra-linker-flags:"$ENGLIB/libphysics_wasm.a $B3ARCH $ENGLIB/libcext_wasm.a $gfx $apphost $ML_ARCHS $HOOK_FLAGS $EXPORTS"
	}
	link_wasm_variant webgpu
	link_wasm_variant webgl2

	# The JS host layer: the shared driver + the two backend tables (static
	# web-shell content, the same set tools/publish_web.sh stages).
	cp "$ROOT/tools/web/odm-core.js" "$OUT/odm-core.js"
	cp "$ROOT/tools/web/glue-webgpu.js" "$OUT/index.js"
	cp "$ROOT/tools/web/glue-webgl2.js" "$OUT/index-gles.js"

	# The single web entry: static HTML (see tools/web/index_template.html).
	sed "s#@TITLE@#$TITLE#g; s#@PROJECT@#$APP#g; s#@OG_URL@#${SITE_URL:-}#g; s#@OG_DESCRIPTION@#${OG_DESCRIPTION:-}#g; s#@OG_IMAGE@#${SITE_URL:-}/${OG_IMAGE:-}#g" \
		"$ROOT/tools/web/index_template.html" > "$OUT/index.html"
	# Apps without a published site (no SITE_URL) ship no og: tags, no meta
	# description, and no canonical at all — empty values would be worse
	# than absent.
	if [ -z "${SITE_URL:-}" ]; then
		grep -vE 'property="og:|name="description"|rel="canonical"' "$OUT/index.html" \
			> "$OUT/index.html.tmp" \
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

	# Regression guard for the export-name contract: the web shell boots
	# the module by calling _start() and then driving the exported
	# shim_js_* procs, so the linked wasm MUST export those symbols. A
	# future Odin runtime change that renames/drops them would otherwise
	# produce a blank canvas; fail the build here instead.
	verify_wasm_exports() {
		local wasm="$1"
		[ -f "$wasm" ] || { echo "Error: $wasm not produced" >&2; exit 1; }
		local nm=""
		for c in llvm-nm wasm-objdump; do command -v "$c" >/dev/null 2>&1 && { nm="$c"; break; }; done
		if [ -z "$nm" ]; then
			echo "  warn: llvm-nm/wasm-objdump not found; skipping export check" >&2
			return
		fi
		# Only the boot-critical FUNCTION exports are required: the web shell
		# boots by calling _start() then driving the shim_js_* procs, so a
		# future rename/drop of those breaks the canvas. (The GL string
		# scratch, shim_gl_scratch, is a data symbol - the odin driver's
		# --export does not emit a wasm data export for it, and its absence
		# is non-fatal: sokol's glGetStringi extension query degrades
		# gracefully - so it is intentionally not guarded here.)
		local syms="_start shim_js_frame shim_js_resize"
		missing=0
		for sym in $syms; do
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