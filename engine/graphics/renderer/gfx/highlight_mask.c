// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

#include "gfx/highlight_mask.h"

#include "gfx/renderer.h"
#include "gfx/shape_instances.h"
#include "mask_capsule.glsl.h"
#include "mask_hull.glsl.h"
#include "mask_sphere.glsl.h"

#include <stdio.h>
#include <string.h>

#define MAX_HIGHLIGHTS_PER_KIND 64

// The mask_*_instance_t types live in gfx/shape_instances.h; the CPU staging
// arrays upload straight into the per-pipeline vertex buffers, no pack step.

static struct
{
	sg_shader shader;
	sg_pipeline pipeline;
	sg_buffer instBuf;
	mask_sphere_instance_t cpu[MAX_HIGHLIGHTS_PER_KIND];
	int count;
} s_sphere;

static struct
{
	sg_shader shader;
	sg_pipeline pipeline;
	sg_buffer instBuf;
	mask_capsule_instance_t cpu[MAX_HIGHLIGHTS_PER_KIND];
	int count;
} s_capsule;

// Hulls draw one-by-one (each with its own vbo/ibo binding); the per-frame
// draw list pairs each instance with its geometry buffers + indexCount.
typedef struct HullDraw
{
	sg_buffer vbo;
	sg_buffer ibo;
	int indexCount;
} HullDraw;

static struct
{
	sg_shader shader;
	sg_pipeline pipeline;
	sg_buffer instBuf;
	mask_hull_instance_t cpu[MAX_HIGHLIGHTS_PER_KIND];
	HullDraw draws[MAX_HIGHLIGHTS_PER_KIND];
	int count;
} s_hull;

static bool s_uiInitialized = false;

