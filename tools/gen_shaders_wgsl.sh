#!/usr/bin/env bash
# One-time shader header regeneration for the forked Box3D Sokol renderer.
#
# Upstream's samples/shaders/CMakeLists.txt generates headers with
#   --slang hlsl5:metal_macos:glsl430
# which emits no wgsl and no glsl300es, so the browser backends (SOKOL_WGPU
# for WebGPU, SOKOL_GLES3 for WebGL2) have no shader code. This regenerates
# every *.glsl.h header with wgsl + glsl300es added to the slang list, so a
# single header set serves the native SOKOL_GLCORE build (glsl430 branch),
# the WASM SOKOL_WGPU build (wgsl branch) and the WASM SOKOL_GLES3 build
# (glsl300es branch). The non-added backend bytes are byte-identical to
# upstream's output (same glslang), so the native build is unaffected.
#
# Note: the three GTAO shaders are compute-only and cannot emit glsl300es
# (sokol-shdc requires ESSL 3.10 for compute). The SOKOL_GLES3 build skips
# the GTAO chain at runtime (see the GLES3 guards in gtao.c / renderer.c),
# so those desc functions are never called with SG_BACKEND_GLES3.
#
# Reads .glsl sources from vendor/box3d/samples/shaders/ (the renderer keeps
# only the generated headers, in engine/graphics/renderer/shaders/generated/).
# sokol-shdc is a generation tool, not a build dependency: the build reads
# these committed headers directly.
#
# Normally invoked by tools/vendor_box3d.sh. Standalone usage:
#   ./tools/gen_shaders_wgsl.sh [path/to/sokol-shdc]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SHADERS="$ROOT/vendor/box3d/samples/shaders"
OUT="$ROOT/engine/graphics/renderer/shaders/generated"

SHDC="${1:-${SOKOL_SHDC:-}}"
if [ -z "$SHDC" ] && command -v sokol-shdc >/dev/null 2>&1; then
	SHDC="$(command -v sokol-shdc)"
fi
if [ -z "$SHDC" ] || ! [ -x "$SHDC" ]; then
	echo "sokol-shdc not found. Install it, set \$SOKOL_SHDC, or pass its path as \$1." >&2
	echo "  (e.g. ./tools/gen_shaders_wgsl.sh /path/to/sokol-shdc)" >&2
	exit 1
fi
mkdir -p "$OUT"

# Same shader list as upstream samples/shaders/CMakeLists.txt add_shader().
# Backend set = upstream's three + wgsl (WebGPU wasm) + glsl300es (WebGL2
# wasm). glsl300es is the only slang sokol-shdc emits for SOKOL_GLES3.
SLANG="hlsl5:metal_macos:glsl430:glsl300es:wgsl"
SHADERS_LIST=(
    "cube shapes/cube.glsl"
    "sphere shapes/sphere.glsl"
    "capsule shapes/capsule.glsl"
    "geom shapes/geom.glsl"
    "edge shapes/edge.glsl"
    "shadow_caster_cube shapes/shadow_caster_cube.glsl"
    "shadow_caster_geom shapes/shadow_caster_geom.glsl"
    "shadow_caster_sphere shapes/shadow_caster_sphere.glsl"
    "shadow_caster_capsule shapes/shadow_caster_capsule.glsl"
    "sky ibl/sky.glsl"
    "brdf_lut ibl/brdf_lut.glsl"
    "sky_to_cube ibl/sky_to_cube.glsl"
    "prefilter ibl/prefilter.glsl"
    "depth_only_cube post/depth_only_cube.glsl"
    "depth_only_sphere post/depth_only_sphere.glsl"
    "depth_only_capsule post/depth_only_capsule.glsl"
    "depth_only_geom post/depth_only_geom.glsl"
    "gtao_prefilter_depth post/gtao_prefilter_depth.glsl"
    "gtao_main_pass post/gtao_main_pass.glsl"
    "gtao_denoise post/gtao_denoise.glsl"
    "tonemap post/tonemap.glsl"
    "mask_sphere post/mask_sphere.glsl"
    "mask_capsule post/mask_capsule.glsl"
    "mask_hull post/mask_hull.glsl"
    "highlight_outline post/highlight_outline.glsl"
    "overlay_line overlays/line.glsl"
    "overlay_point overlays/point.glsl"
    "world_text overlays/world_text.glsl"
)

# Compute-only shaders: sokol-shdc cannot emit glsl300es for compute stages
# (WebGL2 has no compute, ESSL 3.00 has no compute shaders). Generate these
# without the glsl300es slang; their desc functions return NULL for
# SG_BACKEND_GLES3, which the GLES3 build never calls (gtao.c guards).
COMPUTE_ONLY=("gtao_prefilter_depth" "gtao_main_pass" "gtao_denoise")

cd "$SHADERS"
for spec in "${SHADERS_LIST[@]}"; do
    name="${spec%% *}"; input="${spec#* }"
    slang="$SLANG"
    for c in "${COMPUTE_ONLY[@]}"; do
        if [ "$name" = "$c" ]; then
            slang="${SLANG/glsl300es:}"
        fi
    done
    echo "sokol-shdc $name.glsl"
    "$SHDC" --input "$input" --output "$OUT/${name}.glsl.h" --slang "$slang"
done

echo ""
echo "✓ Regenerated $(ls "$OUT"/*.glsl.h 2>/dev/null | wc -l) shader headers in $OUT"
echo "  (glsl430 for native SOKOL_GLCORE, glsl300es for WASM SOKOL_GLES3, wgsl for WASM SOKOL_WGPU;"
echo "   hlsl5/metal_macos retained for parity with upstream; GTAO compute shaders have no glsl300es branch)"