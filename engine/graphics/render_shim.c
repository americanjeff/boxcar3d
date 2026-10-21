// Generic draw primitives + render settings only.
// The app builds its own meshes (e.g. a terrain heightfield) in Odin and
// uploads them via the generic register_mesh/append_mesh below — this shim
// never knows "terrain" exists.
//
// Scalar-in / struct-out render-FFI shim. Odin never touches a C struct:
// every wrapper takes only scalars (floats/ints) and plain arrays, and this
// shim builds the renderer's structs (b3Transform, Vec4, Sun, FrameInput,
// Mat4, MeshVertex) on the C side. IDs/handles cross the FFI as packed u64.
//
// This TU does NOT define any sokol impls. The sokol_gfx impl lives in the
// forked renderer's gfx/sokol_impl.c (compiled into this same archive). The
// sokol_app / sokol_glue / sokol_log IMPLS live in engine/apphost
// (apphost_shim.c). This shim still calls sapp_width()/sapp_height()/
// sapp_frame_count() and sglue_environment()/sglue_swapchain() (declared by
// the headers, resolved from libapphost at final link) for the on-screen
// render path. (A headless host would call the renderer's
// `RenderFrameOffscreen` directly in C; it is not currently wired through
// this scalar FFI because no app needs it — see renderer.h.)

#if defined(__linux__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "sokol_gfx.h"
#include "sokol_app.h"   /* header only — impl is in apphost; for sapp_width/height/frame_count */
#include "sokol_glue.h"  /* header only — impl is in apphost; for sglue_environment/sglue_swapchain */
#include "sokol_log.h"
#include "util/sokol_gl.h" /* header only — impl is in gfx/sokol_impl.c; for sgl_* overlay */

#include "box3d/box3d.h"
#include "box3d/math_functions.h"
#include "gfx/renderer.h"
#include "gfx/utility.h"
#include "gfx/geometry_registry.h"

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Overlay state — declared early so shim_render_frame_camera can test
   g_overlayActive before the overlay section below. */
static bool g_overlayActive = false;
static bool g_overlayReady = false;
static sg_image g_atlasImage;
static sg_view g_atlasView;
static sg_sampler g_atlasSampler;
static sg_image g_iconImage;
static sg_view g_iconView;
static sgl_pipeline g_overlayPip;
static sgl_pipeline g_overlaySdfPip;
/* SDF outline state (set by the app, applied to every SDF quad). */
static float g_sdfOutlineCol[4] = { 0, 0, 0, 0 };
static float g_sdfOutlineW = 1.0f;
static float g_sdfSpread = 4.0f;

/* A pipeline with premultiplied-alpha blending. sokol_gl's default pipeline
   has blending DISABLED, so glyph quads' transparent texels (RGB=0) would
   replace the destination with black instead of showing the background —
   fine for the old solid bitmap font (no holes) but it makes TTF glyphs with
   interior holes render as "light strokes on a black box". This pipeline
   fixes that by blending src over dst with ONE / ONE_MINUS_SRC_ALPHA. */

/* ─── SDF text pipeline ───────────────────────────────────────────────
   The font atlas stores a spread-clamped signed distance field per glyph
   (one byte/px in every channel after upload; 0 = SPREAD outside the ink,
   0.5 = ink edge, 1 = SPREAD inside; distance in DESIGN px). This pipeline
   thresholds the field with fwidth antialiasing and draws the contrast
   outline as a distance band, so each glyph is ONE quad at any display
   scale (it replaced the 8-bit-alpha bake + 8 offset passes).

   The SDF parameters (outline rgba, outline width, field spread) are
   packed into sgl's texture-matrix slot (vs_params[4..7]): this shader
   passes the UVs through untransformed, so that 16-float slot is free
   parameter storage that sgl_draw() already uploads for every pipeline
   state change. The built-in textured quads need tm == identity, so the
   quad functions below toggle it. The vertex shader forwards the params
   to the fragment shader as varyings — this sokol_gfx's WGPU backend
   only supports single-stage uniform blocks, so the block stays
   VERTEX-visible like sgl's built-in.

   The shader mirrors sgl's built-in attribute contract (position/tex-
   coord0/color0, vs_params uniform block, tex_smp texture slot) so
   sgl_make_pipeline() can fill in the vertex layout as usual. */
#if defined( SOKOL_GLCORE )
static const char *const OVERLAY_SDF_VS_GLSL =
    "#version 430\n"
    "uniform vec4 vs_params[8];\n"
    "layout(location = 0) in vec4 position;\n"
    "layout(location = 1) in vec2 texcoord0;\n"
    "layout(location = 2) in vec4 color0;\n"
    "layout(location = 0) out vec2 v_uv;\n"
    "layout(location = 1) out vec4 v_col;\n"
    "layout(location = 2) out vec4 v_outl;\n"
    "layout(location = 3) out vec2 v_sdf;\n"
    "void main() {\n"
    "    gl_Position = mat4(vs_params[0], vs_params[1], vs_params[2], vs_params[3]) * vec4(position.xyz, 1.0);\n"
    "    v_uv = texcoord0;\n"
    "    v_col = color0;\n"
    "    v_outl = vs_params[4];\n"
    "    v_sdf = vec2(vs_params[5].x, vs_params[5].y);\n"
    "}\n";
