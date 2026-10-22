// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

// Depth-only pre-pass for cubes. Writes positive
// linear view-space depth to an R32F color attachment, the D32F depth
// attachment is transient (rasterizer / early-Z only, never sampled). The
// full XeGTAO port reconstructs normals from depth derivatives inside
// MainPass, so the prepass produces no normal channel.

#pragma sokol @module depth_only_cube

#pragma sokol @ctype mat4 Mat4
#pragma sokol @ctype vec4 Vec4
#pragma sokol @ctype vec3 b3Vec3
#pragma sokol @ctype vec2 b3Vec2

#pragma sokol @vs vs

layout(binding = 0) uniform ub_frame
{
	mat4 view_proj;
	mat4 view;
};

in vec3 in_pos;

// Per-instance xform rows (step rate 2, offsets 0/16/32 in the 80-byte
// cube_instance_t, stride 80 - same arena as the lit pipeline).
in vec4 inst_xform_row0;
in vec4 inst_xform_row1;
in vec4 inst_xform_row2;

out float v_linear_view_z;

void main()
{
	vec4 local_pos = vec4(in_pos, 1.0);
	vec3 world_pos = vec3(
		dot(inst_xform_row0, local_pos),
		dot(inst_xform_row1, local_pos),
		dot(inst_xform_row2, local_pos)
	);
	vec4 view_h = view * vec4(world_pos, 1.0);
	v_linear_view_z = -view_h.z;
	gl_Position = view_proj * vec4(world_pos, 1.0);
}

#pragma sokol @end

#pragma sokol @fs fs

in float v_linear_view_z;
out vec4 out_linear_depth;

void main()
{
	out_linear_depth = vec4(v_linear_view_z, 0.0, 0.0, 0.0);
}

#pragma sokol @end

#pragma sokol @program prog vs fs