void HighlightMaskInit( void )
{
	if ( s_uiInitialized )
		return;

	// Sphere mask pipeline
	s_sphere.shader = sg_make_shader( mask_sphere_prog_shader_desc( sg_query_backend() ) );

	sg_buffer_desc sphBufDesc = { 0 };
	sphBufDesc.usage.vertex_buffer = true;
	sphBufDesc.usage.stream_update = true;
	sphBufDesc.size = sizeof( s_sphere.cpu );
	sphBufDesc.label = "highlight_sphere_instances";
	s_sphere.instBuf = sg_make_buffer( &sphBufDesc );

	sg_pipeline_desc sphPdesc = { 0 };
	sphPdesc.shader = s_sphere.shader;
	sphPdesc.layout.buffers[0].stride = sizeof( float ) * 3;
	sphPdesc.layout.attrs[ATTR_mask_sphere_prog_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	sphPdesc.layout.attrs[ATTR_mask_sphere_prog_in_pos].buffer_index = 0;
	sphPdesc.layout.buffers[1].stride = (int)sizeof( mask_sphere_instance_t );
	sphPdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	sphPdesc.layout.buffers[1].step_rate = 1;
	sphPdesc.layout.attrs[ATTR_mask_sphere_prog_inst_center_radius].format = SG_VERTEXFORMAT_FLOAT4;
	sphPdesc.layout.attrs[ATTR_mask_sphere_prog_inst_center_radius].buffer_index = 1;
	sphPdesc.layout.attrs[ATTR_mask_sphere_prog_inst_center_radius].offset = offsetof( mask_sphere_instance_t, center_radius );
	sphPdesc.layout.attrs[ATTR_mask_sphere_prog_inst_kind].format = SG_VERTEXFORMAT_FLOAT4;
	sphPdesc.layout.attrs[ATTR_mask_sphere_prog_inst_kind].buffer_index = 1;
	sphPdesc.layout.attrs[ATTR_mask_sphere_prog_inst_kind].offset = offsetof( mask_sphere_instance_t, kind );
	sphPdesc.index_type = SG_INDEXTYPE_UINT16;
	sphPdesc.colors[0].pixel_format = SG_PIXELFORMAT_R8;
	sphPdesc.color_count = 1;
	sphPdesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	// Mask the full unoccluded projection, not the visible silhouette: a large
	// occluded shape would punch a hole per occluder and the outline would
	// ring every one of them. The outline is not occlusion-aware as a result.
	sphPdesc.depth.compare = SG_COMPAREFUNC_ALWAYS;
	sphPdesc.depth.write_enabled = false;
	// Impostor convention: front-face cull on the proxy box, so the analytic
	// intersection rasterizes from the back faces and stays visible when the
	// camera sits inside the proxy AABB but outside the analytic sphere.
	sphPdesc.cull_mode = SG_CULLMODE_FRONT;
	sphPdesc.face_winding = SG_FACEWINDING_CCW;
	sphPdesc.sample_count = 1;
	sphPdesc.label = "highlight_sphere_pipeline";
	s_sphere.pipeline = sg_make_pipeline( &sphPdesc );

	// Capsule mask pipeline
	s_capsule.shader = sg_make_shader( mask_capsule_prog_shader_desc( sg_query_backend() ) );

	sg_buffer_desc capBufDesc = { 0 };
	capBufDesc.usage.vertex_buffer = true;
	capBufDesc.usage.stream_update = true;
	capBufDesc.size = sizeof( s_capsule.cpu );
	capBufDesc.label = "highlight_capsule_instances";
	s_capsule.instBuf = sg_make_buffer( &capBufDesc );

	sg_pipeline_desc capPdesc = { 0 };
	capPdesc.shader = s_capsule.shader;
	capPdesc.layout.buffers[0].stride = sizeof( float ) * 3;
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_in_pos].buffer_index = 0;
	capPdesc.layout.buffers[1].stride = (int)sizeof( mask_capsule_instance_t );
	capPdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	capPdesc.layout.buffers[1].step_rate = 1;
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_inst_xform_row0].format = SG_VERTEXFORMAT_FLOAT4;
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_inst_xform_row0].buffer_index = 1;
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_inst_xform_row0].offset = offsetof( mask_capsule_instance_t, xform_row0 );
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_inst_xform_row1].format = SG_VERTEXFORMAT_FLOAT4;
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_inst_xform_row1].buffer_index = 1;
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_inst_xform_row1].offset = offsetof( mask_capsule_instance_t, xform_row1 );
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_inst_xform_row2].format = SG_VERTEXFORMAT_FLOAT4;
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_inst_xform_row2].buffer_index = 1;
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_inst_xform_row2].offset = offsetof( mask_capsule_instance_t, xform_row2 );
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_inst_params].format = SG_VERTEXFORMAT_FLOAT4;
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_inst_params].buffer_index = 1;
	capPdesc.layout.attrs[ATTR_mask_capsule_prog_inst_params].offset = offsetof( mask_capsule_instance_t, params );
	capPdesc.index_type = SG_INDEXTYPE_UINT16;
	capPdesc.colors[0].pixel_format = SG_PIXELFORMAT_R8;
	capPdesc.color_count = 1;
	capPdesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	capPdesc.depth.compare = SG_COMPAREFUNC_ALWAYS;
	capPdesc.depth.write_enabled = false;
	capPdesc.cull_mode = SG_CULLMODE_FRONT;
	capPdesc.face_winding = SG_FACEWINDING_CCW;
	capPdesc.sample_count = 1;
	capPdesc.label = "highlight_capsule_pipeline";
	s_capsule.pipeline = sg_make_pipeline( &capPdesc );

	// Hull mask pipeline
	s_hull.shader = sg_make_shader( mask_hull_prog_shader_desc( sg_query_backend() ) );

	sg_buffer_desc hullBufDesc = { 0 };
	hullBufDesc.usage.vertex_buffer = true;
	hullBufDesc.usage.stream_update = true;
	hullBufDesc.size = sizeof( s_hull.cpu );
	hullBufDesc.label = "highlight_hull_instances";
	s_hull.instBuf = sg_make_buffer( &hullBufDesc );

	sg_pipeline_desc hullPdesc = { 0 };
	hullPdesc.shader = s_hull.shader;
	// The geometry registry vbo is interleaved {position(3), normal(3)}; keep
	// the stride at 6 floats so this pipeline can share it. The shader declares
	// only in_pos, so no normal attribute is bound.
	hullPdesc.layout.buffers[0].stride = sizeof( float ) * 6;
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_in_pos].format = SG_VERTEXFORMAT_FLOAT3;
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_in_pos].buffer_index = 0;
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_in_pos].offset = 0;
	hullPdesc.layout.buffers[1].stride = (int)sizeof( mask_hull_instance_t );
	hullPdesc.layout.buffers[1].step_func = SG_VERTEXSTEP_PER_INSTANCE;
	hullPdesc.layout.buffers[1].step_rate = 1;
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_inst_xform_row0].format = SG_VERTEXFORMAT_FLOAT4;
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_inst_xform_row0].buffer_index = 1;
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_inst_xform_row0].offset = offsetof( mask_hull_instance_t, xform_row0 );
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_inst_xform_row1].format = SG_VERTEXFORMAT_FLOAT4;
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_inst_xform_row1].buffer_index = 1;
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_inst_xform_row1].offset = offsetof( mask_hull_instance_t, xform_row1 );
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_inst_xform_row2].format = SG_VERTEXFORMAT_FLOAT4;
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_inst_xform_row2].buffer_index = 1;
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_inst_xform_row2].offset = offsetof( mask_hull_instance_t, xform_row2 );
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_inst_scale_kind].format = SG_VERTEXFORMAT_FLOAT4;
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_inst_scale_kind].buffer_index = 1;
	hullPdesc.layout.attrs[ATTR_mask_hull_prog_inst_scale_kind].offset = offsetof( mask_hull_instance_t, scale_kind );
	hullPdesc.index_type = SG_INDEXTYPE_UINT32;
	hullPdesc.colors[0].pixel_format = SG_PIXELFORMAT_R8;
	hullPdesc.color_count = 1;
	hullPdesc.depth.pixel_format = SG_PIXELFORMAT_DEPTH;
	hullPdesc.depth.compare = SG_COMPAREFUNC_ALWAYS;
	hullPdesc.depth.write_enabled = false;
	hullPdesc.cull_mode = SG_CULLMODE_BACK;
	hullPdesc.face_winding = SG_FACEWINDING_CCW;
	hullPdesc.sample_count = 1;
	hullPdesc.label = "highlight_hull_pipeline";
	s_hull.pipeline = sg_make_pipeline( &hullPdesc );

	s_uiInitialized = true;
}

