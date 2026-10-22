// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

#include "gfx/renderer.h"

#include "capsule.glsl.h"
#include "cube.glsl.h"
#include "depth_only_capsule.glsl.h"
#include "depth_only_cube.glsl.h"
#include "depth_only_geom.glsl.h"
#include "depth_only_sphere.glsl.h"
#include "geom.glsl.h"
#include "gfx/arena.h"
#include "gfx/edges.h"
#include "gfx/geometry_registry.h"
#include "gfx/gtao.h"
#include "gfx/highlight_mask.h"
#include "gfx/highlight_outline.h"
#include "gfx/highlight_target.h"
#include "gfx/ibl.h"
#include "gfx/overlay.h"
#include "gfx/qsort.h"
#include "gfx/scene_target.h"
#include "gfx/shape_instances.h"
#include "gfx/shadow.h"
#include "gfx/sky.h"
#include "gfx/text.h"
#include "gfx/tone_map.h"
#include "gfx/world_text.h"
#include "shadow_caster_capsule.glsl.h"
#include "shadow_caster_cube.glsl.h"
#include "shadow_caster_geom.glsl.h"
#include "shadow_caster_sphere.glsl.h"
#include "sphere.glsl.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Shape instance arena sizes
#define SHAPE_CAPACITY 65536

// Transparent shape instance arena sizes
#define TRANSPARENT_SHAPE_CAPACITY 1024

static struct
{
	// Unit cube shared by cubes, spheres, and capsules
	sg_buffer vbuf; // 8 unit-cube positions
	sg_buffer ibuf; // 36 indices

	// Cube pipeline + per-instance vertex-attribute buffer (buffer 1).
	sg_buffer cubeInstBuf;
	sg_shader cubeShader;
	sg_pipeline cubePipeline;

	// Sphere-impostor pipeline + per-instance vertex-attribute buffer.
	sg_buffer sphereInstBuf;
	sg_shader sphereShader;
	sg_pipeline spherePipeline;

	// Capsule-impostor pipeline + per-instance vertex-attribute buffer.
	sg_buffer capsuleInstBuf;
	sg_shader capsuleShader;
	sg_pipeline capsulePipeline;

	// Triangle-geometry pipeline (hulls, meshes, heightfields). Per-instance
	// storage and per-geometry vbo/ibo live inside the geometry_registry.
	sg_shader geomShader;
	sg_pipeline geomPipeline;
	// Front-cull sibling for mirror-scaled (negative determinant) instances.
	sg_pipeline geomPipelineMirror;

	// Shadow caster pipeline (cube). Reuses cubeInstBuf, caster and lit
	// pipelines share the same per-instance data, just sample different
	// ub_frame matrices.
	sg_shader shadowCubeShader;
	sg_pipeline shadowCubePipeline;

	// Shadow caster pipeline (geom). Reuses the geom registry's per-entry
	// vbo/ibo + global instance buffer, one draw per entry per cascade,
	// mirroring the lit geom path.
	sg_shader shadowGeomShader;
	sg_pipeline shadowGeomPipeline;
	sg_pipeline shadowGeomPipelineMirror;

	// Shadow caster pipelines (sphere, capsule). Both rasterize the same
	// bounding proxy the lit impostor uses and ray-cast the exact surface,
	// so they borrow the cube's vbuf/ibuf and share the lit pipeline's
	// instance buffers.
	sg_shader shadowSphereShader;
	sg_pipeline shadowSpherePipeline;
	sg_shader shadowCapsuleShader;
	sg_pipeline shadowCapsulePipeline;

	// depth-only pre-pass: dedicated shaders that write positive
	// linear view-space depth into an R32F color attachment. The
	// transient D32F depth attachment is bound alongside for early-Z and
	// closest-fragment selection only, it is never sampled.
	sg_shader depthOnlyCubeShader;
	sg_pipeline depthOnlyCubePipeline;
	Vec4 winDepth;
	sg_shader depthOnlySphereShader;
	sg_pipeline depthOnlySpherePipeline;
	sg_shader depthOnlyCapsuleShader;
	sg_pipeline depthOnlyCapsulePipeline;
	sg_shader depthOnlyGeomShader;
	sg_pipeline depthOnlyGeomPipeline;
	sg_pipeline depthOnlyGeomPipelineMirror;

	int errorCount;

	// Latched by Gpu_DrainGlErrors the first time the GL context reports
	// GL_OUT_OF_MEMORY. Sticky for the process lifetime: a target that
	// failed to allocate is unusable, the only safe recovery is a restart.
	// Apps poll it via GetGpuOutOfMemory() to surface the condition instead
	// of leaving a frozen window.
	bool gpuOom;

	// Per-shape frame arenas. One bump allocator per stream so a stream's
	// entries stay contiguous regardless of how callers interleave DrawCube,
	// DrawSphere, etc. The GPU upload reads each as a single span.
	Arena cubeArena;
	cube_instance_t* cubeBase;
	size_t cubeCount;
	Arena sphereArena;
	sphere_instance_t* sphereBase;
	size_t sphereCount;
	Arena capsuleArena;
	capsule_instance_t* capsuleBase;
	size_t capsuleCount;

	// transparent arenas. Parallel to the opaque arenas above, a single
	// instance never lives in both. Each gets its own GPU buffer + view +
	// pipeline so the opaque path stays byte-identical when no transparent
	// shapes are submitted (no extra apply_bindings, no extra apply_uniforms).
	Arena cubeArenaXp;
	cube_instance_t* cubeBaseXp;
	size_t cubeCountXp;
	Arena sphereArenaXp;
	sphere_instance_t* sphereBaseXp;
	size_t sphereCountXp;
	Arena capsuleArenaXp;
	capsule_instance_t* capsuleBaseXp;
	size_t capsuleCountXp;

	// transparent pipelines + GPU instance buffers. Same shaders as the
	// opaque variants, only blend/depth/sample state differs. Per-instance
	// picks are per-draw vertex buffer offsets into the xp buffers.
	sg_buffer cubeInstBufXp;
	sg_pipeline cubePipelineXp;
	sg_buffer sphereInstBufXp;
	sg_pipeline spherePipelineXp;
	sg_buffer capsuleInstBufXp;
	sg_pipeline capsulePipelineXp;
	sg_pipeline geomPipelineXp;

	// OIT depth peel. Three single-sample distance targets
	// (RGBA16F, .x = linear view distance) + one peel depth target, all at
	// scene size. The lit shape shaders double as the peel shaders:
	// flags.x == 5 makes the FS emit the distance, peel_range gates the
	// per-layer band test (0 in every non-peel pass). The peel pipelines
	// reuse the lit shaders with blend off + depth write on, one variant
	// per compare function (reverse-Z: GREATER = nearer wins, LESS = the
	// next layer behind).
	sg_image oitDist[3];
	sg_view oitDistView[3];
	int oitSizeW, oitSizeH;
	sg_image oitPeelDepth;
	sg_view oitPeelDepthView;
	sg_image oitDummy;	// 1x1 RGBA16F bound into the peel slots on non-peel passes
	sg_view oitDummyView;
	sg_sampler oitPointSampler;
	sg_pipeline oitPeelNearest[4]; // [cube, sphere, capsule, geom]
	sg_pipeline oitPeelFarther[4];

	// Directional light. Persists across frames, SetSun replaces it.
	// Read by DrawScene to populate the lit shaders' ub_pass blocks.
	Sun sun;

	// AgX exposure stop. Applied as pow(2, ev) by the tonemap pass on
	// the resolved HDR scene color. Default set in InitRenderer, SetExposure
	// overrides. Tests/demos can override per-scene if they want to deviate
	// from the spec calibration.
	float exposureEv;

	// AgX-look saturation applied by the tonemap pass after the sigmoid.
	// 1.0 = identity (stock AgX Standard look). SetToneMapSaturation
	// overrides, default set in InitRenderer.
	float tonemapSaturation;

	// IBL master switch for the lit shapes' ambient term. true = image-
	// based lighting from the sky, false = legacy flat ambient
	// (base_color * sun.ambient). Packed into every lit pipeline's
	// ub_pass.ibl_params.y each frame.
	bool iblEnabled;

	// output color format. Captured at InitRenderer from env.defaults.color_format
	// and used as the tonemap pipeline cache key for the swapchain path.
	// Offscreen callers pass their own format through RenderFrameOffscreen.
	sg_pixel_format swapchainColorFormat;

	// Preetham turbidity. Single source of truth for both the sky pass and
	// the IBL cubemap rebuild. Default 2.2 (spec). SetSkyTurbidity marks
	// IBL dirty.
	float turbidity;

	// edge overlay knobs. Default off (edgesDefaultParams), SetEdgeOverlayParams
	// overrides. Consumed by the edge pass each frame.
	EdgeOverlayParams edgeOverlay;

	// highlight outline knobs. Defaults from GetDefaultHighlightParams(),
	// SetHighlightParams overrides. Consumed by the outline pass each
	// frame. The mask pass itself is unconditional, it only runs when the
	// adapter submits any hover/select instances.
	HighlightParams highlight;

	// stats snapshot from the last completed frame. Populated at the
	// end of RenderFrame / RenderFrameOffscreen.
	RenderStats stats;

	// last-frame camera state for post-scene consumers (the UI overlay the
	// app draws after RenderFrame). Latched at the top of each render
	// entry point.
	CameraState cameraState;
} s_gfx;

// Per-instance vertex attribute binding for buffer 1. One FLOAT4 attribute
// per instance-struct field (see shape_instances.h); the buffer offset
// comes from offsetof so C and shader layouts cannot drift. step_func PER_INSTANCE / step_rate 1 on
// buffers[1] is set by the caller.
static void InstAttr( sg_pipeline_desc* pd, int attr, size_t offset )
{
	pd->layout.attrs[attr].format = SG_VERTEXFORMAT_FLOAT4;
	pd->layout.attrs[attr].buffer_index = 1;
	pd->layout.attrs[attr].offset = (int)offset;
}



static void OnSokolLog( const char* tag, uint32_t logLevel, uint32_t logItemId, const char* message, uint32_t lineNr,
						const char* filename, void* userData )
{
	(void)logItemId;
	(void)userData;
	const char* levelName = ( logLevel == 0 ) ? "panic" : ( logLevel == 1 ) ? "error" : ( logLevel == 2 ) ? "warn" : "info";
	fprintf( stderr, "[%s/%s] %s (%s:%u)\n", tag ? tag : "?", levelName, message ? message : "(no message)",
			 filename ? filename : "?", (unsigned)lineNr );
	if ( logLevel <= 1 )
	{
		s_gfx.errorCount++;
	}
}

// Cube geometry
// 8 corners of a unit cube centered at origin (half-extent 0.5). Per-vertex
// data is just position, flat shading is recovered in the fragment shader
// via dFdx/dFdy of view-space position, so no per-vertex normals are needed.
static const float CUBE_VERTS[8 * 3] = {
	-0.5f, -0.5f, -0.5f, // 0: (-,-,-)
	0.5f,  -0.5f, -0.5f, // 1: (+,-,-)
	-0.5f, 0.5f,  -0.5f, // 2: (-,+,-)
	0.5f,  0.5f,  -0.5f, // 3: (+,+,-)
	-0.5f, -0.5f, 0.5f,	 // 4: (-,-,+)
	0.5f,  -0.5f, 0.5f,	 // 5: (+,-,+)
	-0.5f, 0.5f,  0.5f,	 // 6: (-,+,+)
	0.5f,  0.5f,  0.5f,	 // 7: (+,+,+)
};

// CCW outward winding, pipeline cull mode = BACK, face_winding = CCW.
static const uint16_t CUBE_INDICES[36] = {
	0, 4, 6, 0, 6, 2, // -X
	1, 3, 7, 1, 7, 5, // +X
	0, 1, 5, 0, 5, 4, // -Y
	2, 6, 7, 2, 7, 3, // +Y
	0, 2, 3, 0, 3, 1, // -Z
	4, 5, 7, 4, 7, 6, // +Z
};

// GL backend: set clip-space Z to [0,1] so the rasterizer's gl_FragCoord.z
// matches the impostors' gl_FragDepth writes (see ConfigureGLClipControl).
// D3D11 and Metal are natively [0,1] in clip space.
#if defined( SOKOL_GLCORE )
#include <dlfcn.h>

#ifndef GL_LOWER_LEFT
#define GL_LOWER_LEFT 0x8CA1
#endif
#ifndef GL_ZERO_TO_ONE
#define GL_ZERO_TO_ONE 0x935F
#endif
#ifndef GL_VENDOR
#define GL_VENDOR 0x1F00
#endif
#ifndef GL_RENDERER
#define GL_RENDERER 0x1F01
#endif

typedef void ( *PFN_glClipControl )( uint32_t origin, uint32_t depth );
typedef const unsigned char* ( *PFN_glGetString )( uint32_t name );

static void ConfigureGLClipControl( void )
{
	// Hard requirement: without [0,1] clip-space Z, reverse-Z is a no-op
	// (GL's default [-1,1] mapping wastes all the float precision in the
	// middle of the range) and the GREATER compare between rasterized
	// geometry and impostor gl_FragDepth writes is broken. Abort rather
	// than render with a silently-wrong depth pipeline.
	void* libgl = dlopen( "libGL.so.1", RTLD_LAZY | RTLD_GLOBAL );
	if ( !libgl )
	{
		fprintf( stderr, "[gfx/fatal] clip control: dlopen libGL.so.1 failed: %s\n", dlerror() );
		abort();
	}
	// POSIX dlsym returns void*, ISO C forbids the direct cast to a function
	// pointer. The void**-aliasing dance is the standard workaround.
	PFN_glClipControl fn = NULL;
	*(void**)( &fn ) = dlsym( libgl, "glClipControl" );
	if ( !fn )
	{
		fprintf( stderr, "[gfx/fatal] clip control: glClipControl symbol not found "
						 "(GL 4.5 / ARB_clip_control required)\n" );
		abort();
	}
	fn( GL_LOWER_LEFT, GL_ZERO_TO_ONE );
}

static void LogGLDeviceInfo( void )
{
	void* libgl = dlopen( "libGL.so.1", RTLD_LAZY | RTLD_GLOBAL );
	if ( !libgl )
	{
		fprintf( stderr, "[gfx/info] GPU: dlopen libGL.so.1 failed: %s\n", dlerror() );
		return;
	}
	PFN_glGetString fn = NULL;
	*(void**)( &fn ) = dlsym( libgl, "glGetString" );
	if ( !fn )
	{
		fprintf( stderr, "[gfx/info] GPU: glGetString symbol not found\n" );
		return;
	}
	const unsigned char* renderer = fn( GL_RENDERER );
	const unsigned char* vendor = fn( GL_VENDOR );
	fprintf( stderr, "[gfx/info] GPU: %s (%s)\n", renderer ? (const char*)renderer : "unknown",
			 vendor ? (const char*)vendor : "unknown" );
}
#endif

// ── GL error drain: VRAM-exhaustion detection ────────────────────────
// GL reports a failed allocation as a latched error code, and sokol_gfx's
// release build never calls glGetError(), so a VRAM-exhausted target would
// come back "valid" with no storage and every bound pass would render into
// nothing. Drain once per frame, latch GL_OUT_OF_MEMORY for
// GetGpuOutOfMemory(). GL-only: WebGPU reports exhaustion as device-lost.
#define GFX_GL_OUT_OF_MEMORY 0x0505 // GL_OUT_OF_MEMORY

#if defined( SOKOL_GLCORE )
typedef uint32_t ( *PFN_glGetError )( void );
static PFN_glGetError s_glGetError;

static void Gpu_DrainGlErrors( void )
{
	if ( !s_glGetError )
	{
		// dlopened like glClipControl/glGetString above: this TU does not
		// pull in the GL headers (the sokol impl TU does).
		void* libgl = dlopen( "libGL.so.1", RTLD_LAZY | RTLD_GLOBAL );
		if ( libgl )
		{
			PFN_glGetError fn = NULL;
			*(void**)( &fn ) = dlsym( libgl, "glGetError" );
			s_glGetError = fn;
		}
	}
	if ( !s_glGetError )
	{
		return;
	}
	uint32_t err;
	while ( ( err = s_glGetError() ) != 0 )
	{
		if ( err == GFX_GL_OUT_OF_MEMORY && !s_gfx.gpuOom )
		{
			s_gfx.gpuOom = true;
			fprintf( stderr, "[gfx/error] GL_OUT_OF_MEMORY: GPU allocation failed. "
							 "The affected render targets are unusable and the window "
							 "may be frozen; free GPU memory or restart the app.\n" );
		}
	}
}
#else
static void Gpu_DrainGlErrors( void ) { }
#endif

// public API

