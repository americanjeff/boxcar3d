#!/usr/bin/env bash
# Stage 1 — build the shared engine C into engine/lib/*_<target>.a.
#
# Per target, compiles the engine C (renderer + render-FFI shim, ML vendors)
# into generic archives that every app links. Box3D comes from the Odin
# toolchain (vendor:box3d) on BOTH targets: the app object's
# `foreign import lib` makes `odin build` link the toolchain's prebuilt
# (libbox3d.a native, box3d_wasm.o wasm) — no Box3D source compile here.
#
# The wasm target links through the odin driver (the final wasm-ld
# link): the C compiles with bare clang --target=wasm32-unknown-unknown
# against the toolchain's libc-shim headers, and libc gaps the shim's
# headers lack (tanf/calloc/fputs/syslog/...) are filled by the wasm-only
# engine/cext/ objects in libcext_wasm.a (native never links them).
# -Wno-incompatible-library-redeclaration: the shim's fopen prototype
# (non-const mode) disagrees with clang 23's builtin; suppressed here,
# fixed upstream in the toolchain.
# ENGINE C CHANGES → re-run this once
# (per target); every app picks up the new archives.
#
#   build_engine.sh native   → libphysics_native.a + libgraphics_native.a
#   build_engine.sh wasm     → libphysics_wasm.a   + libgraphics_wasm.a (WebGPU)
#                               + libgraphics_wasmgl.a (WebGL2 fallback)
#
# ML archives are opt-in per app via the ML_LIBS environment variable (a
# space-separated subset of "kann cmaes neat"; unset = all three, mirroring
# each app's project.env).
#
# apphost is NOT built here: its window title is a per-app compile-time string
# (-DSHIM_WINDOW_TITLE), so tools/build_app.sh compiles apphost_shim.c per
# app. physics + graphics are fully generic and shared across all apps.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET="${1:?usage: build_engine.sh <native|wasm>}"
# No colon: an empty-but-set ML_LIBS (from the app's project.env) means "no
# ML libs"; the default applies only when the variable is unset.
ML_LIBS="${ML_LIBS-kann cmaes neat}"
# Box3D lives in the Odin toolchain (vendor/box3d in the toolchain tree);
# the C sources + headers used for the wasm compile and the engine C:
ODIN_ROOT="$(odin root)"
B3SRC="$ODIN_ROOT/vendor/box3d/src"
B3INC="$B3SRC/include"
SOKOL="$ROOT/vendor/sokol"
STB="$ROOT/vendor/stb"
FORK="$ROOT/engine/graphics/renderer"
KANN="$ROOT/vendor/kann"
CMAES="$ROOT/vendor/cmaes"
NEAT="$ROOT/vendor/neat"
ML="$ROOT/engine/ml"
ENGLIB="$ROOT/engine/lib"
mkdir -p "$ENGLIB"

