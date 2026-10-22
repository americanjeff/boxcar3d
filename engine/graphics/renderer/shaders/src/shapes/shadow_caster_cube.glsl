// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

// Shadow caster for cubes. Depth-only, no fragment output, the
// pipeline runs with color_count=0 and writes only into the cascade's
// depth attachment.
//
// Shares the cube instance buffer layout with cube.glsl: each instance is
// a 3x4 row-major affine plus PBR material data (base_color + material are
// unused here but kept in the layout so one storage buffer feeds both
// pipelines without any repacking, struct stride MUST match the lit
// pipeline's, otherwise indexing breaks).
//
// Shadow space is standard Z (0 near = closer to light, 1 far). The light
// matrix uploaded as ub_frame.light_view_proj is constructed with
// an orthographic projection and mat4LookAt on the C side, which already
// produces the correct convention. No reverse-Z swap.
//
// `@module shadow_cube` keeps the generated symbols (shadow_cube_*) out
// collision with the lit cube pipeline's symbols.

#pragma sokol @module shadow_cube

#pragma sokol @ctype mat4 Mat4
#pragma sokol @ctype vec4 Vec4
#pragma sokol @ctype vec3 b3Vec3
#pragma sokol @ctype vec2 b3Vec2

#pragma sokol @vs vs

layout( binding = 0 ) uniform ub_frame
{
	mat4 light_view_proj;
};

in vec3 in_pos;

// Per-instance xform rows (step rate 2, offsets 0/16/32 in the 80-byte
// cube_instance_t, stride 80 — same arena as the lit pipeline). base_color
// / material are not needed by the caster and are simply not attributes.
in vec4 inst_xform_row0;
in vec4 inst_xform_row1;
in vec4 inst_xform_row2;

out vec3 v_world_pos;

void main()
{
	vec4 local_pos = vec4( in_pos, 1.0 );
	vec3 world_pos =
		vec3( dot( inst_xform_row0, local_pos ), dot( inst_xform_row1, local_pos ), dot( inst_xform_row2, local_pos ) );
	v_world_pos = world_pos;
	gl_Position = light_view_proj * vec4( world_pos, 1.0 );
}
#pragma sokol @end

#pragma sokol @fs fs
// FORK (wasm/WGPU): the cascade pass carries a throwaway color
// attachment because WebGPU depth-only passes (empty colorAttachments)
// silently never write the depth attachment. The value is never read.
out vec4 out_color;
// Same WGPU gap as the geom caster (root-caused 2026-09-17 with a
// cascade-depth probe pass): a gl_FragDepth written from gl_FragCoord.z
// is never stored in this pass — the same read-position +
// write-conservative-depth combination D3D11 rejects. Rebuild the depth
// from the projection's depth row like the sphere/capsule casters do.
// A no-op value-wise on the GL backends.
layout( depth_greater ) out float gl_FragDepth;
layout( binding = 1 ) uniform ub_pass
{
	vec4 light_dir; // unused for cubes, present so the layout matches the other casters
	vec4 depth_row; // depth row of the light view-proj, world position to clip depth
};

in vec3 v_world_pos;

void main()
{
	out_color = vec4( 0.0 );
	// Orthographic light, so the clip w is 1 and the divide drops out.
	gl_FragDepth = dot( depth_row, vec4( v_world_pos, 1.0 ) );
}
#pragma sokol @end

#pragma sokol @program caster vs fs