void InitRenderer( const sg_environment* env )
{
	sg_desc desc = { 0 };
	desc.environment = *env;
	desc.logger.func = OnSokolLog;

	// Sokol's default buffer/view pools are 128/256, which exhausts on scenes that register many unique geometries.
	// The geometry registry holds up to MAX_REGISTRY_ENTRIES (4096) entries, each consuming 3 buffers (vertex,
	// index, edge) and 1 edge view. Size the pools past 4096 entries worth so the registry cap, which degrades
	// gracefully, is the binding limit rather than a sokol pool assert. Pool slots are small structs, a few MB total.
	desc.buffer_pool_size = 16384;
	desc.view_pool_size = 8192;
	sg_setup( &desc );

#if defined( SOKOL_GLCORE )
	ConfigureGLClipControl();
	LogGLDeviceInfo();
#endif

	sg_buffer_desc vdesc = { 0 };
	vdesc.usage.vertex_buffer = true;
	vdesc.data.ptr = CUBE_VERTS;
	vdesc.data.size = sizeof( CUBE_VERTS );
	vdesc.label = "cube_verts";
	s_gfx.vbuf = sg_make_buffer( &vdesc );

	sg_buffer_desc idesc = { 0 };
	idesc.usage.index_buffer = true;
	idesc.data.ptr = CUBE_INDICES;
	idesc.data.size = sizeof( CUBE_INDICES );
	idesc.label = "cube_indices";
	s_gfx.ibuf = sg_make_buffer( &idesc );

	// Per-instance shape data is vertex-attribute data on buffer 1 (step
	// rate 1): one FLOAT4 attribute per instance-struct field, buffer
	// offsets via offsetof(shape_instances.h). Per-draw instance picks use
	// the per-binding vertex buffer offset (sg_bindings
	// .vertex_buffer_offsets). Same layout on every backend, WebGL2
	// (ESSL 3.00) included.
	//
	// Cube pipeline
	sg_buffer_desc cubeInstDesc = { 0 };
	cubeInstDesc.usage.vertex_buffer = true;
	cubeInstDesc.usage.stream_update = true;
	cubeInstDesc.size = (size_t)SHAPE_CAPACITY * sizeof( cube_instance_t );
	cubeInstDesc.label = "cube_instances";
	s_gfx.cubeInstBuf = sg_make_buffer( &cubeInstDesc );

	s_gfx.cubeShader = sg_make_shader( cube_shader_desc( sg_query_backend() ) );

	sg_pipeline_desc cubePdesc = { 0 };
	cubePdesc.shader = s_gfx.cubeShader;
	cubePdesc.layout.buffers[0].stride = sizeof( float ) * 3;
	cubePdesc.layout.attrs[ATTR_cube_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	cubePdesc.layout.attrs[ATTR_cube_in_pos].buffer_index = 0;
	cubePdesc.layout.buffers[1].stride = (int)sizeof( cube_instance_t );
	cubePdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	cubePdesc.layout.buffers[1].step_rate = 1;
	InstAttr( &cubePdesc, ATTR_cube_inst_xform_row0, offsetof( cube_instance_t, xform_row0 ) );
	InstAttr( &cubePdesc, ATTR_cube_inst_xform_row1, offsetof( cube_instance_t, xform_row1 ) );
	InstAttr( &cubePdesc, ATTR_cube_inst_xform_row2, offsetof( cube_instance_t, xform_row2 ) );
	InstAttr( &cubePdesc, ATTR_cube_inst_base_color, offsetof( cube_instance_t, base_color ) );
	InstAttr( &cubePdesc, ATTR_cube_inst_material, offsetof( cube_instance_t, material ) );
	cubePdesc.index_type = SG_INDEXTYPE_UINT16;
	// Color attachment is the HDR scene target (RGBA16F MSAA, resolved
	// single-sample for the tonemap pass). Depth format mirrors the
	// environment's default, sokol_app reports DEPTH_STENCIL on every
	// backend, and the scene target's MSAA depth image uses the same.
	cubePdesc.colors[0].pixel_format = SG_PIXELFORMAT_RGBA16F;
	cubePdesc.color_count = 1;
	cubePdesc.depth.pixel_format = env->defaults.depth_format;
	cubePdesc.depth.compare = SG_COMPAREFUNC_GREATER;
	cubePdesc.depth.write_enabled = true;
	cubePdesc.cull_mode = SG_CULLMODE_BACK;
	cubePdesc.face_winding = SG_FACEWINDING_CCW;
	cubePdesc.sample_count = SCENE_SAMPLE_COUNT;
	cubePdesc.label = "cube_pipeline";
	s_gfx.cubePipeline = sg_make_pipeline( &cubePdesc );

	// Sphere-impostor pipeline
	// Reuses cube vbuf/ibuf for the bounding-cube proxy. Cull mode FRONT,
	// the sphere lives entirely inside the proxy, so the back faces are
	// strictly closer to the camera than the front ones, raster the back
	// faces and the impostor still draws the same image while staying
	// visible when the camera is inside the proxy AABB but outside the
	// sphere itself. (Front-face cull is the standard impostor trick).
	sg_buffer_desc sphereInstDesc = { 0 };
	sphereInstDesc.usage.vertex_buffer = true;
	sphereInstDesc.usage.stream_update = true;
	sphereInstDesc.size = (size_t)SHAPE_CAPACITY * sizeof( sphere_instance_t );
	sphereInstDesc.label = "sphere_instances";
	s_gfx.sphereInstBuf = sg_make_buffer( &sphereInstDesc );

	s_gfx.sphereShader = sg_make_shader( sphere_impostor_shader_desc( sg_query_backend() ) );

	sg_pipeline_desc spherePdesc = { 0 };
	spherePdesc.shader = s_gfx.sphereShader;
	spherePdesc.layout.buffers[0].stride = sizeof( float ) * 3;
	spherePdesc.layout.attrs[ATTR_sphere_impostor_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	spherePdesc.layout.attrs[ATTR_sphere_impostor_in_pos].buffer_index = 0;
	spherePdesc.layout.buffers[1].stride = (int)sizeof( sphere_instance_t );
	spherePdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	spherePdesc.layout.buffers[1].step_rate = 1;
	InstAttr( &spherePdesc, ATTR_sphere_impostor_inst_xform_row0, offsetof( sphere_instance_t, xform_row0 ) );
	InstAttr( &spherePdesc, ATTR_sphere_impostor_inst_xform_row1, offsetof( sphere_instance_t, xform_row1 ) );
	InstAttr( &spherePdesc, ATTR_sphere_impostor_inst_xform_row2, offsetof( sphere_instance_t, xform_row2 ) );
	InstAttr( &spherePdesc, ATTR_sphere_impostor_inst_base_color, offsetof( sphere_instance_t, base_color ) );
	InstAttr( &spherePdesc, ATTR_sphere_impostor_inst_params, offsetof( sphere_instance_t, params ) );
	InstAttr( &spherePdesc, ATTR_sphere_impostor_inst_material, offsetof( sphere_instance_t, material ) );
	InstAttr( &spherePdesc, ATTR_sphere_impostor_inst_cap_color, offsetof( sphere_instance_t, cap_color ) );
	spherePdesc.index_type = SG_INDEXTYPE_UINT16;
	spherePdesc.colors[0].pixel_format = SG_PIXELFORMAT_RGBA16F;
	spherePdesc.color_count = 1;
	spherePdesc.depth.pixel_format = env->defaults.depth_format;
	spherePdesc.depth.compare = SG_COMPAREFUNC_GREATER;
	spherePdesc.depth.write_enabled = true;
	spherePdesc.cull_mode = SG_CULLMODE_FRONT;
	spherePdesc.face_winding = SG_FACEWINDING_CCW;
	spherePdesc.sample_count = SCENE_SAMPLE_COUNT;
	// Analytical silhouette AA: the FS writes a sub-pixel coverage value
	// into alpha (see vendor/box3d/samples/shaders/shapes/sphere.glsl).
	// At MSAA this maps it to the sample mask. At sample_count=1
	// alpha-to-coverage would degenerate to an alpha test, which is why
	// the transparent variant turns it back off and relies on the
	// premultiplied alpha blend instead.
	spherePdesc.alpha_to_coverage_enabled = true;
	spherePdesc.label = "sphere_pipeline";
	s_gfx.spherePipeline = sg_make_pipeline( &spherePdesc );

	// Capsule-impostor pipeline
	// Reuses cube vbuf/ibuf for the OBB proxy (the VS scales the unit cube
	// non-uniformly per instance to match each capsule's bounds). Cull mode
	// FRONT, same impostor trick as the sphere pipeline.
	sg_buffer_desc capsuleInstDesc = { 0 };
	capsuleInstDesc.usage.vertex_buffer = true;
	capsuleInstDesc.usage.stream_update = true;
	capsuleInstDesc.size = (size_t)SHAPE_CAPACITY * sizeof( capsule_instance_t );
	capsuleInstDesc.label = "capsule_instances";
	s_gfx.capsuleInstBuf = sg_make_buffer( &capsuleInstDesc );

	s_gfx.capsuleShader = sg_make_shader( capsule_impostor_shader_desc( sg_query_backend() ) );

	sg_pipeline_desc capsulePdesc = { 0 };
	capsulePdesc.shader = s_gfx.capsuleShader;
	capsulePdesc.layout.buffers[0].stride = sizeof( float ) * 3;
	capsulePdesc.layout.attrs[ATTR_capsule_impostor_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	capsulePdesc.layout.attrs[ATTR_capsule_impostor_in_pos].buffer_index = 0;
	capsulePdesc.layout.buffers[1].stride = (int)sizeof( capsule_instance_t );
	capsulePdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	capsulePdesc.layout.buffers[1].step_rate = 1;
	InstAttr( &capsulePdesc, ATTR_capsule_impostor_inst_xform_row0, offsetof( capsule_instance_t, xform_row0 ) );
	InstAttr( &capsulePdesc, ATTR_capsule_impostor_inst_xform_row1, offsetof( capsule_instance_t, xform_row1 ) );
	InstAttr( &capsulePdesc, ATTR_capsule_impostor_inst_xform_row2, offsetof( capsule_instance_t, xform_row2 ) );
	InstAttr( &capsulePdesc, ATTR_capsule_impostor_inst_base_color, offsetof( capsule_instance_t, base_color ) );
	InstAttr( &capsulePdesc, ATTR_capsule_impostor_inst_params, offsetof( capsule_instance_t, params ) );
	InstAttr( &capsulePdesc, ATTR_capsule_impostor_inst_material, offsetof( capsule_instance_t, material ) );
	capsulePdesc.index_type = SG_INDEXTYPE_UINT16;
	capsulePdesc.colors[0].pixel_format = SG_PIXELFORMAT_RGBA16F;
	capsulePdesc.color_count = 1;
	capsulePdesc.depth.pixel_format = env->defaults.depth_format;
	capsulePdesc.depth.compare = SG_COMPAREFUNC_GREATER;
	capsulePdesc.depth.write_enabled = true;
	capsulePdesc.cull_mode = SG_CULLMODE_FRONT;
	capsulePdesc.face_winding = SG_FACEWINDING_CCW;
	capsulePdesc.sample_count = SCENE_SAMPLE_COUNT;
	// Analytical silhouette AA. See spherePdesc above for the rationale.
	capsulePdesc.alpha_to_coverage_enabled = true;
	capsulePdesc.label = "capsule_pipeline";
	s_gfx.capsulePipeline = sg_make_pipeline( &capsulePdesc );

	// Triangle mesh pipeline
	// Real geometry uploaded per-registry-entry, no proxy. Each draw rebinds
	// the entry's vbo/ibo and sets the per-binding vertex buffer offset so
	// the instance attributes fetch that mesh's slice of the global
	// instance buffer. Cull mode BACK, CCW winding, the builders emit CCW
	// outward triangles for hulls and CCW upward for heightfields, mesh
	// winding follows whatever the source data carries.
	CreateMeshRegistry();

	s_gfx.geomShader = sg_make_shader( geom_triangle_shader_desc( sg_query_backend() ) );

	sg_pipeline_desc geomPdesc = { 0 };
	geomPdesc.shader = s_gfx.geomShader;
	geomPdesc.layout.buffers[0].stride = sizeof( float ) * 6;
	geomPdesc.layout.attrs[ATTR_geom_triangle_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	geomPdesc.layout.attrs[ATTR_geom_triangle_in_pos].buffer_index = 0;
	geomPdesc.layout.attrs[ATTR_geom_triangle_in_pos].offset = 0;
	geomPdesc.layout.attrs[ATTR_geom_triangle_in_normal].format = SG_VERTEXFORMAT_FLOAT3;
	geomPdesc.layout.attrs[ATTR_geom_triangle_in_normal].buffer_index = 0;
	geomPdesc.layout.attrs[ATTR_geom_triangle_in_normal].offset = sizeof( float ) * 3;
	geomPdesc.layout.buffers[1].stride = (int)sizeof( geom_instance_t );
	geomPdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	geomPdesc.layout.buffers[1].step_rate = 1;
	InstAttr( &geomPdesc, ATTR_geom_triangle_inst_xform_row0, offsetof( geom_instance_t, xform_row0 ) );
	InstAttr( &geomPdesc, ATTR_geom_triangle_inst_xform_row1, offsetof( geom_instance_t, xform_row1 ) );
	InstAttr( &geomPdesc, ATTR_geom_triangle_inst_xform_row2, offsetof( geom_instance_t, xform_row2 ) );
	InstAttr( &geomPdesc, ATTR_geom_triangle_inst_base_color, offsetof( geom_instance_t, base_color ) );
	InstAttr( &geomPdesc, ATTR_geom_triangle_inst_scale, offsetof( geom_instance_t, scale ) );
	InstAttr( &geomPdesc, ATTR_geom_triangle_inst_material, offsetof( geom_instance_t, material ) );
	geomPdesc.index_type = SG_INDEXTYPE_UINT32;
	geomPdesc.colors[0].pixel_format = SG_PIXELFORMAT_RGBA16F;
	geomPdesc.color_count = 1;
	geomPdesc.depth.pixel_format = env->defaults.depth_format;
	geomPdesc.depth.compare = SG_COMPAREFUNC_GREATER;
	geomPdesc.depth.write_enabled = true;
	// Back-cull the common case. A mesh instance may carry a negative
	// determinant scale that flips winding, those are partitioned out by the
	// registry and drawn with the front-cull sibling below. The FS faces the
	// shading normal toward the camera, so both pipelines shade correctly.
	geomPdesc.cull_mode = SG_CULLMODE_BACK;
	geomPdesc.face_winding = SG_FACEWINDING_CCW;
	geomPdesc.sample_count = SCENE_SAMPLE_COUNT;
	geomPdesc.label = "geom_pipeline";
	s_gfx.geomPipeline = sg_make_pipeline( &geomPdesc );

	sg_pipeline_desc geomMirrorPdesc = geomPdesc;
	geomMirrorPdesc.cull_mode = SG_CULLMODE_FRONT;
	geomMirrorPdesc.label = "geom_pipeline_mirror";
	s_gfx.geomPipelineMirror = sg_make_pipeline( &geomMirrorPdesc );

	InitShadows();

	// Shadow caster pipeline: cubes
	// Depth-only (the WGPU dummy color target below is never read).
	// Depth format must match the shadow depth texture's D32F
	// (SG_PIXELFORMAT_DEPTH). Compare LESS (standard Z, not reverse-Z)
	// and write enabled.
	s_gfx.shadowCubeShader = sg_make_shader( shadow_cube_caster_shader_desc( sg_query_backend() ) );

	sg_pipeline_desc shadowCubePdesc = { 0 };
	shadowCubePdesc.shader = s_gfx.shadowCubeShader;
	shadowCubePdesc.layout.buffers[0].stride = sizeof( float ) * 3;
	shadowCubePdesc.layout.attrs[ATTR_shadow_cube_caster_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	shadowCubePdesc.layout.attrs[ATTR_shadow_cube_caster_in_pos].buffer_index = 0;
	shadowCubePdesc.layout.buffers[1].stride = (int)sizeof( cube_instance_t );
	shadowCubePdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	shadowCubePdesc.layout.buffers[1].step_rate = 1;
	InstAttr( &shadowCubePdesc, ATTR_shadow_cube_caster_inst_xform_row0, offsetof( cube_instance_t, xform_row0 ) );
	InstAttr( &shadowCubePdesc, ATTR_shadow_cube_caster_inst_xform_row1, offsetof( cube_instance_t, xform_row1 ) );
	InstAttr( &shadowCubePdesc, ATTR_shadow_cube_caster_inst_xform_row2, offsetof( cube_instance_t, xform_row2 ) );
	shadowCubePdesc.index_type = SG_INDEXTYPE_UINT16;

	// FORK (wasm/WGPU): the cascade pass carries a throwaway RGBA8 color
	// attachment (WebGPU depth-only passes silently never write depth — see
	// the dummyColor comment in shadow.c), so the caster pipelines declare
	// that color target. The FS emits a constant; the value is never read.
	shadowCubePdesc.colors[0].pixel_format = SG_PIXELFORMAT_RGBA8;
	shadowCubePdesc.color_count = 1;
	shadowCubePdesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	shadowCubePdesc.depth.compare = SG_COMPAREFUNC_LESS;
	shadowCubePdesc.depth.write_enabled = true;
	shadowCubePdesc.cull_mode = SG_CULLMODE_BACK;
	shadowCubePdesc.face_winding = SG_FACEWINDING_CCW;

	// Shadow attachments are single-sample. The env default sample_count is
	// now 4 (lit-path MSAA), so we must override here. Otherwise pipelines
	// pick up the env default and fail validation against shadow passes.
	shadowCubePdesc.sample_count = 1;
	shadowCubePdesc.label = "shadow_cube_pipeline";
	s_gfx.shadowCubePipeline = sg_make_pipeline( &shadowCubePdesc );

	// Shadow caster pipeline: mesh
	// Same depth-only setup as the cube caster. The per-entry vbo/ibo and
	// per-draw vertex buffer offset come from the geometry_registry,
	// identical to the lit geom pipeline.
	s_gfx.shadowGeomShader = sg_make_shader( shadow_geom_caster_shader_desc( sg_query_backend() ) );

	sg_pipeline_desc shadowGeomPdesc = { 0 };
	shadowGeomPdesc.shader = s_gfx.shadowGeomShader;

	// Stride matches the lit geom pipeline (position+normal interleaved),
	// but the caster shader only declares in_pos, the normal slot in
	// each vertex is skipped, which is fine.
	shadowGeomPdesc.layout.buffers[0].stride = sizeof( float ) * 6;
	shadowGeomPdesc.layout.attrs[ATTR_shadow_geom_caster_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	shadowGeomPdesc.layout.attrs[ATTR_shadow_geom_caster_in_pos].buffer_index = 0;
	shadowGeomPdesc.layout.attrs[ATTR_shadow_geom_caster_in_pos].offset = 0;
	shadowGeomPdesc.layout.buffers[1].stride = (int)sizeof( geom_instance_t );
	shadowGeomPdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	shadowGeomPdesc.layout.buffers[1].step_rate = 1;
	InstAttr( &shadowGeomPdesc, ATTR_shadow_geom_caster_inst_xform_row0, offsetof( geom_instance_t, xform_row0 ) );
	InstAttr( &shadowGeomPdesc, ATTR_shadow_geom_caster_inst_xform_row1, offsetof( geom_instance_t, xform_row1 ) );
	InstAttr( &shadowGeomPdesc, ATTR_shadow_geom_caster_inst_xform_row2, offsetof( geom_instance_t, xform_row2 ) );
	InstAttr( &shadowGeomPdesc, ATTR_shadow_geom_caster_inst_scale, offsetof( geom_instance_t, scale ) );
	shadowGeomPdesc.index_type = SG_INDEXTYPE_UINT32;
	shadowGeomPdesc.colors[0].pixel_format = SG_PIXELFORMAT_RGBA8; // FORK (wgpu) dummy target, see shadow.c
	shadowGeomPdesc.color_count = 1;
	shadowGeomPdesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	shadowGeomPdesc.depth.compare = SG_COMPAREFUNC_LESS;
	shadowGeomPdesc.depth.write_enabled = true;
	shadowGeomPdesc.cull_mode = SG_CULLMODE_BACK; // match geom pipeline, mirror runs use the front-cull sibling
	shadowGeomPdesc.face_winding = SG_FACEWINDING_CCW;
	shadowGeomPdesc.sample_count = 1;
	shadowGeomPdesc.label = "shadow_geom_pipeline";
	s_gfx.shadowGeomPipeline = sg_make_pipeline( &shadowGeomPdesc );

	sg_pipeline_desc shadowGeomMirrorPdesc = shadowGeomPdesc;
	shadowGeomMirrorPdesc.cull_mode = SG_CULLMODE_FRONT;
	shadowGeomMirrorPdesc.label = "shadow_geom_pipeline_mirror";
	s_gfx.shadowGeomPipelineMirror = sg_make_pipeline( &shadowGeomMirrorPdesc );

	// Shadow caster pipeline: spheres
	// Rasterizes the bounding cube the lit impostor uses, so it borrows the
	// cube's buffers and vertex format. Culling stays on back faces: the
	// shader's conservative-depth promise only holds while the rasterized
	// surface is the light-facing one.
	s_gfx.shadowSphereShader = sg_make_shader( shadow_sphere_caster_shader_desc( sg_query_backend() ) );

	sg_pipeline_desc shadowSpherePdesc = { 0 };
	shadowSpherePdesc.shader = s_gfx.shadowSphereShader;
	shadowSpherePdesc.layout.buffers[0].stride = sizeof( float ) * 3;
	shadowSpherePdesc.layout.attrs[ATTR_shadow_sphere_caster_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	shadowSpherePdesc.layout.attrs[ATTR_shadow_sphere_caster_in_pos].buffer_index = 0;
	shadowSpherePdesc.layout.buffers[1].stride = (int)sizeof( sphere_instance_t );
	shadowSpherePdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	shadowSpherePdesc.layout.buffers[1].step_rate = 1;
	InstAttr( &shadowSpherePdesc, ATTR_shadow_sphere_caster_inst_xform_row0, offsetof( sphere_instance_t, xform_row0 ) );
	InstAttr( &shadowSpherePdesc, ATTR_shadow_sphere_caster_inst_xform_row1, offsetof( sphere_instance_t, xform_row1 ) );
	InstAttr( &shadowSpherePdesc, ATTR_shadow_sphere_caster_inst_xform_row2, offsetof( sphere_instance_t, xform_row2 ) );
	InstAttr( &shadowSpherePdesc, ATTR_shadow_sphere_caster_inst_params, offsetof( sphere_instance_t, params ) );
	shadowSpherePdesc.index_type = SG_INDEXTYPE_UINT16;
	shadowSpherePdesc.colors[0].pixel_format = SG_PIXELFORMAT_RGBA8; // FORK (wgpu) dummy target, see shadow.c
	shadowSpherePdesc.color_count = 1;
	shadowSpherePdesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	shadowSpherePdesc.depth.compare = SG_COMPAREFUNC_LESS;
	shadowSpherePdesc.depth.write_enabled = true;
	shadowSpherePdesc.cull_mode = SG_CULLMODE_BACK;
	shadowSpherePdesc.face_winding = SG_FACEWINDING_CCW;
	shadowSpherePdesc.sample_count = 1;
	shadowSpherePdesc.label = "shadow_sphere_pipeline";
	s_gfx.shadowSpherePipeline = sg_make_pipeline( &shadowSpherePdesc );

	// Shadow caster pipeline: capsules, see the sphere caster above. The
	// OBB comes from the same cube buffers.
	s_gfx.shadowCapsuleShader = sg_make_shader( shadow_capsule_caster_shader_desc( sg_query_backend() ) );

	sg_pipeline_desc shadowCapsulePdesc = { 0 };
	shadowCapsulePdesc.shader = s_gfx.shadowCapsuleShader;
	shadowCapsulePdesc.layout.buffers[0].stride = sizeof( float ) * 3;
	shadowCapsulePdesc.layout.attrs[ATTR_shadow_capsule_caster_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	shadowCapsulePdesc.layout.attrs[ATTR_shadow_capsule_caster_in_pos].buffer_index = 0;
	shadowCapsulePdesc.layout.buffers[1].stride = (int)sizeof( capsule_instance_t );
	shadowCapsulePdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	shadowCapsulePdesc.layout.buffers[1].step_rate = 1;
	InstAttr( &shadowCapsulePdesc, ATTR_shadow_capsule_caster_inst_xform_row0, offsetof( capsule_instance_t, xform_row0 ) );
	InstAttr( &shadowCapsulePdesc, ATTR_shadow_capsule_caster_inst_xform_row1, offsetof( capsule_instance_t, xform_row1 ) );
	InstAttr( &shadowCapsulePdesc, ATTR_shadow_capsule_caster_inst_xform_row2, offsetof( capsule_instance_t, xform_row2 ) );
	InstAttr( &shadowCapsulePdesc, ATTR_shadow_capsule_caster_inst_params, offsetof( capsule_instance_t, params ) );
	shadowCapsulePdesc.index_type = SG_INDEXTYPE_UINT16;
	shadowCapsulePdesc.colors[0].pixel_format = SG_PIXELFORMAT_RGBA8; // FORK (wgpu) dummy target, see shadow.c
	shadowCapsulePdesc.color_count = 1;
	shadowCapsulePdesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	shadowCapsulePdesc.depth.compare = SG_COMPAREFUNC_LESS;
	shadowCapsulePdesc.depth.write_enabled = true;
	shadowCapsulePdesc.cull_mode = SG_CULLMODE_BACK;
	shadowCapsulePdesc.face_winding = SG_FACEWINDING_CCW;
	shadowCapsulePdesc.sample_count = 1;
	shadowCapsulePdesc.label = "shadow_capsule_pipeline";
	s_gfx.shadowCapsulePipeline = sg_make_pipeline( &shadowCapsulePdesc );

	// Depth-only pre-pass pipelines
	// Renders all opaque shapes from the main camera into a depth target
	// (rasterizer / early-Z) and an R32F color target carrying positive
	// linear view-space depth. The GTAO compute pipeline reconstructs
	// normals from depth derivatives, so no normal channel is produced
	// here. Sphere/capsule pipelines reuse the lit impostor pattern.
	// Cubes and mesh use the standard raster path.

	// NDC -> window-depth affine for the impostors' gl_FragDepth writes
	// (the shaders compute ndc_z * slope + bias). The app's projection is
	// 0..1 clip-Z (near -> 1, far -> 0), so the window depth depends on
	// the backend's clip-Z range: GLCORE sets GL_ZERO..GL_ONE and WGPU's
	// frag_depth is NDC [0,1] (both identity); GLES3 (incl. WebGL2) has
	// no clip control and keeps GL's default [-1,+1], so window depth =
	// (ndc_z + 1) / 2 - the identity would make impostors in front of
	// the ground fail the reverse-Z GREATER test and vanish.
#if defined( SOKOL_GLES3 )
	s_gfx.winDepth = MakeVec4( 0.5f, 0.5f, 0.0f, 0.0f );
#else
	s_gfx.winDepth = MakeVec4( 1.0f, 0.0f, 0.0f, 0.0f );
#endif

	s_gfx.depthOnlyCubeShader = sg_make_shader( depth_only_cube_prog_shader_desc( sg_query_backend() ) );

	sg_pipeline_desc dnCubePdesc = { 0 };
	dnCubePdesc.shader = s_gfx.depthOnlyCubeShader;
	dnCubePdesc.layout.buffers[0].stride = sizeof( float ) * 3;
	dnCubePdesc.layout.attrs[ATTR_depth_only_cube_prog_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	dnCubePdesc.layout.attrs[ATTR_depth_only_cube_prog_in_pos].buffer_index = 0;
	dnCubePdesc.layout.buffers[1].stride = (int)sizeof( cube_instance_t );
	dnCubePdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	dnCubePdesc.layout.buffers[1].step_rate = 1;
	InstAttr( &dnCubePdesc, ATTR_depth_only_cube_prog_inst_xform_row0, offsetof( cube_instance_t, xform_row0 ) );
	InstAttr( &dnCubePdesc, ATTR_depth_only_cube_prog_inst_xform_row1, offsetof( cube_instance_t, xform_row1 ) );
	InstAttr( &dnCubePdesc, ATTR_depth_only_cube_prog_inst_xform_row2, offsetof( cube_instance_t, xform_row2 ) );
	dnCubePdesc.index_type = SG_INDEXTYPE_UINT16;
	dnCubePdesc.colors[0].pixel_format = SG_PIXELFORMAT_R32F;
	dnCubePdesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	dnCubePdesc.depth.compare = SG_COMPAREFUNC_GREATER;
	dnCubePdesc.depth.write_enabled = true;
	dnCubePdesc.cull_mode = SG_CULLMODE_BACK;
	dnCubePdesc.face_winding = SG_FACEWINDING_CCW;
	dnCubePdesc.sample_count = 1;
	dnCubePdesc.label = "depth_only_cube_pipeline";
	s_gfx.depthOnlyCubePipeline = sg_make_pipeline( &dnCubePdesc );

	s_gfx.depthOnlySphereShader = sg_make_shader( depth_only_sphere_prog_shader_desc( sg_query_backend() ) );

	sg_pipeline_desc dnSpherePdesc = { 0 };
	dnSpherePdesc.shader = s_gfx.depthOnlySphereShader;
	dnSpherePdesc.layout.buffers[0].stride = sizeof( float ) * 3;
	dnSpherePdesc.layout.attrs[ATTR_depth_only_sphere_prog_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	dnSpherePdesc.layout.attrs[ATTR_depth_only_sphere_prog_in_pos].buffer_index = 0;
	dnSpherePdesc.layout.buffers[1].stride = (int)sizeof( sphere_instance_t );
	dnSpherePdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	dnSpherePdesc.layout.buffers[1].step_rate = 1;
	InstAttr( &dnSpherePdesc, ATTR_depth_only_sphere_prog_inst_xform_row0, offsetof( sphere_instance_t, xform_row0 ) );
	InstAttr( &dnSpherePdesc, ATTR_depth_only_sphere_prog_inst_xform_row1, offsetof( sphere_instance_t, xform_row1 ) );
	InstAttr( &dnSpherePdesc, ATTR_depth_only_sphere_prog_inst_xform_row2, offsetof( sphere_instance_t, xform_row2 ) );
	InstAttr( &dnSpherePdesc, ATTR_depth_only_sphere_prog_inst_params, offsetof( sphere_instance_t, params ) );
	dnSpherePdesc.index_type = SG_INDEXTYPE_UINT16;
	dnSpherePdesc.colors[0].pixel_format = SG_PIXELFORMAT_R32F;
	dnSpherePdesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	dnSpherePdesc.depth.compare = SG_COMPAREFUNC_GREATER;
	dnSpherePdesc.depth.write_enabled = true;

	// Impostor: bounding-cube proxy with front-face cull (same as lit
	// sphere). Ensures the impostor draws even when the camera is inside
	// the proxy AABB but outside the analytic sphere.
	dnSpherePdesc.cull_mode = SG_CULLMODE_FRONT;
	dnSpherePdesc.face_winding = SG_FACEWINDING_CCW;
	dnSpherePdesc.sample_count = 1;
	dnSpherePdesc.label = "depth_only_sphere_pipeline";
	s_gfx.depthOnlySpherePipeline = sg_make_pipeline( &dnSpherePdesc );

	s_gfx.depthOnlyCapsuleShader = sg_make_shader( depth_only_capsule_prog_shader_desc( sg_query_backend() ) );

	sg_pipeline_desc dnCapsulePdesc = { 0 };
	dnCapsulePdesc.shader = s_gfx.depthOnlyCapsuleShader;
	dnCapsulePdesc.layout.buffers[0].stride = sizeof( float ) * 3;
	dnCapsulePdesc.layout.attrs[ATTR_depth_only_capsule_prog_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	dnCapsulePdesc.layout.attrs[ATTR_depth_only_capsule_prog_in_pos].buffer_index = 0;
	dnCapsulePdesc.layout.buffers[1].stride = (int)sizeof( capsule_instance_t );
	dnCapsulePdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	dnCapsulePdesc.layout.buffers[1].step_rate = 1;
	InstAttr( &dnCapsulePdesc, ATTR_depth_only_capsule_prog_inst_xform_row0, offsetof( capsule_instance_t, xform_row0 ) );
	InstAttr( &dnCapsulePdesc, ATTR_depth_only_capsule_prog_inst_xform_row1, offsetof( capsule_instance_t, xform_row1 ) );
	InstAttr( &dnCapsulePdesc, ATTR_depth_only_capsule_prog_inst_xform_row2, offsetof( capsule_instance_t, xform_row2 ) );
	InstAttr( &dnCapsulePdesc, ATTR_depth_only_capsule_prog_inst_params, offsetof( capsule_instance_t, params ) );
	dnCapsulePdesc.index_type = SG_INDEXTYPE_UINT16;
	dnCapsulePdesc.colors[0].pixel_format = SG_PIXELFORMAT_R32F;
	dnCapsulePdesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	dnCapsulePdesc.depth.compare = SG_COMPAREFUNC_GREATER;
	dnCapsulePdesc.depth.write_enabled = true;
	dnCapsulePdesc.cull_mode = SG_CULLMODE_FRONT;
	dnCapsulePdesc.face_winding = SG_FACEWINDING_CCW;
	dnCapsulePdesc.sample_count = 1;
	dnCapsulePdesc.label = "depth_only_capsule_pipeline";
	s_gfx.depthOnlyCapsulePipeline = sg_make_pipeline( &dnCapsulePdesc );

	s_gfx.depthOnlyGeomShader = sg_make_shader( depth_only_geom_prog_shader_desc( sg_query_backend() ) );

	sg_pipeline_desc dnGeomPdesc = { 0 };
	dnGeomPdesc.shader = s_gfx.depthOnlyGeomShader;
	dnGeomPdesc.layout.buffers[0].stride = sizeof( float ) * 6;
	dnGeomPdesc.layout.attrs[ATTR_depth_only_geom_prog_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	dnGeomPdesc.layout.attrs[ATTR_depth_only_geom_prog_in_pos].buffer_index = 0;
	dnGeomPdesc.layout.attrs[ATTR_depth_only_geom_prog_in_pos].offset = 0;
	// in_normal is declared by the lit geom vbo at offset 12 but unused here,
	// the shader doesn't declare it so the binding is skipped to match.
	dnGeomPdesc.layout.buffers[1].stride = (int)sizeof( geom_instance_t );
	dnGeomPdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	dnGeomPdesc.layout.buffers[1].step_rate = 1;
	InstAttr( &dnGeomPdesc, ATTR_depth_only_geom_prog_inst_xform_row0, offsetof( geom_instance_t, xform_row0 ) );
	InstAttr( &dnGeomPdesc, ATTR_depth_only_geom_prog_inst_xform_row1, offsetof( geom_instance_t, xform_row1 ) );
	InstAttr( &dnGeomPdesc, ATTR_depth_only_geom_prog_inst_xform_row2, offsetof( geom_instance_t, xform_row2 ) );
	InstAttr( &dnGeomPdesc, ATTR_depth_only_geom_prog_inst_scale, offsetof( geom_instance_t, scale ) );
	dnGeomPdesc.index_type = SG_INDEXTYPE_UINT32;
	dnGeomPdesc.colors[0].pixel_format = SG_PIXELFORMAT_R32F;
	dnGeomPdesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	dnGeomPdesc.depth.compare = SG_COMPAREFUNC_GREATER;
	dnGeomPdesc.depth.write_enabled = true;
	dnGeomPdesc.cull_mode = SG_CULLMODE_BACK; // match geom pipeline, mirror runs use the front-cull sibling
	dnGeomPdesc.face_winding = SG_FACEWINDING_CCW;
	dnGeomPdesc.sample_count = 1;
	dnGeomPdesc.label = "depth_only_geom_pipeline";
	s_gfx.depthOnlyGeomPipeline = sg_make_pipeline( &dnGeomPdesc );

	sg_pipeline_desc dnGeomMirrorPdesc = dnGeomPdesc;
	dnGeomMirrorPdesc.cull_mode = SG_CULLMODE_FRONT;
	dnGeomMirrorPdesc.label = "depth_only_geom_pipeline_mirror";
	s_gfx.depthOnlyGeomPipelineMirror = sg_make_pipeline( &dnGeomMirrorPdesc );

	// transparent pipelines + per-shape transparent buffers
	// Same shaders as the opaque variants (cubeShader, sphereShader,
	// capsuleShader, geomShader), only the pipeline state differs:
	// * sample_count = 1 (single-sample resolved scene target)
	// * depth.compare = GREATER, depth.write_enabled = false
	// * depth.pixel_format = SG_PIXELFORMAT_DEPTH to match the GTAO
	// prepass attachment (not env->defaults.depth_format, the
	// transparent pass re-attaches the prepass depth, not the MSAA
	// scene depth, so the format must match the prepass image).
	// * premultiplied-alpha blend (ONE / ONE_MINUS_SRC_ALPHA, ADD, RGB+A)
	// matching the overlay convention.
	{
		sg_buffer_desc cb = { 0 };
		cb.usage.vertex_buffer = true;
		cb.usage.stream_update = true;
		cb.size = (size_t)TRANSPARENT_SHAPE_CAPACITY * sizeof( cube_instance_t );
		cb.label = "cube_instances_xp";
		s_gfx.cubeInstBufXp = sg_make_buffer( &cb );

		sg_buffer_desc sb = { 0 };
		sb.usage.vertex_buffer = true;
		sb.usage.stream_update = true;
		sb.size = (size_t)TRANSPARENT_SHAPE_CAPACITY * sizeof( sphere_instance_t );
		sb.label = "sphere_instances_xp";
		s_gfx.sphereInstBufXp = sg_make_buffer( &sb );

		sg_buffer_desc kb = { 0 };
		kb.usage.vertex_buffer = true;
		kb.usage.stream_update = true;
		kb.size = (size_t)TRANSPARENT_SHAPE_CAPACITY * sizeof( capsule_instance_t );
		kb.label = "capsule_instances_xp";
		s_gfx.capsuleInstBufXp = sg_make_buffer( &kb );
	}

	// The transparent pipelines share their shader with the opaque sibling
	// and differ only in blend/depth/sample/depth-format. Build a desc by
	// copying the opaque one and patching the differing fields.
	sg_pipeline_desc cubeXpDesc = cubePdesc;
	cubeXpDesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	cubeXpDesc.depth.compare = SG_COMPAREFUNC_GREATER;
	cubeXpDesc.depth.write_enabled = false;
	cubeXpDesc.sample_count = 1;
	cubeXpDesc.colors[0].blend.enabled = true;
	cubeXpDesc.colors[0].blend.src_factor_rgb = SG_BLENDFACTOR_ONE;
	cubeXpDesc.colors[0].blend.dst_factor_rgb = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
	cubeXpDesc.colors[0].blend.op_rgb = SG_BLENDOP_ADD;
	cubeXpDesc.colors[0].blend.src_factor_alpha = SG_BLENDFACTOR_ONE;
	cubeXpDesc.colors[0].blend.dst_factor_alpha = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
	cubeXpDesc.colors[0].blend.op_alpha = SG_BLENDOP_ADD;
	cubeXpDesc.label = "cube_pipeline_xp";
	s_gfx.cubePipelineXp = sg_make_pipeline( &cubeXpDesc );

	sg_pipeline_desc sphereXpDesc = spherePdesc;
	sphereXpDesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	sphereXpDesc.depth.compare = SG_COMPAREFUNC_GREATER;
	sphereXpDesc.depth.write_enabled = false;
	sphereXpDesc.sample_count = 1;
	sphereXpDesc.alpha_to_coverage_enabled = false;
	sphereXpDesc.colors[0].blend = cubeXpDesc.colors[0].blend;
	sphereXpDesc.label = "sphere_pipeline_xp";
	s_gfx.spherePipelineXp = sg_make_pipeline( &sphereXpDesc );

	sg_pipeline_desc capsuleXpDesc = capsulePdesc;
	capsuleXpDesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	capsuleXpDesc.depth.compare = SG_COMPAREFUNC_GREATER;
	capsuleXpDesc.depth.write_enabled = false;
	capsuleXpDesc.sample_count = 1;
	capsuleXpDesc.alpha_to_coverage_enabled = false;
	capsuleXpDesc.colors[0].blend = cubeXpDesc.colors[0].blend;
	capsuleXpDesc.label = "capsule_pipeline_xp";
	s_gfx.capsulePipelineXp = sg_make_pipeline( &capsuleXpDesc );

	sg_pipeline_desc geomXpDesc = geomPdesc;
	geomXpDesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	geomXpDesc.depth.compare = SG_COMPAREFUNC_GREATER;
	geomXpDesc.depth.write_enabled = false;
	// Only hulls are drawn transparent and they never have negative scale
	geomXpDesc.cull_mode = SG_CULLMODE_BACK;
	geomXpDesc.sample_count = 1;
	geomXpDesc.colors[0].blend = cubeXpDesc.colors[0].blend;
	geomXpDesc.label = "geom_pipeline_xp";
	s_gfx.geomPipelineXp = sg_make_pipeline( &geomXpDesc );

	// OIT depth-peel resources. The sampler is point: the
	// distance maps are sampled 1:1 (gl_FragCoord / view_size). The dummy
	// 1x1 target fills the peel texture slots on every non-peel pass
	// (WebGPU bind groups must be complete).
	sg_sampler_desc oitSmpDesc = { 0 };
	oitSmpDesc.min_filter = SG_FILTER_NEAREST;
	oitSmpDesc.mag_filter = SG_FILTER_NEAREST;
	oitSmpDesc.label = "oit_point_sampler";
	s_gfx.oitPointSampler = sg_make_sampler( &oitSmpDesc );

	sg_image_desc oitDummyDesc = { 0 };
	oitDummyDesc.sample_count = 1;
	oitDummyDesc.width = 1;
	oitDummyDesc.height = 1;
	oitDummyDesc.pixel_format = SG_PIXELFORMAT_RGBA16F;
	oitDummyDesc.label = "oit_dummy_1x1";
	s_gfx.oitDummy = sg_make_image( &oitDummyDesc );
	sg_view_desc oitDummyViewDesc = { 0 };
	oitDummyViewDesc.texture.image = s_gfx.oitDummy;
	oitDummyViewDesc.label = "oit_dummy_view";
	s_gfx.oitDummyView = sg_make_view( &oitDummyViewDesc );

	// Peel pipelines: the lit xp pipeline state minus the blend, plus depth
	// write. Same shaders, so the vertex layout + bindgroup match the xp
	// passes that feed and consume them.
	const sg_pipeline_desc* xpDescs[4] = { &cubeXpDesc, &sphereXpDesc, &capsuleXpDesc, &geomXpDesc };
	for ( int i = 0; i < 4; ++i )
	{
		sg_pipeline_desc pd = *xpDescs[i];
		pd.colors[0].blend.enabled = false;
		pd.depth.write_enabled = true;
		pd.depth.compare = SG_COMPAREFUNC_GREATER;
		pd.label = "oit_peel_nearest";
		s_gfx.oitPeelNearest[i] = sg_make_pipeline( &pd );
		pd.depth.compare = SG_COMPAREFUNC_LESS;
		pd.label = "oit_peel_farther";
		s_gfx.oitPeelFarther[i] = sg_make_pipeline( &pd );
	}

	if ( ArenaInit( &s_gfx.cubeArena, (size_t)SHAPE_CAPACITY * sizeof( cube_instance_t ) ) != 0 )
	{
		fprintf( stderr, "[gfx/error] cube arena alloc failed\n" );
		s_gfx.errorCount++;
	}
	if ( ArenaInit( &s_gfx.sphereArena, (size_t)SHAPE_CAPACITY * sizeof( sphere_instance_t ) ) != 0 )
	{
		fprintf( stderr, "[gfx/error] sphere arena alloc failed\n" );
		s_gfx.errorCount++;
	}
	if ( ArenaInit( &s_gfx.capsuleArena, (size_t)SHAPE_CAPACITY * sizeof( capsule_instance_t ) ) != 0 )
	{
		fprintf( stderr, "[gfx/error] capsule arena alloc failed\n" );
		s_gfx.errorCount++;
	}
	if ( ArenaInit( &s_gfx.cubeArenaXp, (size_t)TRANSPARENT_SHAPE_CAPACITY * sizeof( cube_instance_t ) ) != 0 )
	{
		fprintf( stderr, "[gfx/error] cube(xp) arena alloc failed\n" );
		s_gfx.errorCount++;
	}
	if ( ArenaInit( &s_gfx.sphereArenaXp, (size_t)TRANSPARENT_SHAPE_CAPACITY * sizeof( sphere_instance_t ) ) != 0 )
	{
		fprintf( stderr, "[gfx/error] sphere(xp) arena alloc failed\n" );
		s_gfx.errorCount++;
	}
	if ( ArenaInit( &s_gfx.capsuleArenaXp, (size_t)TRANSPARENT_SHAPE_CAPACITY * sizeof( capsule_instance_t ) ) != 0 )
	{
		fprintf( stderr, "[gfx/error] capsule(xp) arena alloc failed\n" );
		s_gfx.errorCount++;
	}

	// procedural sky pipeline (drawn after opaque in DrawScene).
	InitSky( env );

	// IBL: BRDF LUT generated immediately at boot, sky cubemap +
	// SH coefficients are filled on the first DrawScene via the dirty
	// flag picked up by RebuildImageBasedLightingIfDirty.
	InitImageBasedLighting( env );

	// GTAO: owns the depth pre-pass target plus the AO trace targets.
	// Sized lazily per frame via ResizeGTAO from the main render
	// entry points.
	InitAmbientOcclusion();

	// HDR scene target (RGBA16F MSAA + resolve), the opaque-scene pass
	// writes here, the tonemap pass samples the resolved copy and writes
	// the swapchain/test output.
	InitSceneTarget( env );
	InitToneMap();
	InitEdges();
	InitHighlightTarget();
	HighlightMaskInit();
	InitHighlightOutline();
	OverlayInit();
	WorldTextInit();
	s_gfx.swapchainColorFormat = env->defaults.color_format;

	s_gfx.sun.dirToSun = b3Normalize( (b3Vec3){ 0.5f, 0.8f, 0.4f } );

	// Sun default: 8:1 sun:sky luminance ratio under AgX (the curve
	// absorbs the headroom); strength multiplies the color, ambient is
	// added flat as base_color * ambient (0.10 keeps ~10:1 under the PBR
	// ambient term).
	s_gfx.sun.color = (b3Vec3){ 8.0f, 7.6f, 6.8f };
	s_gfx.sun.strength = 0.8f;
	s_gfx.sun.ambient = 0.10f;

	// Default exposure: Preetham at physical strength is bright, -2.5 EV
	// brings the integrated sky+sun into AgX's sweet spot.
	s_gfx.exposureEv = -2.5f;

	// 1.0 is AgX's stock Standard look (identity), the Render Settings
	// panel raises it to counteract AgX's path-to-white desaturation.
	s_gfx.tonemapSaturation = 1.4f;

	// IBL on by default, the Render Settings panel toggles it.
	s_gfx.iblEnabled = true;

	// Spec turbidity.
	s_gfx.turbidity = 2.2f;

	// edge overlay: off by default, SetEdgeOverlayParams flips it on.
	s_gfx.edgeOverlay = GetDefaultEdgeParams();

	// highlight outline: enabled by default but the mask is empty until
	// the adapter forwards hovered/selected shapes, so nothing draws unless
	// the host wires up picking.
	s_gfx.highlight = GetDefaultHighlightParams();

	// Bring IBL in sync with the initial sun before the first frame so
	// lit pipelines (once they sample the cubemap) don't read garbage
	// upper mips on frame 0. Bakes y-up, the first frame's up axis arrives
	// via FrameInput and rebakes if it differs.
	RebuildImageBasedLightingIfDirty( s_gfx.sun.dirToSun, s_gfx.turbidity, false );
}

void SetSun( Sun sun )
{
	const float lenSq = sun.dirToSun.x * sun.dirToSun.x + sun.dirToSun.y * sun.dirToSun.y + sun.dirToSun.z * sun.dirToSun.z;
	if ( lenSq > 0.0f )
	{
		sun.dirToSun = b3Normalize( sun.dirToSun );
	}
	else
	{
		sun.dirToSun = b3Vec3_axisY;
	}
	s_gfx.sun = sun;
	s_gfx.sun.strength = b3ClampFloat( s_gfx.sun.strength, 0.0f, 1.0f );

	SetShadowSunDir( sun.dirToSun );
	// The sun direction is a single source of truth, every consumer
	// (shadow caster, direct lighting, sky, IBL) reads it through the
	// renderer. Marking IBL dirty here ensures the cubemap + SH stay in
	// step on the next DrawScene without callers having to remember.
	MarkIblDirty();
}

static b3Vec3 TransformDir( Mat4 m, b3Vec3 v )
{
	// 3x3 of m times v (treats v as a direction, ignores translation).
	Vec4 r = MulMV4( m, MakeVec4( v.x, v.y, v.z, 0.0f ) );
	return (b3Vec3){ r.x, r.y, r.z };
}

// The generated shader layouts carry their own cascade count, nothing
// links it to SHADOW_CASCADE_COUNT: check the struct instead, so a
// mismatch is a build error, not a silent missing matrix or a fill
// running off the array. Tripping this means regenerating the shaders.
_Static_assert( sizeof( ( (ub_pass_t*)0 )->cascade_matrices ) / sizeof( Mat4 ) == SHADOW_CASCADE_COUNT,
				"cube shader cascade count differs from SHADOW_CASCADE_COUNT" );
_Static_assert( sizeof( ( (sphere_ub_pass_t*)0 )->cascade_matrices ) / sizeof( Mat4 ) == SHADOW_CASCADE_COUNT,
				"sphere shader cascade count differs from SHADOW_CASCADE_COUNT" );
_Static_assert( sizeof( ( (capsule_ub_pass_t*)0 )->cascade_matrices ) / sizeof( Mat4 ) == SHADOW_CASCADE_COUNT,
				"capsule shader cascade count differs from SHADOW_CASCADE_COUNT" );
_Static_assert( sizeof( ( (geom_ub_pass_t*)0 )->cascade_matrices ) / sizeof( Mat4 ) == SHADOW_CASCADE_COUNT,
				"geom shader cascade count differs from SHADOW_CASCADE_COUNT" );

// One vec4 lane per cascade, which is what caps the count at four. Lanes past
// the count stay zero, so a shader built for more would read unlit rather than
// garbage.
static Vec4 PackCascades( float ( *get )( int cascade ) )
{
	float lanes[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
	for ( int i = 0; i < SHADOW_CASCADE_COUNT; ++i )
	{
		lanes[i] = get( i );
	}
	return MakeVec4( lanes[0], lanes[1], lanes[2], lanes[3] );
}

static sg_pass_action MakeSceneClear( void )
{
	sg_pass_action a = { 0 };
	a.colors[0].load_action = SG_LOADACTION_CLEAR;
	a.colors[0].clear_value = (sg_color){ 0.0f, 0.0f, 0.0f, 1.0f };
	a.depth.load_action = SG_LOADACTION_CLEAR;
	a.depth.clear_value = 0.0f; // reverse-Z far
	return a;
}

static void UploadInstances( void )
{
	if ( s_gfx.cubeCount > 0 )
	{
		sg_range r;
		r.ptr = s_gfx.cubeBase;
		r.size = s_gfx.cubeCount * sizeof( cube_instance_t );
		sg_update_buffer( s_gfx.cubeInstBuf, &r );
	}
	if ( s_gfx.sphereCount > 0 )
	{
		sg_range r;
		r.ptr = s_gfx.sphereBase;
		r.size = s_gfx.sphereCount * sizeof( sphere_instance_t );
		sg_update_buffer( s_gfx.sphereInstBuf, &r );
	}
	if ( s_gfx.capsuleCount > 0 )
	{
		sg_range r;
		r.ptr = s_gfx.capsuleBase;
		r.size = s_gfx.capsuleCount * sizeof( capsule_instance_t );
		sg_update_buffer( s_gfx.capsuleInstBuf, &r );
	}
	// Per-instance picks happen at draw time via the per-binding vertex
	// buffer offset, so the buffers can stay in append-order (no need to
	// permute by view-Z here).
	if ( s_gfx.cubeCountXp > 0 )
	{
		sg_range r;
		r.ptr = s_gfx.cubeBaseXp;
		r.size = s_gfx.cubeCountXp * sizeof( cube_instance_t );
		sg_update_buffer( s_gfx.cubeInstBufXp, &r );
	}
	if ( s_gfx.sphereCountXp > 0 )
	{
		sg_range r;
		r.ptr = s_gfx.sphereBaseXp;
		r.size = s_gfx.sphereCountXp * sizeof( sphere_instance_t );
		sg_update_buffer( s_gfx.sphereInstBufXp, &r );
	}
	if ( s_gfx.capsuleCountXp > 0 )
	{
		sg_range r;
		r.ptr = s_gfx.capsuleBaseXp;
		r.size = s_gfx.capsuleCountXp * sizeof( capsule_instance_t );
		sg_update_buffer( s_gfx.capsuleInstBufXp, &r );
	}
	UploadMeshInstances();
}

// Render every caster shape into the cascade i shadow map. Each cascade
// gets one pass, depth attachment is the per-cascade view, viewport is
// the full shadow texture. The pass is always begun (even with zero
// casters) so the attachment gets cleared and lit shaders won't read
// stale data.
static void DrawShadowCascade( int cascade )
{
	char cascadeMarker[24];
	snprintf( cascadeMarker, sizeof( cascadeMarker ), "shadow_cascade_%d", cascade );
	sg_push_debug_group( cascadeMarker );
	BeginShadowPass( cascade );

	const Mat4 lightVP = GetCascadeMatrix( cascade );
	bool viewportApplied = false;

	// Impostor casters march along the light from the proxy face they
	// rasterized, then turn the hit into clip depth themselves. Both
	// quantities come out of the projection's depth row, which under an
	// orthographic light varies only along the light axis: its gradient
	// is the direction light travels, and it is the row that maps a
	// world position to depth. Reading the direction back off the matrix
	// rather than off the sun keeps the two from drifting apart.
	const Vec4 lightDepthRow = MakeVec4( lightVP.cx.z, lightVP.cy.z, lightVP.cz.z, lightVP.cw.z );
	const b3Vec3 lightDir = b3Normalize( ( b3Vec3 ){ lightDepthRow.x, lightDepthRow.y, lightDepthRow.z } );
	const Vec4 lightDirPacked = MakeVec4( lightDir.x, lightDir.y, lightDir.z, 0.0f );

	// Cubes
	if ( s_gfx.cubeCount > 0 )
	{
		sg_push_debug_group( "caster_cube" );
		if ( !viewportApplied )
		{
			sg_apply_viewport( 0, 0, SHADOW_RESOLUTION, SHADOW_RESOLUTION, true );
			viewportApplied = true;
		}
		sg_apply_pipeline( s_gfx.shadowCubePipeline );
		sg_bindings bindings = { 0 };
		bindings.vertex_buffers[0] = s_gfx.vbuf;
		bindings.vertex_buffers[1] = s_gfx.cubeInstBuf; // offset 0, the whole arena
		bindings.index_buffer = s_gfx.ibuf;
		sg_apply_bindings( &bindings );

		shadow_cube_ub_frame_t ub = { 0 };
		ub.light_view_proj = lightVP;
		sg_apply_uniforms( UB_shadow_cube_ub_frame, &SG_RANGE( ub ) );
		// FORK: the FS rebuilds depth from the depth row (WGPU does not
		// store a gl_FragDepth derived from gl_FragCoord.z, see the shader).
		shadow_cube_ub_pass_t ubpass = { 0 };
		ubpass.light_dir = lightDirPacked;
		ubpass.depth_row = lightDepthRow;
		sg_apply_uniforms( UB_shadow_cube_ub_pass, &SG_RANGE( ubpass ) );

		sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), (int)s_gfx.cubeCount );
		sg_pop_debug_group();
	}

	// Spheres
	if ( s_gfx.sphereCount > 0 )
	{
		sg_push_debug_group( "caster_sphere" );
		if ( !viewportApplied )
		{
			sg_apply_viewport( 0, 0, SHADOW_RESOLUTION, SHADOW_RESOLUTION, true );
			viewportApplied = true;
		}
		sg_apply_pipeline( s_gfx.shadowSpherePipeline );
		sg_bindings bindings = { 0 };
		bindings.vertex_buffers[0] = s_gfx.vbuf;
		bindings.vertex_buffers[1] = s_gfx.sphereInstBuf;
		bindings.index_buffer = s_gfx.ibuf;
		sg_apply_bindings( &bindings );

		shadow_sphere_ub_frame_t sub = { 0 };
		sub.light_view_proj = lightVP;
		sg_apply_uniforms( UB_shadow_sphere_ub_frame, &SG_RANGE( sub ) );
		shadow_sphere_ub_pass_t supass = { 0 };
		supass.light_dir = lightDirPacked;
		supass.depth_row = lightDepthRow;
		sg_apply_uniforms( UB_shadow_sphere_ub_pass, &SG_RANGE( supass ) );

		sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), (int)s_gfx.sphereCount );
		sg_pop_debug_group();
	}

	// Capsules
	if ( s_gfx.capsuleCount > 0 )
	{
		sg_push_debug_group( "caster_capsule" );
		if ( !viewportApplied )
		{
			sg_apply_viewport( 0, 0, SHADOW_RESOLUTION, SHADOW_RESOLUTION, true );
			viewportApplied = true;
		}
		sg_apply_pipeline( s_gfx.shadowCapsulePipeline );
		sg_bindings bindings = { 0 };
		bindings.vertex_buffers[0] = s_gfx.vbuf;
		bindings.vertex_buffers[1] = s_gfx.capsuleInstBuf;
		bindings.index_buffer = s_gfx.ibuf;
		sg_apply_bindings( &bindings );

		shadow_capsule_ub_frame_t cub = { 0 };
		cub.light_view_proj = lightVP;
		sg_apply_uniforms( UB_shadow_capsule_ub_frame, &SG_RANGE( cub ) );
		shadow_capsule_ub_pass_t cupass = { 0 };
		cupass.light_dir = lightDirPacked;
		cupass.depth_row = lightDepthRow;
		sg_apply_uniforms( UB_shadow_capsule_ub_pass, &SG_RANGE( cupass ) );

		sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), (int)s_gfx.capsuleCount );
		sg_pop_debug_group();
	}

	// Triangle geometries (hulls, meshes, heightfields)
	// One draw per registry entry, same per-entry bindings as the lit
	// pipeline, just a different (depth-only) shader and ub_frame.
	const int geomSpanCount = GetMeshDrawSpanCount();
	const int geomMirrorSpanCount = GetMeshMirrorDrawSpanCount();
	if ( geomSpanCount > 0 || geomMirrorSpanCount > 0 )
	{
		sg_push_debug_group( "caster_geom" );
		if ( !viewportApplied )
		{
			sg_apply_viewport( 0, 0, SHADOW_RESOLUTION, SHADOW_RESOLUTION, true );
			viewportApplied = true;
		}

		shadow_geom_ub_frame_t gub = { 0 };
		gub.light_view_proj = lightVP;

		const sg_buffer geomInstBuf = GetMeshInstanceBuffer();
		for ( int pass = 0; pass < 2; ++pass )
		{
			const int spanCount = ( pass == 0 ) ? geomSpanCount : geomMirrorSpanCount;
			if ( spanCount == 0 )
			{
				continue;
			}
			sg_apply_pipeline( ( pass == 0 ) ? s_gfx.shadowGeomPipeline : s_gfx.shadowGeomPipelineMirror );
			sg_apply_uniforms( UB_shadow_geom_ub_frame, &SG_RANGE( gub ) );
			// FORK: the FS rebuilds depth from the depth row (WGPU does not
			// store a gl_FragDepth derived from gl_FragCoord.z, see the shader).
			shadow_geom_ub_pass_t gupass = { 0 };
			gupass.light_dir = lightDirPacked;
			gupass.depth_row = lightDepthRow;
			sg_apply_uniforms( UB_shadow_geom_ub_pass, &SG_RANGE( gupass ) );

			for ( int i = 0; i < spanCount; ++i )
			{
				const MeshDrawSpan span = ( pass == 0 ) ? GetMeshDrawSpan( i ) : GetMeshMirrorDrawSpan( i );

				sg_bindings bindings = { 0 };
				bindings.vertex_buffers[0] = span.vbo;
				bindings.vertex_buffers[1] = geomInstBuf;
				bindings.vertex_buffer_offsets[1] = span.firstInstance * (int)sizeof( geom_instance_t );
				bindings.index_buffer = span.ibo;
				sg_apply_bindings( &bindings );

				sg_draw( 0, span.indexCount, span.instanceCount );
			}
		}
		sg_pop_debug_group();
	}

	// Transparent shadow casters
	// Per-instance per-shape: emit a 1-instance shadow draw for each
	// transparent shape with material.z packed as SHADOW_FULL. SHADOW_NONE
	// entries are skipped here, so the cascade depth map ignores them.
	// Opaque casters above are batched, transparent counts are small
	// enough that per-instance draws are fine.
	if ( s_gfx.cubeCountXp > 0 )
	{
		sg_push_debug_group( "caster_cube_xp" );
		if ( !viewportApplied )
		{
			sg_apply_viewport( 0, 0, SHADOW_RESOLUTION, SHADOW_RESOLUTION, true );
			viewportApplied = true;
		}
		sg_apply_pipeline( s_gfx.shadowCubePipeline );

		shadow_cube_ub_frame_t ub = { 0 };
		ub.light_view_proj = lightVP;
		sg_apply_uniforms( UB_shadow_cube_ub_frame, &SG_RANGE( ub ) );
		// FORK: same depth-row uniform as the opaque cube section.
		shadow_cube_ub_pass_t ubpass = { 0 };
		ubpass.light_dir = lightDirPacked;
		ubpass.depth_row = lightDepthRow;
		sg_apply_uniforms( UB_shadow_cube_ub_pass, &SG_RANGE( ubpass ) );

		for ( size_t i = 0; i < s_gfx.cubeCountXp; ++i )
		{
			if ( s_gfx.cubeBaseXp[i].material.z < 0.5f )
				continue; // SHADOW_NONE
			// Per-instance pick: offset into the xp arena, one draw per instance.
			sg_bindings bindings = { 0 };
			bindings.vertex_buffers[0] = s_gfx.vbuf;
			bindings.vertex_buffers[1] = s_gfx.cubeInstBufXp;
			bindings.vertex_buffer_offsets[1] = (int)i * (int)sizeof( cube_instance_t );
			bindings.index_buffer = s_gfx.ibuf;
			sg_apply_bindings( &bindings );
			sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), 1 );
		}
		sg_pop_debug_group();
	}

	if ( s_gfx.sphereCountXp > 0 )
	{
		sg_push_debug_group( "caster_sphere_xp" );
		if ( !viewportApplied )
		{
			sg_apply_viewport( 0, 0, SHADOW_RESOLUTION, SHADOW_RESOLUTION, true );
			viewportApplied = true;
		}
		sg_apply_pipeline( s_gfx.shadowSpherePipeline );

		shadow_sphere_ub_frame_t sub = { 0 };
		sub.light_view_proj = lightVP;
		sg_apply_uniforms( UB_shadow_sphere_ub_frame, &SG_RANGE( sub ) );
		shadow_sphere_ub_pass_t supass = { 0 };
		supass.light_dir = lightDirPacked;
		supass.depth_row = lightDepthRow;
		sg_apply_uniforms( UB_shadow_sphere_ub_pass, &SG_RANGE( supass ) );

		for ( size_t i = 0; i < s_gfx.sphereCountXp; ++i )
		{
			if ( s_gfx.sphereBaseXp[i].material.z < 0.5f )
				continue;
			sg_bindings bindings = { 0 };
			bindings.vertex_buffers[0] = s_gfx.vbuf;
			bindings.vertex_buffers[1] = s_gfx.sphereInstBufXp;
			bindings.vertex_buffer_offsets[1] = (int)i * (int)sizeof( sphere_instance_t );
			bindings.index_buffer = s_gfx.ibuf;
			sg_apply_bindings( &bindings );
			sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), 1 );
		}
		sg_pop_debug_group();
	}

	if ( s_gfx.capsuleCountXp > 0 )
	{
		sg_push_debug_group( "caster_capsule_xp" );
		if ( !viewportApplied )
		{
			sg_apply_viewport( 0, 0, SHADOW_RESOLUTION, SHADOW_RESOLUTION, true );
			viewportApplied = true;
		}
		sg_apply_pipeline( s_gfx.shadowCapsulePipeline );

		shadow_capsule_ub_frame_t cub = { 0 };
		cub.light_view_proj = lightVP;
		sg_apply_uniforms( UB_shadow_capsule_ub_frame, &SG_RANGE( cub ) );
		shadow_capsule_ub_pass_t cupass = { 0 };
		cupass.light_dir = lightDirPacked;
		cupass.depth_row = lightDepthRow;
		sg_apply_uniforms( UB_shadow_capsule_ub_pass, &SG_RANGE( cupass ) );

		for ( size_t i = 0; i < s_gfx.capsuleCountXp; ++i )
		{
			if ( s_gfx.capsuleBaseXp[i].material.z < 0.5f )
				continue;
			sg_bindings bindings = { 0 };
			bindings.vertex_buffers[0] = s_gfx.vbuf;
			bindings.vertex_buffers[1] = s_gfx.capsuleInstBufXp;
			bindings.vertex_buffer_offsets[1] = (int)i * (int)sizeof( capsule_instance_t );
			bindings.index_buffer = s_gfx.ibuf;
			sg_apply_bindings( &bindings );
			sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), 1 );
		}
		sg_pop_debug_group();
	}

	const int geomXpCount = GetTransparentMeshInstanceCount();
	if ( geomXpCount > 0 )
	{
		sg_push_debug_group( "caster_geom_xp" );
		if ( !viewportApplied )
		{
			sg_apply_viewport( 0, 0, SHADOW_RESOLUTION, SHADOW_RESOLUTION, true );
			viewportApplied = true;
		}
		sg_apply_pipeline( s_gfx.shadowGeomPipeline );

		shadow_geom_ub_frame_t gub = { 0 };
		gub.light_view_proj = lightVP;
		sg_apply_uniforms( UB_shadow_geom_ub_frame, &SG_RANGE( gub ) );

		const sg_buffer xpInstBuf = GetTransparentMeshInstanceBuffer();
		for ( int i = 0; i < geomXpCount; ++i )
		{
			const MeshXpInstance xp = GetTransparentMeshInstance( i );
			if ( xp.shadowCast < 0.5f )
				continue;
			sg_bindings bindings = { 0 };
			bindings.vertex_buffers[0] = xp.vbo;
			bindings.vertex_buffers[1] = xpInstBuf;
			bindings.vertex_buffer_offsets[1] = xp.firstInstance * (int)sizeof( geom_instance_t );
			bindings.index_buffer = xp.ibo;
			sg_apply_bindings( &bindings );
			sg_draw( 0, xp.indexCount, 1 );
		}
		sg_pop_debug_group();
	}

	EndShadowPass();
	sg_pop_debug_group();
}

static void DrawScene( int targetWidth, int targetHeight, const FrameInput* frame )
{
	const Mat4 viewProj = MulMM4( frame->proj, frame->view );
	// inv(P*V) = inv(V)*inv(P), produced from the same params as P and V.
	const Mat4 invViewProj = MulMM4( frame->viewInv, frame->projInv );

	const float w = (float)targetWidth;
	const float h = (float)targetHeight;
	const Vec4 viewport = MakeVec4( w, h, w > 0.0f ? 1.0f / w : 0.0f, h > 0.0f ? 1.0f / h : 0.0f );

	// Sun direction TO the light. Sphere/capsule/geom shaders work in
	// world space (analytic normals or per-vertex-data normals), the cube
	// shader works in view space (dFdx/dFdy of v_view_pos, converting to
	// world inverts the normal on D3D11). Both forms uploaded so each
	// pipeline takes what it needs.
	const b3Vec3 sunWorld = s_gfx.sun.dirToSun;
	const b3Vec3 sunView = b3Normalize( TransformDir( frame->view, sunWorld ) );
	// Pre-multiply sun_color RGB by pi so the BRDF's `baseColor / pi`
	// diffuse term cancels to the old Lambert magnitude: sun.color is
	// illuminance, not radiance. Ambient (sun_color.a) is unscaled.
	float str = s_gfx.sun.strength * B3_PI;
	const Vec4 sunColor =
		MakeVec4( s_gfx.sun.color.x * str, s_gfx.sun.color.y * str, s_gfx.sun.color.z * str, s_gfx.sun.ambient );

	// Cascade data built once and copied into each lit pipeline's ub_pass.
	// .w packs a backend-conditional UV.y sign for the shadow lookup:
	// OpenGL render targets have V=0 at the bottom (UV.y matches NDC.y so
	// sign = +1), D3D11/Metal/WebGPU put V=0 at the top (sign = -1 to
	// flip). The shader multiplies NDC.y by this before mapping to UV.y.
	const sg_backend backend = sg_query_backend();
	const float uvYSign = ( backend == SG_BACKEND_GLCORE || backend == SG_BACKEND_GLES3 ) ? 1.0f : -1.0f;
	const Vec4 shadowParams = MakeVec4( uvYSign, GetShadowTexelSize(), 0.0f, 0.0f );
	const Vec4 cascadeFarViewZ = PackCascades( GetCascadeFarViewZ );
	const Vec4 cascadeTexelWorld = PackCascades( GetCascadeTexelWorld );
	const Vec4 cascadeDepthBias = PackCascades( GetCascadeDepthBias );
	Mat4 cascadeMatrices[SHADOW_CASCADE_COUNT];
	for ( int i = 0; i < SHADOW_CASCADE_COUNT; ++i )
	{
		cascadeMatrices[i] = GetCascadeMatrix( i );
	}
	const sg_view shadowSampleView = GetShadowSampleView();
	const sg_sampler shadowSampler = GetShadowSampler();

	// IBL state, pulled once, shared across every lit pipeline.
	// sh is stored as b3Vec3 in the IBL cache, the UBO layout expects
	// Vec4 with .w padding (std140 array stride).
	const sg_view iblSpecView = GetIblSpecularView();
	const sg_sampler iblSpecSampler = GetIblSpecularSampler();
	const sg_view iblLutView = GetIblBrdfLutView();
	const sg_sampler iblLutSampler = GetIblBrdfLutSampler();
	const float iblMaxLod = GetIblSpecularMaxLod();
	// ibl_params.y: 1.0 = IBL ambient, 0.0 = legacy flat ambient. Shared
	// across all four lit pipelines' ub_pass below.
	const float iblEnabledFlag = s_gfx.iblEnabled ? 1.0f : 0.0f;
	b3Vec3 iblSh[9];
	GetIblSphericalHarmonicCoefficients( iblSh );

	// GTAO state, full-res R16F `result` AO target sampled per-fragment in
	// every lit pipeline. Cleared to 1.0 (no occlusion) whenever the AO
	// chain is skipped.
	const sg_view aoView = GetAOResultSampleView();
	const sg_sampler aoSampler = GetAOSampler();

	// Cubes
	if ( s_gfx.cubeCount > 0 )
	{
		ub_frame_t ub = { 0 };
		ub.view = frame->view;
		ub.proj = frame->proj;
		ub.view_proj = viewProj;
		ub.inv_view_proj = invViewProj;
		ub.camera_pos = MakeVec4( frame->cameraPosition.x, frame->cameraPosition.y, frame->cameraPosition.z, frame->time );
		ub.viewport = viewport;

		ub_pass_t up = { 0 };
		up.sun_dir_view = MakeVec4( sunView.x, sunView.y, sunView.z, 0.0f );
		up.sun_color = sunColor;
		up.flags[0] = frame->debugMode;
		up.cascade_far_view_z = cascadeFarViewZ;
		up.cascade_texel_world = cascadeTexelWorld;
		up.cascade_depth_bias = cascadeDepthBias;
		up.shadow_params = shadowParams;
		for ( int i = 0; i < SHADOW_CASCADE_COUNT; ++i )
			up.cascade_matrices[i] = cascadeMatrices[i];
		up.view = frame->view;
		up.camera_pos_world = MakeVec4( frame->cameraPosition.x, frame->cameraPosition.y, frame->cameraPosition.z, 0.0f );
		for ( int i = 0; i < 9; ++i )
		{
			up.sh[i] = MakeVec4( iblSh[i].x, iblSh[i].y, iblSh[i].z, 0.0f );
		}
		up.ibl_params = MakeVec4( iblMaxLod, iblEnabledFlag, 0.0f, 0.0f );

		sg_apply_pipeline( s_gfx.cubePipeline );
		sg_bindings bindings = { 0 };
		bindings.vertex_buffers[0] = s_gfx.vbuf;
		bindings.vertex_buffers[1] = s_gfx.cubeInstBuf;
		bindings.index_buffer = s_gfx.ibuf;
		bindings.views[VIEW_tex_shadow] = shadowSampleView;
		bindings.views[VIEW_tex_ibl_spec] = iblSpecView;
		bindings.views[VIEW_tex_brdf_lut] = iblLutView;
		bindings.views[VIEW_tex_ao] = aoView;
		bindings.views[VIEW_tex_peel_prev] = s_gfx.oitDummyView; // OIT: non-peel pass, peel_range = 0
		bindings.views[VIEW_tex_peel_cur] = s_gfx.oitDummyView;
		bindings.samplers[SMP_smp_shadow] = shadowSampler;
		bindings.samplers[SMP_smp_ibl_spec] = iblSpecSampler;
		bindings.samplers[SMP_smp_brdf_lut] = iblLutSampler;
		bindings.samplers[SMP_smp_ao] = aoSampler;
		bindings.samplers[SMP_smp_peel] = s_gfx.oitPointSampler;
		sg_apply_bindings( &bindings );
		sg_apply_uniforms( UB_ub_frame, &SG_RANGE( ub ) );
		sg_apply_uniforms( UB_ub_pass, &SG_RANGE( up ) );
		sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), (int)s_gfx.cubeCount );
	}

	// Sphere impostors
	if ( s_gfx.sphereCount > 0 )
	{
		sphere_ub_frame_t sub = { 0 };
		sub.view_proj = viewProj;

		sphere_ub_pass_t sup = { 0 };
		sup.sun_dir_world = MakeVec4( sunWorld.x, sunWorld.y, sunWorld.z, 0.0f );
		sup.sun_color = sunColor;
		sup.flags[0] = frame->debugMode;
		sup.camera_pos = MakeVec4( frame->cameraPosition.x, frame->cameraPosition.y, frame->cameraPosition.z, 0.0f );
		sup.view_proj = viewProj;
		sup.view = frame->view;
		sup.cascade_far_view_z = cascadeFarViewZ;
		sup.cascade_texel_world = cascadeTexelWorld;
		sup.cascade_depth_bias = cascadeDepthBias;
		sup.shadow_params = shadowParams;
		for ( int i = 0; i < SHADOW_CASCADE_COUNT; ++i )
			sup.cascade_matrices[i] = cascadeMatrices[i];
		for ( int i = 0; i < 9; ++i )
		{
			sup.sh[i] = MakeVec4( iblSh[i].x, iblSh[i].y, iblSh[i].z, 0.0f );
		}
		sup.ibl_params = MakeVec4( iblMaxLod, iblEnabledFlag, 0.0f, 0.0f );
		sup.win_depth = s_gfx.winDepth;

		sg_apply_pipeline( s_gfx.spherePipeline );
		sg_bindings bindings = { 0 };
		bindings.vertex_buffers[0] = s_gfx.vbuf;
		bindings.vertex_buffers[1] = s_gfx.sphereInstBuf;
		bindings.index_buffer = s_gfx.ibuf;
		bindings.views[VIEW_sphere_tex_shadow] = shadowSampleView;
		bindings.views[VIEW_sphere_tex_ibl_spec] = iblSpecView;
		bindings.views[VIEW_sphere_tex_brdf_lut] = iblLutView;
		bindings.views[VIEW_sphere_tex_ao] = aoView;
		bindings.views[VIEW_sphere_tex_peel_prev] = s_gfx.oitDummyView; // OIT: non-peel pass
		bindings.views[VIEW_sphere_tex_peel_cur] = s_gfx.oitDummyView;
		bindings.samplers[SMP_sphere_smp_shadow] = shadowSampler;
		bindings.samplers[SMP_sphere_smp_ibl_spec] = iblSpecSampler;
		bindings.samplers[SMP_sphere_smp_brdf_lut] = iblLutSampler;
		bindings.samplers[SMP_sphere_smp_ao] = aoSampler;
		bindings.samplers[SMP_sphere_smp_peel] = s_gfx.oitPointSampler;
		sg_apply_bindings( &bindings );
		sg_apply_uniforms( UB_sphere_ub_frame, &SG_RANGE( sub ) );
		sg_apply_uniforms( UB_sphere_ub_pass, &SG_RANGE( sup ) );
		sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), (int)s_gfx.sphereCount );
	}

	// Capsule impostors
	if ( s_gfx.capsuleCount > 0 )
	{
		capsule_ub_frame_t cub = { 0 };
		cub.view_proj = viewProj;

		capsule_ub_pass_t cup = { 0 };
		cup.sun_dir_world = MakeVec4( sunWorld.x, sunWorld.y, sunWorld.z, 0.0f );
		cup.sun_color = sunColor;
		cup.flags[0] = frame->debugMode;
		cup.camera_pos = MakeVec4( frame->cameraPosition.x, frame->cameraPosition.y, frame->cameraPosition.z, 0.0f );
		cup.view_proj = viewProj;
		cup.view = frame->view;
		cup.cascade_far_view_z = cascadeFarViewZ;
		cup.cascade_texel_world = cascadeTexelWorld;
		cup.cascade_depth_bias = cascadeDepthBias;
		cup.shadow_params = shadowParams;
		for ( int i = 0; i < SHADOW_CASCADE_COUNT; ++i )
			cup.cascade_matrices[i] = cascadeMatrices[i];
		for ( int i = 0; i < 9; ++i )
		{
			cup.sh[i] = MakeVec4( iblSh[i].x, iblSh[i].y, iblSh[i].z, 0.0f );
		}
		cup.ibl_params = MakeVec4( iblMaxLod, iblEnabledFlag, 0.0f, 0.0f );
		cup.win_depth = s_gfx.winDepth;

		sg_apply_pipeline( s_gfx.capsulePipeline );
		sg_bindings bindings = { 0 };
		bindings.vertex_buffers[0] = s_gfx.vbuf;
		bindings.vertex_buffers[1] = s_gfx.capsuleInstBuf;
		bindings.index_buffer = s_gfx.ibuf;
		bindings.views[VIEW_capsule_tex_shadow] = shadowSampleView;
		bindings.views[VIEW_capsule_tex_ibl_spec] = iblSpecView;
		bindings.views[VIEW_capsule_tex_brdf_lut] = iblLutView;
		bindings.views[VIEW_capsule_tex_ao] = aoView;
		bindings.views[VIEW_capsule_tex_peel_prev] = s_gfx.oitDummyView; // OIT: non-peel pass
		bindings.views[VIEW_capsule_tex_peel_cur] = s_gfx.oitDummyView;
		bindings.samplers[SMP_capsule_smp_shadow] = shadowSampler;
		bindings.samplers[SMP_capsule_smp_ibl_spec] = iblSpecSampler;
		bindings.samplers[SMP_capsule_smp_brdf_lut] = iblLutSampler;
		bindings.samplers[SMP_capsule_smp_ao] = aoSampler;
		bindings.samplers[SMP_capsule_smp_peel] = s_gfx.oitPointSampler;
		sg_apply_bindings( &bindings );
		sg_apply_uniforms( UB_capsule_ub_frame, &SG_RANGE( cub ) );
		sg_apply_uniforms( UB_capsule_ub_pass, &SG_RANGE( cup ) );
		sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), (int)s_gfx.capsuleCount );
	}

	// Triangle geometries (hulls, meshes, heightfields)
	// The registry produced one draw span per geometry that had at least one
	// instance this frame. Each span carries its own vbo+ibo and a base
	// offset into the shared instance buffer. Normal spans back-cull, mirror
	// spans front-cull, drawn in two passes so the pipeline binds at most
	// twice. Uniforms re-apply after each pipeline switch, only the bindings
	// (vbo/ibo + instance buffer offset) change per span.
	const int geomSpanCount = GetMeshDrawSpanCount();
	const int geomMirrorSpanCount = GetMeshMirrorDrawSpanCount();
	if ( geomSpanCount > 0 || geomMirrorSpanCount > 0 )
	{
		geom_ub_frame_t gub = { 0 };
		gub.view_proj = viewProj;

		geom_ub_pass_t gup = { 0 };
		gup.sun_dir_world = MakeVec4( sunWorld.x, sunWorld.y, sunWorld.z, 0.0f );
		gup.sun_color = sunColor;
		gup.flags[0] = frame->debugMode;
		gup.camera_pos = MakeVec4( frame->cameraPosition.x, frame->cameraPosition.y, frame->cameraPosition.z, 0.0f );
		// .xy = origin wrapped to the grid period (grid lines), .zw = full origin (origin axes).
		gup.grid_offset = MakeVec4( frame->gridWrap.x, frame->gridWrap.y, frame->drawOrigin.x, frame->drawOrigin.z );
		gup.view = frame->view;
		gup.cascade_far_view_z = cascadeFarViewZ;
		gup.cascade_texel_world = cascadeTexelWorld;
		gup.cascade_depth_bias = cascadeDepthBias;
		gup.shadow_params = shadowParams;
		for ( int i = 0; i < SHADOW_CASCADE_COUNT; ++i )
			gup.cascade_matrices[i] = cascadeMatrices[i];
		for ( int i = 0; i < 9; ++i )
		{
			gup.sh[i] = MakeVec4( iblSh[i].x, iblSh[i].y, iblSh[i].z, 0.0f );
		}
		gup.ibl_params = MakeVec4( iblMaxLod, iblEnabledFlag, 0.0f, 0.0f );

		const sg_buffer geomInstBuf = GetMeshInstanceBuffer();
		for ( int pass = 0; pass < 2; ++pass )
		{
			const int spanCount = ( pass == 0 ) ? geomSpanCount : geomMirrorSpanCount;
			if ( spanCount == 0 )
			{
				continue;
			}
			sg_apply_pipeline( ( pass == 0 ) ? s_gfx.geomPipeline : s_gfx.geomPipelineMirror );
			sg_apply_uniforms( UB_geom_ub_frame, &SG_RANGE( gub ) );
			sg_apply_uniforms( UB_geom_ub_pass, &SG_RANGE( gup ) );

			for ( int i = 0; i < spanCount; ++i )
			{
				const MeshDrawSpan span = ( pass == 0 ) ? GetMeshDrawSpan( i ) : GetMeshMirrorDrawSpan( i );

				sg_bindings bindings = { 0 };
				bindings.vertex_buffers[0] = span.vbo;
				bindings.vertex_buffers[1] = geomInstBuf;
				bindings.vertex_buffer_offsets[1] = span.firstInstance * (int)sizeof( geom_instance_t );
				bindings.index_buffer = span.ibo;
				bindings.views[VIEW_geom_tex_shadow] = shadowSampleView;
				bindings.views[VIEW_geom_tex_ibl_spec] = iblSpecView;
				bindings.views[VIEW_geom_tex_brdf_lut] = iblLutView;
				bindings.views[VIEW_geom_tex_ao] = aoView;
				bindings.views[VIEW_geom_tex_peel_prev] = s_gfx.oitDummyView; // OIT: non-peel pass
				bindings.views[VIEW_geom_tex_peel_cur] = s_gfx.oitDummyView;
				bindings.samplers[SMP_geom_smp_shadow] = shadowSampler;
				bindings.samplers[SMP_geom_smp_ibl_spec] = iblSpecSampler;
				bindings.samplers[SMP_geom_smp_brdf_lut] = iblLutSampler;
				bindings.samplers[SMP_geom_smp_ao] = aoSampler;
				bindings.samplers[SMP_geom_smp_peel] = s_gfx.oitPointSampler;
				sg_apply_bindings( &bindings );

				sg_draw( 0, span.indexCount, span.instanceCount );
			}
		}
	}

	// Sky
	// Draw after all opaque shapes. The sky pipeline tests GREATER_EQUAL
	// at NDC z = 0 against the reverse-Z cleared depth (0), so it fills
	// only pixels that no opaque draw touched.
	DrawSky( s_gfx.sun.dirToSun, s_gfx.turbidity, frame->cameraPosition, invViewProj, frame->zUp );
}

