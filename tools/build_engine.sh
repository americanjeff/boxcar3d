#!/usr/bin/env bash
# Stage 1 — build the shared engine C into engine/lib/*_<target>.a.
#
# Per target, compiles the vendored Box3D + each project's C shims into
# generic archives that every app links. ENGINE C CHANGES → re-run this once
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
BOX3D="$ROOT/vendor/box3d"
SOKOL="$ROOT/vendor/sokol"
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
		echo "  Install sokol-shdc (see tools/gen_shaders_wgsl.sh) or run" >&2
		echo "  ./tools/vendor_box3d.sh, then re-run this script." >&2
		exit 1
	fi
fi

# Locate Emscripten (emcmake/emcc/emar) for the wasm target, sourcing the
# emsdk env if the tools aren't already on PATH (mirrors build_app.sh).
ensure_emcc() {
	if command -v emcc &>/dev/null && command -v emcmake &>/dev/null; then return; fi
	for c in "${EMSDK_HOME:-}" "$HOME/dev/upstream/toolchain/emsdk" "$HOME/dev/clone/emsdk" "$HOME/emsdk" /opt/emsdk; do
		if [ -n "$c" ] && [ -f "$c/emsdk_env.sh" ]; then
			# shellcheck disable=SC1091
			source "$c/emsdk_env.sh" >/dev/null 2>&1
			break
		fi
	done
	command -v emcc >/dev/null    || { echo "Error: emcc not found (install Emscripten or set EMSDK_HOME)." >&2; exit 1; }
	command -v emcmake >/dev/null || { echo "Error: emcmake not found (install Emscripten or set EMSDK_HOME)." >&2; exit 1; }
}

# Common include roots (the forked renderer keeps the upstream "gfx/..."
# include convention; shaders are committed with both glsl430 + wgsl branches).
INC_COMMON=(-I"$BOX3D/include" -I"$SOKOL" -I"$FORK" -I"$FORK/shaders/generated")

build_box3d_native() {
	echo "── Building Box3D physics (native) ──"
	cmake -B "$BOX3D/build_native" -S "$BOX3D" \
		-DBOX3D_SAMPLES=OFF -DBOX3D_UNIT_TESTS=OFF -DBOX3D_BENCHMARKS=OFF \
		-DBOX3D_DOCS=OFF -DBOX3D_VALIDATE=OFF -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_C_FLAGS="-fPIC" -G "Unix Makefiles"
	cmake --build "$BOX3D/build_native" --config Release -j"$(nproc)"
}