static const char *const OVERLAY_SDF_FS_GLSL =
    "#version 430\n"
    "uniform sampler2D tex_smp;\n"
    "layout(location = 0) in vec2 v_uv;\n"
    "layout(location = 1) in vec4 v_col;\n"
    "layout(location = 2) in vec4 v_outl;\n"
    "layout(location = 3) in vec2 v_sdf;\n"
    "layout(location = 0) out vec4 frag_color;\n"
    "void main() {\n"
    "    float d = (texture(tex_smp, v_uv).r - 0.5) * 2.0 * v_sdf.y;\n"
    "    float aa = max(fwidth(d), 0.0001);\n"
    "    float a_ink = v_col.a * smoothstep(-aa, aa, d);\n"
    "    float a_out = v_outl.a * smoothstep(-aa, aa, d + v_sdf.x);\n"
    "    float a = a_ink + a_out * (1.0 - a_ink);\n"
    "    vec3 rgb = v_col.rgb * a_ink + v_outl.rgb * a_out * (1.0 - a_ink);\n"
    "    frag_color = vec4(rgb, a);\n"
    "}\n";
#elif defined( SOKOL_GLES3 )
/* WebGL2 (ES 3.00): same math, but ES forbids `location` on varyings
   (vertex outputs / fragment inputs) — those match by name — and
   needs explicit float precision (the built-in sgl ES shader uses
   highp VS / mediump FS; the SDF math is fine in mediump). */
static const char *const OVERLAY_SDF_VS_GLSL =
    "#version 300 es\n"
    "precision highp float;\n"
    "uniform highp vec4 vs_params[8];\n"
    "layout(location = 0) in highp vec4 position;\n"
    "layout(location = 1) in highp vec2 texcoord0;\n"
    "layout(location = 2) in highp vec4 color0;\n"
    "out highp vec2 v_uv;\n"
    "out highp vec4 v_col;\n"
    "out highp vec4 v_outl;\n"
    "out highp vec2 v_sdf;\n"
    "void main() {\n"
    "    gl_Position = mat4(vs_params[0], vs_params[1], vs_params[2], vs_params[3]) * vec4(position.xyz, 1.0);\n"
    "    v_uv = texcoord0;\n"
    "    v_col = color0;\n"
    "    v_outl = vs_params[4];\n"
    "    v_sdf = vec2(vs_params[5].x, vs_params[5].y);\n"
    "}\n";
static const char *const OVERLAY_SDF_FS_GLSL =
    "#version 300 es\n"
    "precision mediump float;\n"
    "precision highp int;\n"
    "uniform highp sampler2D tex_smp;\n"
    "in highp vec2 v_uv;\n"
    "in highp vec4 v_col;\n"
    "in highp vec4 v_outl;\n"
    "in highp vec2 v_sdf;\n"
    "layout(location = 0) out highp vec4 frag_color;\n"
    "void main() {\n"
    "    float d = (texture(tex_smp, v_uv).r - 0.5) * 2.0 * v_sdf.y;\n"
    "    float aa = max(fwidth(d), 0.0001);\n"
    "    float a_ink = v_col.a * smoothstep(-aa, aa, d);\n"
    "    float a_out = v_outl.a * smoothstep(-aa, aa, d + v_sdf.x);\n"
    "    float a = a_ink + a_out * (1.0 - a_ink);\n"
    "    vec3 rgb = v_col.rgb * a_ink + v_outl.rgb * a_out * (1.0 - a_ink);\n"
    "    frag_color = vec4(rgb, a);\n"
    "}\n";
#elif defined( SOKOL_WGPU )
static const char *const OVERLAY_SDF_VS_WGSL =
    "struct Params {\n"
    "    mvp: mat4x4f,\n"
    "    tm: mat4x4f,\n"
    "}\n"
    "@group(0) @binding(0) var<uniform> p: Params;\n"
    "struct VsOut {\n"
    "    @builtin(position) pos: vec4f,\n"
    "    @location(0) uv: vec2f,\n"
    "    @location(1) col: vec4f,\n"
    "    @location(2) outl: vec4f,\n"
    "    @location(3) sdf: vec2f,\n"
    "}\n"
    "@vertex\n"
    "fn main(@location(0) position: vec4f, @location(1) texcoord0: vec2f, @location(2) color0: vec4f) -> VsOut {\n"
    "    var o: VsOut;\n"
    "    o.pos = p.mvp * vec4f(position.x, position.y, 0.0, 1.0);\n"
    "    o.uv = texcoord0;\n"
    "    o.col = color0;\n"
    "    o.outl = vec4f(p.tm[0][0], p.tm[0][1], p.tm[0][2], p.tm[0][3]);\n"
    "    o.sdf = vec2f(p.tm[1][0], p.tm[1][1]);\n"
    "    return o;\n"
    "}\n";
static const char *const OVERLAY_SDF_FS_WGSL =
    "diagnostic(off, derivative_uniformity);\n"
    "@group(1) @binding(0) var tex: texture_2d<f32>;\n"
    "@group(1) @binding(32) var smp: sampler;\n"
    "@fragment\n"
    "fn main(@location(0) uv: vec2f, @location(1) col: vec4f, @location(2) outl: vec4f, @location(3) sdf: vec2f) -> @location(0) vec4f {\n"
    "    let d = (textureSample(tex, smp, uv).r - 0.5f) * 2.0f * sdf.y;\n"
    "    let aa = max(fwidth(d), 0.0001f);\n"
    "    let a_ink = col.a * smoothstep(-aa, aa, d);\n"
    "    let a_out = outl.a * smoothstep(-aa, aa, d + sdf.x);\n"
    "    let a = a_ink + a_out * (1.0 - a_ink);\n"
    "    let rgb = col.rgb * a_ink + outl.rgb * a_out * (1.0 - a_ink);\n"
    "    return vec4f(rgb, a);\n"
    "}\n";
#endif /* SOKOL_WGPU */

static sg_shader g_sdfShd;