// Depth-only pre-pass: all opaque shapes from the main camera into two
// gtao-module attachments: an R32F color target with positive linear
// view-space depth (sampled by the GTAO compute) and a transient D32F
// attachment for closest-fragment selection only (never sampled).
// Sphere/capsule reuse the lit impostor ray-cast, cube/geom raster.
// Color clears to SKY_SENTINEL = 1e9 so sky pixels carry an
// unmistakably-far depth that stays well-defined for the bilateral-
// upsample depth-diff math.
static void DepthPrepass( int targetWidth, int targetHeight, Mat4 view, Mat4 viewProj, b3Vec3 camera_pos_world )
{
	sg_pass pass = { 0 };
	pass.action.colors[0].load_action = SG_LOADACTION_CLEAR;
	pass.action.colors[0].clear_value.r = 1.0e9f; // sky sentinel
	pass.action.colors[0].clear_value.g = 0.0f;
	pass.action.colors[0].clear_value.b = 0.0f;
	pass.action.colors[0].clear_value.a = 0.0f;
	pass.action.colors[0].store_action = SG_STOREACTION_STORE;
	pass.action.depth.load_action = SG_LOADACTION_CLEAR;
	pass.action.depth.clear_value = 0.0f; // reverse-Z far
	// STORE rather than DONTCARE: the transparent pass re-attaches
	// this depth view as its depth_stencil and LOADs it for depth-test
	// against the opaque scene.
	pass.action.depth.store_action = SG_STOREACTION_STORE;
	pass.attachments.colors[0] = GetLinearDepthAttachmentView();
	pass.attachments.depth_stencil = GetPrepassDepthAttachmentView();
	sg_push_debug_group( "depth_prepass" );
	sg_begin_pass( &pass );

	sg_apply_viewport( 0, 0, targetWidth, targetHeight, true );

	// Cubes
	if ( s_gfx.cubeCount > 0 )
	{
		sg_apply_pipeline( s_gfx.depthOnlyCubePipeline );
		sg_bindings bindings = { 0 };
		bindings.vertex_buffers[0] = s_gfx.vbuf;
		bindings.vertex_buffers[1] = s_gfx.cubeInstBuf;
		bindings.index_buffer = s_gfx.ibuf;
		sg_apply_bindings( &bindings );

		depth_only_cube_ub_frame_t ub = { 0 };
		ub.view_proj = viewProj;
		ub.view = view;
		sg_apply_uniforms( UB_depth_only_cube_ub_frame, &SG_RANGE( ub ) );

		sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), (int)s_gfx.cubeCount );
	}

	// Spheres (analytic impostor)
	if ( s_gfx.sphereCount > 0 )
	{
		sg_apply_pipeline( s_gfx.depthOnlySpherePipeline );
		sg_bindings bindings = { 0 };
		bindings.vertex_buffers[0] = s_gfx.vbuf;
		bindings.vertex_buffers[1] = s_gfx.sphereInstBuf;
		bindings.index_buffer = s_gfx.ibuf;
		sg_apply_bindings( &bindings );

		depth_only_sphere_ub_frame_t sub = { 0 };
		sub.view_proj = viewProj;
		sg_apply_uniforms( UB_depth_only_sphere_ub_frame, &SG_RANGE( sub ) );

		depth_only_sphere_ub_pass_t spp = { 0 };
		spp.view_proj = viewProj;
		spp.view = view;
		spp.camera_pos = MakeVec4( camera_pos_world.x, camera_pos_world.y, camera_pos_world.z, 0.0f );
		spp.win_depth = s_gfx.winDepth;
		sg_apply_uniforms( UB_depth_only_sphere_ub_pass, &SG_RANGE( spp ) );

		sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), (int)s_gfx.sphereCount );
	}

	// Capsules (analytic impostor)
	if ( s_gfx.capsuleCount > 0 )
	{
		sg_apply_pipeline( s_gfx.depthOnlyCapsulePipeline );
		sg_bindings bindings = { 0 };
		bindings.vertex_buffers[0] = s_gfx.vbuf;
		bindings.vertex_buffers[1] = s_gfx.capsuleInstBuf;
		bindings.index_buffer = s_gfx.ibuf;
		sg_apply_bindings( &bindings );

		depth_only_capsule_ub_frame_t cub = { 0 };
		cub.view_proj = viewProj;
		sg_apply_uniforms( UB_depth_only_capsule_ub_frame, &SG_RANGE( cub ) );

		depth_only_capsule_ub_pass_t cpp = { 0 };
		cpp.view_proj = viewProj;
		cpp.view = view;
		cpp.camera_pos = MakeVec4( camera_pos_world.x, camera_pos_world.y, camera_pos_world.z, 0.0f );
		cpp.win_depth = s_gfx.winDepth;
		sg_apply_uniforms( UB_depth_only_capsule_ub_pass, &SG_RANGE( cpp ) );

		sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), (int)s_gfx.capsuleCount );
	}

	// Triangle geometries (hulls/meshes/heightfields)
	const int geomSpanCount = GetMeshDrawSpanCount();
	const int geomMirrorSpanCount = GetMeshMirrorDrawSpanCount();
	if ( geomSpanCount > 0 || geomMirrorSpanCount > 0 )
	{
		const sg_buffer geomInstBuf = GetMeshInstanceBuffer();

		// 0 for normal and 1 for reflect geometry (non-uniform scale polarity)
		for ( int j = 0; j < 2; ++j )
		{
			const int spanCount = ( j == 0 ) ? geomSpanCount : geomMirrorSpanCount;
			if ( spanCount == 0 )
			{
				continue;
			}
			sg_apply_pipeline( ( j == 0 ) ? s_gfx.depthOnlyGeomPipeline : s_gfx.depthOnlyGeomPipelineMirror );

			depth_only_geom_ub_frame_t gub = { 0 };
			gub.view_proj = viewProj;
			gub.view = view;
			sg_apply_uniforms( UB_depth_only_geom_ub_frame, &SG_RANGE( gub ) );

			for ( int i = 0; i < spanCount; ++i )
			{
				const MeshDrawSpan span = ( j == 0 ) ? GetMeshDrawSpan( i ) : GetMeshMirrorDrawSpan( i );

				sg_bindings bindings = { 0 };
				bindings.vertex_buffers[0] = span.vbo;
				bindings.vertex_buffers[1] = geomInstBuf;
				bindings.vertex_buffer_offsets[1] = span.firstInstance * (int)sizeof( geom_instance_t );
				bindings.index_buffer = span.ibo;
				sg_apply_bindings( &bindings );

				sg_draw( 0, span.indexCount, span.instanceCount );
			}
		}
	}

	sg_end_pass();
	sg_pop_debug_group();
}

