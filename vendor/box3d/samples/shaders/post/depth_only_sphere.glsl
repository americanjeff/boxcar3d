// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

// Depth-only pre-pass for spheres. Same shape as
// the lit sphere impostor: bounding-cube proxy in the VS, analytic
// ray-sphere intersection in the FS. Writes the analytic surface's linear
// view-space depth to an R32F color attachment and the reverse-Z clip
// depth to gl_FragDepth (transient D32F attachment, rasterizer only).

#pragma sokol @module depth_only_sphere

#pragma sokol @ctype mat4 Mat4
#pragma sokol @ctype vec4 Vec4
#pragma sokol @ctype vec3 b3Vec3
#pragma sokol @ctype vec2 b3Vec2

#pragma sokol @vs vs

layout(binding = 0) uniform ub_frame
{
	mat4 view_proj;
};

in vec3 in_pos; // unit-cube corner, half-extent 0.5

// Per-instance data (step rate 2, offsets in the 96-byte sphere_instance_t,
// stride 96 - same arena as the lit pipeline): xform rows at 0/16/32,
// params at 64.
in vec4 inst_xform_row0; // .w = center.x
in vec4 inst_xform_row1; // .w = center.y
in vec4 inst_xform_row2; // .w = center.z
in vec4 inst_params; // .x = radius

out vec3 v_world_pos_proxy;
flat out vec3 v_center;
flat out float v_radius;

void main()
{
	vec3 center = vec3(inst_xform_row0.w, inst_xform_row1.w, inst_xform_row2.w);
	float radius = inst_params.x;
	vec3 world_pos = center + (2.0 * radius) * in_pos;
	
	v_world_pos_proxy = world_pos;
	v_center = center;
	v_radius = radius;
	
	gl_Position = view_proj * vec4(world_pos, 1.0);
}

#pragma sokol @end

#pragma sokol @fs fs

layout(binding = 1) uniform ub_pass
{
	mat4 view_proj; // for gl_FragDepth (reverse-Z)
	mat4 view; // for linear view-space depth
	vec4 camera_pos; // .xyz = world camera position
	vec4 win_depth; // .x = slope, .y = bias: gl_FragDepth = ndc_z * x + y
};

in vec3 v_world_pos_proxy;
flat in vec3 v_center;
flat in float v_radius;

out vec4 out_linear_depth;

void main()
{
	vec3 ro = camera_pos.xyz;
	vec3 rd = normalize(v_world_pos_proxy - ro);
	
	vec3 oc = ro - v_center;
	float b = dot(oc, rd);
	float c2 = dot(oc, oc) - v_radius * v_radius;
	float h = b * b - c2;
	if (h < 0.0) discard;
	float t = -b - sqrt(h);
	if (t < 0.0) discard;
	
	vec3 hit_world = ro + t * rd;
	float view_z = -(view * vec4(hit_world, 1.0)).z;
	
	vec4 hit_clip = view_proj * vec4(hit_world, 1.0);
	// hit_clip.z/hit_clip.w is the [0,1] NDC clip ratio (reverse-Z:
	// near -> 1, far -> 0). Both backends use [0,1] NDC (GL via
	// glClipControl(ZERO_TO_ONE), WGPU natively), so window depth == NDC
	// and win_depth is the identity: the analytic impostor depth lands on
	// the same scale as the rasterized depth and GREATER tests against
	// the prepass compare like-for-like.
	gl_FragDepth = hit_clip.z / hit_clip.w * win_depth.x + win_depth.y;

	out_linear_depth = vec4(view_z, 0.0, 0.0, 0.0);
}

#pragma sokol @end

#pragma sokol @program prog vs fs
