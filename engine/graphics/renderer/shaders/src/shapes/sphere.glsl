// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

// Sphere impostor.
//
// Per-instance: a 3x4 rigid affine (orthonormal rotation rows in .xyz of each
// xform_row*, sphere center in .w of each row), an RGBA color, a `params`
// row whose .x is the world-space radius, and a `cap_color` row: .rgb is a
// linear polar-cap paint color, .a is the cap threshold — the cosine of the
// cap's angular radius around the instance's local +z axis (1.0 = no cap,
// 0.0 = +z hemisphere, -1.0 = the whole sphere). Rotation does not change
// the silhouette (a sphere is rotation-invariant) so the bounding-cube proxy
// is emitted axis-aligned. Rotation feeds the surface pattern in the FS so
// spin is visible.
//
// Pipeline overview:
//   VS: emit a unit-cube vertex scaled by 2*radius and translated by center.
//       Pass world position of the proxy vertex (interpolated) plus flat
//       per-instance data (center, radius, rotation rows, color) to FS.
//   FS: reconstruct view ray as (camera, normalize(v_world_pos_proxy - camera)).
//       Analytic ray-sphere intersection. discard on miss / behind-camera.
//       Compute world-space normal at the hit, transform to object space via
//       transpose(rotation), shade three great-circle rings at the
//       object-space x=0, y=0, z=0 equators (constant screen-space pixel
//       thickness via fwidth) over a north/south hemisphere base contrast.
//       The rings are a per-instance pattern switch (material.w: 1.0 = on
//       so spin is visible, 0.0 = plain matte sphere). The polar cap
//       (cap_color: paint + threshold) recolors the base albedo where the
//       object-space normal's z component exceeds the threshold
//       (cap_color.a, 1.0 = disabled); the hemisphere contrast and the
//       rings apply over the cap exactly as over the base color. Apply
//       Lambert + ambient against world-space sun, write reverse-Z
//       gl_FragDepth.
//
// `@module sphere` prefixes the generated C symbols (sphere_ub_frame_t,
// sphere_instance_t, sphere_shader_desc, ...) so this header coexists with
// cube.glsl.h in renderer.c without typedef collisions on ub_frame_t.
//
// UBO layout. UBOs are per-stage in sokol-shdc:
//   VS binding=0 ub_frame: just view_proj. That's all the VS needs to emit
//                          the proxy in clip space.
//   FS binding=1 ub_pass:  sun + debug flags + camera_pos + view_proj + view.
//                          The frame-level matrices live here (rather than in
//                          a second FS UBO at a different binding) because
//                          the renderer always re-applies ub_pass per draw,
//                          and one FS UBO is simpler than two. Naming is a
//                          slight stretch (some fields are per-frame, not
//                          per-pass) but correctness-wise irrelevant in a
//                          single-pass renderer.
//
// gl_FragDepth disables hi-Z. That's accepted for impostors.

#pragma sokol @module sphere

#pragma sokol @ctype mat4 Mat4
#pragma sokol @ctype vec4 Vec4
#pragma sokol @ctype vec3 b3Vec3
#pragma sokol @ctype vec2 b3Vec2

#pragma sokol @vs vs

layout( binding = 0 ) uniform ub_frame
{
	mat4 view_proj;
};

in vec3 in_pos; // unit-cube corner, half-extent 0.5

// Per-instance data, one attribute per sphere_instance_t field (step rate
// 2, offsets 0/16/32/48/64/80/96 in the 112-byte struct, stride 112). See
// cube.glsl for the per-draw offset rationale.
in vec4 inst_xform_row0; // .xyz = rotation row 0, .w = center.x
in vec4 inst_xform_row1; // .xyz = rotation row 1, .w = center.y
in vec4 inst_xform_row2; // .xyz = rotation row 2, .w = center.z
in vec4 inst_base_color; // .rgb = linear baseColor, .a = alpha
in vec4 inst_params;	 // .x = radius, .yzw = unused
in vec4 inst_material;	 // .x = metallic, .y = roughness,
					 // .z = shadow-cast bit (, CPU-only, ignored here),
					 // .w = pattern switch (1.0 = great-circle rings,
					 //      0.0 = plain matte sphere)