static void overlay_make_sdf_pipeline( void )
{
	sg_shader_desc shd;
	memset( &shd, 0, sizeof( shd ) );
	/* Mirror sgl's built-in shader contract (attribute names, the
	   vs_params block, the tex_smp texture/sampler slots) so sgl_draw()
	   applies the same bindings to this pipeline. */
	shd.attrs[0].glsl_name = "position";
	shd.attrs[1].glsl_name = "texcoord0";
	shd.attrs[2].glsl_name = "color0";
	shd.attrs[3].glsl_name = "psize";
	shd.attrs[0].hlsl_sem_name = "TEXCOORD";
	shd.attrs[0].hlsl_sem_index = 0;
	shd.attrs[1].hlsl_sem_name = "TEXCOORD";
	shd.attrs[1].hlsl_sem_index = 1;
	shd.attrs[2].hlsl_sem_name = "TEXCOORD";
	shd.attrs[2].hlsl_sem_index = 2;
	shd.attrs[3].hlsl_sem_name = "TEXCOORD";
	shd.attrs[3].hlsl_sem_index = 3;
	shd.attrs[0].base_type = SG_SHADERATTRBASETYPE_FLOAT;
	shd.attrs[1].base_type = SG_SHADERATTRBASETYPE_FLOAT;
	shd.attrs[2].base_type = SG_SHADERATTRBASETYPE_FLOAT;
	shd.attrs[3].base_type = SG_SHADERATTRBASETYPE_FLOAT;
	shd.uniform_blocks[0].stage = SG_SHADERSTAGE_VERTEX;
	shd.uniform_blocks[0].size = 128;
	shd.uniform_blocks[0].hlsl_register_b_n = 0;
	shd.uniform_blocks[0].msl_buffer_n = 0;
	shd.uniform_blocks[0].wgsl_group0_binding_n = 0;
	shd.uniform_blocks[0].spirv_set0_binding_n = 0;
	shd.uniform_blocks[0].glsl_uniforms[0].glsl_name = "vs_params";
	shd.uniform_blocks[0].glsl_uniforms[0].type = SG_UNIFORMTYPE_FLOAT4;
	shd.uniform_blocks[0].glsl_uniforms[0].array_count = 8;
	shd.views[0].texture.stage = SG_SHADERSTAGE_FRAGMENT;
	shd.views[0].texture.image_type = SG_IMAGETYPE_2D;
	shd.views[0].texture.sample_type = SG_IMAGESAMPLETYPE_FLOAT;
	shd.views[0].texture.hlsl_register_t_n = 0;
	shd.views[0].texture.msl_texture_n = 0;
	shd.views[0].texture.wgsl_group1_binding_n = 0;
	shd.views[0].texture.spirv_set1_binding_n = 0;
	shd.samplers[0].stage = SG_SHADERSTAGE_FRAGMENT;
	shd.samplers[0].sampler_type = SG_SAMPLERTYPE_FILTERING;
	shd.samplers[0].hlsl_register_s_n = 0;
	shd.samplers[0].msl_sampler_n = 0;
	shd.samplers[0].wgsl_group1_binding_n = 32;
	shd.samplers[0].spirv_set1_binding_n = 32;
	shd.texture_sampler_pairs[0].stage = SG_SHADERSTAGE_FRAGMENT;
	shd.texture_sampler_pairs[0].view_slot = 0;
	shd.texture_sampler_pairs[0].sampler_slot = 0;
	shd.texture_sampler_pairs[0].glsl_name = "tex_smp";
	shd.label = "overlay_sdf_shader";
#if defined( SOKOL_GLCORE ) || defined( SOKOL_GLES3 )
	shd.vertex_func.source = OVERLAY_SDF_VS_GLSL;
	shd.fragment_func.source = OVERLAY_SDF_FS_GLSL;
#elif defined( SOKOL_WGPU )
	shd.vertex_func.source = OVERLAY_SDF_VS_WGSL;
	shd.fragment_func.source = OVERLAY_SDF_FS_WGSL;
#else
	shd.vertex_func.source = "";
	shd.fragment_func.source = "";
#endif
	g_sdfShd = sg_make_shader( &shd );

	sg_pipeline_desc pdesc;
	memset( &pdesc, 0, sizeof( pdesc ) );
	pdesc.shader = g_sdfShd;
	pdesc.colors[0].blend.enabled = true;
	pdesc.colors[0].blend.src_factor_rgb = SG_BLENDFACTOR_ONE;
	pdesc.colors[0].blend.dst_factor_rgb = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
	pdesc.colors[0].blend.src_factor_alpha = SG_BLENDFACTOR_ONE;
	pdesc.colors[0].blend.dst_factor_alpha = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
	g_overlaySdfPip = sgl_make_pipeline( &pdesc );
}

static bool g_sdfActive = false;  /* texture matrix currently holds SDF params */
static bool g_sdfDirty = false;   /* params changed since last load */

/* The built-in textured quads transform their UVs with the texture
   matrix, so it must be identity when they draw. */
static void overlay_ensure_identity_texture_matrix( void )
{
	if ( !g_sdfActive ) return;
	sgl_matrix_mode_texture();
	sgl_load_identity();
	g_sdfActive = false;
}

/* Load the SDF pipeline and (re)pack the params into the texture matrix. */
static void overlay_sdf_ensure_state( void )
{
	sgl_load_pipeline( g_overlaySdfPip );
	if ( g_sdfDirty || !g_sdfActive )
	{
		/* tm row 0 = outline rgba, row 1 = (outline width, spread). */
		float tm[16] = {
			g_sdfOutlineCol[0], g_sdfOutlineCol[1], g_sdfOutlineCol[2], g_sdfOutlineCol[3],
			g_sdfOutlineW, g_sdfSpread, 0.0f, 0.0f,
			0.0f, 0.0f, 0.0f, 0.0f,
			0.0f, 0.0f, 0.0f, 0.0f
		};
		sgl_matrix_mode_texture();
		sgl_load_matrix( tm );
		g_sdfActive = true;
		g_sdfDirty = false;
	}
	sgl_enable_texture();
	sgl_texture( g_atlasView, g_atlasSampler );
}

