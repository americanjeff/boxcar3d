// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

// Highlight mask, sphere impostor.
//
// Stripped sibling of depth_only_sphere. Same bounding-cube proxy + analytic
// ray-sphere intersection in the FS, outputs a uint highlight kind to the
// R8_UINT mask attachment instead of writing depth. Depth-TEST against the
// existing GTAO prepass depth (reverse-Z GREATER, no depth write) so
// highlighted shapes behind opaque geometry don't bleed outlines.

#pragma sokol @module mask_sphere

#pragma sokol @ctype mat4 Mat4
#pragma sokol @ctype vec4 Vec4
#pragma sokol @ctype vec3 b3Vec3

#pragma sokol @vs vs

layout( binding = 0 ) uniform ub_frame
{
	mat4 view_proj;
};

in vec3 in_pos; // unit-cube corner, half-extent 0.5

// Per-instance data (step rate 2, the 32-byte mask_sphere_instance_t):
// center_radius at 0, kind at 16.
in vec4 inst_center_radius; // .xyz = center, .w = radius
in vec4 inst_kind;			// .x = highlight kind (1.0 = hover, 2.0 = select), .yzw unused

out vec3 v_world_pos_proxy;
flat out vec3 v_center;
flat out float v_radius;
flat out float v_kind;

void main()
{
	vec3 center = inst_center_radius.xyz;
	float radius = inst_center_radius.w;

	vec3 world_pos = center + ( 2.0 * radius ) * in_pos;

	v_world_pos_proxy = world_pos;
	v_center = center;
	v_radius = radius;
	v_kind = inst_kind.x;

	gl_Position = view_proj * vec4( world_pos, 1.0 );
}
#pragma sokol @end

#pragma sokol @fs fs

layout( binding = 1 ) uniform ub_pass
{
	mat4 view_proj;	 // for reverse-Z gl_FragDepth
	vec4 camera_pos; // .xyz = world camera position
	vec4 win_depth;	 // .x = slope, .y = bias: gl_FragDepth = ndc_z * x + y
};

in vec3 v_world_pos_proxy;
flat in vec3 v_center;
flat in float v_radius;
flat in float v_kind;

layout( location = 0 ) out vec4 out_kind;

void main()
{
	vec3 ro = camera_pos.xyz;
	vec3 rd = normalize( v_world_pos_proxy - ro );

	vec3 oc = ro - v_center;
	float b = dot( oc, rd );
	float c2 = dot( oc, oc ) - v_radius * v_radius;
	float h = b * b - c2;
	if ( h < 0.0 )
		discard;
	float t = -b - sqrt( h );
	if ( t < 0.0 )
		discard;

	// Write analytic surface depth so the depth test compares at the
	// sphere's true surface, not at the bounding-cube proxy. Matches the
	// prepass depth's contents bit-for-bit, so GREATER_EQUAL passes when
	// unoccluded and fails when an opaque shape is in front.
	vec3 hit_world = ro + t * rd;
	vec4 hit_clip = view_proj * vec4( hit_world, 1.0 );
	gl_FragDepth = hit_clip.z / hit_clip.w * win_depth.x + win_depth.y;

	// R8 UNORM mask: 1.0=hover, 2.0=select -> 0.5, 1.0.
	out_kind = vec4( v_kind * 0.5, 0.0, 0.0, 1.0 );
}
#pragma sokol @end

#pragma sokol @program prog vs fs