build_physics_native() {
	echo "── Compiling physics shim + combining into libphysics_native.a ──"
	BUILD="$ROOT/build/native"
	mkdir -p "$BUILD"
	gcc -c -O2 -fPIC -DNDEBUG -I"$BOX3D/include" \
		"$ROOT/engine/physics/physics_shim.c" -o "$BUILD/physics_shim.o"
	COMBINE="$BUILD/phys_combine"
	rm -rf "$COMBINE"; mkdir -p "$COMBINE"
	( cd "$COMBINE" && cp ../physics_shim.o . \
		&& ar x "$BOX3D/build_native/src/libbox3d.a" \
		&& ar rcs "$ROOT/engine/lib/libphysics_native.a" *.o )
	rm -rf "$COMBINE"
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

build_box3d_wasm() {
	echo "── Building Box3D physics (wasm, single-threaded, no SIMD) ──"
	# Build Box3D as a SUBPROJECT (PROJECT_IS_TOP_LEVEL=false) so its CMake
	# does not auto-enable Emscripten pthreads (which would force
	# SharedArrayBuffer / COOP-COEP serving). -DBOX3D_DISABLE_SIMD=ON avoids a
	# clang `-O3 -msimd128` backend crash on src/shape.c.
	BUILD="$ROOT/build/wasm"
	B3_BUILD="$BOX3D/build_wasm"
	mkdir -p "$BUILD" "$B3_BUILD"
	WRAPPER="$BUILD/wasm_box3d_wrapper"
	mkdir -p "$WRAPPER"
	sed "s#@BOX3D_SOURCE@#$BOX3D#" "$ROOT/tools/wasm_box3d_wrapper.cmake.in" > "$WRAPPER/CMakeLists.txt"
	emcmake cmake -B "$B3_BUILD" -S "$WRAPPER" \
		-DBOX3D_DISABLE_SIMD=ON -DCMAKE_BUILD_TYPE=Release -G "Unix Makefiles"
	cmake --build "$B3_BUILD" --config Release -j"$(nproc)"
}

build_physics_wasm() {
	echo "── Compiling physics shim (wasm) → libphysics_wasm.a ──"
	BUILD="$ROOT/build/wasm"; mkdir -p "$BUILD"
	emcc -c -O3 -DNDEBUG -I"$BOX3D/include" "$ROOT/engine/physics/physics_shim.c" -o "$BUILD/physics_shim.o"
	rm -f "$ENGLIB/libphysics_wasm.a"
	cp "$BOX3D/build_wasm/box3d/src/libbox3d.a" "$ENGLIB/libphysics_wasm.a"
	emar rcs "$ENGLIB/libphysics_wasm.a" "$BUILD/physics_shim.o"
}

build_graphics_wasm() {
	echo "── Compiling renderer + render_shim (wasm, SOKOL_WGPU) → libgraphics_wasm.a ──"
	BUILD="$ROOT/build/wasm"; mkdir -p "$BUILD"
	DEF=(-DSOKOL_WGPU -DNDEBUG)
	# --use-port=emdawnwebgpu adds webgpu/webgpu.h at compile time + Dawn at link.
	PORT=(--use-port=emdawnwebgpu)
	GFX_OBJS=()
	for src in "$FORK"/gfx/*.c; do
		base=$(basename "$src" .c)
		emcc -c -O3 -std=gnu17 "${DEF[@]}" "${PORT[@]}" "${INC_COMMON[@]}" "$src" -o "$BUILD/gfx_${base}.o"
		GFX_OBJS+=("$BUILD/gfx_${base}.o")
	done
	emcc -c -O3 -std=gnu17 "${DEF[@]}" "${PORT[@]}" "${INC_COMMON[@]}" \
		"$ROOT/engine/graphics/render_shim.c" -o "$BUILD/render_shim.o"
	GFX_OBJS+=("$BUILD/render_shim.o")
	emar rcs "$ENGLIB/libgraphics_wasm.a" "${GFX_OBJS[@]}"
}

# WebGL2 fallback variant of the same renderer: identical sources,
# SOKOL_GLES3 instead of SOKOL_WGPU (sokol's backend is compile-time, so the
# two wasm flavors are separate archives; the shared physics/ml archives are
# backend-agnostic and reused). The GLES3 renderer compiles out the GTAO
# compute chain (see the guards in gtao.c / renderer.c) and swaps its R32F
# targets for WebGL2-core-renderable formats.
build_graphics_wasm_gl() {
	echo "── Compiling renderer + render_shim (wasm, SOKOL_GLES3) → libgraphics_wasmgl.a ──"
	BUILD="$ROOT/build/wasm"; mkdir -p "$BUILD"
	DEF=(-DSOKOL_GLES3 -DNDEBUG)
	GFX_OBJS=()
	for src in "$FORK"/gfx/*.c; do
		base=$(basename "$src" .c)
		emcc -c -O3 -std=gnu17 "${DEF[@]}" "${INC_COMMON[@]}" "$src" \
			-o "$BUILD/gfxgl_${base}.o"
		GFX_OBJS+=("$BUILD/gfxgl_${base}.o")
	done
	emcc -c -O3 -std=gnu17 "${DEF[@]}" "${INC_COMMON[@]}" \
		"$ROOT/engine/graphics/render_shim.c" -o "$BUILD/render_shim_gl.o"
	GFX_OBJS+=("$BUILD/render_shim_gl.o")
	emar rcs "$ENGLIB/libgraphics_wasmgl.a" "${GFX_OBJS[@]}"
}

build_ml_wasm() {
	[ -n "$ML_LIBS" ] || return 0
	echo "── Compiling ML shims + vendors (wasm) → lib{${ML_LIBS// /,}}_wasm.a ──"
	BUILD="$ROOT/build/wasm"; mkdir -p "$BUILD"
	if want_lib kann; then
		# KANN → libkann_wasm.a
		emcc -c -O3 -std=gnu17 -I"$KANN" "$KANN/kann.c" \
			-o "$BUILD/ml_kann.o"
		emcc -c -O3 -std=gnu17 -I"$KANN" "$KANN/kautodiff.c" \
			-o "$BUILD/ml_kautodiff.o"
		emcc -c -O3 -std=gnu17 -I"$KANN" \
			"$ML/kann/kann_shim.c" -o "$BUILD/ml_kann_shim.o"
		emar rcs "$ENGLIB/libkann_wasm.a" "$BUILD/ml_kann.o" "$BUILD/ml_kautodiff.o" "$BUILD/ml_kann_shim.o"
	fi
	if want_lib cmaes; then
		# c-cmaes → libcmaes_wasm.a
		emcc -c -O3 -std=gnu17 -I"$CMAES" "$CMAES/cmaes.c" \
			-o "$BUILD/ml_cmaes.o"
		emcc -c -O3 -std=gnu17 -I"$CMAES" "$CMAES/boundary_transformation.c" \
			-o "$BUILD/ml_boundary_transformation.o"
		emcc -c -O3 -std=gnu17 -I"$KANN" -I"$CMAES" \
			"$ML/cmaes/cmaes_shim.c" -o "$BUILD/ml_cmaes_shim.o"
		emar rcs "$ENGLIB/libcmaes_wasm.a" "$BUILD/ml_cmaes.o" "$BUILD/ml_boundary_transformation.o" "$BUILD/ml_cmaes_shim.o"
	fi
	if want_lib neat; then
		# NEAT → libneat_wasm.a
		emcc -c -O3 -std=gnu17 -I"$NEAT" "$NEAT/neat.c" \
			-o "$BUILD/ml_neat.o"
		emcc -c -O3 -std=gnu17 -I"$NEAT" \
			"$ML/neat/neat_shim.c" -o "$BUILD/ml_neat_shim.o"
		emar rcs "$ENGLIB/libneat_wasm.a" "$BUILD/ml_neat.o" "$BUILD/ml_neat_shim.o"
	fi
}

case "$TARGET" in
	native)
		build_box3d_native
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
		ensure_emcc
		build_box3d_wasm
		build_physics_wasm
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