void shim_overlay_make_pipeline( void )
{
	sg_pipeline_desc pdesc;
	memset( &pdesc, 0, sizeof( pdesc ) );
	pdesc.colors[0].blend.enabled = true;
	pdesc.colors[0].blend.src_factor_rgb = SG_BLENDFACTOR_ONE;
	pdesc.colors[0].blend.dst_factor_rgb = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
	pdesc.colors[0].blend.src_factor_alpha = SG_BLENDFACTOR_ONE;
	pdesc.colors[0].blend.dst_factor_alpha = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
	g_overlayPip = sgl_make_pipeline( &pdesc );
	overlay_make_sdf_pipeline();
}

/* Set the SDF outline parameters (straight 0..1 colors; width and spread
   in DESIGN px). Applied to every subsequent SDF quad. */
void shim_overlay_set_sdf( float r, float g, float b, float a, float outline_w, float spread )
{
	g_sdfOutlineCol[0] = r;
	g_sdfOutlineCol[1] = g;
	g_sdfOutlineCol[2] = b;
	g_sdfOutlineCol[3] = a;
	g_sdfOutlineW = outline_w;
	g_sdfSpread = spread;
	g_sdfDirty = true;
}

/* Layout assertions: Mat4 is exactly 16 contiguous floats (column-major),
   so the shim can build it from the C helpers and the Odin side never sees
   it. MeshVertex is exactly 6 contiguous floats (position[3], normal[3]). */
_Static_assert(sizeof(Mat4) == 64, "Mat4 must be 16 floats");
_Static_assert(sizeof(Vec4) == 16, "Vec4 must be 4 floats");
_Static_assert(sizeof(MeshVertex) == 24, "MeshVertex must be 6 floats");

/* ─── Renderer lifecycle ────────────────────────────────────────────── */

void shim_init_renderer(void) {
	const sg_environment env = sglue_environment();
	InitRenderer(&env);

	/* Sensible midday sun defaults; Odin can override via shim_set_sun. */
	Sun sun;
	memset(&sun, 0, sizeof(sun));
	sun.dirToSun = (b3Vec3){0.5f, 0.8f, 0.4f};
	sun.color = (b3Vec3){1.0f, 0.95f, 0.85f};
	sun.ambient = 0.10f;
	sun.strength = 1.0f;
	SetSun(sun);
}

void shim_shutdown_renderer(void) {
	ShutdownRenderer();
}

void shim_set_sun(float dx, float dy, float dz, float r, float g, float b, float ambient, float strength) {
	Sun sun;
	memset(&sun, 0, sizeof(sun));
	sun.dirToSun = (b3Vec3){dx, dy, dz};
	sun.color = (b3Vec3){r, g, b};
	sun.ambient = ambient;
	sun.strength = strength;
	SetSun(sun);
}

/* Preetham turbidity (>=1). Higher = warmer/more orange sky, so IBL
   reflections carry a visible tint distinct from the white direct sun.
   Fed to both the sky pass and the IBL cubemap rebuild. */
void shim_set_sky_turbidity(float t) {
	SetSkyTurbidity(t);
}

/* Exposure stop applied by the AgX tone map (final image *= pow(2, ev)). */
void shim_set_exposure(float ev) {
	SetExposure(ev);
}

/* Toggle image-based lighting (diffuse SH + prefiltered specular from the
   procedural sky). When off, lit shapes fall back to flat ambient. */
void shim_set_ibl_enabled(int enabled) {
	SetIblEnabled((bool)enabled);
}

/* Edge overlay (per-shape hull/mesh/heightfield outlines): scalar-in build of
   EdgeOverlayParams. Starts from the engine defaults (colors + showEdgeConvexity
   stay default) and overrides the master on/off, per-kind visibility, line
   thickness / reverse-Z nudge, and the hull edge color. A generic render
   setting: any app that registered edge lists (see shim_register_mesh_edges)
   wants to toggle them and tune their contrast. */
void shim_set_edge_overlay(int enabled, int showHulls, int showMeshes, int showHeightfields,
                            float thicknessPx, float zBias,
                            float hullR, float hullG, float hullB, float hullA) {
	EdgeOverlayParams p = GetDefaultEdgeParams();
	p.enabled = (bool)enabled;
	p.showHulls = (bool)showHulls;
	p.showMeshes = (bool)showMeshes;
	p.showHeightfields = (bool)showHeightfields;
	p.thicknessPx = thicknessPx;
	p.zBias = zBias;
	p.hullColor = MakeVec4(hullR, hullG, hullB, hullA);
	SetEdgeOverlayParams(&p);
}

void shim_reset_frame_arena(void) {
	ResetFrameArena();
}

/* ─── Shape append (scalar-in → renderer structs) ───────────────────── */

void shim_append_cube(float px, float py, float pz,
                      float qx, float qy, float qz, float qw,
                      float sx, float sy, float sz,
                      float r, float g, float b, float a,
                      float metallic, float roughness) {
	b3Transform t;
	t.p = (b3Vec3){px, py, pz};
	t.q = (b3Quat){{qx, qy, qz}, qw};
	const Vec4 color = {r, g, b, a};
	/* scale = full side lengths (the unit cube proxy spans [-0.5, 0.5]). */
	AppendCube(t, (b3Vec3){sx, sy, sz}, color, metallic, roughness, TRANSPARENT_SHADOW_FULL);
}

