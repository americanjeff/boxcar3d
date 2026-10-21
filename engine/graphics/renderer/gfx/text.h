// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

// Text label storage, world space and screen space.
//
// Labels accumulate in a fixed per-frame array; ResetTextArena clears it at
// the start of each frame (called from ResetFrameArena). The world-text pass
// (world_text.c) drains the world-space entries at submit time; screen-space
// entries carry pixel positions for the 2D overlay.

#pragma once

#include "gfx/projection.h"
#include "gfx/utility.h"

#include <stdbool.h>

#ifdef __cplusplus
extern "C"
{
#endif

// Whether an entry carries a world position to project or a screen pixel to
// use directly.
typedef enum TextSpace
{
	TEXT_SPACE_WORLD = 0,
	TEXT_SPACE_SCREEN = 1,
} TextSpace;

typedef struct TextEntry
{
	TextSpace space;
	b3Vec3 worldPos;  // valid when space == TEXT_SPACE_WORLD
	int screenX;	  // framebuffer pixels, origin top-left, when space == TEXT_SPACE_SCREEN
	int screenY;
	Vec4 color;		  // linear RGBA, not premultiplied
	const char* text; // points into the per-frame text arena, NUL-terminated
} TextEntry;

// Submit a UTF-8 string at a world-space position. Text is copied into the
// per-frame text arena and truncated to fit (current cap: 63 chars + NUL).
// Color is linear RGBA. Dropped on overflow.
void DrawString( b3Vec3 worldPos, Vec4 color, const char* text );

// Submit a UTF-8 string at a screen-pixel position (origin top-left, Y down,
// framebuffer pixels). Same copy/truncation/overflow rules as DrawString.
void DrawScreenString( int x, int y, Vec4 color, const char* text );
void DrawScreenStringFormat( int x, int y, Vec4 color, const char* fmt, ... );

// Iteration surface for the world-text pass. Pointers/strings are valid until
// the next ResetTextArena (called by ResetFrameArena, which the renderer
// invokes each frame). Caller is expected to honor 0 <= i < count.
int GetTextCount( void );
const TextEntry* GetTextAt( int i );

// Wipe the per-frame text array. Called from ResetFrameArena.
void ResetTextArena( void );

// Resolve an entry to its screen-pixel position. Screen entries pass through;
// world entries project through view/proj for the given viewport. Returns
// false (leaving outputs untouched) when a world entry is off-frustum or
// behind the camera, matching ProjectWorldToScreen.
static inline bool ResolveTextScreenPos( const TextEntry* e, Mat4 view, Mat4 proj, int viewportW, int viewportH,
										 float* outScreenX, float* outScreenY )
{
	if ( e->space == TEXT_SPACE_SCREEN )
	{
		*outScreenX = (float)e->screenX;
		*outScreenY = (float)e->screenY;
		return true;
	}
	return ProjectWorldToScreen( view, proj, viewportW, viewportH, e->worldPos, outScreenX, outScreenY );
}

#ifdef __cplusplus
} // extern "C"
#endif