// FORK: transparent-hull depth stamp. DepthPrepass only draws the opaque
// arena, so without this the edge pass would show a transparent hull's own
// back edges through its body. Stamps every transparent geom's front faces
// into the prepass depth (front edges pass the GREATER_EQUAL test at
// surface depth, back edges fail).
// Ordering: after the GTAO chain (hulls must not occlude), before the edge
// pass. The linear-depth color is LOADed/STOREd, so uncovered pixels keep
// the opaque values; overlay lines/points in occlusion mode treat hulls as
// occluders.
static void RenderTransparentDepthPrepass( int targetWidth, int targetHeight, const Mat4* view, const Mat4* viewProj )
{
	const int xpCount = GetTransparentMeshInstanceCount();
	if ( xpCount <= 0 )
	{
		return;
	}

	sg_pass pass = { 0 };
	pass.action.colors[0].load_action = SG_LOADACTION_LOAD;
	pass.action.colors[0].store_action = SG_STOREACTION_STORE;
	pass.action.depth.load_action = SG_LOADACTION_LOAD;
	pass.action.depth.store_action = SG_STOREACTION_STORE;
	pass.attachments.colors[0] = GetLinearDepthAttachmentView();
	pass.attachments.depth_stencil = GetPrepassDepthAttachmentView();
	sg_push_debug_group( "transparent_depth_prepass" );
	sg_begin_pass( &pass );
	sg_apply_viewport( 0, 0, targetWidth, targetHeight, true );

	// Back-cull (front faces only) + depth write, same pipeline the opaque
	// prepass uses. Transparent geoms never carry negative scale (see the
	// transparent pipeline note above), so the mirror sibling is not needed.
	sg_apply_pipeline( s_gfx.depthOnlyGeomPipeline );

	depth_only_geom_ub_frame_t gub = { 0 };
	gub.view_proj = *viewProj;
	gub.view = *view;
	sg_apply_uniforms( UB_depth_only_geom_ub_frame, &SG_RANGE( gub ) );

	sg_bindings bindings = { 0 };
	bindings.vertex_buffers[1] = GetTransparentMeshInstanceBuffer();
	for ( int i = 0; i < xpCount; ++i )
	{
		const MeshXpInstance xp = GetTransparentMeshInstance( i );
		bindings.vertex_buffers[0] = xp.vbo;
		bindings.vertex_buffer_offsets[0] = 0;
		bindings.vertex_buffer_offsets[1] = xp.firstInstance * (int)sizeof( geom_instance_t );
		bindings.index_buffer = xp.ibo;
		sg_apply_bindings( &bindings );
		sg_draw( 0, xp.indexCount, 1 );
	}

	sg_end_pass();
	sg_pop_debug_group();
}