# The generated shader headers are gitignored (sokol-shdc embeds absolute
# paths in them), so a fresh checkout has none: regenerate before compiling.
GEN_DIR="$FORK/shaders/generated"
if ! ls "$GEN_DIR"/*.glsl.h >/dev/null 2>&1; then
	SHDC="$(command -v sokol-shdc || true)"
	if [ -n "$SHDC" ]; then
		echo "── generated shader headers missing — regenerating (sokol-shdc) ──"
		"$ROOT/tools/gen_shaders_wgsl.sh" "$SHDC"
	else
		echo "Error: $GEN_DIR/*.glsl.h missing and sokol-shdc not found." >&2
		echo "  Install sokol-shdc (see tools/gen_shaders_wgsl.sh), then" >&2
		echo "  re-run this script." >&2
		exit 1
	fi
fi

# Bare-wasm toolchain bits: clang with a wasm32 target (any LLVM clang
# 16+) and the header roots the C needs (the backend API headers are
# vendored: vendor/webgpu-headers, vendor/gles3-headers).
SHIM_INC="$ODIN_ROOT/vendor/libc-shim/include"
WGPU_INC="$ROOT/vendor/webgpu-headers"
GL_INC="$ROOT/vendor/gles3-headers"
CXT="$ROOT/engine/cext"

ensure_wasm_clang() {
	command -v clang >/dev/null || { echo "Error: clang not found (need clang with wasm32 target support)." >&2; exit 1; }
	[ -d "$SHIM_INC" ] || { echo "Error: libc-shim headers missing at $SHIM_INC (broken toolchain install?)." >&2; exit 1; }
	[ -f "$WGPU_INC/webgpu/webgpu.h" ] || { echo "Error: webgpu.h missing at $WGPU_INC/webgpu/webgpu.h (missing vendor dir?)." >&2; exit 1; }
	[ -f "$GL_INC/GLES3/gl3.h" ] || { echo "Error: GLES3/gl3.h missing at $GL_INC (missing vendor dir?)." >&2; exit 1; }
}

# Common include roots (the forked renderer keeps the upstream "gfx/..."
# include convention; shaders are committed with both glsl430 + wgsl branches).
INC_COMMON=(-I"$B3INC" -I"$SOKOL" -I"$STB" -I"$FORK" -I"$FORK/shaders/generated")

build_physics_native() {
	# libphysics_native.a is empty by design: the sim runs on the
	# toolchain's Box3D (vendor:box3d), which `odin build` links from the
	# app object's `foreign import lib` input (the toolchain's prebuilt
	# libbox3d.a). The empty archive keeps every app's link line uniform.
	echo "── libphysics_native.a (empty; vendor:box3d supplies b3*) ──"
	rm -f "$ENGLIB/libphysics_native.a"
	ar rcs "$ENGLIB/libphysics_native.a"
}

build_graphics_native() {
	echo "── Building renderer + render_shim into libgraphics_native.a ──"
	BUILD="$ROOT/build/native"
	mkdir -p "$BUILD"
	DEF=(-DSOKOL_GLCORE -DNDEBUG)
	GFX_OBJS=()
	for src in "$FORK"/gfx/*.c; do
		base=$(basename "$src" .c)
		gcc -c -O2 -fPIC -std=c17 -Wall -Wextra "${DEF[@]}" "${INC_COMMON[@]}" \
			"$src" -o "$BUILD/gfx_${base}.o"
		GFX_OBJS+=("$BUILD/gfx_${base}.o")
	done
	gcc -c -O2 -fPIC -std=c17 -Wall -Wextra "${DEF[@]}" "${INC_COMMON[@]}" \
		"$ROOT/engine/graphics/render_shim.c" -o "$BUILD/render_shim.o"
	GFX_OBJS+=("$BUILD/render_shim.o")
	ar rcs "$ENGLIB/libgraphics_native.a" "${GFX_OBJS[@]}"
}

# ── ML archives: engine/ml/{kann,cmaes,neat} ──
#
# Three independent upstreams with three distinct concerns (NN graph /
# derivative-free optimizer / topology evolution). Each maps onto the same
# pattern as physics/graphics: one vendor dep → one C shim → one archive.
# Per-app selection: only the libs named in ML_LIBS are built. New ML
# upstreams slot in as engine/ml/<name>/ siblings.

# want_lib <name>: is <name> in the ML_LIBS list?
want_lib() { case " $ML_LIBS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

build_ml_native() {
	[ -n "$ML_LIBS" ] || return 0
	echo "── Compiling ML shims + vendors → lib{${ML_LIBS// /,}}_native.a ──"
	BUILD="$ROOT/build/native"
	mkdir -p "$BUILD"
	if want_lib kann; then
		# KANN: kann.c + kautodiff.c + kann_shim.c → libkann_native.a
		gcc -c -O2 -fPIC -std=c17 -Wall -Wextra -I"$KANN" "$KANN/kann.c" \
			-o "$BUILD/ml_kann.o"
		gcc -c -O2 -fPIC -std=c17 -Wall -Wextra -I"$KANN" "$KANN/kautodiff.c" \
			-o "$BUILD/ml_kautodiff.o"
		gcc -c -O2 -fPIC -std=c17 -Wall -Wextra -I"$KANN" \
			"$ML/kann/kann_shim.c" -o "$BUILD/ml_kann_shim.o"
		ar rcs "$ENGLIB/libkann_native.a" "$BUILD/ml_kann.o" "$BUILD/ml_kautodiff.o" "$BUILD/ml_kann_shim.o"
	fi
	if want_lib cmaes; then
		# c-cmaes: cmaes.c + boundary_transformation.c + cmaes_shim.c → libcmaes_native.a
		gcc -c -O2 -fPIC -std=c17 -Wall -Wextra -I"$CMAES" "$CMAES/cmaes.c" \
			-o "$BUILD/ml_cmaes.o"
		gcc -c -O2 -fPIC -std=c17 -Wall -Wextra -I"$CMAES" "$CMAES/boundary_transformation.c" \
			-o "$BUILD/ml_boundary_transformation.o"
		gcc -c -O2 -fPIC -std=c17 -Wall -Wextra -I"$KANN" -I"$CMAES" \
			"$ML/cmaes/cmaes_shim.c" -o "$BUILD/ml_cmaes_shim.o"
		ar rcs "$ENGLIB/libcmaes_native.a" "$BUILD/ml_cmaes.o" "$BUILD/ml_boundary_transformation.o" "$BUILD/ml_cmaes_shim.o"
	fi
	if want_lib neat; then
		# NEAT: neat.c + neat_shim.c → libneat_native.a
		gcc -c -O2 -fPIC -std=c17 -Wall -Wextra -I"$NEAT" "$NEAT/neat.c" \
			-o "$BUILD/ml_neat.o"
		gcc -c -O2 -fPIC -std=c17 -Wall -Wextra -I"$NEAT" \
			"$ML/neat/neat_shim.c" -o "$BUILD/ml_neat_shim.o"
		ar rcs "$ENGLIB/libneat_native.a" "$BUILD/ml_neat.o" "$BUILD/ml_neat_shim.o"
	fi
}

build_physics_wasm() {
	# libphysics_wasm.a is empty by design (mirrors native): the sim runs
	# on the toolchain's Box3D (vendor:box3d), whose prebuilt
	# box3d_wasm.o the `odin build` driver links from the app object's
	# `foreign import lib`. The empty archive keeps every app's link line
	# uniform.
	echo "── libphysics_wasm.a (empty; vendor:box3d prebuilt supplies b3*) ──"
	rm -f "$ENGLIB/libphysics_wasm.a"
	ar rcs "$ENGLIB/libphysics_wasm.a"
}

build_cext_wasm() {
	# engine/cext/: declarations + definitions the toolchain's libc-shim
	# headers lack (math tanf/expf/round/roundf, stdlib calloc, stdio
	# fputs, syslog stub). wasm-only by construction (clang --target
	# wasm32); native builds never link this archive.
	echo "── Compiling engine/cext → libcext_wasm.a ──"
	BUILD="$ROOT/build/wasm"; mkdir -p "$BUILD"
	local objs=()
	for src in "$CXT"/*.c; do
		base=$(basename "$src" .c)
		clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -DNDEBUG \
			-I"$CXT" -I"$SHIM_INC" -c "$src" -o "$BUILD/cext_${base}.o"
		objs+=("$BUILD/cext_${base}.o")
	done
	ar rcs "$ENGLIB/libcext_wasm.a" "${objs[@]}"
}

build_graphics_wasm() {
	echo "── Compiling renderer + render_shim (bare wasm, SOKOL_WGPU) → libgraphics_wasm.a ──"
	BUILD="$ROOT/build/wasm"; mkdir -p "$BUILD"
	DEF=(-DSOKOL_WGPU -DNDEBUG)
	# webgpu.h (the WebGPU C API) is vendored — headers only; the wgpu*
	# calls become module imports the JS glue implements.
	PORT=(-I"$WGPU_INC")
	GFX_OBJS=()
	for src in "$FORK"/gfx/*.c; do
		base=$(basename "$src" .c)
		clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -c "${DEF[@]}" \
			"${PORT[@]}" -I"$CXT" -I"$SHIM_INC" "${INC_COMMON[@]}" \
			"$src" -o "$BUILD/gfx_${base}.o"
		GFX_OBJS+=("$BUILD/gfx_${base}.o")
	done
	clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -c "${DEF[@]}" \
		"${PORT[@]}" -I"$CXT" -I"$SHIM_INC" "${INC_COMMON[@]}" \
		"$ROOT/engine/graphics/render_shim.c" -o "$BUILD/render_shim.o"
	GFX_OBJS+=("$BUILD/render_shim.o")
	ar rcs "$ENGLIB/libgraphics_wasm.a" "${GFX_OBJS[@]}"
}

# WebGL2 fallback variant of the same renderer: identical sources,
# SOKOL_GLES3 instead of SOKOL_WGPU (sokol's backend is compile-time, so the
# two wasm flavors are separate archives; the shared physics/ml archives are
# backend-agnostic and reused). The GLES3 renderer compiles out the GTAO
# compute chain (see the guards in gtao.c / renderer.c) and swaps its R32F
# targets for WebGL2-core-renderable formats.
build_graphics_wasm_gl() {
	echo "── Compiling renderer + render_shim (bare wasm, SOKOL_GLES3) → libgraphics_wasmgl.a ──"
	BUILD="$ROOT/build/wasm"; mkdir -p "$BUILD"
	DEF=(-DSOKOL_GLES3 -DNDEBUG)
	# The wasm target matches none of sokol_gfx's GL platform branches, so
	# it includes no GL header; force the GLES3 API header in (the vendored
	# Khronos copy) to provide the GL types the GLES3 backend uses.
	GL=(-I"$GL_INC" -include "$GL_INC/GLES3/gl3.h")
	GFX_OBJS=()
	for src in "$FORK"/gfx/*.c; do
		base=$(basename "$src" .c)
		clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -c "${DEF[@]}" \
			-I"$CXT" -I"$SHIM_INC" "${GL[@]}" "${INC_COMMON[@]}" \
			"$src" -o "$BUILD/gfxgl_${base}.o"
		GFX_OBJS+=("$BUILD/gfxgl_${base}.o")
	done
	clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -c "${DEF[@]}" \
		-I"$CXT" -I"$SHIM_INC" "${GL[@]}" "${INC_COMMON[@]}" \
		"$ROOT/engine/graphics/render_shim.c" -o "$BUILD/render_shim_gl.o"
	GFX_OBJS+=("$BUILD/render_shim_gl.o")
	ar rcs "$ENGLIB/libgraphics_wasmgl.a" "${GFX_OBJS[@]}"
}

build_ml_wasm() {
	[ -n "$ML_LIBS" ] || return 0
	echo "── Compiling ML shims + vendors (bare wasm) → lib{${ML_LIBS// /,}}_wasm.a ──"
	BUILD="$ROOT/build/wasm"; mkdir -p "$BUILD"
	# ML vendors are pure C (no sokol): shim headers + cext cover their
	# libc surface (they exercise the same math/stdlib as the renderer);
	# the prelude force-include gives the old-style vendors (implicit
	# declarations) a complete standard header surface.
	WC=(-I"$CXT" -I"$SHIM_INC" -include "$CXT/cext_prelude.h")
	if want_lib kann; then
		# KANN → libkann_wasm.a
		clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -DNDEBUG -I"$KANN" "${WC[@]}" \
			-c "$KANN/kann.c" -o "$BUILD/ml_kann.o"
		clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -DNDEBUG -I"$KANN" "${WC[@]}" \
			-c "$KANN/kautodiff.c" -o "$BUILD/ml_kautodiff.o"
		clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -DNDEBUG -I"$KANN" "${WC[@]}" \
			-c "$ML/kann/kann_shim.c" -o "$BUILD/ml_kann_shim.o"
		ar rcs "$ENGLIB/libkann_wasm.a" "$BUILD/ml_kann.o" "$BUILD/ml_kautodiff.o" "$BUILD/ml_kann_shim.o"
	fi
	if want_lib cmaes; then
		# c-cmaes → libcmaes_wasm.a
		clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -DNDEBUG -I"$CMAES" "${WC[@]}" \
			-c "$CMAES/cmaes.c" -o "$BUILD/ml_cmaes.o"
		clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -DNDEBUG -I"$CMAES" "${WC[@]}" \
			-c "$CMAES/boundary_transformation.c" -o "$BUILD/ml_boundary_transformation.o"
		clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -DNDEBUG -I"$KANN" -I"$CMAES" "${WC[@]}" \
			-c "$ML/cmaes/cmaes_shim.c" -o "$BUILD/ml_cmaes_shim.o"
		ar rcs "$ENGLIB/libcmaes_wasm.a" "$BUILD/ml_cmaes.o" "$BUILD/ml_boundary_transformation.o" "$BUILD/ml_cmaes_shim.o"
	fi
	if want_lib neat; then
		# NEAT → libneat_wasm.a
		clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -DNDEBUG -I"$NEAT" "${WC[@]}" \
			-c "$NEAT/neat.c" -o "$BUILD/ml_neat.o"
		clang --target=wasm32-unknown-unknown -O3 -std=gnu17 -Wno-incompatible-library-redeclaration -DNDEBUG -I"$NEAT" "${WC[@]}" \
			-c "$ML/neat/neat_shim.c" -o "$BUILD/ml_neat_shim.o"
		ar rcs "$ENGLIB/libneat_wasm.a" "$BUILD/ml_neat.o" "$BUILD/ml_neat_shim.o"
	fi
}

case "$TARGET" in
	native)
		build_physics_native
		build_graphics_native
		build_ml_native
		echo ""
		ML_NOTE=""
		if [ -n "$ML_LIBS" ]; then ML_NOTE=" + lib{${ML_LIBS// /,}}_native.a"; fi
		echo "✓ Engine built (native): libphysics_native.a + libgraphics_native.a$ML_NOTE"
		echo "  Next: ./tools/build_app.sh native <app>"
		;;
	wasm)
		ensure_wasm_clang
		build_physics_wasm
		build_cext_wasm
		build_graphics_wasm
		build_graphics_wasm_gl
		build_ml_wasm
		echo ""
		ML_NOTE=""
		if [ -n "$ML_LIBS" ]; then ML_NOTE=" + lib{${ML_LIBS// /,}}_wasm.a"; fi
		echo "✓ Engine built (wasm): libphysics_wasm.a + libgraphics_wasm.a (WebGPU)"
		echo "                       + libgraphics_wasmgl.a (WebGL2)$ML_NOTE"
		echo "  Next: ./tools/build_app.sh wasm <app>"
		;;
	*)
		echo "usage: build_engine.sh <native|wasm>" >&2
		exit 1
		;;
esac