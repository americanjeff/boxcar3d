// Standalone C smoke test: prove the forked Box3D renderer
// (engine/graphics/renderer/gfx/) + the separately-vendored Sokol
// (vendor/sokol) + libbox3d (the Odin toolchain's prebuilt) build and link
// as one unit on native Linux, WITHOUT Odin or the engine shims, and render
// a lit, shadowed cube on a ground slab with the Preetham sky.
//
// Build:  tools/build_smoke.sh
// Run:    ./build/native/smoke_renderer
//         ./build/native/smoke_renderer --frames 60   # exit after N frames
//
// This isolates the renderer integration from the Odin FFI integration. It
// implements sokol_app + sokol_glue + sokol_log in this TU (the gfx impl
// comes from the fork's gfx/sokol_impl.c) and drives the renderer through the
// same public API the engine render_shim wraps: InitRenderer, SetSun,
// ResetFrameArena, AppendCube, RenderFrame.

#if defined(__linux__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#define SOKOL_APP_IMPL
#define SOKOL_GLUE_IMPL
#define SOKOL_LOG_IMPL

/* sokol_gfx.h must be included before sokol_glue.h (glue uses sg_* types). */
#include "sokol_gfx.h" /* header only; impl is in the fork's gfx/sokol_impl.c */
#include "sokol_app.h"
#include "sokol_glue.h"
#include "sokol_log.h"

#include "box3d/box3d.h"
#include "box3d/math_functions.h"
#include "gfx/renderer.h"
#include "gfx/utility.h"
#include "gfx/geometry_registry.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#define DEG (M_PI / 180.0)

static const float FOV = 60.0f * (float)DEG;
static const float NEAR = 0.1f;
static const float FAR = 1000.0f;
static const float EYE_X = 20.0f, EYE_Y = 15.0f, EYE_Z = 25.0f; /* fixed camera */

static int s_frame = 0;
static int s_frameLimit = -1; /* --frames N: exit cleanly after N frames */
static int s_registryTest = 0;	/* --registry-test: run the refcount lifecycle, then quit */
static int s_registryFailures = 0;
static MeshHandle s_gridQuad = {0}; /* 20x20 ground-grid quad (geom path regression) */
static int s_dumpFrame = -1;        /* --dump N path.ppm: read back frame N */
static const char* s_dumpPath = NULL;

/* Read the (post-swap) front buffer and write a binary PPM. The window may be
   occluded or off-screen; this needs no compositor cooperation. */
static void DumpFrontBuffer(const int W, const int H, const char* path) {
	unsigned char* px = (unsigned char*)malloc((size_t)W * (size_t)H * 4);
	FILE* f = fopen(path, "wb");
	if (!px || !f) {
		fprintf(stderr, "smoke_renderer: dump open failed: %s\n", path);
		free(px);
		if (f) fclose(f);
		return;
	}
	glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
	fprintf(f, "P6\n%d %d\n255\n", W, H);
	for (int y = H - 1; y >= 0; --y) {
		const unsigned char* row = px + (size_t)y * W * 4;
		for (int x = 0; x < W; ++x) {
			fputc(row[x*4+0], f); fputc(row[x*4+1], f); fputc(row[x*4+2], f);
		}
	}
	fclose(f);
	free(px);
	fprintf(stderr, "smoke_renderer: dumped frame %d -> %s\n", s_frame, path);
}

static void RegCheck(const char* what, int cond) {
	if (cond) {
		fprintf(stderr, "registry PASS: %s\n", what);
	} else {
		fprintf(stderr, "registry FAIL: %s\n", what);
		++s_registryFailures;
	}
}

/* --registry-test: drive the ref-counted geometry-registry lifecycle
   (Register -> Find -> AddRef -> Release -> still-alive -> Release-free ->
   re-Register -> Release) against the real GPU buffers. This is the runtime
   contract the engine:graphics Find_Mesh / Add_Mesh_Reference /
   Release_Mesh_Reference FFI wraps, so a wiring or refcount regression shows
   up here before it reaches an app. Runs once in OnInit after InitRenderer
   (the GL context is live). Note: GetMeshEntryCount is a high-water mark that
   does not shrink, so the no-leak check is "FindMesh misses" not "count flat". */
