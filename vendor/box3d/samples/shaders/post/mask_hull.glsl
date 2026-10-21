// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

// Highlight mask, convex hull (triangle-rasterized).
//
// Same vertex math as depth_only_geom (transform + per-instance scale), but the
// FS just emits the highlight kind into the R8_UINT mask. Rasterized depth
// is correct as-is, no gl_FragDepth write. Pipeline depth-tests GREATER_EQUAL
// against the prepass depth.

#pragma sokol @module mask_hull

#pragma sokol @ctype mat4 Mat4
#pragma sokol @ctype vec4 Vec4
#pragma sokol @ctype vec3 b3Vec3

#pragma sokol @vs vs

layout( binding = 0 ) uniform ub_frame
{
	mat4 view_proj;
};

// Per-instance data (step rate 2, the 64-byte mask_hull_instance_t): xform
// rows at 0/16/32, scale_kind at 48. Per-hull draws pick their slot
// through the C-side per-binding vertex buffer offset.
in vec4 inst_xform_row0;
in vec4 inst_xform_row1;
in vec4 inst_xform_row2;
in vec4 inst_scale_kind; // .xyz = per-instance scale, .w = highlight kind

// Position-only input. The shared geom vbo carries position+normal
// (stride 24 bytes), but the mask FS only needs world position. We
// don't declare an `in_normal` attribute so the GL linker doesn't strip
// it and warn. The C-side pipeline desc skips the in_normal binding to
// match.
in vec3 in_pos;

flat out float v_kind;

void main()
{
	vec3 scaled_pos = in_pos * inst_scale_kind.xyz;
	vec4 local_pos = vec4( scaled_pos, 1.0 );
	vec3 world_pos =
		vec3( dot( inst_xform_row0, local_pos ), dot( inst_xform_row1, local_pos ), dot( inst_xform_row2, local_pos ) );

	v_kind = inst_scale_kind.w;
	gl_Position = view_proj * vec4( world_pos, 1.0 );
}
#pragma sokol @end

#pragma sokol @fs fs

flat in float v_kind;

layout( location = 0 ) out vec4 out_kind;

void main()
{
	// R8 UNORM mask: 1.0=hover, 2.0=select -> 0.5, 1.0.
	out_kind = vec4( v_kind * 0.5, 0.0, 0.0, 1.0 );
}
#pragma sokol @end

#pragma sokol @program prog vs fs
