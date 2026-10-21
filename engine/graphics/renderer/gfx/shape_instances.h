// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

// Hand-mirrors of the per-instance vertex-attribute structs consumed by the
// shape / depth-prepass / shadow-caster / highlight-mask shaders.
//
// These replace the sokol-shdc-generated C types after the instance data
// moved from storage buffers to per-instance vertex attributes. Every field
// is one FLOAT4 vertex attribute, and the field order is the byte layout of
// the per-instance vertex buffer (stride = sizeof of the struct).
//
// renderer.c / geometry_registry.c / highlight_mask.c bind these fields by
// offsetof, so a drift against the shader-side attribute offsets (see the
// `in vec4` blocks in the .glsl sources) is a silent per-vertex mis-fetch,
// not a compile error.

#pragma once

#include "gfx/utility.h"

// cube.glsl / shadow_caster_cube.glsl / depth_only_cube.glsl (80 bytes)
typedef struct cube_instance
{
	Vec4 xform_row0; // 3x4 affine, rows
	Vec4 xform_row1;
	Vec4 xform_row2;
	Vec4 base_color; // .rgb = linear baseColor, .a = alpha
	Vec4 material;	// .x = metallic, .y = roughness, .z = shadow-cast bit, .w = reserved
} cube_instance_t;
#define CUBE_INSTANCE_STRIDE (sizeof( cube_instance_t ))

// sphere.glsl / shadow_caster_sphere.glsl / depth_only_sphere.glsl (112 bytes)
typedef struct sphere_instance
{
	Vec4 xform_row0; // .xyz = rotation row 0, .w = center.x
	Vec4 xform_row1; // .xyz = rotation row 1, .w = center.y
	Vec4 xform_row2; // .xyz = rotation row 2, .w = center.z
	Vec4 base_color; // .rgb = linear baseColor, .a = alpha
	Vec4 params;	 // .x = radius
	Vec4 material;	// .x = metallic, .y = roughness, .z = shadow-cast bit, .w = pattern switch
	Vec4 cap_color; // .rgb = linear polar-cap paint color, .a = cap threshold: cosine of
				   // the cap's angular radius around local +z (1.0 = no cap, read only
				   // by sphere.glsl; the depth-only / shadow-caster spheres ignore it)
} sphere_instance_t;
#define SPHERE_INSTANCE_STRIDE (sizeof( sphere_instance_t ))

// capsule.glsl / shadow_caster_capsule.glsl / depth_only_capsule.glsl (96 bytes)
typedef struct capsule_instance
{
	Vec4 xform_row0; // .xyz = rotation row 0, .w = center.x
	Vec4 xform_row1; // .xyz = rotation row 1, .w = center.y
	Vec4 xform_row2; // .xyz = rotation row 2, .w = center.z
	Vec4 base_color; // .rgb = linear baseColor, .a = alpha
	Vec4 params;	 // .x = halfLength, .y = radius
	Vec4 material;	// .x = metallic, .y = roughness, .z = shadow-cast bit, .w = reserved
} capsule_instance_t;
#define CAPSULE_INSTANCE_STRIDE (sizeof( capsule_instance_t ))

// geom.glsl / shadow_caster_geom.glsl / depth_only_geom.glsl (96 bytes)
typedef struct geom_instance
{
	Vec4 xform_row0; // .xyz = rotation row 0, .w = center.x
	Vec4 xform_row1; // .xyz = rotation row 1, .w = center.y
	Vec4 xform_row2; // .xyz = rotation row 2, .w = center.z
	Vec4 base_color; // .rgb = linear baseColor, .a = alpha
	Vec4 scale;		 // .xyz = per-instance scale
	Vec4 material;	 // .x = metallic, .y = roughness, .z = materialMode, .w = gridCellSize
} geom_instance_t;
#define GEOM_INSTANCE_STRIDE (sizeof( geom_instance_t ))

// mask_hull.glsl (64 bytes)
typedef struct mask_hull_instance
{
	Vec4 xform_row0;
	Vec4 xform_row1;
	Vec4 xform_row2;
	Vec4 scale_kind; // .xyz = per-instance scale, .w = highlight kind
} mask_hull_instance_t;
#define MASK_HULL_INSTANCE_STRIDE (sizeof( mask_hull_instance_t ))

// mask_capsule.glsl (64 bytes)
typedef struct mask_capsule_instance
{
	Vec4 xform_row0; // .xyz = R row 0, .w = center.x
	Vec4 xform_row1; // .xyz = R row 1, .w = center.y
	Vec4 xform_row2; // .xyz = R row 2, .w = center.z
	Vec4 params;	 // .x = halfLength, .y = radius, .z = highlight kind
} mask_capsule_instance_t;
#define MASK_CAPSULE_INSTANCE_STRIDE (sizeof( mask_capsule_instance_t ))

// mask_sphere.glsl (32 bytes)
typedef struct mask_sphere_instance
{
	Vec4 center_radius; // .xyz = center, .w = radius
	Vec4 kind;			// .x = highlight kind
} mask_sphere_instance_t;
#define MASK_SPHERE_INSTANCE_STRIDE (sizeof( mask_sphere_instance_t ))

// Layout guards: the per-instance vertex buffer stride must equal the struct
// size and every field must sit on a 16-byte boundary (one FLOAT4 each). A
// stray padding byte breaks the attribute fetch silently.
_Static_assert( sizeof( Vec4 ) == 16, "Vec4 must be 16 bytes (one FLOAT4 attribute)" );
_Static_assert( sizeof( cube_instance_t ) == 5 * 16, "cube_instance_t layout" );
_Static_assert( sizeof( sphere_instance_t ) == 7 * 16, "sphere_instance_t layout" );
_Static_assert( sizeof( capsule_instance_t ) == 6 * 16, "capsule_instance_t layout" );
_Static_assert( sizeof( geom_instance_t ) == 6 * 16, "geom_instance_t layout" );
_Static_assert( sizeof( mask_hull_instance_t ) == 4 * 16, "mask_hull_instance_t layout" );
_Static_assert( sizeof( mask_capsule_instance_t ) == 4 * 16, "mask_capsule_instance_t layout" );
_Static_assert( sizeof( mask_sphere_instance_t ) == 2 * 16, "mask_sphere_instance_t layout" );