void HighlightMaskShutdown( void )
{
	if ( !s_uiInitialized )
		return;

	sg_destroy_pipeline( s_hull.pipeline );
	s_hull.pipeline.id = 0;
	sg_destroy_buffer( s_hull.instBuf );
	s_hull.instBuf.id = 0;
	sg_destroy_shader( s_hull.shader );
	s_hull.shader.id = 0;

	sg_destroy_pipeline( s_capsule.pipeline );
	s_capsule.pipeline.id = 0;
	sg_destroy_buffer( s_capsule.instBuf );
	s_capsule.instBuf.id = 0;
	sg_destroy_shader( s_capsule.shader );
	s_capsule.shader.id = 0;

	sg_destroy_pipeline( s_sphere.pipeline );
	s_sphere.pipeline.id = 0;
	sg_destroy_buffer( s_sphere.instBuf );
	s_sphere.instBuf.id = 0;
	sg_destroy_shader( s_sphere.shader );
	s_sphere.shader.id = 0;

	s_uiInitialized = false;
}

void HighlightMaskBeginFrame( void )
{
	s_sphere.count = 0;
	s_capsule.count = 0;
	s_hull.count = 0;
}

bool HasHighlightMaskContent( void )
{
	return ( s_sphere.count + s_capsule.count + s_hull.count ) > 0;
}

