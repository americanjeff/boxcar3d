// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

// Shadow caster for triangle geometries (hulls, meshes, heightfields).
// Depth-only: color_count=0, empty fragment shader, writes only the
// cascade's depth attachment.
//
// Mirrors geom.glsl exactly in instance/vertex layout so the same
// per-frame instance buffer + per-entry vbo/ibo bindings drive both
// pipelines. The lit pipeline samples the surface normal for shading,
// here it's accepted as a vertex attribute and ignored. Keeping the
// vertex layout identical means the renderer doesn't have to maintain
// two parallel buffer schemes.
//
// `@module shadow_geom` keeps the generated symbols out of collision
// with the lit geom pipeline's symbols.

#pragma sokol @module shadow_geom

#pragma sokol @ctype mat4 Mat4
#pragma sokol @ctype vec4 Vec4
#pragma sokol @ctype vec3 b3Vec3
#pragma sokol @ctype vec2 b3Vec2

#pragma sokol @vs vs

layout( binding = 0 ) uniform ub_frame
{
	mat4 light_view_proj;
};

// Per-instance data (step rate 2, offsets in the 96-byte geom_instance_t,
// stride 96 — same arena as the lit pipeline): xform rows at 0/16/32,
// scale at 64. Per-mesh first-instance picks come from the C-side
// per-binding vertex buffer offset.
in vec4 inst_xform_row0; // .xyz = rotation row 0, .w = center.x
in vec4 inst_xform_row1;
in vec4 inst_xform_row2;
in vec4 inst_scale;		 // .xyz = per-instance scale (mesh only), hulls/heightfields = 1

// Position-only input. The shared vertex buffer carries position+normal
// (stride 24 bytes), but this caster doesn't read the normal. We just
// don't declare an `in_normal` attribute so glslang doesn't keep it
// around (and the GL driver doesn't warn about an unused attribute slot
// after stripping). The C-side pipeline desc skips the in_normal binding
// to match.
in vec3 in_pos;

out vec3 v_world_pos;

void main()
{
	vec3 scaled_pos = in_pos * inst_scale.xyz;
	vec4 local_pos = vec4( scaled_pos, 1.0 );
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
// Second WGPU gap, same class (root-caused 2026-09-17 with a
// cascade-depth probe pass: with only this caster enabled the cascade
// stays fully cleared): a gl_FragDepth written from gl_FragCoord.z is
// never stored in this pass — the same read-position + write-conservative-
// depth combination D3D11 rejects (see shadow_caster_sphere.glsl).
// Rebuild the depth from the projection's depth row exactly like the
// sphere/capsule casters do. On the GL backends the value equals the
// rasterized depth, so native shots are pixel-identical.
layout( depth_greater ) out float gl_FragDepth;
layout( binding = 1 ) uniform ub_pass
{
	vec4 light_dir; // unused for geometry, present so the layout matches the other casters
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