static void RunRegistryTest(void) {
	const uint32_t H = 0x12345678u;
	MeshVertex verts[3] = {
		{{0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 1.0f}},
		{{1.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 1.0f}},
		{{0.0f, 1.0f, 0.0f}, {0.0f, 0.0f, 1.0f}},
	};
	const uint32_t idx[3] = {0, 1, 2};

	// (1) Register takes exactly one reference.
	MeshHandle h = RegisterMesh(H, verts, 3, idx, 3, "reg-test");
	RegCheck("RegisterMesh returns a valid handle", IsMeshHandleValid(h));

	// (2) FindMesh returns the SAME live slot (index + hash must match).
	MeshHandle f = FindMesh(H);
	RegCheck("FindMesh locates the registered slot",
	         IsMeshHandleValid(f) && f.index == h.index && f.hash == h.hash);

	// (3) A reference taken and then dropped keeps the slot alive.
	AddMeshReference(h);
	ReleaseMeshReference(h);
	MeshHandle f2 = FindMesh(H);
	RegCheck("slot survives a release while refcount > 1",
	         IsMeshHandleValid(f2) && f2.index == h.index);

	// (4) Dropping to refcount 0 frees the slot: FindMesh must now miss.
	ReleaseMeshReference(h);
	MeshHandle f3 = FindMesh(H);
	RegCheck("slot freed at refcount 0 (FindMesh misses)", !IsMeshHandleValid(f3));

	// (5) Re-registering the same hash after the free succeeds.
	MeshHandle h2 = RegisterMesh(H, verts, 3, idx, 3, "reg-test-2");
	RegCheck("re-register after free returns a valid handle", IsMeshHandleValid(h2));

	// (6) Drop the re-registration; no live entry for H may remain (no leak).
	if (IsMeshHandleValid(h2)) ReleaseMeshReference(h2);
	RegCheck("no leaked live entry after full lifecycle", !IsMeshHandleValid(FindMesh(H)));

	// (7) A multi-mesh batch with a replace-and-release. Register a body + 8
	//     shards, shed a segment (release the body, register a new one), then
	//     teardown (release the current body + all 8 shards). Every slot must
	//     free at refcount 0, so FindMesh must miss all of them. This mirrors
	//     apps/boxcar3d release_car_meshes (body + [8] shard slots) — the car is
	//     the only multi-mesh, replace-on-break consumer today — so a refcount
	//     regression under a 9-mesh pattern is caught here, not in the app.
	const uint32_t CB = 0xC0A00001u, CS = 0xC0A10000u, CB2 = 0xC0A00002u;
	MeshHandle body = RegisterMesh(CB, verts, 3, idx, 3, "batch-body");
	MeshHandle shards[8];
	for (int s = 0; s < 8; s++) {
		shards[s] = RegisterMesh(CS + (uint32_t)s, verts, 3, idx, 3, "batch-shard");
	}
	ReleaseMeshReference(body);
	RegCheck("batch: body freed at refcount 0 on replace", !IsMeshHandleValid(FindMesh(CB)));
	body = RegisterMesh(CB2, verts, 3, idx, 3, "batch-body-2");
	ReleaseMeshReference(body);
	for (int s = 0; s < 8; s++) {
		ReleaseMeshReference(shards[s]);
	}
	RegCheck("batch: no leaked body after teardown", !IsMeshHandleValid(FindMesh(CB2)));
	int leaked = 0;
	for (int s = 0; s < 8; s++) {
		if (IsMeshHandleValid(FindMesh(CS + (uint32_t)s))) {
			++leaked;
		}
	}
	RegCheck("batch: no leaked shards after teardown (0 of 8 live)", leaked == 0);
}

