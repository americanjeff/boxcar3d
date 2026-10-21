// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

// Single-translation-unit build of sokol_gfx's + sokol_gl's implementation.
// Backend macro (SOKOL_D3D11 / SOKOL_METAL / SOKOL_GLCORE) is provided by
// the `sokol` INTERFACE target. On macOS this file is compiled as
// Objective-C with ARC.

#define SOKOL_IMPL
#include "sokol_gfx.h"

// sokol_gl: immediate-mode 2D rendering on top of sokol_gfx. Used by the
// overlay API (render_shim.c) for microui's command list (rects, text,
// icons, scissor clips). Compiled into the same archive as the renderer.
#define SOKOL_GL_IMPL
#include "util/sokol_gl.h"