// Cascade fitting + caster passes. Runs before the main pass so the lit
// shaders can sample populated shadow data.
//
// When `castersEnabled` is false (FrameInput.disable_shadows = true) each
// cascade pass is opened and immediately closed, the pass clears the
// attachment to depth=1.0, which the LESS_EQUAL comparison sampler reads
// as "lit" for every fragment, so lit shaders see no shadows without
// needing a shader-side branch.
static void RenderShadowCascades( const FrameInput* frame, bool castersEnabled )
{
	FitShadows( &frame->viewInv, &frame->proj );
	for ( int i = 0; i < SHADOW_CASCADE_COUNT; ++i )
	{
		if ( castersEnabled )
		{
			DrawShadowCascade( i );
		}
		else
		{
			char cascadeMarker[24];
			snprintf( cascadeMarker, sizeof( cascadeMarker ), "shadow_cascade_%d_clear", i );
			sg_push_debug_group( cascadeMarker );
			BeginShadowPass( i );
			EndShadowPass();
			sg_pop_debug_group();
		}
	}
}

// All pre-scene work (instance upload, IBL regen, shadow cascades, GTAO chain).
static void PreSceneWork( int width, int height, const FrameInput* frame )
{
	UploadInstances();

	// IBL regen must run before the main pass starts
	RebuildImageBasedLightingIfDirty( s_gfx.sun.dirToSun, s_gfx.turbidity, frame->zUp );

	RenderShadowCascades( frame, frame->disableShadows == false );

	ResizeGTAO( width, height );

	const Mat4 view_proj = MulMM4( frame->proj, frame->view );
	DepthPrepass( width, height, frame->view, view_proj, frame->cameraPosition );

#if defined( SOKOL_GLES3 )
	// WebGL2 has no compute shaders: the GTAO chain is force-disabled
	// regardless of the frame flag; lit shaders sample the 1x1 white
	// AO fallback target (see the SOKOL_GLES3 note in gtao.h).
	ClearAmbientOcclusion();
#else
	if ( frame->disableAmbientOcclusion == false )
	{
		PrefilterDepth( &frame->proj, width, height );
		ComputeNoisyResult( &frame->proj, width, height );
		Denoise( &frame->proj, width, height );
	}
	else
	{
		ClearAmbientOcclusion();
	}
#endif
}