static void OnInit(void) {
	const sg_environment env = sglue_environment();
	InitRenderer(&env);

	/* Bright midday sun so direct lighting is obvious against the sky. */
	Sun sun = {0};
	sun.dirToSun = (b3Vec3){0.5f, 0.8f, 0.4f};
	sun.color = (b3Vec3){1.0f, 0.95f, 0.85f};
	sun.ambient = 0.10f;
	sun.strength = 1.0f;
	SetSun(sun);

	/* --registry-test runs the lifecycle now (before any frame) so the
	   verdict is printed by the time the window closes. */
	if (s_registryTest) {
		RunRegistryTest();
	}

	/* A ground-grid quad so the mesh (geom) instance path is exercised the
	   same way the cube path is. */
	{
		const MeshVertex quad[4] = {
			{{-10.0f, 0.0f, -10.0f}, {0.0f, 1.0f, 0.0f}},
			{{ 10.0f, 0.0f, -10.0f}, {0.0f, 1.0f, 0.0f}},
			{{ 10.0f, 0.0f,  10.0f}, {0.0f, 1.0f, 0.0f}},
			{{-10.0f, 0.0f,  10.0f}, {0.0f, 1.0f, 0.0f}},
		};
		const uint32_t quadIdx[6] = {0, 2, 1, 0, 3, 2};
		s_gridQuad = RegisterMesh(0x00F00D1Eu, quad, 4, quadIdx, 6, "smoke-grid-quad");
	}
}

static void OnFrame(void) {
	const int W = sapp_width();
	const int H = sapp_height();
	const float aspect = (H > 0) ? (float)W / (float)H : 1.0f;

	/* Fixed view basis: eye -> origin, Y up. */
	const b3Vec3 eye = {EYE_X, EYE_Y, EYE_Z};
	const b3Vec3 target = {0.0f, 0.0f, 0.0f};
	const b3Vec3 worldUp = {0.0f, 1.0f, 0.0f};
	b3Vec3 forward = b3Normalize(b3Sub(eye, target));      /* pivot -> eye (+view-Z) */
	b3Vec3 up = b3Normalize(b3Sub(worldUp, b3MulSV(b3Dot(worldUp, forward), forward)));
	b3Vec3 right = b3Normalize(b3Cross(up, forward));

	Mat4 view, viewInv;
	MakeViewAndInverse(&view, &viewInv, right, up, forward, eye);

	/* Reverse-Z RH perspective: swap near/far so near -> clip.z = 1, far -> 0. */
	Mat4 proj, projInv;
	MakePerspectiveAndInverse(&proj, &projInv, FOV, aspect, FAR, NEAR);

	ResetFrameArena();

	/* Ground slab: 100x100, top at y=0 (center at y=-10, half-height 10). */
	{
		b3Transform t = b3Transform_identity;
		t.p = (b3Vec3){0.0f, -10.0f, 0.0f};
		const Vec4 color = MakeColor(0x333344u); /* rough dark slab */
		AppendCube(t, (b3Vec3){100.0f, 20.0f, 100.0f}, color, 0.0f, 0.9f, TRANSPARENT_SHADOW_FULL);
	}

	/* Ground-grid quad on the mesh (geom) instance path. */
	{
		b3Transform t = b3Transform_identity;
		AppendMesh(s_gridQuad, t, (b3Vec3){1.0f, 1.0f, 1.0f}, MakeColor(0x22aa44u),
				   0.0f, 0.9f, MESH_MATERIAL_MODE_GROUND_GRID, 2.0f, TRANSPARENT_SHADOW_FULL);
	}

	/* One lit cube spinning around Y so the PBR/IBL response is visible. */
	{
		const float time = (float)sapp_frame_count() / 60.0f;
		b3Transform t = b3Transform_identity;
		t.p = (b3Vec3){0.0f, 1.0f, 0.0f};
		t.q = b3MakeQuatFromAxisAngle(b3Normalize((b3Vec3){0.0f, 1.0f, 0.0f}), time);
		AppendCube(t, (b3Vec3){2.0f, 2.0f, 2.0f}, MakeColor(0xcc4422u), 0.1f, 0.4f, TRANSPARENT_SHADOW_FULL);
	}

	/* Impostor sphere + capsule next to the cube (impostor FS / gl_FragDepth path).
	   The sphere exercises the polar-cap path: a yellow +z hemisphere (threshold 0.0). */
	{
		b3Transform t = b3Transform_identity;
		t.p = (b3Vec3){4.0f, 1.5f, 0.0f};
		AppendSphere(t, 1.5f, MakeColor(0x2288ccu), 0.2f, 0.4f, 1.0f, MakeVec4( 1.0f, 1.0f, 0.2f, 0.0f ), TRANSPARENT_SHADOW_FULL);
		t.p = (b3Vec3){-4.0f, 2.0f, 0.0f};
		AppendCapsule(t, 1.0f, 1.0f, MakeColor(0x88cc22u), 0.2f, 0.4f, TRANSPARENT_SHADOW_FULL);
	}

	FrameInput fi = {0};
	fi.view = view;
	fi.viewInv = viewInv;
	fi.proj = proj;
	fi.projInv = projInv;
	fi.cameraPosition = eye;
	fi.drawOrigin = b3Vec3_zero;
	fi.gridWrap = (b3Vec2){0.0f, 0.0f};
	fi.time = (float)sapp_frame_count() / 60.0f;
	fi.debugMode = 0;
	fi.disableShadows = false;
	fi.disableAmbientOcclusion = false;
	fi.zUp = false;

	const sg_swapchain sc = sglue_swapchain();
	RenderFrame(&sc, &fi);
	sg_commit();

	++s_frame;
	if (s_dumpFrame > 0 && s_frame == s_dumpFrame && s_dumpPath) {
		DumpFrontBuffer(W, H, s_dumpPath);
	}
	if (s_frameLimit > 0 && s_frame >= s_frameLimit) {
		sapp_request_quit();
	}
}

