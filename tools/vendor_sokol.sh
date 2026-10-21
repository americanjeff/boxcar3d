#!/usr/bin/env bash
# Bootstrap the vendored Sokol headers (separately from Box3D's bundled
# extern/sokol) at the pinned commit, and apply the vendor patches
# (tools/patches/*.patch).
#
# Sokol is header-only, so there are no link/compatibility concerns — only
# include-path consistency with the forked renderer (which uses the
# post-Nov-2024 sg_view/sg_sampler bindgroups-cache API this pin provides).
# The separate pin makes the renderer-fork↔sokol sync relationship explicit.
#
# Idempotent: safe to re-run. Uses `patch --forward` so an already-applied
# patch is skipped. Cloning is skipped if vendor/sokol already exists.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Pinned upstream commit (floooh/sokol master, same generation Box3D
#    bundles; the forked renderer's sg_view/sg_sampler API matches this pin) ──
SOKOL_COMMIT="b02162392486717c2c9b229c37166594d6d7a7ac"
SOKOL_REMOTE="https://github.com/floooh/sokol.git"
VENDOR="$ROOT/vendor/sokol"
PATCHES="$ROOT/tools/patches"

# ── 1. Clone upstream at the pinned commit (skip if already present) ──
if [ ! -d "$VENDOR" ] || [ ! -f "$VENDOR/sokol_gfx.h" ]; then
	echo "── Cloning floooh/sokol @ $SOKOL_COMMIT ──"
	rm -rf "$VENDOR"
	mkdir -p "$ROOT/vendor"
	if command -v jj >/dev/null 2>&1; then
		jj git clone "$SOKOL_REMOTE" "$VENDOR"
		jj -R "$VENDOR" restore --from="$SOKOL_COMMIT"
		rm -rf "$VENDOR/.jj" "$VENDOR/.git"
	else
		git clone "$SOKOL_REMOTE" "$VENDOR"
		git -C "$VENDOR" checkout "$SOKOL_COMMIT"
		rm -rf "$VENDOR/.git"
	fi
else
	echo "── vendor/sokol already present, skipping clone ──"
fi

# ── 2. Record the pinned commit ──
echo "$SOKOL_COMMIT" > "$VENDOR/COMMIT.txt"

# ── 3. Apply the one vendor patch (idempotent) ──
# `patch --forward` exits nonzero both on a real conflict AND on "already
# applied". Dry-run first to tell them apart (dry-run writes no .rej/.orig).
echo "── Applying sokol patch ──"
for p in "$PATCHES"/*.patch; do
	[ -f "$p" ] || continue
	name="$(basename "$p")"
	if ( cd "$VENDOR" && patch -p1 --forward --dry-run < "$p" >/dev/null 2>&1 ); then
		echo "  $name (applying)"
		( cd "$VENDOR" && patch -p1 --forward --no-backup-if-mismatch < "$p" ) \
			|| { echo "ERROR: $name failed to apply." >&2; exit 1; }
	else
		msg="$( cd "$VENDOR" && patch -p1 --forward --dry-run < "$p" 2>&1 )" || true
		if echo "$msg" | grep -qi 'previously applied\|already applied\|reversed'; then
			echo "  $name (already applied — skipped)"
		else
			echo "ERROR: $name does not apply cleanly:" >&2
			echo "$msg" >&2
			exit 1
		fi
	fi
done

echo ""
echo "✓ Vendor ready: $VENDOR (commit $SOKOL_COMMIT)"