// OIT depth-peel targets: three RGBA16F distance maps + one
// D32F peel depth, single-sample at scene size. Recreated on resize.
static void ResizeOIT( int width, int height )
{
	if ( s_gfx.oitSizeW == width && s_gfx.oitSizeH == height )
	{
		return;
	}
	for ( int i = 0; i < 3; ++i )
	{
		if ( s_gfx.oitDistView[i].id != SG_INVALID_ID )
		{
			sg_destroy_view( s_gfx.oitDistView[i] );
		}
		if ( s_gfx.oitDist[i].id != SG_INVALID_ID )
		{
			sg_destroy_image( s_gfx.oitDist[i] );
		}
	}
	if ( s_gfx.oitPeelDepthView.id != SG_INVALID_ID )
	{
		sg_destroy_view( s_gfx.oitPeelDepthView );
	}
	if ( s_gfx.oitPeelDepth.id != SG_INVALID_ID )
	{
		sg_destroy_image( s_gfx.oitPeelDepth );
	}
	s_gfx.oitSizeW = width;
	s_gfx.oitSizeH = height;
	sg_image_desc idesc = { 0 };
	idesc.sample_count = 1;
	idesc.width = width;
	idesc.height = height;
	for ( int i = 0; i < 3; ++i )
	{
		idesc.usage.color_attachment = true;
		idesc.pixel_format = SG_PIXELFORMAT_RGBA16F;
		idesc.label = "oit_dist";
		s_gfx.oitDist[i] = sg_make_image( &idesc );
		sg_view_desc dv = { 0 };
		dv.texture.image = s_gfx.oitDist[i];
		dv.label = "oit_dist_view";
		s_gfx.oitDistView[i] = sg_make_view( &dv );
	}
	idesc.usage.depth_stencil_attachment = true;
	idesc.pixel_format = SG_PIXELFORMAT_DEPTH;
	idesc.label = "oit_peel_depth";
	s_gfx.oitPeelDepth = sg_make_image( &idesc );
	sg_view_desc pv = { 0 };
	pv.texture.image = s_gfx.oitPeelDepth;
	pv.label = "oit_peel_depth_view";
	s_gfx.oitPeelDepthView = sg_make_view( &pv );
}

// Renders the opaque scene into the HDR scene target (RGBA16F MSAA ->
// single-sample resolve). Pass action clears the MSAA color to a dark
// background (covered by the sky on every visible pixel) and the MSAA
// depth to the reverse-Z far value.
static void DrawSceneIntoHdr( int width, int height, const FrameInput* frame )
{
	ResizeSceneTarget( width, height );
	ResizeOIT( width, height );

	sg_pass pass = { 0 };
	pass.action = MakeSceneClear();

	// Resolve store-action defaults to STORE when a resolve view is bound.
	pass.attachments = GetSceneTargetAttachments();
	sg_push_debug_group( "scene_hdr" );
	sg_begin_pass( &pass );
	DrawScene( width, height, frame );

	// Edge overlay drawn inside the MSAA scene pass so edges get the same MSAA as the opaque shapes.
	RenderEdgesInMSAA( width, height, &frame->view, &frame->proj, GetMeshInstanceBuffer(), GetTransparentMeshInstanceBuffer(),
					   &s_gfx.edgeOverlay );
	sg_end_pass();
	sg_pop_debug_group();
}

// Transparent pass
//
// Runs after the scene is drawn into HDR resolve and before tone-map.
// Attachments:
// * colors[0] = scene resolve image (LOAD), so we blend over the
// resolved opaque scene rather than overwriting it.
// * depth_stencil = GTAO prepass depth (LOAD), so depth-test against
// the opaque scene works. Single-sample, matches the prepass image
// format. Depth write is OFF on the transparent pipelines.
//
// Order across shape types is realized through a back-to-front sort on the
// view-space Z of each instance's world-space origin. Per shape kind, the
// per-instance pick is the per-draw vertex buffer offset into the xp arena,
// so each transparent draw is one sg_draw(0, indexCount, 1).

typedef enum
{
	TRANSPARENT_KIND_CUBE = 0,
	TRANSPARENT_KIND_SPHERE,
	TRANSPARENT_KIND_CAPSULE,
	TRANSPARENT_KIND_MESH,
} TransparentShapeKind;

typedef struct
{
	float viewZ; // positive = farther from camera
	uint16_t kind;
	uint16_t srcIndex; // arena index for cube/sphere/capsule, xpDraws[] index for geom
} TransparentRef;

// Project an instance's world-space origin to view-space and return the
// positive distance (-view_pos.z). Matches the lit shaders' view_z convention.
static inline float ComputeOriginViewZ( const Mat4* view, b3Vec3 origin )
{
	Vec4 viewPos = MulMV4( *view, MakeVec4( origin.x, origin.y, origin.z, 1.0f ) );
	return -viewPos.z;
}

// One per-shape pipeline set for a transparent subpass: the lit xp
// pipelines for the color subpasses, the OIT peel pipelines for the peel
// subpasses.
typedef struct
{
	sg_pipeline cube, sphere, capsule, geom;
} XpPipelines;

// Per-subpass draw state for DrawXpInstances: the per-shape uniform sets,
// the pipeline set, the shared texture/sampler state, and the two OIT
// peel-layer views (the 1x1 dummy on every pass that doesn't read them).
typedef struct
{
	const ub_frame_t* cubeFrame;
	const ub_pass_t* cubePass;
	const sphere_ub_frame_t* sphereFrame;
	const sphere_ub_pass_t* spherePass;
	const capsule_ub_frame_t* capsuleFrame;
	const capsule_ub_pass_t* capsulePass;
	const geom_ub_frame_t* geomFrame;
	const geom_ub_pass_t* geomPass;
	const XpPipelines* pips;
	sg_view shadowView;
	sg_sampler shadowSampler;
	sg_view iblSpecView;
	sg_sampler iblSpecSampler;
	sg_view iblLutView;
	sg_sampler iblLutSampler;
	sg_view aoView;
	sg_sampler aoSampler;
	sg_view peelPrev;
	sg_view peelCur;
} XpDrawState;

// The transparent instance draw loop, shared by every subpass (the OIT
// peel + color subpasses, and the debug-mode sorted pass).
// Iterates the refs in the given order, switching pipeline + per-shape
// uniforms on kind changes, and draws one instance per ref.
static void DrawXpInstances( int n, const TransparentRef* refs, const XpDrawState* st )
{
	// forces first-iteration pipeline + bindings + uniforms apply
	int currentKind = -1;

	for ( int i = 0; i < n; ++i )
	{
		const TransparentRef ref = refs[i];

		if ( (int)ref.kind != currentKind )
		{
			switch ( (TransparentShapeKind)ref.kind )
			{
				case TRANSPARENT_KIND_CUBE:
				{
					// Bindings re-apply per draw below (the instance offset
					// changes every iteration).
					sg_apply_pipeline( st->pips->cube );
					sg_apply_uniforms( UB_ub_frame, &SG_RANGE( *st->cubeFrame ) );
					sg_apply_uniforms( UB_ub_pass, &SG_RANGE( *st->cubePass ) );
				}
				break;
				case TRANSPARENT_KIND_SPHERE:
				{
					sg_apply_pipeline( st->pips->sphere );
					sg_apply_uniforms( UB_sphere_ub_frame, &SG_RANGE( *st->sphereFrame ) );
					sg_apply_uniforms( UB_sphere_ub_pass, &SG_RANGE( *st->spherePass ) );
				}
				break;
				case TRANSPARENT_KIND_CAPSULE:
				{
					sg_apply_pipeline( st->pips->capsule );
					sg_apply_uniforms( UB_capsule_ub_frame, &SG_RANGE( *st->capsuleFrame ) );
					sg_apply_uniforms( UB_capsule_ub_pass, &SG_RANGE( *st->capsulePass ) );
				}
				break;
				case TRANSPARENT_KIND_MESH:
				{
					sg_apply_pipeline( st->pips->geom );
					sg_apply_uniforms( UB_geom_ub_frame, &SG_RANGE( *st->geomFrame ) );
					sg_apply_uniforms( UB_geom_ub_pass, &SG_RANGE( *st->geomPass ) );
					// Geom bindings rebind per draw below (per-entry vbo/ibo + offset).
				}
				break;
			}
			currentKind = (int)ref.kind;
		}

		switch ( (TransparentShapeKind)ref.kind )
		{
			case TRANSPARENT_KIND_CUBE:
			{
				sg_bindings b = { 0 };
				b.vertex_buffers[0] = s_gfx.vbuf;
				b.vertex_buffers[1] = s_gfx.cubeInstBufXp;
				b.vertex_buffer_offsets[1] = (int)ref.srcIndex * (int)sizeof( cube_instance_t );
				b.index_buffer = s_gfx.ibuf;
				b.views[VIEW_tex_shadow] = st->shadowView;
				b.views[VIEW_tex_ibl_spec] = st->iblSpecView;
				b.views[VIEW_tex_brdf_lut] = st->iblLutView;
				b.views[VIEW_tex_ao] = st->aoView;
				b.views[VIEW_tex_peel_prev] = st->peelPrev;
				b.views[VIEW_tex_peel_cur] = st->peelCur;
				b.samplers[SMP_smp_shadow] = st->shadowSampler;
				b.samplers[SMP_smp_ibl_spec] = st->iblSpecSampler;
				b.samplers[SMP_smp_brdf_lut] = st->iblLutSampler;
				b.samplers[SMP_smp_ao] = st->aoSampler;
				b.samplers[SMP_smp_peel] = s_gfx.oitPointSampler;
				sg_apply_bindings( &b );
				sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), 1 );
			}
			break;
			case TRANSPARENT_KIND_SPHERE:
			{
				sg_bindings b = { 0 };
				b.vertex_buffers[0] = s_gfx.vbuf;
				b.vertex_buffers[1] = s_gfx.sphereInstBufXp;
				b.vertex_buffer_offsets[1] = (int)ref.srcIndex * (int)sizeof( sphere_instance_t );
				b.index_buffer = s_gfx.ibuf;
				b.views[VIEW_sphere_tex_shadow] = st->shadowView;
				b.views[VIEW_sphere_tex_ibl_spec] = st->iblSpecView;
				b.views[VIEW_sphere_tex_brdf_lut] = st->iblLutView;
				b.views[VIEW_sphere_tex_ao] = st->aoView;
				b.views[VIEW_sphere_tex_peel_prev] = st->peelPrev;
				b.views[VIEW_sphere_tex_peel_cur] = st->peelCur;
				b.samplers[SMP_sphere_smp_shadow] = st->shadowSampler;
				b.samplers[SMP_sphere_smp_ibl_spec] = st->iblSpecSampler;
				b.samplers[SMP_sphere_smp_brdf_lut] = st->iblLutSampler;
				b.samplers[SMP_sphere_smp_ao] = st->aoSampler;
				b.samplers[SMP_sphere_smp_peel] = s_gfx.oitPointSampler;
				sg_apply_bindings( &b );
				sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), 1 );
			}
			break;
			case TRANSPARENT_KIND_CAPSULE:
			{
				sg_bindings b = { 0 };
				b.vertex_buffers[0] = s_gfx.vbuf;
				b.vertex_buffers[1] = s_gfx.capsuleInstBufXp;
				b.vertex_buffer_offsets[1] = (int)ref.srcIndex * (int)sizeof( capsule_instance_t );
				b.index_buffer = s_gfx.ibuf;
				b.views[VIEW_capsule_tex_shadow] = st->shadowView;
				b.views[VIEW_capsule_tex_ibl_spec] = st->iblSpecView;
				b.views[VIEW_capsule_tex_brdf_lut] = st->iblLutView;
				b.views[VIEW_capsule_tex_ao] = st->aoView;
				b.views[VIEW_capsule_tex_peel_prev] = st->peelPrev;
				b.views[VIEW_capsule_tex_peel_cur] = st->peelCur;
				b.samplers[SMP_capsule_smp_shadow] = st->shadowSampler;
				b.samplers[SMP_capsule_smp_ibl_spec] = st->iblSpecSampler;
				b.samplers[SMP_capsule_smp_brdf_lut] = st->iblLutSampler;
				b.samplers[SMP_capsule_smp_ao] = st->aoSampler;
				b.samplers[SMP_capsule_smp_peel] = s_gfx.oitPointSampler;
				sg_apply_bindings( &b );
				sg_draw( 0, (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) ), 1 );
			}
			break;
			case TRANSPARENT_KIND_MESH:
			{
				const MeshXpInstance xp = GetTransparentMeshInstance( (int)ref.srcIndex );
				sg_bindings b = { 0 };
				b.vertex_buffers[0] = xp.vbo;
				b.vertex_buffers[1] = GetTransparentMeshInstanceBuffer();
				b.vertex_buffer_offsets[1] = xp.firstInstance * (int)sizeof( geom_instance_t );
				b.index_buffer = xp.ibo;
				b.views[VIEW_geom_tex_shadow] = st->shadowView;
				b.views[VIEW_geom_tex_ibl_spec] = st->iblSpecView;
				b.views[VIEW_geom_tex_brdf_lut] = st->iblLutView;
				b.views[VIEW_geom_tex_ao] = st->aoView;
				b.views[VIEW_geom_tex_peel_prev] = st->peelPrev;
				b.views[VIEW_geom_tex_peel_cur] = st->peelCur;
				b.samplers[SMP_geom_smp_shadow] = st->shadowSampler;
				b.samplers[SMP_geom_smp_ibl_spec] = st->iblSpecSampler;
				b.samplers[SMP_geom_smp_brdf_lut] = st->iblLutSampler;
				b.samplers[SMP_geom_smp_ao] = st->aoSampler;
				b.samplers[SMP_geom_smp_peel] = s_gfx.oitPointSampler;
				sg_apply_bindings( &b );
				sg_draw( 0, xp.indexCount, 1 );
			}
			break;
		}
	}
}