in vec4 inst_cap_color; // .rgb = linear polar-cap paint color,
					 // .a = cap threshold: cosine of the cap's angular
					 //      radius around local +z (1.0 = no cap,
					 //      0.0 = +z hemisphere, -1.0 = whole sphere)

// Interpolated: any point along the camera-to-pixel ray works as a far
// reference, we re-normalize in FS. Per-pixel (not per-sample): the FS
// computes analytical sub-pixel coverage from the signed silhouette
// distance and feeds it through alpha-to-coverage, which replaces the
// per-sample ray test the `sample` qualifier used to do.
out vec3 v_world_pos_proxy;

// Flat: same value for every fragment in this instance.
flat out vec3 v_center;
flat out float v_radius;
flat out vec3 v_rot_row0;
flat out vec3 v_rot_row1;
flat out vec3 v_rot_row2;
flat out vec4 v_base_color;
flat out vec4 v_material;
flat out vec4 v_cap_color;

void main()
{
	// sphere center in world space
	vec3 center = vec3( inst_xform_row0.w, inst_xform_row1.w, inst_xform_row2.w );
	float radius = inst_params.x;

	// Local in_pos has half-extent 0.5, multiply by 2*radius to get a cube
	// half-extent radius exactly enclosing the sphere.
	// This creates an AABB in world space
	vec3 world_pos = center + ( 2.0 * radius ) * in_pos;

	v_world_pos_proxy = world_pos;
	v_center = center;
	v_radius = radius;
	v_rot_row0 = inst_xform_row0.xyz;
	v_rot_row1 = inst_xform_row1.xyz;
	v_rot_row2 = inst_xform_row2.xyz;
	v_base_color = inst_base_color;
	v_material = inst_material;
	v_cap_color = inst_cap_color;

	gl_Position = view_proj * vec4( world_pos, 1.0 );
}

#pragma sokol @end

#pragma sokol @fs fs

#pragma sokol @include ../common/pbr.glsl
#pragma sokol @include ../common/shadow_cascade.glsl

layout( binding = 1 ) uniform ub_pass
{
	vec4 sun_dir_world;		  // .xyz = world-space dir TO sun (normalized)
	vec4 sun_color;			  // .rgb = color, .a = ambient strength (flat-ambient fallback)
	ivec4 flags;			  // .x = debug_view_mode (0 lit, 1 view-depth, 2 cascade-index)
	vec4 camera_pos;		  // .xyz = camera world pos, .w unused
	mat4 view_proj;			  // for reverse-Z gl_FragDepth
	mat4 view;				  // for view-space depth debug mode + cascade selection
	vec4 cascade_far_view_z;  // far view-space Z per cascade
	vec4 cascade_texel_world; // one shadow texel in world units per cascade
	vec4 cascade_depth_bias;  // residual comparison bias in shadow clip-Z per cascade
	vec4 shadow_params;		  // .x = UV.y sign, .y = one texel in UV
	mat4 cascade_matrices[SHADOW_CASCADE_COUNT]; // light-space view-proj per cascade
	vec4 sh[9];				  // IBL diffuse SH coefficients (band 0..2, RGB in .xyz)
	vec4 ibl_params;		  // .x = prefilter cube max_lod, .y = IBL enable (1=IBL, 0=flat ambient), .zw reserved
	vec4 win_depth;		  // .x = slope, .y = bias: gl_FragDepth = ndc_z * x + y
	vec4 view_size;		  // OIT (change 14): .xy = target resolution for the peel-col range test
	vec4 peel_range;		  // OIT: .x = prev-layer test on, .y = cur-layer test on, .z = half-float eps, .w unused
};

