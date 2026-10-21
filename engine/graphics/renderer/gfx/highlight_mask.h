// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

// Per-frame append API + the render pass that rasterizes a small set of
// "highlighted" shapes into the renderer-owned R8 mask target. The pass
// runs once per frame after the GTAO depth prepass and before tonemap; the
// outline post-pass then reads the mask and composites silhouette colors
// over the tone-mapped scene.
//
// Covers spheres, capsules, and any registered geometry (hull, mesh,
// height field). All paths are occlusion unaware, so a large selected
// shape outlines its whole projected footprint.
//
// Encodes one of three states per pixel as the kind value passed in:
// 1 = hover -> R8 UNORM 0.5
// 2 = select -> R8 UNORM 1.0
// 0 -> unhighlighted, never written
//
// Single-threaded, render-thread only. Submission counts capped per
// shape class, overflow drops.

#pragma once

#include "gfx/geometry_registry.h"
#include "gfx/utility.h"
#include "sokol_gfx.h"

#ifdef __cplusplus
extern "C"
{
#endif

typedef enum HighlightKind
{
	HIGHLIGHT_KIND_NONE = 0,
	HIGHLIGHT_KIND_HOVER = 1,
	HIGHLIGHT_KIND_SELECT = 2,
} HighlightKind;

void HighlightMaskInit( void );
void HighlightMaskShutdown( void );

// Reset per-frame counts. Called from ResetFrameArena.
void HighlightMaskBeginFrame( void );

// Append a highlighted sphere. transform supplies the world-space center via
// its translation, rotation is ignored (a sphere is rotationally invariant
// for silhouette purposes). Drops on overflow.
void AppendHighlightSphere( b3Transform transform, float radius, HighlightKind kind );

// Append a highlighted capsule. transform follows the same convention as
// AppendCapsule. halfLength and radius are world-space scalars. Drops on
// overflow.
void AppendHighlightCapsule( b3Transform transform, float halfLength, float radius, HighlightKind kind );

// Append highlighted geometry (hull, mesh, or height field). handle resolves
// to a registered geometry (vbo/ibo). transform + scale match AppendMesh,
// rotation matters because the geometry isn't rotationally symmetric. Drops
// on overflow.
void AppendHighlightGeometry( MeshHandle handle, b3Transform transform, b3Vec3 scale, HighlightKind kind );

// True when at least one shape was submitted this frame. Lets the caller
// skip mask + outline passes entirely on the common empty case.
bool HasHighlightMaskContent( void );

// Open a single-sample render pass against (maskAttachView,
// depthAttachView), clear the mask to 0, and rasterize all submitted
// highlights. depthAttachView is bound (load, no write) only to match the
// pipeline's declared depth format. No-op when no highlights were submitted.
// winDepth is the NDC->window-depth affine (slope, bias) the sphere/capsule
// impostors use for their gl_FragDepth writes; the caller (renderer)
// supplies its backend-specific value.
void SubmitHighlightMask( int width, int height, const Mat4* viewProj, b3Vec3 cameraPosWorld, sg_view maskAttachView,
						  sg_view depthAttachView, const Vec4 winDepth );

#ifdef __cplusplus
} // extern "C"
#endif