void AppendHighlightSphere( b3Transform transform, float radius, HighlightKind kind )
{
	if ( kind == HIGHLIGHT_KIND_NONE )
		return;
	if ( s_sphere.count >= MAX_HIGHLIGHTS_PER_KIND )
	{
		return;
	}
	mask_sphere_instance_t* inst = &s_sphere.cpu[s_sphere.count++];
	inst->center_radius = MakeVec4( transform.p.x, transform.p.y, transform.p.z, radius );
	inst->kind = MakeVec4( (float)kind, 0.0f, 0.0f, 0.0f );
}

void AppendHighlightCapsule( b3Transform transform, float halfLength, float radius, HighlightKind kind )
{
	if ( kind == HIGHLIGHT_KIND_NONE )
		return;
	if ( s_capsule.count >= MAX_HIGHLIGHTS_PER_KIND )
	{
		return;
	}
	mask_capsule_instance_t* inst = &s_capsule.cpu[s_capsule.count++];
	// 3x4 affine row layout: row i = (R_i0, R_i1, R_i2, t_i).
	Mat4 m = MakeMat4FromTransform( transform, b3Vec3_one );
	inst->xform_row0 = MakeVec4( m.cx.x, m.cy.x, m.cz.x, m.cw.x );
	inst->xform_row1 = MakeVec4( m.cx.y, m.cy.y, m.cz.y, m.cw.y );
	inst->xform_row2 = MakeVec4( m.cx.z, m.cy.z, m.cz.z, m.cw.z );
	inst->params = MakeVec4( halfLength, radius, (float)kind, 0.0f );
}

void AppendHighlightGeometry( MeshHandle handle, b3Transform transform, b3Vec3 scale, HighlightKind kind )
{
	if ( kind == HIGHLIGHT_KIND_NONE )
		return;
	if ( s_hull.count >= MAX_HIGHLIGHTS_PER_KIND )
	{
		return;
	}
	MeshBuffers gb = { 0 };
	if ( !GetMeshBuffers( handle, &gb ) )
	{
		return; // stale or invalid handle, skip silently
	}
	const int index = s_hull.count++;
	mask_hull_instance_t* inst = &s_hull.cpu[index];
	Mat4 m = MakeMat4FromTransform( transform, b3Vec3_one );
	inst->xform_row0 = MakeVec4( m.cx.x, m.cy.x, m.cz.x, m.cw.x );
	inst->xform_row1 = MakeVec4( m.cx.y, m.cy.y, m.cz.y, m.cw.y );
	inst->xform_row2 = MakeVec4( m.cx.z, m.cy.z, m.cz.z, m.cw.z );
	inst->scale_kind = MakeVec4( scale.x, scale.y, scale.z, (float)kind );
	s_hull.draws[index].vbo = gb.vbo;
	s_hull.draws[index].ibo = gb.ibo;
	s_hull.draws[index].indexCount = gb.indexCount;
}