#pragma sokol @image_sample_type tex_shadow depth
layout( binding = 1 ) uniform texture2DArray tex_shadow;
#pragma sokol @sampler_type smp_shadow comparison
layout( binding = 0 ) uniform samplerShadow smp_shadow;

// IBL bindings, same convention as cube.glsl: texture bindings 2/3,
// sampler bindings 1/2, disjoint from the shadow path's 1/0.
#pragma sokol @image_sample_type tex_ibl_spec float
layout( binding = 2 ) uniform textureCube tex_ibl_spec;
#pragma sokol @sampler_type smp_ibl_spec filtering
layout( binding = 1 ) uniform sampler smp_ibl_spec;
#pragma sokol @image_sample_type tex_brdf_lut float
layout( binding = 3 ) uniform texture2D tex_brdf_lut;
#pragma sokol @sampler_type smp_brdf_lut filtering
layout( binding = 2 ) uniform sampler smp_brdf_lut;

// GTAO, same convention as cube.glsl. Multiplies only the IBL ambient.
#pragma sokol @image_sample_type tex_ao unfilterable_float
layout( binding = 4 ) uniform texture2D tex_ao;
#pragma sokol @sampler_type smp_ao nonfiltering
layout( binding = 3 ) uniform sampler smp_ao;

// OIT depth peel (change 14): the per-pixel linear-view-distance maps the
// peel passes write, sampled 1:1 (point). Non-peel passes bind the 1x1
// dummy and run peel_range = 0, which skips the range test.
#pragma sokol @image_sample_type tex_peel_prev float
layout( binding = 5 ) uniform texture2D tex_peel_prev;
#pragma sokol @image_sample_type tex_peel_cur float
layout( binding = 6 ) uniform texture2D tex_peel_cur;
#pragma sokol @sampler_type smp_peel nonfiltering
layout( binding = 4 ) uniform sampler smp_peel;

#pragma sokol @include ../common/shadow_pcf.glsl

// Normal-offset shadows, see cube.glsl for the longer note.
float sampleCascade( int cascade, vec3 world_pos, vec3 world_normal )
{
	float texel_world = cascade_texel_world[cascade];
	float depth_bias = cascade_depth_bias[cascade];

	// Shrink the kernel in the coarser cascades so the penumbra keeps a
	// constant world width. See cube.glsl for the longer note.
	float scale = clamp( cascade_texel_world.x / texel_world, 0.25, 1.0 );

	// Slide the lookup along the surface far enough to clear the whole
	// scaled 7x7 footprint, growing toward grazing light.
	float n_dot_l = max( dot( world_normal, normalize( sun_dir_world.xyz ) ), 0.0 );
	float sin_theta = sqrt( max( 1.0 - n_dot_l * n_dot_l, 0.0 ) );
	float offset = ( 3.0 * scale + 0.5 ) * 1.41421 * sin_theta * texel_world;

	vec4 light_clip = cascade_matrices[cascade] * vec4( world_pos + world_normal * offset, 1.0 );
	vec3 light_ndc = light_clip.xyz / light_clip.w;
	// Backend-dependent Y orientation, see cube.glsl for the longer note.
	float ny = light_ndc.y * shadow_params.x;
	vec3 light_uv = vec3( light_ndc.x * 0.5 + 0.5, ny * 0.5 + 0.5, light_ndc.z );

	if ( light_uv.z < 0.0 || light_uv.z > 1.0 )
	{
		return 1.0;
	}

	// The white border dissolves the XY boundary, only reject past the
	// kernel's reach. See cube.glsl for the longer note.
	float reach = ( 3.0 * scale + 1.0 ) * shadow_params.y;
	if ( any( lessThan( light_uv.xy, vec2( -reach ) ) ) || any( greaterThan( light_uv.xy, vec2( 1.0 + reach ) ) ) )
	{
		return 1.0;
	}

	return sampleShadowPCF( tex_shadow, smp_shadow, cascade, light_uv, depth_bias, scale, shadow_params.y );
}

