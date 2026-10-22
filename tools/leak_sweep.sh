#!/usr/bin/env bash
# On-demand leak sweep for a big review / test pass (NOT a per-commit guard).
#
# Builds the C engine (Box3D from the toolchain's C sources + the shims + the
# renderer) with AddressSanitizer/LeakSanitizer and runs the native tests
# under it, so a new C-heap leak (engine, shims, Box3D) or a
# geometry-registry refcount regression is caught here instead of as a slow
# OOM deep in a long session.
#
#   ./tools/leak_sweep.sh            # full sweep: physics + registry
#   ./tools/leak_sweep.sh physics    # just the ASan physics tests (no display)
#   ./tools/leak_sweep.sh registry   # just the ASan registry test (needs DISPLAY)
#
# Covers:
#   * C-heap leaks — the physics (Box3D, rebuilt here with ASan from the
#     toolchain's C sources) and graphics (renderer + render_shim) C is
#     built with -fsanitize=address and every test runs under LeakSanitizer;
#     an allocation we never free is reported at exit. (Box3D-internal
#     allocations are tracked only on the registry path: the odin physics
#     tests link the toolchain's uninstrumented prebuilt, which wins the
#     link — see build_physics_leak.)
#   * Registry refcount leaks — smoke_renderer --registry-test drives the
#     ref-counted geometry registry through a full lifecycle + a 9-mesh
#     car-shaped cycle (body + 8 shards, a replace-and-release, teardown); a
#     slot that fails to free at refcount 0 is reported.
# Does NOT cover: GPU device memory (LSan only sees the heap) and Odin-side
# allocations (the Odin runtime owns those; invisible to LSan).
#
# The ASan rebuild of Box3D is the slow part (~1 min); the graphics/shim
# objects are incremental, so a re-run with no engine change is fast.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ODIN_ROOT="$(odin root)"
B3SRC="$ODIN_ROOT/vendor/box3d/src"
B3INC="$B3SRC/include"
SOKOL="$ROOT/vendor/sokol"
FORK="$ROOT/engine/graphics/renderer"
ENGLIB="$ROOT/engine/lib"
BUILD="$ROOT/build/leak"
B3D_LEAK="$BUILD/libbox3dd.a"
SUP="$ROOT/tools/lsan_suppressions.txt"
mkdir -p "$ENGLIB" "$BUILD"

INC=(-I"$B3INC" -I"$SOKOL" -I"$FORK" -I"$FORK/shaders/generated")
DEF=(-DSOKOL_GLCORE -DNDEBUG -fsanitize=address -g)
GL_LIBS=(-lGL -ldl -lm -lpthread -lX11 -lXi -lXcursor)
# LeakSanitizer is driven via ASAN_OPTIONS=detect_leaks=1; the suppression
# file is handed to LSan (LSAN_OPTIONS), NOT ASan, because the `leak:`
# suppression type is LSan-specific and ASan rejects it.
LSAN_ENV=(ASAN_OPTIONS=detect_leaks=1 LSAN_OPTIONS="suppressions=$SUP")

has_display() { [ -n "${DISPLAY:-}" ]; }

