#!/usr/bin/env bash
# Bootstrap the vendored Box3D tree from upstream at the pinned commit, and
# copy the sample renderer source into the owned fork at
# engine/graphics/renderer/gfx/ (samples/gfx/*.c,*.h minus debug_adapter/
# debug_shapes). The fork is owned — engine edits to the renderer are
# committed directly to engine/graphics/renderer/gfx/, not re-applied as
# patches. The ibl/sky empty-bindgroup edits are committed fork edits applied
# at first bootstrap.
#
# Idempotent: safe to re-run (re-clones if vendor/box3d is missing; always
# refreshes the fork source from a fresh clone). Cloning is skipped if
# vendor/box3d already exists.
#
# Prereqs: jj (or git) for the clone, sokol-shdc on $PATH or $1 (for shader
# regen — see tools/gen_shaders_wgsl.sh).
#
# After this, run:  ./tools/build_engine.sh native
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Pinned upstream commit ──
BOX3D_COMMIT="d421e45c828f6f853a145f726f0b9425d31146eb"
BOX3D_REMOTE="https://github.com/erincatto/box3d.git"
VENDOR="$ROOT/vendor/box3d"

# ── 1. Clone upstream at the pinned commit (skip if already present) ──
if [ ! -d "$VENDOR" ] || [ ! -f "$VENDOR/include/box3d/box3d.h" ]; then
	echo "── Cloning Box3D @ $BOX3D_COMMIT ──"
	rm -rf "$VENDOR"
	mkdir -p "$ROOT/vendor"
	# Prefer jj (the project uses jj); fall back to git. Both metadata dirs
	# are stripped so vendor/box3d is a plain file tree (the outer project
	# manages versioning).
	if command -v jj >/dev/null 2>&1; then
		jj git clone "$BOX3D_REMOTE" "$VENDOR"
		jj -R "$VENDOR" restore --from="$BOX3D_COMMIT"
		rm -rf "$VENDOR/.jj" "$VENDOR/.git"
	else
		git clone "$BOX3D_REMOTE" "$VENDOR"
		git -C "$VENDOR" checkout "$BOX3D_COMMIT"
		rm -rf "$VENDOR/.git"
	fi
else
	echo "── vendor/box3d already present, skipping clone ──"
fi

# ── 2. Record the pinned commit ──
echo "$BOX3D_COMMIT" > "$VENDOR/COMMIT.txt"

# ── 3. Copy the sample renderer into the owned fork ──
# engine/graphics/renderer/gfx/ holds samples/gfx/*.c,*.h minus the physics-
# debug-draw paths (debug_adapter, debug_shapes), which the driving demo does
# not use. The fork is owned from here on; re-running refreshes it from a
# fresh clone (re-apply the ibl/sky fork edits by hand on re-sync).
FORK="$ROOT/engine/graphics/renderer/gfx"
mkdir -p "$FORK"
echo "── Copying sample renderer → $FORK ──"
SKIP=" debug_adapter debug_shapes "
copied=0
for src in "$VENDOR"/samples/gfx/*.c "$VENDOR"/samples/gfx/*.h; do
	base=$(basename "$src")
	case "$SKIP" in
		*" ${base%.*} "*) echo "  skip $base (physics-debug path)"; continue ;;
	esac
	cp -f "$src" "$FORK/$base"
	copied=$((copied + 1))
done
echo "  copied $copied files"

# ── 4. Regenerate the wgsl shader headers (one-time output, committed) ──
# Adds the wgsl branch to every committed *.glsl.h so the SOKOL_WGPU build
# has shader code. Reads the .glsl sources from vendor/box3d/samples/shaders/
# and writes engine/graphics/renderer/shaders/generated/. Skipped if
# sokol-shdc isn't installed (the headers may already be committed).
SHDC="${1:-${SOKOL_SHDC:-}}"
if [ -z "$SHDC" ] && command -v sokol-shdc >/dev/null 2>&1; then
	SHDC="$(command -v sokol-shdc)"
fi
if [ -n "$SHDC" ] && [ -x "$SHDC" ]; then
	echo "── Regenerating wgsl shader headers ──"
	"$ROOT/tools/gen_shaders_wgsl.sh" "$SHDC"
else
	echo "── sokol-shdc not found; skipping shader regen ──"
	echo "   (headers must already carry the wgsl branch — check"
	echo "    engine/graphics/renderer/shaders/generated/*.glsl.h)"
fi

echo ""
echo "✓ Vendor ready: $VENDOR (commit $BOX3D_COMMIT)"
echo "  Fork:         $FORK (owned — edit the ibl/sky empty-bindgroup fixes in)"
echo "  Next:         ./tools/build_engine.sh native"