void SubmitHighlightMask( int width, int height, const Mat4* viewProj, b3Vec3 cameraPosWorld, sg_view maskAttachView,
						  sg_view depthAttachView, const Vec4 winDepth )
{
	if ( !s_uiInitialized )
		return;
	if ( !HasHighlightMaskContent() )
		return;

	sg_pass pass = { 0 };
	pass.action.colors[0].load_action = SG_LOADACTION_CLEAR;
	pass.action.colors[0].clear_value.r = 0.0f;
	pass.action.colors[0].clear_value.g = 0.0f;
	pass.action.colors[0].clear_value.b = 0.0f;
	pass.action.colors[0].clear_value.a = 0.0f;
	pass.action.colors[0].store_action = SG_STOREACTION_STORE;
	pass.action.depth.load_action = SG_LOADACTION_LOAD;
	pass.action.depth.store_action = SG_STOREACTION_DONTCARE;
	pass.attachments.colors[0] = maskAttachView;
	pass.attachments.depth_stencil = depthAttachView;
	pass.label = "highlight_mask_pass";
	sg_push_debug_group( "highlight_mask" );
	sg_begin_pass( &pass );
	sg_apply_viewport( 0, 0, width, height, true );

	const sg_buffer cubeVbuf = GetCubeProxyVertexBuffer();
	const sg_buffer cubeIbuf = GetCubeProxyIndexBuffer();
	const int cubeCount = GetCubeProxyIndexCount();

	// Spheres
	if ( s_sphere.count > 0 )
	{
		sg_range upload;
		upload.ptr = s_sphere.cpu;
		upload.size = (size_t)s_sphere.count * sizeof( mask_sphere_instance_t );
		sg_update_buffer( s_sphere.instBuf, &upload );

		sg_apply_pipeline( s_sphere.pipeline );

		sg_bindings b = { 0 };
		b.vertex_buffers[0] = cubeVbuf;
		b.vertex_buffers[1] = s_sphere.instBuf; // offset 0, whole upload
		b.index_buffer = cubeIbuf;
		sg_apply_bindings( &b );

		mask_sphere_ub_frame_t uf = { 0 };
		uf.view_proj = *viewProj;
		sg_apply_uniforms( UB_mask_sphere_ub_frame, &SG_RANGE( uf ) );

		mask_sphere_ub_pass_t up = { 0 };
		up.view_proj = *viewProj;
		up.camera_pos = MakeVec4( cameraPosWorld.x, cameraPosWorld.y, cameraPosWorld.z, 0.0f );
		up.win_depth = winDepth;
		sg_apply_uniforms( UB_mask_sphere_ub_pass, &SG_RANGE( up ) );

		sg_draw( 0, cubeCount, s_sphere.count );
	}

	// Capsules
	if ( s_capsule.count > 0 )
	{
		sg_range upload;
		upload.ptr = s_capsule.cpu;
		upload.size = (size_t)s_capsule.count * sizeof( mask_capsule_instance_t );
		sg_update_buffer( s_capsule.instBuf, &upload );

		sg_apply_pipeline( s_capsule.pipeline );

		sg_bindings b = { 0 };
		b.vertex_buffers[0] = cubeVbuf;
		b.vertex_buffers[1] = s_capsule.instBuf;
		b.index_buffer = cubeIbuf;
		sg_apply_bindings( &b );

		mask_capsule_ub_frame_t uf = { 0 };
		uf.view_proj = *viewProj;
		sg_apply_uniforms( UB_mask_capsule_ub_frame, &SG_RANGE( uf ) );

		mask_capsule_ub_pass_t up = { 0 };
		up.view_proj = *viewProj;
		up.camera_pos = MakeVec4( cameraPosWorld.x, cameraPosWorld.y, cameraPosWorld.z, 0.0f );
		up.win_depth = winDepth;
		sg_apply_uniforms( UB_mask_capsule_ub_pass, &SG_RANGE( up ) );

		sg_draw( 0, cubeCount, s_capsule.count );
	}

	// Hulls
	if ( s_hull.count > 0 )
	{
		sg_range upload;
		upload.ptr = s_hull.cpu;
		upload.size = (size_t)s_hull.count * sizeof( mask_hull_instance_t );
		sg_update_buffer( s_hull.instBuf, &upload );

		sg_apply_pipeline( s_hull.pipeline );

		mask_hull_ub_frame_t uf = { 0 };
		uf.view_proj = *viewProj;
		sg_apply_uniforms( UB_mask_hull_ub_frame, &SG_RANGE( uf ) );

		for ( int i = 0; i < s_hull.count; ++i )
		{
			const HullDraw d = s_hull.draws[i];
			sg_bindings b = { 0 };
			b.vertex_buffers[0] = d.vbo;
			b.vertex_buffers[1] = s_hull.instBuf;
			b.vertex_buffer_offsets[1] = i * (int)sizeof( mask_hull_instance_t );
			b.index_buffer = d.ibo;
			sg_apply_bindings( &b );
			sg_draw( 0, d.indexCount, 1 );
		}
	}

	sg_end_pass();
	sg_pop_debug_group();
}
