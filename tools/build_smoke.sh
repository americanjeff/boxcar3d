#!/usr/bin/env bash
# Standalone C renderer smoke test: prove the forked Box3D renderer
# (engine/graphics/renderer/gfx/*.c minus debug_*) + the separately-vendored
# Sokol (vendor/sokol) + libbox3d (built from vendor/box3d) build and link as
# one unit on native Linux, WITHOUT Odin or the engine shims. Renders a lit,
# shadowed cube on a ground slab with the Preetham sky.
#
# This is the renderer-isolation tool and the native regression guard for the
# WGPU-guarded fork edits + the sokol patch (all changes are WGPU-guarded or
# fork-only; native must still build clean).
#
# Build:  tools/build_smoke.sh          # SOKOL_GLCORE (default, GL 4.5)
#         tools/build_smoke.sh gles3    # SOKOL_GLES3 (mirrors the WASM/WebGL2
#                                       # path: no glClipControl, default
#                                       # [-1,1] clip-Z range)
# Run:    ./build/native/smoke_renderer
#         ./build/native/smoke_renderer --frames 60   # exit after N frames
set -euo pipefail

BACKEND="${1:-glcore}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BOX3D="$ROOT/vendor/box3d"
SOKOL="$ROOT/vendor/sokol"
FORK="$ROOT/engine/graphics/renderer"
BUILD="$ROOT/build/native"
mkdir -p "$BUILD"

echo "── Building libbox3d (native, from pinned tree) ──"
# Skip the cmake configure/build when libbox3d.a is already present and newer
# than the Box3D C sources (e.g. build_engine.sh native just built it). cmake
# --build is incremental anyway, but skipping the configure step keeps this
# smoke tool fast to re-run.
B3_LIB="$BOX3D/build_native/src/libbox3d.a"
need_box3d=1
if [ -f "$B3_LIB" ]; then
	need_box3d=0
	while read -r src; do
		if [ "$src" -nt "$B3_LIB" ]; then need_box3d=1; break; fi
	done < <(find "$BOX3D/src" "$BOX3D/include" -name '*.c' -o -name '*.h' 2>/dev/null)
fi
if [ "$need_box3d" -eq 1 ]; then
	cmake -B "$BOX3D/build_native" -S "$BOX3D" \
		-DBOX3D_SAMPLES=OFF -DBOX3D_UNIT_TESTS=OFF -DBOX3D_BENCHMARKS=OFF \
		-DBOX3D_DOCS=OFF -DBOX3D_VALIDATE=OFF -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_C_FLAGS="-fPIC" -G "Unix Makefiles"
	cmake --build "$BOX3D/build_native" --config Release -j"$(nproc)"
else
	echo "  libbox3d.a up to date — skipping cmake"
fi

# Include roots:
#   vendor/box3d/include              box3d/ headers   (box3d/box3d.h)
#   vendor/sokol                      sokol headers    (sokol_gfx.h)
#   engine/graphics/renderer          forked renderer  (gfx/renderer.h)
#   engine/graphics/renderer/shaders/generated   committed .glsl.h
INC=(-I"$BOX3D/include" -I"$SOKOL" -I"$FORK" -I"$FORK/shaders/generated")
case "$BACKEND" in
	gles3)
		SUFFIX="_gles3"
		DEF=(-DSOKOL_GLES3 -DNDEBUG)
		# No standalone libGLESv3 on this box; libGL exports the GLES3
		# entry points (GLES3 is a core-GL subset) and provides the
		# context-free entry points sokol_app's EGL path needs.
		LIBS=(-lGL -lEGL -ldl -lm -lpthread -lX11 -lXi -lXcursor)
		;;
	glcore)
		SUFFIX=""
		DEF=(-DSOKOL_GLCORE -DNDEBUG)
		LIBS=(-lGL -ldl -lm -lpthread -lX11 -lXi -lXcursor)
		;;
	*)
		echo "Unknown backend '$BACKEND' (expected glcore or gles3)" >&2
		exit 1
		;;
esac

echo "── Compiling forked renderer + sokol + smoke driver ($BACKEND) ──"
OBJS=()
for src in "$FORK"/gfx/*.c; do
	base=$(basename "$src" .c)
	# Physics-debug-draw paths are dropped from the fork (not copied).
	gcc -c -O2 -fPIC -std=c17 -Wall -Wextra "${DEF[@]}" "${INC[@]}" \
		"$src" -o "$BUILD/smoke_${base}${SUFFIX}.o"
	OBJS+=("$BUILD/smoke_${base}${SUFFIX}.o")
done

# Smoke driver (implements sokol_app + glue + log; app logic).
gcc -c -O2 -fPIC -std=c17 -Wall -Wextra "${DEF[@]}" "${INC[@]}" \
	"$ROOT/tools/smoke_renderer.c" -o "$BUILD/smoke_main${SUFFIX}.o"
OBJS+=("$BUILD/smoke_main${SUFFIX}.o")

echo "── Linking smoke_renderer$SUFFIX ──"
gcc -O2 -o "$BUILD/smoke_renderer$SUFFIX" "${OBJS[@]}" \
	"$BOX3D/build_native/src/libbox3d.a" "${LIBS[@]}"

echo ""
echo "✓ Smoke build complete: $BUILD/smoke_renderer$SUFFIX"
echo "  Run with: ./$BUILD/smoke_renderer$SUFFIX"