void shim_append_sphere(float px, float py, float pz,
                        float qx, float qy, float qz, float qw,
                        float radius,
                        float r, float g, float b, float a,
                        float metallic, float roughness, float pattern,
                        float cap_r, float cap_g, float cap_b, float cap_threshold) {
	b3Transform t;
	t.p = (b3Vec3){px, py, pz};
	t.q = (b3Quat){{qx, qy, qz}, qw};
	const Vec4 color = {r, g, b, a};
	/* cap: .rgb = polar-cap paint color, .a = threshold (1.0 = no cap). */
	const Vec4 cap = {cap_r, cap_g, cap_b, cap_threshold};
	AppendSphere(t, radius, color, metallic, roughness, pattern, cap, TRANSPARENT_SHADOW_FULL);
}

/* The renderer's capsule local +X axis is the long axis; `halfLength` is the
   distance from center to either cap center. The app passes a quaternion
   that orients +X into the world (e.g. 90° about Z to stand it on its end). */
void shim_append_capsule(float px, float py, float pz,
                         float qx, float qy, float qz, float qw,
                         float halfLength, float radius,
                         float r, float g, float b, float a,
                         float metallic, float roughness) {
	b3Transform t;
	t.p = (b3Vec3){px, py, pz};
	t.q = (b3Quat){{qx, qy, qz}, qw};
	const Vec4 color = {r, g, b, a};
	AppendCapsule(t, halfLength, radius, color, metallic, roughness, TRANSPARENT_SHADOW_FULL);
}

/* ─── Generic mesh API (register_mesh / append_mesh) ────────────────── */
// GENERIC: any app uploads its own triangle mesh (a terrain heightfield, a
// custom shape, …) once and appends instances each frame. The engine never
// knows what the mesh represents. `verts` is `vertexCount * 6` contiguous
// floats (position.xyz, normal.xyz per vertex); `indices` is `indexCount`
// uint32s. The returned handle is a packed u64 (MeshHandle.index << 32 |
// MeshHandle.hash) — pass it back to shim_append_mesh / shim_is_mesh_handle_valid.

static uint64_t pack_mesh_handle(MeshHandle h) {
	return ((uint64_t)(uint32_t)h.index << 32) | (uint64_t)h.hash;
}

static MeshHandle unpack_mesh_handle(uint64_t v) {
	MeshHandle h;
	h.index = (int)(v >> 32);
	h.hash = (uint32_t)v;
	return h;
}

// `kind` is a MeshKind enum value (MESH_KIND_*); pass MESH_KIND_UNKNOWN (0) if
// the app does not care. The renderer uses the kind tag for the edge overlay
// / debug classification; it does not affect solid drawing.
uint64_t shim_register_mesh(uint32_t hash, const float *verts, int vertexCount,
                             const uint32_t *indices, int indexCount, int kind) {
	const MeshVertex *mv = (const MeshVertex *)verts;
	MeshHandle h = RegisterMesh(hash, mv, vertexCount, indices, indexCount, "app_mesh");
	SetMeshKind(h, (MeshKind)kind);
	return pack_mesh_handle(h);
}

int shim_is_mesh_handle_valid(uint64_t handle) {
	return IsMeshHandleValid(unpack_mesh_handle(handle)) ? 1 : 0;
}

// Optional edge list for a mesh already registered via shim_register_mesh.
// Call once, right after registration, before the first shim_append_mesh.
// `edges` is `edgeCount * 2` EdgeVertex entries laid out flat as 8 floats per
// edge (endpoint0.xyz, flag0, endpoint1.xyz, flag1) — cast straight to
// `const EdgeVertex*` (EdgeVertex is exactly 4 contiguous floats, same cast
// pattern as the MeshVertex cast in shim_register_mesh). The renderer builds
// per-edge batches from this on the next instance upload; without it the edge
// overlay has nothing to draw for this mesh. `flag` = 0 concave / 1 convex
// crease / 2 flat; the edge overlay FS picks convex/concave/flat color from
// it (hull-kind batches ignore it — their color is hard-coded). A generic
// draw primitive: any app that wants outlines uploads its own edge list.
// Caller may free `edges` after this returns.
void shim_register_mesh_edges(uint64_t handle, const float *edges, int edgeCount) {
	MeshHandle h = unpack_mesh_handle(handle);
	const EdgeVertex *ev = (const EdgeVertex *)edges;
	RegisterMeshEdges(h, ev, edgeCount, "app_mesh_edges");
}

// Look up a registered mesh by content hash. Returns the packed handle of a
// live (refCount > 0) entry with that hash, or the invalid handle (index -1)
// if none. RegisterMesh does NOT dedup internally — every call takes a fresh
// slot — so an app must FindMesh before RegisterMesh, or identical geometry
// re-registered on a miss leaks duplicate slots toward the 4096-entry cap.
uint64_t shim_find_mesh(uint32_t hash) {
	return pack_mesh_handle(FindMesh(hash));
}

// Add a reference to a registered mesh (refCount += 1). The mesh's GPU buffers
// are destroyed only when its reference count drops to 0; pair every call with
// a shim_release_mesh_reference. No-op for an invalid handle.
void shim_add_mesh_reference(uint64_t handle) {
	AddMeshReference(unpack_mesh_handle(handle));
}

// Drop a reference to a registered mesh (refCount -= 1); when it reaches 0 the
// slot and its GPU buffers are freed for the next tenant. No-op for an
// invalid handle.
void shim_release_mesh_reference(uint64_t handle) {
	ReleaseMeshReference(unpack_mesh_handle(handle));
}

// Total registry entry count (diagnostics / cap proximity — the cap is
// MAX_REGISTRY_ENTRIES; near it, registrations start failing).
int shim_get_mesh_entry_count(void) {
	return GetMeshEntryCount();
}

