#!/usr/bin/env bash
# E2E regression tests for the engine/app boundary (native).
#
# Builds and runs the packages under tests/ against the prebuilt engine
# archives (engine/lib/*_native.a). Each test is a package main that exits
# nonzero on failure. This is the native regression guard for the
# engine:graphics mesh-handle sentinel contract and the engine:physics
# lifecycle/destroy-order contract.
#
#   ./tools/test.sh            # run all tests
#   ./tools/test.sh <name>     # run one (mesh_handle | registry_test |
#                              #        physics_lifecycle | prismatic_joint)
#
# registry_test drives the ref-counted geometry-registry lifecycle (the C
# contract Find_Mesh / Add_Mesh_Reference / Release_Mesh_Reference wrap) via
# smoke_renderer --registry-test; it opens a tiny sokol_app window for a live
# GL context, so it needs a display (DISPLAY) and is skipped on headless CI.
#
# Prereq: ./tools/build_engine.sh native has run (engine/lib/*_native.a exist).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENGLIB="$ROOT/engine/lib"
need_lib() {
	[ -f "$ENGLIB/$1" ] || { echo "Error: $ENGLIB/$1 missing — run ./tools/build_engine.sh native first." >&2; exit 1; }
}
need_lib libphysics_native.a
need_lib libgraphics_native.a
need_lib libapphost_native.a

# The registry test opens a sokol_app window for a live GL context, which on
# Linux means an X display (DISPLAY). Present under X11 and XWayland.
has_display() { [ -n "${DISPLAY:-}" ]; }

OUT="$ROOT/build/test"
mkdir -p "$OUT"

# The graphics test links only engine:graphics, which (via the forked
# renderer) references libbox3d math/hull symbols. Those live in the Odin
# toolchain's prebuilt libbox3d.a (the physics tests get it automatically
# via engine:physics's `foreign import lib`, but the graphics test does not
# import engine:physics), so add it to the link group explicitly.
ODIN_ROOT="$(odin root)"
B3_LIB="$ODIN_ROOT/vendor/box3d/lib/linux-$(uname -m)/libbox3d.a"
[ -f "$B3_LIB" ] || B3_LIB="$ODIN_ROOT/vendor/box3d/lib/linux-amd64/libbox3d.a"
GRAPHICS_LINK="-Wl,--start-group $ENGLIB/libgraphics_native.a $ENGLIB/libapphost_native.a $ENGLIB/libphysics_native.a $B3_LIB -Wl,--end-group -lGL -ldl -lm -lpthread -lX11 -lXi -lXcursor"
PHYSICS_LINK="$ENGLIB/libphysics_native.a -lm -lpthread"

build_run() {
	local name="$1" link="$2"
	echo "── $name ──"
	odin build "tests/$name" -collection:engine="$ROOT/engine" -out:"$OUT/$name" -o:speed \
		-extra-linker-flags:"$link"
	"$OUT/$name"
	echo ""
}

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
	names=(mesh_handle registry_test physics_lifecycle prismatic_joint)
fi

failed=0
for n in "${names[@]}"; do
	case "$n" in
		mesh_handle)       build_run "$n" "$GRAPHICS_LINK" ;;
		registry_test)
			echo "── registry_test ──"
			if has_display; then
				tools/build_smoke.sh >/dev/null 2>&1 || { echo "  FAIL: smoke_renderer build" >&2; failed=1; }
				"$ROOT/build/native/smoke_renderer" --registry-test || failed=1
			else
				echo "  SKIP: no DISPLAY (needs a GL context) — run on a dev machine with a display"
			fi
			echo ""
			;;
		physics_lifecycle) build_run "$n" "$PHYSICS_LINK"  ;;
		prismatic_joint)   build_run "$n" "$PHYSICS_LINK"  ;;
		*) echo "unknown test: $n" >&2; exit 1 ;;
	esac
done

# Replay-based regression tests: any recording in
# tests/<app>_replay/recordings/*.bin (REPLAY_APP selects the app, default
# "driving") is replayed through the real app sim (tools/replay.sh) and must
# exit 0 (no stall/flip). Skipped when none exist.
REC_DIR="$ROOT/tests/${REPLAY_APP:-driving}_replay/recordings"
if [ -d "$REC_DIR" ]; then
	mapfile -t recs < <(find "$REC_DIR" -maxdepth 1 -name '*.bin' -type f | sort)
	if [ ${#recs[@]} -gt 0 ]; then
		echo "── driving_replay (recordings) ──"
		for r in "${recs[@]}"; do
			name="$(basename "$r")"
			bash tools/replay.sh "$r" && echo "  PASS: $name" || { echo "  FAIL: $name"; failed=1; }
		done
		echo ""
	fi
fi

if [ "$failed" -ne 0 ]; then
	echo "✗ Some tests failed" >&2; exit 1
fi

echo "✓ All tests passed (${names[*]})"