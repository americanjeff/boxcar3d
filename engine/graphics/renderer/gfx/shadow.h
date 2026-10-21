// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

// Cascaded-shadow-map infrastructure.
//
// One depth array texture (D32F) holds all cascades, each cascade gets its
// own depth-only view used as the depth attachment for that cascade's
// shadow pass. A single comparison sampler (LESS_EQUAL with linear PCF)
// is shared by every lit shader that reads from the array.
//
// Light-space matrices and split distances are computed by FitShadows
// each frame from the camera frustum and the sun direction.
//
// Coordinate convention inside shadow space:
// - Standard Z (not reverse-Z): 0 at near, 1 at far. The shadow pass
// clears depth to 1.0, fragments closer to the light overwrite with
// smaller values, the sampler compares LESS_EQUAL to determine "this
// fragment is the closest one, so lit".
// - Right-handed orthographic projection, 0..1 clip-Z.

#pragma once

#include "gfx/utility.h"
#include "sokol_gfx.h"

#include <stdbool.h>

#ifdef __cplusplus
extern "C"
{
#endif

// Must match SHADOW_CASCADE_COUNT in shaders/common/shadow_cascade.glsl,
// which the renderer static asserts against the generated uniform layout.
// Changing it needs a shader regen (BOX3D_BUILD_SHADERS=ON) to reach the
// committed headers. Four is the ceiling: per-cascade values ride in vec4
// lanes and a fifth would need a second vec4 for each of them.
#define SHADOW_CASCADE_COUNT 4
#define SHADOW_RESOLUTION 4096

// Default cascade split range, view-space distance from the camera. The
// near end sits well past the camera near plane on purpose: the first
// cascade's bounding sphere reaches back past the eye, so close content is
// covered either way.
#define SHADOW_SPLIT_NEAR 10.0f
#define SHADOW_SPLIT_FAR 50.0f

// Ceiling on the widened far split: the last cascade's texel size is set
// by this number alone, so pushing it out only coarsens the far cascade.
#define SHADOW_SPLIT_FAR_MAX 80.0f

void InitShadows( void );
void ShutdownShadows( void );

// Set the world-space direction TO the sun
void SetShadowSunDir( b3Vec3 dirToSun );

// Override the view-space distance range PSSM splits over. Pass (0, 0)
// to restore the defaults (SHADOW_SPLIT_NEAR, SHADOW_SPLIT_FAR).
void SetShadowSplits( float nearViewZ, float farViewZ );

// Fit the cascade far split to a scene of this view-space depth, keeping the
// current near.
void SetShadowSplitFar( float farViewZ );

float GetShadowSplitNear( void );
float GetShadowSplitFar( void );

// Blend between the two PSSM split schemes. 0 puts every boundary at an
// equal slice of distance, 1 at an equal multiplicative step. Raising it
// tightens the near cascades at the cost of dragging every boundary toward
// the camera, so the coarse far cascade takes over sooner.
void SetShadowSplitLambda( float lambda );
float GetShadowSplitLambda( void );

// Recompute per-cascade light-space matrices and split distances for the
// camera frustum described by viewInv + proj. viewInv (the camera's world
// matrix) supplies eye + basis directly, so the slice-corner walk does no
// matrix inversion. proj supplies fovY + aspect via proj[1][1] / proj[0][0].
// Cascade slices are fit to the camera frustum and snapped to texel
// boundaries to avoid swimming edges as the camera moves.
void FitShadows( const Mat4* viewInv, const Mat4* proj );

// World-space AABB enclosing every shape that can cast into the cascades:
// each slice's bounding sphere swept toward the sun by the caster margin.
// It reaches well outside the camera frustum, which is the point. A host
// culling its draw submission to the visible volume drops casters that
// belong in the shadow map, and their shadows vanish.
//
// Derived from the camera alone, so it can be queried before FitShadows
// runs for the frame. Bounds come back in the same frame viewInv maps
// into, so a caller working against a shifted draw origin must offset
// them.
void GetShadowCasterBounds( const Mat4* viewInv, const Mat4* projInv, b3Vec3* loOut, b3Vec3* hiOut );

// Begin / end the depth-only render pass for a cascade. Bind this as
// the surrounding pass before issuing caster draws into the cascade.
void BeginShadowPass( int cascade );
void EndShadowPass( void );

// Light-space view-proj matrix for a cascade. Lit shaders multiply a
// world-space position by this to get shadow-space coordinates.
Mat4 GetCascadeMatrix( int cascade );

// Far view-space Z (positive, distance from camera) of a cascade's outer
// split boundary. Lit shaders compare a fragment's view-space depth
// against these to pick which cascade to sample.
float GetCascadeFarViewZ( int cascade );

// One shadow texel in world length units for a cascade. Lit shaders scale
// the normal offset (and the PCF kernel) by this relative to cascade 0,
// so the bias and penumbra stay a constant world width across cascades.
float GetCascadeTexelWorld( int cascade );

// Residual comparison bias for a cascade, in shadow clip-Z units. The
// normal offset carries the slope term, this only has to cover depth
// quantization. Sized on the CPU because shadow clip-Z spans the whole
// orthographic range, which differs per cascade.
float GetCascadeDepthBias( int cascade );

// Bound by lit pipelines once for sampling across all cascades. The view
// is the depth array's full-array sampling view. Per-cascade selection
// happens inside the shader by passing `cascade` as the layer index.
sg_view GetShadowSampleView( void );
sg_sampler GetShadowSampler( void );

// One-texel size in shadow UV space (1 / SHADOW_RESOLUTION). Lit shaders
// use this to size PCF taps and the cascade-edge reject.
float GetShadowTexelSize( void );

#ifdef __cplusplus
} // extern "C"
#endif