// Append one instance of a registered mesh. `materialMode` is a
// MeshMaterialMode enum value (MESH_MATERIAL_MODE_SOLID = 0,
// MESH_MATERIAL_MODE_GROUND_GRID = 1); `gridCellSize` is only used by the
// ground-grid mode (pass 0 otherwise); `shadowCast` is a
// TransparentShadowCast enum value (TRANSPARENT_SHADOW_FULL = 0,
// TRANSPARENT_SHADOW_NONE = 1).
void shim_append_mesh(uint64_t handle,
                      float px, float py, float pz,
                      float qx, float qy, float qz, float qw,
                      float sx, float sy, float sz,
                      float r, float g, float b, float a,
                      float metallic, float roughness,
                      int materialMode, float gridCellSize, int shadowCast) {
	MeshHandle h = unpack_mesh_handle(handle);
	if (!IsMeshHandleValid(h)) return;
	b3Transform t;
	t.p = (b3Vec3){px, py, pz};
	t.q = (b3Quat){{qx, qy, qz}, qw};
	const Vec4 color = {r, g, b, a};
	AppendMesh(h, t, (b3Vec3){sx, sy, sz}, color, metallic, roughness,
	           (MeshMaterialMode)materialMode, gridCellSize, (TransparentShadowCast)shadowCast);
}

/* ─── Frame render (camera basis + projection → FrameInput) ─────────── */
/* The shim owns the Mat4 math (MakeViewAndInverse / MakePerspectiveAndInverse),
   so no Mat4 ever crosses the FFI. Odin passes the orthonormal camera basis
   (right, up, forward = pivot->eye) + eye position + projection params; the
   shim builds view/viewInv/proj/projInv, fills the rest of FrameInput from
   sokol_app state, and calls RenderFrame. */

void shim_render_frame_camera(float rx, float ry, float rz,
                              float ux, float uy, float uz,
                              float fx, float fy, float fz,
                              float ex, float ey, float ez,
                              float fov, float near_p, float far_p,
                              float time,
                              int debugMode,
                              int disableShadows, int disableAO, int zUp) {
	const b3Vec3 right = {rx, ry, rz};
	const b3Vec3 up = {ux, uy, uz};
	const b3Vec3 forward = {fx, fy, fz};
	const b3Vec3 eye = {ex, ey, ez};

	Mat4 view, viewInv, proj, projInv;
	MakeViewAndInverse(&view, &viewInv, right, up, forward, eye);

	const int W = sapp_width();
	const int H = sapp_height();
	const float aspect = (H > 0) ? (float)W / (float)H : 1.0f;
	/* Reverse-Z: swap near/far so near -> clip.z = 1, far -> 0 (GREATER compare). */
	MakePerspectiveAndInverse(&proj, &projInv, fov, aspect, far_p, near_p);

	FrameInput fi;
	memset(&fi, 0, sizeof(fi));
	fi.view = view;
	fi.viewInv = viewInv;
	fi.proj = proj;
	fi.projInv = projInv;
	fi.cameraPosition = eye;
	fi.drawOrigin = b3Vec3_zero;
	fi.gridWrap = (b3Vec2){0.0f, 0.0f};
	// The renderer's time is the caller's responsibility — it takes whatever
	// clock the app passes (here `time`), never the wall clock. Apps should
	// pass their simulation's accumulated time so any time-animated visual
	// effect stays in lockstep with the physics, and so changing the sim's
	// stepping strategy later never requires a renderer/shim change.
	fi.time = time;
	fi.debugMode = debugMode;
	fi.disableShadows = (bool)disableShadows;
	fi.disableAmbientOcclusion = (bool)disableAO;
	fi.zUp = (bool)zUp;

	const sg_swapchain sc = sglue_swapchain();
	RenderFrame(&sc, &fi);

	// Overlay pass: draw the 2D UI (microui command list rendered via
	// sokol_gl) post-tonemap on the swapchain. The app accumulates sgl
	// commands before calling render_frame; sgl_draw flushes them here.
	// LOADACTION_LOAD preserves the tonemapped scene color.
	if ( g_overlayActive )
	{
		sg_pass uiPass;
		memset( &uiPass, 0, sizeof( uiPass ) );
		uiPass.action.colors[0].load_action = SG_LOADACTION_LOAD;
		uiPass.swapchain = sc;
		sg_begin_pass( &uiPass );
		sgl_draw();
		sg_end_pass();
		g_overlayActive = false;
	}

	// RenderFrame does not call sg_commit() itself (it leaves the frame open
	// so a host can append its own passes before the single per-frame commit).
	// This shim owns the whole frame, so commit here to close it — this is
	// also what resets sokol_gfx's WebGPU uniform-buffer ring offset each
	// frame (without it the offset accumulates across frames and overruns
	// the uniform buffer).
	sg_commit();
}

void shim_get_framebuffer_size(int* w, int* h) {
	if (w) *w = sapp_width();
	if (h) *h = sapp_height();
}

/* Device pixel ratio (HiDPI scale): framebuffer px per logical px. 1.0
   before sapp_run has started (and on unscaled displays). Apps that draw
   UI in framebuffer pixels scale their layout by this to keep the UI the
   same physical size on HiDPI screens. */
void shim_get_dpi_scale(float* s) {
	if (s) *s = sapp_dpi_scale();
}

/* 1 once the GL context reported GL_OUT_OF_MEMORY (usually a resize whose
   new render targets didn't fit in the remaining VRAM), else 0. Latched for
   the process lifetime — the failed targets are unusable and a restart is
   the only recovery. Always 0 on non-GL backends. See GetGpuOutOfMemory in
   gfx/renderer.h. */
int shim_get_gpu_oom(void) {
	return GetGpuOutOfMemory();
}