static void DrawTransparentIntoResolve( int width, int height, const FrameInput* frame )
{
	int cubeXp = (int)s_gfx.cubeCountXp;
	int sphereXp = (int)s_gfx.sphereCountXp;
	int capsuleXp = (int)s_gfx.capsuleCountXp;
	int geomXp = GetTransparentMeshInstanceCount();
	int total = cubeXp + sphereXp + capsuleXp + geomXp;
	if ( total <= 0 )
	{
		return;
	}

	// Static scratch sized to hold every instance the four streams can emit:
	// three primitive streams capped at TRANSPARENT_SHAPE_CAPACITY each, plus the
	// geom stream capped at MAX_GEOM_XP_INSTANCES_GLOBAL. The geom cap dwarfs the
	// others, so a uniform multiple of the small cap would overflow.
	static TransparentRef refs[3 * TRANSPARENT_SHAPE_CAPACITY + MAX_GEOM_XP_INSTANCES_GLOBAL];
	int n = 0;

	for ( int i = 0; i < cubeXp; ++i )
	{
		const cube_instance_t* inst = &s_gfx.cubeBaseXp[i];
		b3Vec3 origin = { inst->xform_row0.w, inst->xform_row1.w, inst->xform_row2.w };
		refs[n].viewZ = ComputeOriginViewZ( &frame->view, origin );
		refs[n].kind = TRANSPARENT_KIND_CUBE;
		refs[n].srcIndex = (uint16_t)i;
		++n;
	}
	for ( int i = 0; i < sphereXp; ++i )
	{
		const sphere_instance_t* inst = &s_gfx.sphereBaseXp[i];
		b3Vec3 origin = { inst->xform_row0.w, inst->xform_row1.w, inst->xform_row2.w };
		refs[n].viewZ = ComputeOriginViewZ( &frame->view, origin );
		refs[n].kind = TRANSPARENT_KIND_SPHERE;
		refs[n].srcIndex = (uint16_t)i;
		++n;
	}
	for ( int i = 0; i < capsuleXp; ++i )
	{
		const capsule_instance_t* inst = &s_gfx.capsuleBaseXp[i];
		b3Vec3 origin = { inst->xform_row0.w, inst->xform_row1.w, inst->xform_row2.w };
		refs[n].viewZ = ComputeOriginViewZ( &frame->view, origin );
		refs[n].kind = TRANSPARENT_KIND_CAPSULE;
		refs[n].srcIndex = (uint16_t)i;
		++n;
	}
	for ( int i = 0; i < geomXp; ++i )
	{
		const MeshXpInstance xp = GetTransparentMeshInstance( i );
		refs[n].viewZ = ComputeOriginViewZ( &frame->view, xp.origin );
		refs[n].kind = TRANSPARENT_KIND_MESH;
		refs[n].srcIndex = (uint16_t)i;
		++n;
	}

	// Back-to-front: larger viewZ first.
#define LESS( i, j ) refs[i].viewZ > refs[j].viewZ
#define SWAP( i, j )                                                                                                             \
	do                                                                                                                           \
	{                                                                                                                            \
		TransparentRef tmp_ = refs[i];                                                                                           \
		refs[i] = refs[j];                                                                                                       \
		refs[j] = tmp_;                                                                                                          \
	}                                                                                                                            \
	while ( 0 )
	QSORT( n, LESS, SWAP );
#undef LESS
#undef SWAP

	// Build per-shape ub_frame / ub_pass once
	// Mirrors DrawScene, the transparent pass needs the same lighting +
	// shadow + IBL + AO context. Computed once outside the draw loop, then
	// re-applied each time the pipeline switches to a new shape kind.
	const Mat4 view_proj = MulMM4( frame->proj, frame->view );
	const Mat4 inv_view_proj = MulMM4( frame->viewInv, frame->projInv );
	const float w = (float)width;
	const float h = (float)height;
	const Vec4 viewport = MakeVec4( w, h, w > 0.0f ? 1.0f / w : 0.0f, h > 0.0f ? 1.0f / h : 0.0f );

	const b3Vec3 sunWorld = s_gfx.sun.dirToSun;
	const b3Vec3 sunView = b3Normalize( TransformDir( frame->view, sunWorld ) );
	float str = s_gfx.sun.strength * B3_PI;
	const Vec4 sunColor =
		MakeVec4( s_gfx.sun.color.x * str, s_gfx.sun.color.y * str, s_gfx.sun.color.z * str, s_gfx.sun.ambient );

	const sg_backend backend = sg_query_backend();
	const float uvYSign = ( backend == SG_BACKEND_GLCORE || backend == SG_BACKEND_GLES3 ) ? 1.0f : -1.0f;
	const Vec4 shadowParams = MakeVec4( uvYSign, GetShadowTexelSize(), 0.0f, 0.0f );
	const Vec4 cascadeFarViewZ = PackCascades( GetCascadeFarViewZ );
	const Vec4 cascadeTexelWorld = PackCascades( GetCascadeTexelWorld );
	const Vec4 cascadeDepthBias = PackCascades( GetCascadeDepthBias );
	Mat4 cascadeMatrices[SHADOW_CASCADE_COUNT];
	for ( int i = 0; i < SHADOW_CASCADE_COUNT; ++i )
	{
		cascadeMatrices[i] = GetCascadeMatrix( i );
	}
	const sg_view shadowSampleView = GetShadowSampleView();
	const sg_sampler shadowSampler = GetShadowSampler();

	const sg_view iblSpecView = GetIblSpecularView();
	const sg_sampler iblSpecSampler = GetIblSpecularSampler();
	const sg_view iblLutView = GetIblBrdfLutView();
	const sg_sampler iblLutSampler = GetIblBrdfLutSampler();
	const float iblMaxLod = GetIblSpecularMaxLod();
	// ibl_params.y: 1.0 = IBL ambient, 0.0 = legacy flat ambient. Shared
	// across all four lit pipelines' ub_pass below.
	const float iblEnabledFlag = s_gfx.iblEnabled ? 1.0f : 0.0f;
	b3Vec3 iblSh[9];
	GetIblSphericalHarmonicCoefficients( iblSh );
	const sg_view aoView = GetAOResultSampleView();
	const sg_sampler aoSampler = GetAOSampler();

	ub_frame_t cubeFrame = { 0 };
	cubeFrame.view = frame->view;
	cubeFrame.proj = frame->proj;
	cubeFrame.view_proj = view_proj;
	cubeFrame.inv_view_proj = inv_view_proj;
	cubeFrame.camera_pos = MakeVec4( frame->cameraPosition.x, frame->cameraPosition.y, frame->cameraPosition.z, frame->time );
	cubeFrame.viewport = viewport;

	ub_pass_t cubePass = { 0 };
	cubePass.sun_dir_view = MakeVec4( sunView.x, sunView.y, sunView.z, 0.0f );
	cubePass.sun_color = sunColor;
	cubePass.flags[0] = frame->debugMode;
	cubePass.cascade_far_view_z = cascadeFarViewZ;
	cubePass.cascade_texel_world = cascadeTexelWorld;
	cubePass.cascade_depth_bias = cascadeDepthBias;
	cubePass.shadow_params = shadowParams;
	for ( int i = 0; i < SHADOW_CASCADE_COUNT; ++i )
	{
		cubePass.cascade_matrices[i] = cascadeMatrices[i];
	}
	cubePass.view = frame->view;
	cubePass.camera_pos_world = MakeVec4( frame->cameraPosition.x, frame->cameraPosition.y, frame->cameraPosition.z, 0.0f );
	for ( int i = 0; i < 9; ++i )
	{
		cubePass.sh[i] = MakeVec4( iblSh[i].x, iblSh[i].y, iblSh[i].z, 0.0f );
	}
	cubePass.ibl_params = MakeVec4( iblMaxLod, iblEnabledFlag, 0.0f, 0.0f );

	sphere_ub_frame_t sphereFrame = { 0 };
	sphereFrame.view_proj = view_proj;
	sphere_ub_pass_t spherePass = { 0 };
	spherePass.sun_dir_world = MakeVec4( sunWorld.x, sunWorld.y, sunWorld.z, 0.0f );
	spherePass.sun_color = sunColor;
	spherePass.flags[0] = frame->debugMode;
	spherePass.camera_pos = MakeVec4( frame->cameraPosition.x, frame->cameraPosition.y, frame->cameraPosition.z, 0.0f );
	spherePass.view_proj = view_proj;
	spherePass.view = frame->view;
	spherePass.cascade_far_view_z = cascadeFarViewZ;
	spherePass.cascade_texel_world = cascadeTexelWorld;
	spherePass.cascade_depth_bias = cascadeDepthBias;
	spherePass.shadow_params = shadowParams;
	for ( int i = 0; i < SHADOW_CASCADE_COUNT; ++i )
		spherePass.cascade_matrices[i] = cascadeMatrices[i];
	for ( int i = 0; i < 9; ++i )
		spherePass.sh[i] = MakeVec4( iblSh[i].x, iblSh[i].y, iblSh[i].z, 0.0f );
	spherePass.ibl_params = MakeVec4( iblMaxLod, iblEnabledFlag, 0.0f, 0.0f );

	capsule_ub_frame_t capsuleFrame = { 0 };
	capsuleFrame.view_proj = view_proj;
	capsule_ub_pass_t capsulePass = { 0 };
	capsulePass.sun_dir_world = MakeVec4( sunWorld.x, sunWorld.y, sunWorld.z, 0.0f );
	capsulePass.sun_color = sunColor;
	capsulePass.flags[0] = frame->debugMode;
	capsulePass.camera_pos = MakeVec4( frame->cameraPosition.x, frame->cameraPosition.y, frame->cameraPosition.z, 0.0f );
	capsulePass.view_proj = view_proj;
	capsulePass.view = frame->view;
	capsulePass.cascade_far_view_z = cascadeFarViewZ;
	capsulePass.cascade_texel_world = cascadeTexelWorld;
	capsulePass.cascade_depth_bias = cascadeDepthBias;
	capsulePass.shadow_params = shadowParams;
	for ( int i = 0; i < SHADOW_CASCADE_COUNT; ++i )
		capsulePass.cascade_matrices[i] = cascadeMatrices[i];
	for ( int i = 0; i < 9; ++i )
		capsulePass.sh[i] = MakeVec4( iblSh[i].x, iblSh[i].y, iblSh[i].z, 0.0f );
	capsulePass.ibl_params = MakeVec4( iblMaxLod, iblEnabledFlag, 0.0f, 0.0f );

	geom_ub_frame_t geomFrame = { 0 };
	geomFrame.view_proj = view_proj;
	geom_ub_pass_t geomPass = { 0 };
	geomPass.sun_dir_world = MakeVec4( sunWorld.x, sunWorld.y, sunWorld.z, 0.0f );
	geomPass.sun_color = sunColor;
	geomPass.flags[0] = frame->debugMode;
	geomPass.camera_pos = MakeVec4( frame->cameraPosition.x, frame->cameraPosition.y, frame->cameraPosition.z, 0.0f );
	// .xy = origin wrapped to the grid period (grid lines), .zw = full origin (origin axes).
	geomPass.grid_offset = MakeVec4( frame->gridWrap.x, frame->gridWrap.y, frame->drawOrigin.x, frame->drawOrigin.z );
	geomPass.view = frame->view;
	geomPass.cascade_far_view_z = cascadeFarViewZ;
	geomPass.cascade_texel_world = cascadeTexelWorld;
	geomPass.cascade_depth_bias = cascadeDepthBias;
	geomPass.shadow_params = shadowParams;
	for ( int i = 0; i < SHADOW_CASCADE_COUNT; ++i )
		geomPass.cascade_matrices[i] = cascadeMatrices[i];
	for ( int i = 0; i < 9; ++i )
		geomPass.sh[i] = MakeVec4( iblSh[i].x, iblSh[i].y, iblSh[i].z, 0.0f );
	geomPass.ibl_params = MakeVec4( iblMaxLod, iblEnabledFlag, 0.0f, 0.0f );

	// OIT. The lit-mode transparent pass is a 3-layer depth
	// peel: three peel subpasses write the k-th-nearest surface's linear
	// view distance per pixel, then three color subpasses (farthest layer
	// first) draw only their band with the normal premultiplied blend. The
	// stack composites in exact painter's order independent of instance
	// draw order, which the old single sorted pass could not guarantee for
	// overlapping parts. Debug view modes (1-4) keep the legacy sorted
	// single pass (the range test runs peel_range = 0 there).
	const int OIT_LAYERS = 3;

	// Peel subpass uniform sets: the lit passes with flags.x = 5 (the FS
	// emits the linear view distance into out_color) and peel_range = 0.
	ub_pass_t cubePeelPass = cubePass;
	cubePeelPass.flags[0] = 5;
	cubePeelPass.view_size = viewport;
	sphere_ub_pass_t spherePeelPass = spherePass;
	spherePeelPass.flags[0] = 5;
	spherePeelPass.view_size = viewport;
	capsule_ub_pass_t capsulePeelPass = capsulePass;
	capsulePeelPass.flags[0] = 5;
	capsulePeelPass.view_size = viewport;
	geom_ub_pass_t geomPeelPass = geomPass;
	geomPeelPass.flags[0] = 5;
	geomPeelPass.view_size = viewport;

	XpDrawState st = { 0 };
	st.cubeFrame = &cubeFrame;
	st.cubePass = &cubePass;
	st.sphereFrame = &sphereFrame;
	st.spherePass = &spherePass;
	st.capsuleFrame = &capsuleFrame;
	st.capsulePass = &capsulePass;
	st.geomFrame = &geomFrame;
	st.geomPass = &geomPass;
	st.shadowView = shadowSampleView;
	st.shadowSampler = shadowSampler;
	st.iblSpecView = iblSpecView;
	st.iblSpecSampler = iblSpecSampler;
	st.iblLutView = iblLutView;
	st.iblLutSampler = iblLutSampler;
	st.aoView = aoView;
	st.aoSampler = aoSampler;
	st.peelPrev = s_gfx.oitDummyView;
	st.peelCur = s_gfx.oitDummyView;

	const XpPipelines litPips = {
		s_gfx.cubePipelineXp, s_gfx.spherePipelineXp, s_gfx.capsulePipelineXp, s_gfx.geomPipelineXp };
	const XpPipelines peelPipsNearest = {
		s_gfx.oitPeelNearest[0], s_gfx.oitPeelNearest[1], s_gfx.oitPeelNearest[2], s_gfx.oitPeelNearest[3] };
	const XpPipelines peelPipsFarther = {
		s_gfx.oitPeelFarther[0], s_gfx.oitPeelFarther[1], s_gfx.oitPeelFarther[2], s_gfx.oitPeelFarther[3] };

	sg_push_debug_group( "transparent" );
	if ( frame->debugMode == 0 )
	{
		// Peel subpasses k = 0..2 on one peel depth image, peeled in
		// place: k=0 keeps NEARER fragments (GREATER, reverse-Z), k>0
		// keeps only fragments BEHIND the previous peel (LESS),
		// overwriting it. The FS (flags.x = 5) writes the linear view
		// distance, cleared to 65000 = "no surface". Fragments behind
		// opaque geometry are harmless: they occupy only the far layers
		// and the color subpasses reject them with the prepass depth test.
		for ( int k = 0; k < OIT_LAYERS; ++k )
		{
			sg_pass p = { 0 };
			p.action.colors[0].load_action = SG_LOADACTION_CLEAR;
			p.action.colors[0].clear_value.r = 65000.0f;
			// STORE: the color subpasses sample these as textures; on
			// WebGPU a discard store op invalidates the image.
			p.action.colors[0].store_action = SG_STOREACTION_STORE;
			p.action.depth.load_action = ( k == 0 ) ? SG_LOADACTION_CLEAR : SG_LOADACTION_LOAD;
			p.action.depth.clear_value = 0.0f;
			p.action.depth.store_action = SG_STOREACTION_STORE;
			p.attachments.colors[0] = s_gfx.oitDistView[k];
			p.attachments.depth_stencil = s_gfx.oitPeelDepthView;
			p.label = "oit_peel";
			sg_begin_pass( &p );
			sg_apply_viewport( 0, 0, width, height, true );
			st.pips = ( k == 0 ) ? &peelPipsNearest : &peelPipsFarther;
			st.cubePass = &cubePeelPass;
			st.spherePass = &spherePeelPass;
			st.capsulePass = &capsulePeelPass;
			st.geomPass = &geomPeelPass;
			DrawXpInstances( n, refs, &st );
			sg_end_pass();
		}

		// Color subpasses k = OIT_LAYERS-1 .. 0 (farthest layer first, so
		// each nearer layer blends over what is already in the scene).
		// Each draws only its band: the FS range test keeps fragments whose
		// distance lies between the two neighbor peel maps (peel_range
		// .x/.y gate the tests, .z = the half-float round-trip eps).
		for ( int k = OIT_LAYERS - 1; k >= 0; --k )
		{
			sg_pass p = { 0 };
			p.action.colors[0].load_action = SG_LOADACTION_LOAD;
			p.action.colors[0].store_action = SG_STOREACTION_STORE;
			p.action.depth.load_action = SG_LOADACTION_LOAD;
			// Must be STORE, not DONTCARE: the edge/highlight passes LOAD
			// this prepass depth next, and on WebGPU depthStoreOp 'discard'
			// invalidates it (GL has no store-op semantics).
			p.action.depth.store_action = SG_STOREACTION_STORE;
			p.attachments.colors[0] = GetSceneTargetResolveColorAttachView();
			p.attachments.depth_stencil = GetPrepassDepthAttachmentView();
			p.label = "oit_peelcol";
			sg_begin_pass( &p );
			sg_apply_viewport( 0, 0, width, height, true );
			st.pips = &litPips;
			st.cubePass = &cubePass;
			st.spherePass = &spherePass;
			st.capsulePass = &capsulePass;
			st.geomPass = &geomPass;
			const Vec4 peelRange = MakeVec4( k > 0 ? 1.0f : 0.0f, k < OIT_LAYERS - 1 ? 1.0f : 0.0f, 0.05f, 0.0f );
			cubePass.view_size = viewport;
			cubePass.peel_range = peelRange;
			spherePass.view_size = viewport;
			spherePass.peel_range = peelRange;
			capsulePass.view_size = viewport;
			capsulePass.peel_range = peelRange;
			geomPass.view_size = viewport;
			geomPass.peel_range = peelRange;
			st.peelPrev = ( k > 0 ) ? s_gfx.oitDistView[k - 1] : s_gfx.oitDummyView;
			st.peelCur = ( k < OIT_LAYERS - 1 ) ? s_gfx.oitDistView[k] : s_gfx.oitDummyView;
			DrawXpInstances( n, refs, &st );
			sg_end_pass();
		}
	}
	else
	{
		// Legacy single sorted pass (debug view modes 1-4): the original
		// back-to-front painter's order. peel_range = 0 (zero-init) skips
		// the range test; the peel slots bind the 1x1 dummy.
		sg_pass pass = { 0 };
		pass.action.colors[0].load_action = SG_LOADACTION_LOAD;
		pass.action.colors[0].store_action = SG_STOREACTION_STORE;
		pass.action.depth.load_action = SG_LOADACTION_LOAD;
		pass.action.depth.store_action = SG_STOREACTION_STORE;
		pass.attachments.colors[0] = GetSceneTargetResolveColorAttachView();
		pass.attachments.depth_stencil = GetPrepassDepthAttachmentView();
		pass.label = "transparent_pass";
		sg_begin_pass( &pass );
		sg_apply_viewport( 0, 0, width, height, true );
		st.pips = &litPips;
		DrawXpInstances( n, refs, &st );
		sg_end_pass();
	}
	sg_pop_debug_group();
}

// Snapshot per-frame counters into s_gfx.stats. Called at the end of each
// render path so the panel reads a consistent set. Geom counts are summed
// across the upload spans recorded by GetMeshDrawSpan(), transparent geom
// instance count comes from the dedicated accessor.
static void PopulateStats( float frameTimeMs )
{
	RenderStats st = { 0 };
	st.cubeCount = (int)s_gfx.cubeCount;
	st.sphereCount = (int)s_gfx.sphereCount;
	st.capsuleCount = (int)s_gfx.capsuleCount;
	st.cubeCountXp = (int)s_gfx.cubeCountXp;
	st.sphereCountXp = (int)s_gfx.sphereCountXp;
	st.capsuleCountXp = (int)s_gfx.capsuleCountXp;

	const int geomSpans = GetMeshDrawSpanCount();
	const int geomMirrorSpans = GetMeshMirrorDrawSpanCount();
	st.geomSpanCount = geomSpans + geomMirrorSpans;
	int geomInstSum = 0;
	for ( int i = 0; i < geomSpans; ++i )
	{
		geomInstSum += GetMeshDrawSpan( i ).instanceCount;
	}
	for ( int i = 0; i < geomMirrorSpans; ++i )
	{
		geomInstSum += GetMeshMirrorDrawSpan( i ).instanceCount;
	}
	st.geomInstanceCount = geomInstSum;
	st.geomInstanceCountXp = GetTransparentMeshInstanceCount();

	st.lineCount = OverlayLineCount();
	st.pointCount = OverlayPointCount();

	// Approximate draw count: one per non-empty opaque shape stream, one per
	// geom span, one per transparent instance (each gets its own draw call
	// in the sorted pass), plus the line/point pipelines and the always-
	// present sky + tonemap. Shadow caster pass adds one draw per cascade
	// per non-empty caster type. This is a rough indicator, not an exact
	// GPU profile.
	int draws = 0;
	draws += ( st.cubeCount > 0 ) ? 1 : 0;
	draws += ( st.sphereCount > 0 ) ? 1 : 0;
	draws += ( st.capsuleCount > 0 ) ? 1 : 0;
	draws += st.geomSpanCount;
	draws += st.cubeCountXp + st.sphereCountXp + st.capsuleCountXp;
	draws += st.geomInstanceCountXp;
	draws += ( st.lineCount > 0 ) ? 1 : 0;
	draws += ( st.pointCount > 0 ) ? 1 : 0;
	draws += 1; // sky
	draws += 1; // tonemap
	st.drawCallCount = draws;

	st.frameTimeMs = frameTimeMs;
	s_gfx.stats = st;
}