float sampleShadowCascaded( vec3 world_pos, vec3 world_normal, float view_z )
{
	int cascade = selectShadowCascade( cascade_far_view_z, view_z );

	float shadow = sampleCascade( cascade, world_pos, world_normal );

	// Blend the last 10% of each cascade's range with the next cascade
	// to hide the polygonal step where they meet. See cube.glsl for the
	// longer note.
	if ( cascade < SHADOW_CASCADE_COUNT - 1 )
	{
		float far_z = cascade_far_view_z[cascade];
		float near_z = ( cascade == 0 ) ? 0.0 : cascade_far_view_z[cascade - 1];
		float blend_start = mix( far_z, near_z, 0.1 );
		if ( view_z > blend_start )
		{
			float alpha = ( view_z - blend_start ) / ( far_z - blend_start );
			shadow = mix( shadow, sampleCascade( cascade + 1, world_pos, world_normal ), alpha );
		}
	}

	return shadow;
}

in vec3 v_world_pos_proxy;

// sphere center in world space
flat in vec3 v_center;
flat in float v_radius;
flat in vec3 v_rot_row0;
flat in vec3 v_rot_row1;
flat in vec3 v_rot_row2;
flat in vec4 v_base_color;
flat in vec4 v_material;
flat in vec4 v_cap_color;

out vec4 out_color;