/* ─── 2D overlay (sokol_gl) ───────────────────────────────────────────
   Generic 2D + text overlay for any app that needs a HUD or immediate-mode
   UI (microui). The app accumulates draw commands via the scalar functions
   below; shim_render_frame_camera flushes them with sgl_draw() after the
   scene renders. Separation test: any app with a HUD wants this.

   The app owns UI logic (microui, command walking, atlas glyph lookup);
   the shim provides the generic 2D draw surface (ortho projection, colored
   quads, textured quads, scissor). The font atlas texture is uploaded by
   the app as RGBA data (it converts the alpha-only microui atlas to RGBA
   white-with-alpha so sokol_gl's default shader modulates correctly). */

void shim_overlay_init( void )
{
	sgl_setup( &(sgl_desc_t){ 0 } );
	shim_overlay_make_pipeline();
	g_overlayReady = true;
}

void shim_overlay_shutdown( void )
{
	if ( !g_overlayReady ) return;
	if ( g_atlasImage.id ) { sg_destroy_image( g_atlasImage ); g_atlasImage.id = 0; }
	if ( g_atlasView.id ) { sg_destroy_view( g_atlasView ); g_atlasView.id = 0; }
	if ( g_iconImage.id ) { sg_destroy_image( g_iconImage ); g_iconImage.id = 0; }
	if ( g_iconView.id ) { sg_destroy_view( g_iconView ); g_iconView.id = 0; }
	if ( g_atlasSampler.id ) { sg_destroy_sampler( g_atlasSampler ); g_atlasSampler.id = 0; }
	if ( g_sdfShd.id ) { sg_destroy_shader( g_sdfShd ); g_sdfShd.id = 0; }
	sgl_shutdown();
	g_overlayReady = false;
}

/* Upload a font/icon atlas as an RGBA8 image. The app converts the
   alpha-only atlas to RGBA (white with varying alpha) before calling. */
void shim_overlay_upload_atlas( int w, int h, const uint8_t* rgba )
{
	if ( g_atlasImage.id ) { sg_destroy_image( g_atlasImage ); g_atlasImage.id = 0; }
	if ( g_atlasView.id ) { sg_destroy_view( g_atlasView ); g_atlasView.id = 0; }

	sg_image_desc idesc;
	memset( &idesc, 0, sizeof( idesc ) );
	idesc.width = w;
	idesc.height = h;
	idesc.pixel_format = SG_PIXELFORMAT_RGBA8;
	idesc.data.mip_levels[0].ptr = rgba;
	idesc.data.mip_levels[0].size = (size_t)w * h * 4;
	idesc.label = "overlay_atlas";
	g_atlasImage = sg_make_image( &idesc );

	sg_view_desc vdesc;
	memset( &vdesc, 0, sizeof( vdesc ) );
	vdesc.texture.image = g_atlasImage;
	vdesc.label = "overlay_atlas_view";
	g_atlasView = sg_make_view( &vdesc );

	if ( !g_atlasSampler.id )
	{
		sg_sampler_desc sdesc;
		memset( &sdesc, 0, sizeof( sdesc ) );
		sdesc.min_filter = SG_FILTER_LINEAR;
		sdesc.mag_filter = SG_FILTER_LINEAR;
		sdesc.wrap_u = SG_WRAP_CLAMP_TO_EDGE;
		sdesc.wrap_v = SG_WRAP_CLAMP_TO_EDGE;
		sdesc.label = "overlay_atlas_sampler";
		g_atlasSampler = sg_make_sampler( &sdesc );
	}
}

/* A second overlay texture: the app's icon atlas (per-entity portraits,
   status icons, ...). Same upload/quad pattern as the font atlas — the
   overlay supports two textures so a HUD can keep font + icon atlases
   separate. Uploaded (or re-uploaded) whole by the app; the quad below
   samples a tile of it. No-op until the first upload. */
void shim_overlay_upload_icons( int w, int h, const uint8_t* rgba )
{
	if ( g_iconImage.id ) { sg_destroy_image( g_iconImage ); g_iconImage.id = 0; }
	if ( g_iconView.id ) { sg_destroy_view( g_iconView ); g_iconView.id = 0; }

	sg_image_desc idesc;
	memset( &idesc, 0, sizeof( idesc ) );
	idesc.width = w;
	idesc.height = h;
	idesc.pixel_format = SG_PIXELFORMAT_RGBA8;
	idesc.data.mip_levels[0].ptr = rgba;
	idesc.data.mip_levels[0].size = (size_t)w * h * 4;
	idesc.label = "overlay_icons";
	g_iconImage = sg_make_image( &idesc );

	sg_view_desc vdesc;
	memset( &vdesc, 0, sizeof( vdesc ) );
	vdesc.texture.image = g_iconImage;
	vdesc.label = "overlay_icons_view";
	g_iconView = sg_make_view( &vdesc );

	if ( !g_atlasSampler.id )
	{
		sg_sampler_desc sdesc;
		memset( &sdesc, 0, sizeof( sdesc ) );
		sdesc.min_filter = SG_FILTER_LINEAR;
		sdesc.mag_filter = SG_FILTER_LINEAR;
		sdesc.wrap_u = SG_WRAP_CLAMP_TO_EDGE;
		sdesc.wrap_v = SG_WRAP_CLAMP_TO_EDGE;
		sdesc.label = "overlay_atlas_sampler";
		g_atlasSampler = sg_make_sampler( &sdesc );
	}
}

/* Begin an overlay frame: set up ortho projection (origin top-left, Y down)
   and viewport. The app calls this before any overlay draw commands. */