void RenderFrame( const sg_swapchain* swapChain, const FrameInput* frame )
{
	uint64_t tStart = b3GetTicks();

	s_gfx.cameraState = (CameraState){
		.view = frame->view,
		.viewInv = frame->viewInv,
		.proj = frame->proj,
		.projInv = frame->projInv,
		.viewportW = swapChain->width,
		.viewportH = swapChain->height,
	};

	PreSceneWork( swapChain->width, swapChain->height, frame );
	DrawSceneIntoHdr( swapChain->width, swapChain->height, frame );
	DrawTransparentIntoResolve( swapChain->width, swapChain->height, frame );

	// Stamp the transparent hulls' front faces into the prepass depth so
	// the edge pass below occludes against them like any other surface.
	{
		const Mat4 viewProj = MulMM4( frame->proj, frame->view );
		RenderTransparentDepthPrepass( swapChain->width, swapChain->height, &frame->view, &viewProj );
	}

	// Transparent edge overlay: read+test against the GTAO prepass depth,
	// write into the resolved scene color above the transparent pass.
	// Opaque-arena edges were already drawn into the MSAA scene target
	// inside DrawSceneIntoHdr, this pass picks up the transparent-hull
	// edges that need to sit on top of the transparent blend.
	RenderEdgesPostTransparent( swapChain->width, swapChain->height, &frame->view, &frame->proj,
								GetSceneTargetResolveColorAttachView(), GetPrepassDepthAttachmentView(), GetMeshInstanceBuffer(),
								GetTransparentMeshInstanceBuffer(), &s_gfx.edgeOverlay );

	// Highlight mask, only when the host forwarded hovered/selected shapes
	// for this frame. The mask captures the full unoccluded projection so
	// the outline rings only a shape's outer contour, never its occluders.
	const bool drawHighlights = s_gfx.highlight.enabled && HasHighlightMaskContent();
	if ( drawHighlights )
	{
		ResizeHighlightTarget( swapChain->width, swapChain->height );
		const Mat4 viewProj = MulMM4( frame->proj, frame->view );
		SubmitHighlightMask( swapChain->width, swapChain->height, &viewProj, frame->cameraPosition,
							 GetHighlightTargetMaskAttachView(), GetPrepassDepthAttachmentView(), s_gfx.winDepth );
	}

	// Tonemap: read the resolved HDR scene color, apply exposure + AgX,
	// write display-encoded sRGB to the swapchain. The outline post-pass
	// piggybacks on the same swapchain pass so the outline composites in
	// display space, behind the UI overlay (the caller draws it after
	// RenderFrame returns).
	sg_pass tmPass = { 0 };
	tmPass.action.colors[0].load_action = SG_LOADACTION_DONTCARE;
	tmPass.swapchain = *swapChain;
	sg_push_debug_group( "present" );
	sg_begin_pass( &tmPass );
	// Swapchain has its own depth attachment (sokol_app default), the
	// tonemap pipeline must declare a matching depth format even though
	// it doesn't read or write depth.
	sg_push_debug_group( "tonemap" );
	SubmitToneMap( GetSceneTargetResolveSampleView(), swapChain->color_format, swapChain->depth_format, s_gfx.exposureEv,
				   s_gfx.tonemapSaturation );
	sg_pop_debug_group();
	if ( drawHighlights )
	{
		sg_push_debug_group( "highlight_outline" );
		SubmitHighlightOutline( GetHighlightTargetMaskSampleView(), swapChain->color_format, swapChain->depth_format,
								&s_gfx.highlight );
		sg_pop_debug_group();
	}
	// overlays, lines + points, drawn post-tonemap so their colors are
	// display-referred (WYSIWYG, consistent with the UI text labels)
	// rather than run through exposure + AgX. Occlusion modes still sample
	// the GTAO linear-depth pre-pass.
	sg_push_debug_group( "overlays" );
	OverlaySubmit( swapChain->width, swapChain->height, &frame->view, &frame->viewInv, &frame->proj, &frame->projInv,
				   frame->cameraPosition, frame->time, GetLinearDepthSampleView(), GetAOSampler(), swapChain->color_format,
				   swapChain->depth_format );
	sg_pop_debug_group();
	// World labels ride the same pass as the overlays, after them so a label
	// reads on top of the primitive it names.
	sg_push_debug_group( "world_text" );
	WorldTextSubmit( swapChain->width, swapChain->height, &frame->view, &frame->viewInv, &frame->proj, &frame->projInv,
					 frame->cameraPosition, frame->time, swapChain->color_format, swapChain->depth_format );
	sg_pop_debug_group();
	sg_end_pass();
	sg_pop_debug_group();


	// No sg_commit here, the caller may append more passes (e.g. the UI
	// overlay) and is responsible for the single per-frame commit. The
	// commit's own GL calls drain on the NEXT frame — the latch is sticky,
	// so one frame of latency is fine.
	PopulateStats( b3GetMilliseconds( tStart ) );
	Gpu_DrainGlErrors();
}

void RenderFrameOffscreen( const sg_attachments* attachments, sg_pixel_format outputFormat, int width, int height,
						   const FrameInput* frame )
{
	uint64_t tStart = b3GetTicks();

	s_gfx.cameraState = (CameraState){
		.view = frame->view,
		.viewInv = frame->viewInv,
		.proj = frame->proj,
		.projInv = frame->projInv,
		.viewportW = width,
		.viewportH = height,
	};

	PreSceneWork( width, height, frame );
	DrawSceneIntoHdr( width, height, frame );
	DrawTransparentIntoResolve( width, height, frame );

	// Stamp the transparent hulls' front faces into the prepass depth so
	// the edge pass below occludes against them like any other surface.
	{
		const Mat4 viewProj = MulMM4( frame->proj, frame->view );
		RenderTransparentDepthPrepass( width, height, &frame->view, &viewProj );
	}

	RenderEdgesPostTransparent( width, height, &frame->view, &frame->proj, GetSceneTargetResolveColorAttachView(),
								GetPrepassDepthAttachmentView(), GetMeshInstanceBuffer(), GetTransparentMeshInstanceBuffer(),
								&s_gfx.edgeOverlay );

	const bool drawHighlights = s_gfx.highlight.enabled && HasHighlightMaskContent();
	if ( drawHighlights )
	{
		ResizeHighlightTarget( width, height );
		const Mat4 viewProj = MulMM4( frame->proj, frame->view );
		SubmitHighlightMask( width, height, &viewProj, frame->cameraPosition, GetHighlightTargetMaskAttachView(),
							 GetPrepassDepthAttachmentView(), s_gfx.winDepth );
	}

	sg_pass tmPass = { 0 };
	tmPass.action.colors[0].load_action = SG_LOADACTION_DONTCARE;
	tmPass.attachments = *attachments;
	sg_push_debug_group( "present_offscreen" );
	sg_begin_pass( &tmPass );
	// Offscreen test targets are color-only (no depth attachment), the
	// pipeline declares NONE for depth so sokol's validation passes.
	sg_push_debug_group( "tonemap" );
	SubmitToneMap( GetSceneTargetResolveSampleView(), outputFormat, SG_PIXELFORMAT_NONE, s_gfx.exposureEv,
				   s_gfx.tonemapSaturation );
	sg_pop_debug_group();
	if ( drawHighlights )
	{
		sg_push_debug_group( "highlight_outline" );
		SubmitHighlightOutline( GetHighlightTargetMaskSampleView(), outputFormat, SG_PIXELFORMAT_NONE, &s_gfx.highlight );
		sg_pop_debug_group();
	}
	// overlays, drawn post-tonemap (display-referred). The offscreen
	// test target is color-only, so depth format is NONE.
	sg_push_debug_group( "overlays" );
	OverlaySubmit( width, height, &frame->view, &frame->viewInv, &frame->proj, &frame->projInv, frame->cameraPosition,
				   frame->time, GetLinearDepthSampleView(), GetAOSampler(), outputFormat, SG_PIXELFORMAT_NONE );
	sg_pop_debug_group();
	sg_push_debug_group( "world_text" );
	WorldTextSubmit( width, height, &frame->view, &frame->viewInv, &frame->proj, &frame->projInv, frame->cameraPosition,
					 frame->time, outputFormat, SG_PIXELFORMAT_NONE );
	sg_pop_debug_group();
	sg_end_pass();
	sg_pop_debug_group();

	sg_commit();

	PopulateStats( b3GetMilliseconds( tStart ) );
	Gpu_DrainGlErrors();
}

void SetExposure( float ev )
{
	s_gfx.exposureEv = ev;
}

float GetExposure( void )
{
	return s_gfx.exposureEv;
}

void SetToneMapSaturation( float saturation )
{
	s_gfx.tonemapSaturation = saturation;
}

float GetToneMapSaturation( void )
{
	return s_gfx.tonemapSaturation;
}

void SetIblEnabled( bool enabled )
{
	s_gfx.iblEnabled = enabled;
}

bool GetIblEnabled( void )
{
	return s_gfx.iblEnabled;
}

void SetEdgeOverlayParams( const EdgeOverlayParams* settings )
{
	if ( !settings )
	{
		return;
	}
	s_gfx.edgeOverlay = *settings;
}

EdgeOverlayParams GetEdgeOverlayParams( void )
{
	return s_gfx.edgeOverlay;
}

void SetHighlightParams( const HighlightParams* params )
{
	if ( !params )
		return;
	s_gfx.highlight = *params;
}

HighlightParams GetHighlightParams( void )
{
	return s_gfx.highlight;
}

Sun GetSun( void )
{
	return s_gfx.sun;
}

void SetSkyTurbidity( float t )
{
	if ( t < 1.0f )
		t = 1.0f;
	if ( t != s_gfx.turbidity )
	{
		s_gfx.turbidity = t;
		MarkIblDirty();
	}
}

float GetSkyTurbidity( void )
{
	return s_gfx.turbidity;
}

RenderStats GetRenderStats( void )
{
	return s_gfx.stats;
}

CameraState GetCameraState( void )
{
	return s_gfx.cameraState;
}

sg_buffer GetCubeProxyVertexBuffer( void )
{
	return s_gfx.vbuf;
}

sg_buffer GetCubeProxyIndexBuffer( void )
{
	return s_gfx.ibuf;
}

int GetCubeProxyIndexCount( void )
{
	return (int)( sizeof( CUBE_INDICES ) / sizeof( CUBE_INDICES[0] ) );
}

void ShutdownRenderer( void )
{
	OverlayShutdown();
	WorldTextShutdown();
	ShutdownHighlightOutline();
	HighlightMaskShutdown();
	ShutdownHighlightTarget();
	ShutdownEdges();
	ShutdownToneMap();
	ShutdownSceneTarget();
	ShutdownAmbientOcclusion();
	sg_destroy_pipeline( s_gfx.depthOnlyGeomPipelineMirror );
	sg_destroy_pipeline( s_gfx.depthOnlyGeomPipeline );
	sg_destroy_shader( s_gfx.depthOnlyGeomShader );
	sg_destroy_pipeline( s_gfx.depthOnlyCapsulePipeline );
	sg_destroy_shader( s_gfx.depthOnlyCapsuleShader );
	sg_destroy_pipeline( s_gfx.depthOnlySpherePipeline );
	sg_destroy_shader( s_gfx.depthOnlySphereShader );
	sg_destroy_pipeline( s_gfx.depthOnlyCubePipeline );
	sg_destroy_shader( s_gfx.depthOnlyCubeShader );
	ShutdownImageBasedLighting();
	ShutdownSky();
	sg_destroy_pipeline( s_gfx.shadowCapsulePipeline );
	sg_destroy_shader( s_gfx.shadowCapsuleShader );
	sg_destroy_pipeline( s_gfx.shadowSpherePipeline );
	sg_destroy_shader( s_gfx.shadowSphereShader );
	sg_destroy_pipeline( s_gfx.shadowGeomPipelineMirror );
	sg_destroy_pipeline( s_gfx.shadowGeomPipeline );
	sg_destroy_shader( s_gfx.shadowGeomShader );
	sg_destroy_pipeline( s_gfx.shadowCubePipeline );
	sg_destroy_shader( s_gfx.shadowCubeShader );
	ShutdownShadows();
	// OIT depth peel
	for ( int i = 0; i < 4; ++i )
	{
		sg_destroy_pipeline( s_gfx.oitPeelFarther[i] );
		sg_destroy_pipeline( s_gfx.oitPeelNearest[i] );
	}
	for ( int i = 0; i < 3; ++i )
	{
		sg_destroy_view( s_gfx.oitDistView[i] );
		sg_destroy_image( s_gfx.oitDist[i] );
	}
	sg_destroy_view( s_gfx.oitPeelDepthView );
	sg_destroy_image( s_gfx.oitPeelDepth );
	sg_destroy_view( s_gfx.oitDummyView );
	sg_destroy_image( s_gfx.oitDummy );
	sg_destroy_sampler( s_gfx.oitPointSampler );
	sg_destroy_pipeline( s_gfx.geomPipelineXp );
	sg_destroy_pipeline( s_gfx.geomPipelineMirror );
	sg_destroy_pipeline( s_gfx.geomPipeline );
	sg_destroy_shader( s_gfx.geomShader );
	DestroyMeshRegistry();
	sg_destroy_pipeline( s_gfx.capsulePipelineXp );
	sg_destroy_buffer( s_gfx.capsuleInstBufXp );
	sg_destroy_pipeline( s_gfx.capsulePipeline );
	sg_destroy_shader( s_gfx.capsuleShader );
	sg_destroy_buffer( s_gfx.capsuleInstBuf );
	sg_destroy_pipeline( s_gfx.spherePipelineXp );
	sg_destroy_buffer( s_gfx.sphereInstBufXp );
	sg_destroy_pipeline( s_gfx.spherePipeline );
	sg_destroy_shader( s_gfx.sphereShader );
	sg_destroy_buffer( s_gfx.sphereInstBuf );
	sg_destroy_pipeline( s_gfx.cubePipelineXp );
	sg_destroy_buffer( s_gfx.cubeInstBufXp );
	sg_destroy_pipeline( s_gfx.cubePipeline );
	sg_destroy_shader( s_gfx.cubeShader );
	sg_destroy_buffer( s_gfx.cubeInstBuf );
	sg_destroy_buffer( s_gfx.ibuf );
	sg_destroy_buffer( s_gfx.vbuf );
	sg_shutdown();
	ArenaShutdown( &s_gfx.cubeArena );
	ArenaShutdown( &s_gfx.sphereArena );
	ArenaShutdown( &s_gfx.capsuleArena );
	ArenaShutdown( &s_gfx.cubeArenaXp );
	ArenaShutdown( &s_gfx.sphereArenaXp );
	ArenaShutdown( &s_gfx.capsuleArenaXp );
	s_gfx.cubeBase = NULL;
	s_gfx.cubeCount = 0;
	s_gfx.sphereBase = NULL;
	s_gfx.sphereCount = 0;
	s_gfx.capsuleBase = NULL;
	s_gfx.capsuleCount = 0;
	s_gfx.cubeBaseXp = NULL;
	s_gfx.cubeCountXp = 0;
	s_gfx.sphereBaseXp = NULL;
	s_gfx.sphereCountXp = 0;
	s_gfx.capsuleBaseXp = NULL;
	s_gfx.capsuleCountXp = 0;
}

int GetRenderErrorCount( void )
{
	return s_gfx.errorCount;
}

int GetGpuOutOfMemory( void )
{
	return s_gfx.gpuOom ? 1 : 0;
}


void ResetFrameArena( void )
{
	ArenaReset( &s_gfx.cubeArena );
	ArenaReset( &s_gfx.sphereArena );
	ArenaReset( &s_gfx.capsuleArena );
	ArenaReset( &s_gfx.cubeArenaXp );
	ArenaReset( &s_gfx.sphereArenaXp );
	ArenaReset( &s_gfx.capsuleArenaXp );
	s_gfx.cubeBase = NULL;
	s_gfx.cubeCount = 0;
	s_gfx.sphereBase = NULL;
	s_gfx.sphereCount = 0;
	s_gfx.capsuleBase = NULL;
	s_gfx.capsuleCount = 0;
	s_gfx.cubeBaseXp = NULL;
	s_gfx.cubeCountXp = 0;
	s_gfx.sphereBaseXp = NULL;
	s_gfx.sphereCountXp = 0;
	s_gfx.capsuleBaseXp = NULL;
	s_gfx.capsuleCountXp = 0;
	ResetFrameForMeshes();
	OverlayResetFrame();
	ResetTextArena();
	HighlightMaskBeginFrame();
}

static void PackTransformRows( const Mat4* transform, Vec4* row0, Vec4* row1, Vec4* row2 )
{
	row0->x = transform->cx.x;
	row0->y = transform->cy.x;
	row0->z = transform->cz.x;
	row0->w = transform->cw.x;
	row1->x = transform->cx.y;
	row1->y = transform->cy.y;
	row1->z = transform->cz.y;
	row1->w = transform->cw.y;
	row2->x = transform->cx.z;
	row2->y = transform->cy.z;
	row2->z = transform->cz.z;
	row2->w = transform->cw.z;
}

static inline bool IsTransparent( Vec4 baseColor )
{
	return baseColor.w < 0.99f;
}

// Pack the shadow-cast flag into material.z. The shader never reads this
// (shape FSes only read material.x/.y for metallic/roughness), but the C
// side reads it back during transparent shadow caster filtering. Using a
// reserved slot in the existing instance struct keeps the GPU layout
// unchanged.
static inline float PackShadowCast( TransparentShadowCast s )
{
	return ( s == TRANSPARENT_SHADOW_FULL ) ? 1.0f : 0.0f;
}

void AppendCube( b3Transform transform, b3Vec3 scale, Vec4 baseColor, float metallic, float roughness,
				 TransparentShadowCast shadowCast )
{
	bool transparent = IsTransparent( baseColor );
	size_t* count = transparent ? &s_gfx.cubeCountXp : &s_gfx.cubeCount;
	cube_instance_t** base = transparent ? &s_gfx.cubeBaseXp : &s_gfx.cubeBase;
	Arena* arena = transparent ? &s_gfx.cubeArenaXp : &s_gfx.cubeArena;
	size_t capacity = transparent ? TRANSPARENT_SHAPE_CAPACITY : SHAPE_CAPACITY;
	if ( *count >= capacity )
	{
		fprintf( stderr, "cube%s overflow: dropping (cap=%zu)\n", transparent ? "(xp)" : "", capacity );
		return;
	}
	cube_instance_t* inst = ArenaAlloc( arena, sizeof( cube_instance_t ), _Alignof( cube_instance_t ) );
	if ( inst == NULL )
	{
		return;
	}
	if ( *count == 0 )
	{
		*base = inst;
	}
	*count += 1;

	Mat4 m = MakeMat4FromTransform( transform, scale );
	PackTransformRows( &m, &inst->xform_row0, &inst->xform_row1, &inst->xform_row2 );
	inst->base_color = baseColor;
	inst->material.x = metallic;
	inst->material.y = roughness;
	inst->material.z = PackShadowCast( shadowCast );
	inst->material.w = 0.0f;
}

void AppendSphere( b3Transform transform, float radius, Vec4 baseColor, float metallic, float roughness,
				   float pattern, Vec4 capColor, TransparentShadowCast shadowCast )
{
	bool transparent = IsTransparent( baseColor );
	size_t* count = transparent ? &s_gfx.sphereCountXp : &s_gfx.sphereCount;
	sphere_instance_t** base = transparent ? &s_gfx.sphereBaseXp : &s_gfx.sphereBase;
	Arena* arena = transparent ? &s_gfx.sphereArenaXp : &s_gfx.sphereArena;
	size_t capacity = transparent ? TRANSPARENT_SHAPE_CAPACITY : SHAPE_CAPACITY;
	if ( *count >= capacity )
	{
		fprintf( stderr, "sphere%s overflow: dropping (cap=%zu)\n", transparent ? "(xp)" : "", capacity );
		return;
	}

	sphere_instance_t* inst = ArenaAlloc( arena, sizeof( sphere_instance_t ), _Alignof( sphere_instance_t ) );
	if ( inst == NULL )
	{
		return;
	}
	if ( *count == 0 )
	{
		*base = inst;
	}
	*count += 1;

	Mat4 m = MakeMat4FromTransform( transform, b3Vec3_one );
	PackTransformRows( &m, &inst->xform_row0, &inst->xform_row1, &inst->xform_row2 );
	inst->base_color = baseColor;
	inst->params.x = radius;
	inst->params.y = 0.0f;
	inst->params.z = 0.0f;
	inst->params.w = 0.0f;
	inst->material.x = metallic;
	inst->material.y = roughness;
	inst->material.z = PackShadowCast( shadowCast );
	// material.w = great-circle pattern switch (1.0 = rings, 0.0 = plain).
	inst->material.w = pattern;
	// .rgb = polar-cap paint color, .a = cap threshold (1.0 = no cap).
	inst->cap_color = capColor;
}

void AppendCapsule( b3Transform transform, float halfLength, float radius, Vec4 baseColor, float metallic, float roughness,
					TransparentShadowCast shadowCast )
{
	bool transparent = IsTransparent( baseColor );
	size_t* count = transparent ? &s_gfx.capsuleCountXp : &s_gfx.capsuleCount;
	capsule_instance_t** base = transparent ? &s_gfx.capsuleBaseXp : &s_gfx.capsuleBase;
	Arena* arena = transparent ? &s_gfx.capsuleArenaXp : &s_gfx.capsuleArena;
	size_t capacity = transparent ? TRANSPARENT_SHAPE_CAPACITY : SHAPE_CAPACITY;
	if ( *count >= capacity )
	{
		fprintf( stderr, "[gfx/error] capsule%s overflow: dropping (cap=%zu)\n", transparent ? "(xp)" : "", capacity );
		return;
	}
	capsule_instance_t* inst = ArenaAlloc( arena, sizeof( capsule_instance_t ), _Alignof( capsule_instance_t ) );
	if ( inst == NULL )
	{
		return;
	}
	if ( *count == 0 )
	{
		*base = inst;
	}
	*count += 1;

	Mat4 m = MakeMat4FromTransform( transform, b3Vec3_one );
	PackTransformRows( &m, &inst->xform_row0, &inst->xform_row1, &inst->xform_row2 );
	inst->base_color = baseColor;
	inst->params.x = halfLength;
	inst->params.y = radius;
	inst->params.z = 0.0f;
	inst->params.w = 0.0f;
	inst->material.x = metallic;
	inst->material.y = roughness;
	inst->material.z = PackShadowCast( shadowCast );
	inst->material.w = 0.0f;
}