void main()
{
	// Ray construction (world space)
	// ray origin
	vec3 ro = camera_pos.xyz;

	// ray direction
	vec3 rd = normalize( v_world_pos_proxy - ro );

	// Ray-sphere intersection
	// |ro + t*rd - c|^2 = r^2 => t^2 + 2*b*t + c2 = 0
	vec3 oc = ro - v_center;
	float b = dot( oc, rd );
	float c2 = dot( oc, oc ) - v_radius * v_radius;
	float h = b * b - c2;

	// Analytical silhouette AA. `d` is the signed perpendicular distance from
	// the ray-line to the sphere surface (in world units): negative when the
	// ray hits, positive when it misses by `d`. fwidth(d) gives world-units
	// per pixel near the silhouette, which becomes the AA half-width. See
	// https://iquilezles.org/articles/spherefunctions . Computed in uniform
	// control flow before any discard so derivatives are defined.
	float d = sqrt( max( 0.0, v_radius * v_radius - h ) ) - v_radius;
	float aa = max( fwidth( d ), 1e-6 );
	float coverage = 1.0 - smoothstep( -aa, aa, d );

	// For hits use the near intersection. For near-misses (h<0) the ray
	// doesn't actually touch the sphere, use the closest-approach distance
	// -b instead, and shade from the closest-approach point. The resulting
	// normal (direction from center to closest-approach) is the silhouette
	// normal, which is what these sub-pixel fragments should display anyway.
	float t = ( h >= 0.0 ) ? ( -b - sqrt( h ) ) : -b;
	if ( coverage <= 0.0 || t < 0.0 )
	{
		// True miss outside the AA band, or sphere behind camera, or camera
		// inside the sphere.
		discard;
	}

	vec3 hit_world = ro + t * rd;
	vec3 n_world = normalize( hit_world - v_center );

	// Object-space normal via R^T
	// n_obj = R^T * n_world. R^T's rows are the columns of R. The .x
	// components of v_rot_row0/1/2 form row 0 of R^T, .y components form row
	// 1, .z components form row 2.
	vec3 n_obj = vec3( v_rot_row0.x * n_world.x + v_rot_row1.x * n_world.y + v_rot_row2.x * n_world.z,
					   v_rot_row0.y * n_world.x + v_rot_row1.y * n_world.y + v_rot_row2.y * n_world.z,
					   v_rot_row0.z * n_world.x + v_rot_row1.z * n_world.y + v_rot_row2.z * n_world.z );

	// Surface pattern
	// Hemisphere split: north 1.0, south 0.65, base shading contrast.
	float hemi = ( n_obj.y > 0.0 ) ? 1.0 : 0.65;

	// Screen-space line width in pixels, shared by the rings and the cap rim.
	const float LINE_PIXELS = 1.5;

	// Polar cap: a recolored region of the SAME material, not flat paint.
	// Where the object-space normal's z component exceeds the threshold
	// (v_cap_color.a: cosine of the cap's angular radius around local +z,
	// 1.0 = disabled) the cap color replaces the base albedo; the hemisphere
	// contrast and the ring pattern below then apply over it exactly as over
	// the base color (the rings darken the cap color too). The rim uses the
	// same fwidth banding as the rings, so it stays ~LINE_PIXELS wide on
	// screen at any zoom.
	float cap_mask = 1.0 - smoothstep( 0.0, fwidth( n_obj.z ) * LINE_PIXELS, v_cap_color.a - n_obj.z );
	vec3 base = mix( v_base_color.rgb, v_cap_color.rgb, cap_mask ) * hemi;
	vec3 surface = base;

	// The great-circle pattern is a per-instance switch (material.w:
	// 1.0 = on so spin is visible, 0.0 = plain matte sphere). The branch
	// is uniform per instance, so it costs nothing in the off case.
	if ( v_material.w > 0.5 )
	{
		// Three great-circle rings at the equators of object-space X, Y, Z.
		// Each equator is the locus where the corresponding object-space
		// normal component is zero, so the distance-to-equator is just the
		// absolute value of that component (a chord-distance metric in [0, 1]
		// that's monotonic in the geodesic distance from the great circle).
		//
		// Constant screen-space thickness via per-component fwidth: each
		// ring's band scales with the per-pixel rate of change of *its own*
		// normal component, so it stays ~LINE_PIXELS wide independent of
		// camera zoom and viewing angle. fwidth is taken on the *signed*
		// component (not on abs(.)): abs has a derivative kink at zero (the
		// equator itself), so fwidth(abs(x)) gives garbage on 2x2 quads that
		// straddle the equator. Don't use max of all three fwidths as the
		// shared band: near the silhouette of one ring, the *other* two
		// components change huge amounts per pixel (the surface is edge-on),
		// and a shared band would over-fatten this ring.
		float ring_x = 1.0 - smoothstep( 0.0, fwidth( n_obj.x ) * LINE_PIXELS, abs( n_obj.x ) );
		float ring_y = 1.0 - smoothstep( 0.0, fwidth( n_obj.y ) * LINE_PIXELS, abs( n_obj.y ) );
		float ring_z = 1.0 - smoothstep( 0.0, fwidth( n_obj.z ) * LINE_PIXELS, abs( n_obj.z ) );
		float line = max( ring_x, max( ring_y, ring_z ) );
		vec3 line_color = base * 0.35;
		surface = mix( base, line_color, line );
	}

	// Reverse-Z depth (win_depth is the identity on both backends, see
	// depth_only_sphere).
	vec4 hit_clip = view_proj * vec4( hit_world, 1.0 );
	gl_FragDepth = hit_clip.z / hit_clip.w * win_depth.x + win_depth.y;

	// OIT depth peel (change 14), after the miss-discard and the gl_FragDepth
	// write so the peel depth attachment gets the true surface depth.
	// flags.x == 5: the peel pass reads the linear view distance out of
	// out_color. The range test keeps only this layer's band in the peel-col
	// passes; every other pass runs peel_range = 0 and skips it.
	float peel_view_z = -( view * vec4( hit_world, 1.0 ) ).z;
	if ( flags.x == 5 || peel_range.x > 0.5 || peel_range.y > 0.5 )
	{
		if ( flags.x == 5 )
		{
			out_color = vec4( peel_view_z, 0.0, 0.0, 1.0 );
			return;
		}
		vec2 peel_uv = gl_FragCoord.xy / view_size.xy;
		float d_prev = texture( sampler2D( tex_peel_prev, smp_peel ), peel_uv ).x;
		float d_cur = texture( sampler2D( tex_peel_cur, smp_peel ), peel_uv ).x;
		if ( ( peel_range.x > 0.5 && peel_view_z < d_prev + peel_range.z ) ||
			 ( peel_range.y > 0.5 && peel_view_z > d_cur + peel_range.z ) )
		{
			discard;
		}
	}

	// Output
	if ( flags.x == 1 )
	{
		// view-space depth grayscale, matches cube debug mode.
		vec3 hit_view = ( view * vec4( hit_world, 1.0 ) ).xyz;
		float view_depth = -hit_view.z;
		float v = clamp( view_depth / 50.0, 0.0, 1.0 );
		out_color = vec4( v, v, v, 1.0 );
		return;
	}
	if ( flags.x == 2 )
	{
		float view_z_dbg = -( view * vec4( hit_world, 1.0 ) ).z;
		int cascade = selectShadowCascade( cascade_far_view_z, view_z_dbg );
		vec4 light_clip = cascade_matrices[cascade] * vec4( hit_world, 1.0 );
		vec3 light_ndc = light_clip.xyz / light_clip.w;
		float ny = light_ndc.y * shadow_params.x;
		vec3 light_uv = vec3( light_ndc.x * 0.5 + 0.5, ny * 0.5 + 0.5, light_ndc.z );
		bool oob = any( lessThan( light_uv, vec3( 0.0 ) ) ) || any( greaterThan( light_uv, vec3( 1.0 ) ) );
		vec3 tint = vec3( 1.0 );
		if ( !oob )
		{
			tint = shadowCascadeTint( cascade );
		}
		out_color = vec4( tint, 1.0 );
		return;
	}
	if ( flags.x == 3 )
	{
		// View-space normal as RGB, [-1,1] mapped to [0,1].
		vec3 n_view = ( view * vec4( n_world, 0.0 ) ).xyz;
		out_color = vec4( normalize( n_view ) * 0.5 + 0.5, 1.0 );
		return;
	}

	// GTAO sample.
	vec2 ao_uv = gl_FragCoord.xy / vec2( textureSize( sampler2D( tex_ao, smp_ao ), 0 ) );
	float ao = textureLod( sampler2D( tex_ao, smp_ao ), ao_uv, 0.0 ).x;

	if ( flags.x == 4 )
	{
		out_color = vec4( vec3( ao ), 1.0 );
		return;
	}

	vec3 L = normalize( sun_dir_world.xyz );
	float n_dot_l = max( dot( n_world, L ), 0.0 );
	float view_z = -( view * vec4( hit_world, 1.0 ) ).z;
	float shadow = sampleShadowCascaded( hit_world, n_world, view_z );
	vec3 V = normalize( camera_pos.xyz - hit_world );
	vec3 direct = brdf_evaluate( n_world, V, L, sun_color.rgb * shadow, surface, v_material.x, v_material.y );
	vec3 ambient = pbrEvaluateAmbient( ibl_params.y > 0.5, n_world, V, surface, v_material.x, v_material.y, sun_color.a, sh,
									   tex_ibl_spec, smp_ibl_spec, tex_brdf_lut, smp_brdf_lut, ibl_params.x );
	// premultiplied output, see cube.glsl. Alpha is scaled by analytical
	// silhouette coverage so alpha-to-coverage (opaque pipeline) or the
	// premultiplied alpha blend (transparent pipeline) produces a smooth
	// sub-pixel silhouette instead of a binary hit/miss edge.
	float a = v_base_color.a * coverage;
	out_color = vec4( ( direct + ambient * ao ) * a, a );
}
#pragma sokol @end

#pragma sokol @program impostor vs fs