void shim_overlay_begin( int fb_w, int fb_h )
{
	sgl_viewport( 0, 0, fb_w, fb_h, true );
	sgl_scissor_rect( 0, 0, fb_w, fb_h, true );
	sgl_defaults();
	if ( g_overlayPip.id ) { sgl_load_pipeline( g_overlayPip ); }
	sgl_matrix_mode_projection();
	sgl_ortho( 0.0f, (float)fb_w, (float)fb_h, 0.0f, -1.0f, 1.0f );
	sgl_matrix_mode_modelview();
	sgl_load_identity();
}

/* Draw a filled, colored rect (no texture). */
void shim_overlay_rect( float x, float y, float w, float h, float r, float g, float b, float a )
{
	overlay_ensure_identity_texture_matrix();
	sgl_load_pipeline( g_overlayPip );
	sgl_disable_texture();
	sgl_begin_quads();
	sgl_v2f_c4f( x,     y,     r, g, b, a );
	sgl_v2f_c4f( x + w, y,     r, g, b, a );
	sgl_v2f_c4f( x + w, y + h, r, g, b, a );
	sgl_v2f_c4f( x,     y + h, r, g, b, a );
	sgl_end();
}

/* Draw a textured quad (atlas region) with vertex color modulation.
   u0/v0 = top-left UV, u1/v1 = bottom-right UV. Plain-alpha path (the
   app looks up the atlas rect and computes UVs); SDF text uses
   shim_overlay_sdf_quad instead. */
void shim_overlay_textured_quad( float x, float y, float w, float h,
								 float u0, float v0, float u1, float v1,
								 float r, float g, float b, float a )
{
	overlay_ensure_identity_texture_matrix();
	sgl_load_pipeline( g_overlayPip );
	sgl_enable_texture();
	sgl_texture( g_atlasView, g_atlasSampler );
	sgl_begin_quads();
	sgl_v2f_t2f_c4f( x,     y,     u0, v0, r, g, b, a );
	sgl_v2f_t2f_c4f( x + w, y,     u1, v0, r, g, b, a );
	sgl_v2f_t2f_c4f( x + w, y + h, u1, v1, r, g, b, a );
	sgl_v2f_t2f_c4f( x,     y + h, u0, v1, r, g, b, a );
	sgl_end();
}

/* Draw a textured quad from the SECOND overlay texture (the icon atlas),
   rotated about its center by `angle` radians. u0/v0 = top-left UV,
   u1/v1 = bottom-right UV. Screen is Y-down; positive angle tilts the
   quad's right edge up (a sprite's "nose up"). No-op before the first
   upload_icons (the atlas image does not exist yet). */
void shim_overlay_textured_quad_rot( float cx, float cy, float w, float h, float angle,
									 float u0, float v0, float u1, float v1,
									 float r, float g, float b, float a )
{
	if ( !g_iconView.id ) return;
	overlay_ensure_identity_texture_matrix();
	sgl_load_pipeline( g_overlayPip );
	float c = cosf( angle ), s = sinf( angle );
	/* Corners of the w×h rect about the center, in quad order
	   (top-left, top-right, bottom-right, bottom-left). */
	float dx[4] = { -w * 0.5f,  w * 0.5f,  w * 0.5f, -w * 0.5f };
	float dy[4] = { -h * 0.5f, -h * 0.5f,  h * 0.5f,  h * 0.5f };
	float px[4], py[4];
	int i;
	for ( i = 0; i < 4; i++ )
	{
		px[i] = cx + c * dx[i] + s * dy[i];
		py[i] = cy - s * dx[i] + c * dy[i];
	}
	float uv[4][2] = { { u0, v0 }, { u1, v0 }, { u1, v1 }, { u0, v1 } };
	sgl_enable_texture();
	sgl_texture( g_iconView, g_atlasSampler );
	sgl_begin_quads();
	for ( i = 0; i < 4; i++ )
	{
		sgl_v2f_t2f_c4f( px[i], py[i], uv[i][0], uv[i][1], r, g, b, a );
	}
	sgl_end();
}

/* Draw one SDF quad (a glyph's field region): threshold + outline happen
   in the fragment shader. x/y/w/h are FRAMEBUFFER px (top-left origin,
   Y down); u0/v0..u1/v1 bound the glyph's field region in the font atlas;
   r/g/b/a is the ink color (straight 0..1). No-op before the first
   upload_atlas (the font atlas image does not exist yet). */
void shim_overlay_sdf_quad( float x, float y, float w, float h,
							float u0, float v0, float u1, float v1,
							float r, float g, float b, float a )
{
	if ( !g_atlasView.id ) return;
	overlay_sdf_ensure_state();
	sgl_begin_quads();
	sgl_v2f_t2f_c4f( x,     y,     u0, v0, r, g, b, a );
	sgl_v2f_t2f_c4f( x + w, y,     u1, v0, r, g, b, a );
	sgl_v2f_t2f_c4f( x + w, y + h, u1, v1, r, g, b, a );
	sgl_v2f_t2f_c4f( x,     y + h, u0, v1, r, g, b, a );
	sgl_end();
}

/* Set scissor clip rect (origin top-left, Y down). */
void shim_overlay_clip( int x, int y, int w, int h )
{
	sgl_scissor_rect( x, y, w, h, true );
}

/* Disable scissor (full-screen clip). */
void shim_overlay_noclip( void )
{
	/* Will be set to full viewport on next overlay_begin; for now just
	   set a large rect. The app calls overlay_begin each frame which
	   resets to full viewport. */
	sgl_scissor_rect( 0, 0, 65536, 65536, true );
}

/* Mark that overlay commands have been accumulated and should be drawn
   during the next render_frame. Called by the app after all overlay draw
   commands for the frame. */
void shim_overlay_end( void )
{
	g_overlayActive = true;
}