static void OnCleanup(void) {
	ShutdownRenderer();
	const int errors = GetRenderErrorCount();
	fprintf(stderr, "smoke_renderer: %d sokol errors\n", errors);
	if (s_registryTest) {
		fprintf(stderr, "registry-test: %s (%d failure(s))\n",
		        s_registryFailures == 0 ? "ALL PASSED" : "FAILED", s_registryFailures);
		if (s_registryFailures > 0) exit(1);
	}
}

static void OnAppLog(const char* tag, uint32_t logLevel, uint32_t logItemId, const char* message,
                     uint32_t lineNumber, const char* filename, void* userData) {
	(void)tag; (void)logItemId; (void)filename; (void)userData; (void)lineNumber;
	const char* level = (logLevel == 0) ? "panic" : (logLevel == 1) ? "error" : (logLevel == 2) ? "warn" : "info";
	fprintf(stderr, "sokol(%s) %s\n", level, message ? message : "(no message)");
	if (logLevel == 0) {
		exit(1);
	}
}

sapp_desc sokol_main(int argc, char** argv) {
	for (int i = 1; i < argc; ++i) {
		if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
			s_frameLimit = atoi(argv[++i]);
		} else if (strcmp(argv[i], "--registry-test") == 0) {
			s_registryTest = 1;
		} else if (strcmp(argv[i], "--dump") == 0 && i + 2 < argc) {
			s_dumpFrame = atoi(argv[++i]);
			s_dumpPath = argv[++i];
		}
	}
	sapp_desc desc = {0};
	desc.init_cb = OnInit;
	desc.frame_cb = OnFrame;
	desc.event_cb = NULL;
	desc.cleanup_cb = OnCleanup;
	desc.logger.func = OnAppLog;

#if defined( SOKOL_GLCORE )
	/* The renderer hard-requires glClipControl (GL 4.5 / ARB_clip_control)
	   for its reverse-Z depth pipeline on SOKOL_GLCORE. Request a 4.5
	   context, exactly as upstream samples/main.cpp does. */
	desc.gl.major_version = 4;
	desc.gl.minor_version = 5;
#elif defined( SOKOL_GLES3 )
	/* The GLES3 build mirrors the WASM/WebGL2 path exactly: no
	   glClipControl, default [-1,1] clip-Z range, 0..1 clip-Z projection
	   from the app. Request a plain 3.0 context. */
	desc.gl.major_version = 3;
	desc.gl.minor_version = 0;
#endif

	desc.width = 1280;
	desc.height = 720;
	desc.sample_count = 1; /* renderer runs MSAA in its own scene target */
	desc.swap_interval = 1;
	desc.window_title = "Box3D Sokol renderer — smoke test";
	if (s_registryTest) {
		/* The lifecycle test only needs a live GL context, not a visible
		   surface: shrink the window and quit after one frame. */
		desc.width = 64;
		desc.height = 64;
		desc.window_title = "Box3D renderer — registry test";
		if (s_frameLimit < 0) s_frameLimit = 1;
	}
	return desc;
}