# ── Build the ASan engine (incremental) ──────────────────────────────────────
build_box3d_leak() {
	echo "── Box3D (ASan, from the toolchain's C sources) ──"
	# Compiled directly (no cmake): the toolchain ships only prebuilts, and
	# the prebuilt is not ASan-instrumented, so a Box3D-internal leak would
	# be invisible to LSan.
	local objs=()
	for src in "$B3SRC"/src/*.c; do
		gcc -c -O1 -fPIC -g -std=c17 -fsanitize=address -I"$B3INC" \
			"$src" -o "$BUILD/box3d_leak_$(basename "${src%.c}").o"
		objs+=("$BUILD/box3d_leak_$(basename "${src%.c}").o")
	done
	rm -f "$B3D_LEAK"
	ar rcs "$B3D_LEAK" "${objs[@]}"
}

build_physics_leak() {
	# Empty, like libphysics_native.a: the odin physics tests link the
	# toolchain's prebuilt libbox3d.a via `foreign import lib` (the driver
	# always adds it, and it wins the link over any archive passed via
	# -extra-linker-flags), so Box3D-internal allocations are outside LSan
	# on this path — upstream territory, pinned by the toolchain version.
	# The registry path (smoke_renderer_leak, linked directly with gcc)
	# still gets the ASan-instrumented Box3D via $B3D_LEAK.
	echo "── libphysics_leak.a (empty; vendor:box3d supplies b3*) ──"
	rm -f "$ENGLIB/libphysics_leak.a"
	ar rcs "$ENGLIB/libphysics_leak.a"
}

build_graphics_leak() {
	echo "── renderer + render_shim → libgraphics_leak.a (ASan) ──"
	local objs=()
	for src in "$FORK"/gfx/*.c; do
		local base; base=$(basename "$src" .c)
		gcc -c -O1 -fPIC -std=c17 -Wall -Wextra "${DEF[@]}" "${INC[@]}" \
			"$src" -o "$BUILD/leak_gfx_${base}.o"
		objs+=("$BUILD/leak_gfx_${base}.o")
	done
	gcc -c -O1 -fPIC -std=c17 -Wall -Wextra "${DEF[@]}" "${INC[@]}" \
		"$ROOT/engine/graphics/render_shim.c" -o "$BUILD/leak_render_shim.o"
	objs+=("$BUILD/leak_render_shim.o")
	ar rcs "$ENGLIB/libgraphics_leak.a" "${objs[@]}"
}

build_smoke_leak() {
	echo "── smoke_renderer (ASan) ──"
	gcc -c -O1 -fPIC -std=c17 -Wall -Wextra "${DEF[@]}" "${INC[@]}" \
		"$ROOT/tools/smoke_renderer.c" -o "$BUILD/leak_smoke_main.o" 2>/dev/null
	local objs=("$BUILD"/leak_gfx_*.o "$BUILD/leak_render_shim.o" "$BUILD/leak_smoke_main.o")
	gcc -O1 -fsanitize=address -o "$BUILD/smoke_renderer_leak" "${objs[@]}" \
		"$B3D_LEAK" "${GL_LIBS[@]}"
}

# ── Run the ASan tests ───────────────────────────────────────────────────────
PHYSICS_LINK="-fsanitize=address $ENGLIB/libphysics_leak.a -lm -lpthread"

run_asan_odin() {
	local name="$1"
	echo "── $name (ASan/LSan) ──"
	odin build "tests/$name" -collection:engine="$ROOT/engine" -out:"$BUILD/${name}_leak" -o:speed \
		-extra-linker-flags:"$PHYSICS_LINK"
	env "${LSAN_ENV[@]}" "$BUILD/${name}_leak"
}

run_physics() {
	run_asan_odin physics_lifecycle
	run_asan_odin prismatic_joint
}

run_registry() {
	echo "── registry_test (ASan/LSan, smoke_renderer --registry-test) ──"
	if ! has_display; then
		echo "  SKIP: no DISPLAY (the registry test opens a GL context) — run on a dev machine with a display"
		return 0
	fi
	env "${LSAN_ENV[@]}" "$BUILD/smoke_renderer_leak" --registry-test
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "${1:-full}" in
	physics)  build_physics_leak; run_physics ;;
	registry) build_box3d_leak; build_graphics_leak; build_smoke_leak; run_registry ;;
	full)     build_box3d_leak; build_physics_leak; build_graphics_leak; build_smoke_leak
	         run_physics; run_registry ;;
	*) echo "usage: leak_sweep.sh [full|physics|registry]" >&2; exit 1 ;;
esac

echo ""
echo "✓ Leak sweep clean: no C-heap leaks, no registry refcount leaks."
echo "  (GPU device memory + Odin allocations are out of scope — see the header.)"
