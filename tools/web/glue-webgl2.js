/* glue-webgl2.js — WebGL2 backend table for the bare-wasm web build.
 * Shipped as index-gles.js (the template loads it when the browser has no
 * WebGPU, or ?gl=webgl2 forces it).
 *
 * The renderer C (sokol_gfx GLES3 backend) calls the GL ES 3.0 API; every
 * call lands here as an `env.gl*` import. WebGL2 IS the ES 3.0 API, so
 * most entries are direct context-method calls; the interesting cases are
 * (a) GL's pointer parameters, which are byte offsets/pointers into wasm
 * linear memory (uniforms, data uploads, gen/delete handle arrays), and
 * (b) GL's GLuint handles, which WebGL returns as JS objects — mapped
 * through the handle table below (0 = NULL, the GL convention).
 *
 * String params (glGetAttribLocation's name) are decoded from memory;
 * glGetString[1]i returns the module's exported shim_gl_scratch buffer
 * (the C shim owns the buffer, this file copies the string into it).
 */
(function () {
	"use strict";

	var ctx = null;
	var H = { next: 1, m: new Map() }; /* handle -> {t: kind, o: object} */
	var T = { shader: 0, program: 0, buffer: 0, texture: 0, fbo: 0, rb: 0, sampler: 0, vao: 0 };

	function V() { return window.odmCore.views(); }

	function hNew(kind, o) {
		var h = H.next++;
		H.m.set(h, { t: kind, o: o });
		return h;
	}
	function hObj(h, kind) {
		var e = H.m.get(h);
		return e && e.t === kind ? e.o : null;
	}
	function hDel(h) { H.m.delete(h); }

	/* Uniform locations. In C-GL a location is a GLint (int, -1 = not
	   found); in WebGL it is a WebGLUniformLocation object (or null).
	   Objects cannot cross the wasm i32 boundary, so we map each location
	   to a small int handle here and translate back in the glUniform*
	   imports (a not-found / invalid handle is a no-op, matching the
	   GL spec's null-location behavior). */
	var LOC = []; /* index -> WebGLUniformLocation */
	function locNew(loc) {
		if (loc === null) { return -1; }
		var i = LOC.length;
		LOC[i] = loc;
		return i;
	}
	function locObj(i) {
		if (i < 0 || i >= LOC.length) { return null; }
		return LOC[i];
	}

	function memStr(ptr) {
		var v = V();
		var n = 0;
		while (ptr + n < v.U8.length && v.U8[ptr + n]) { n++; }
		return new TextDecoder().decode(v.U8.subarray(ptr, ptr + n));
	}
	function copyStr(ptr, s, max) {
		var v = V();
		var b = new TextEncoder().encode(s);
		var n = Math.min(b.length, max - 1);
		v.U8.set(b.subarray(0, n), ptr);
		v.U8[ptr + n] = 0;
		return n;
	}

	/* GL string constants (the GLES3 path only ever asks for the
	   implementation strings; GL_EXTENSIONS is unused — the backend
	   feature set is compile-time fixed). */
	function glString(name) {
		var s = "";
		switch (name) {
			case 0x1F00: s = ctx.getParameter(ctx.VENDOR); break;      /* GL_VENDOR */
			case 0x1F01: s = ctx.getParameter(ctx.RENDERER); break;    /* GL_RENDERER */
			case 0x1F02: s = ctx.getParameter(ctx.VERSION); break;     /* GL_VERSION */
			case 0x8B8C: s = ctx.getParameter(ctx.SHADING_LANGUAGE_VERSION); break;
			default: s = "0x0"; break;                                 /* GL_EXTENSIONS */
		}
		return s;
	}
	/* Matches SHIM_GL_STRING_CAP in apphost_shim.c (the shim owns the
	   buffer, exported as the shim_gl_scratch data symbol). */
	var GL_STRING_CAP = 2048;

	/* Bytes per pixel for an uploaded (internal-format, type) pair — the
	   GL data view must be exactly w*h*bytes, or texImage* rejects it.
	   channels come from the internal format, bytes/component from the type
	   (sokol_gfx's GLES3 surface: 8/16/32-bit integer + float). */
	function texBpp(f, ty) {
		var bpc = (ty === 0x140A) ? 4      /* GL_FLOAT */
			: (ty === 0x140B) ? 2          /* GL_HALF_FLOAT */
			: (ty === 0x1405) ? 4          /* GL_UNSIGNED_INT */
			: (ty === 0x1403) ? 2          /* GL_UNSIGNED_SHORT */
			: 1;                            /* GL_UNSIGNED_BYTE */
		var ch;
		switch (f) {
			case 0x1903: ch = 1; break;   /* RED   */
			case 0x822D: ch = 1; break;   /* R16F  */
			case 0x822E: ch = 1; break;   /* R32F  */
			case 0x8227: ch = 2; break;   /* RG    */
			case 0x822F: ch = 2; break;   /* RG16F */
			case 0x1907: ch = 3; break;   /* RGB   */
			case 0x1908: ch = 4; break;   /* RGBA  */
			case 0x881A: ch = 4; break;   /* RGBA16F */
			case 0x8814: ch = 4; break;   /* RGBA32F */
			case 0x1902: ch = 1; break;   /* DEPTH_COMPONENT */
			default:     ch = 4; break;
		}
		return ch * bpc;
	}

	function imports() {
		var G = {
			/* ── context / state (direct) ── */
			glActiveTexture: function (u) { ctx.activeTexture(u); },
			glBlendColor: function (r, g, b, a) { ctx.blendColor(r, g, b, a); },
			glBlendEquationSeparate: function (m, om) { ctx.blendEquationSeparate(m, om); },
			glBlendFuncSeparate: function (s, d, sa, da) { ctx.blendFuncSeparate(s, d, sa, da); },
			glBlitFramebuffer: function (x0, y0, x1, y1, x2, y2, x3, y3, mask, f) {
				ctx.blitFramebuffer(x0, y0, x1, y1, x2, y2, x3, y3, mask, f);
			},
			glClear: function (m) { ctx.clear(m); },
			glClearColor: function (r, g, b, a) { ctx.clearColor(r, g, b, a); },
			glClearDepth: function (d) { ctx.clearDepth(d); },
			glColorMask: function (r, g, b, a) { ctx.colorMask(r, g, b, a); },
			glCullFace: function (m) { ctx.cullFace(m); },
			glDepthFunc: function (f) { ctx.depthFunc(f); },
			glDepthMask: function (m) { ctx.depthMask(!!m); },
			glDisable: function (c) { ctx.disable(c); },
			glEnable: function (c) { ctx.enable(c); },
			glFrontFace: function (m) { ctx.frontFace(m); },
			glPixelStorei: function (p, v) { ctx.pixelStorei(p, v); },
			glPolygonOffset: function (f, u) { ctx.polygonOffset(f, u); },
			glReadBuffer: function (m) { ctx.readBuffer(m); },
			glScissor: function (x, y, w, h) { ctx.scissor(x, y, w, h); },
			glStencilFunc: function (f, r, m) { ctx.stencilFunc(f, r, m); },
			glStencilFuncSeparate: function (f, func, r, m) { ctx.stencilFuncSeparate(f, func, r, m); },
			glStencilMask: function (m) { ctx.stencilMask(m); },
			glStencilOp: function (f, p, dp) { ctx.stencilOp(f, p, dp); },
			glStencilOpSeparate: function (f, sf, sp, sd) { ctx.stencilOpSeparate(f, sf, sp, sd); },
			glViewport: function (x, y, w, h) { ctx.viewport(x, y, w, h); },

			/* ── shaders / programs ── */
			glCreateShader: function (t) { return hNew("shader", ctx.createShader(t)); },
			glDeleteShader: function (h) { var o = hObj(h, "shader"); if (o) { ctx.deleteShader(o); hDel(h); } },
			glCompileShader: function (h) { ctx.compileShader(hObj(h, "shader")); },
			glShaderSource: function (h, count, strPtrs, lensPtr) {
				var v = V();
				var s = "";
				for (var i = 0; i < count; i++) {
					var p = v.I32[(strPtrs >> 2) + i];
					if (lensPtr) {
						// explicit per-string lengths
						s += new TextDecoder().decode(
							v.U8.subarray(p, p + v.I32[(lensPtr >> 2) + i]));
					} else {
						// NULL length: GL spec => null-terminated strings.
						// sokol passes length=0 here (see sokol_gfx's
						// glShaderSource(gl_shd, 1, &src, 0)).
						var end = p;
						while (end < v.U8.length && v.U8[end] !== 0) end++;
						s += new TextDecoder().decode(v.U8.subarray(p, end));
					}
				}
				ctx.shaderSource(hObj(h, "shader"), s);
			},
			glGetShaderiv: function (h, p, ptr) {
				var v = V();
				v.I32[ptr >> 2] = ctx.getShaderParameter(hObj(h, "shader"), p);
			},
			glGetShaderInfoLog: function (h, len, lenPtr, bufPtr) {
				var log = ctx.getShaderInfoLog(hObj(h, "shader")) || "";
				var n = copyStr(bufPtr, log, len);
				if (lenPtr) { V().I32[lenPtr >> 2] = n; }
			},
			glCreateProgram: function () { return hNew("program", ctx.createProgram()); },
			glDeleteProgram: function (h) { var o = hObj(h, "program"); if (o) { ctx.deleteProgram(o); hDel(h); } },
			glAttachShader: function (p, s) { ctx.attachShader(hObj(p, "program"), hObj(s, "shader")); },
			glLinkProgram: function (h) { ctx.linkProgram(hObj(h, "program")); },
			glUseProgram: function (h) { ctx.useProgram(hObj(h, "program")); },
			glGetProgramiv: function (h, p, ptr) {
				var v = V();
				v.I32[ptr >> 2] = ctx.getProgramParameter(hObj(h, "program"), p);
			},
			glGetProgramInfoLog: function (h, len, lenPtr, bufPtr) {
				var log = ctx.getProgramInfoLog(hObj(h, "program")) || "";
				var n = copyStr(bufPtr, log, len);
				if (lenPtr) { V().I32[lenPtr >> 2] = n; }
			},
			glGetAttribLocation: function (h, namePtr) {
				return ctx.getAttribLocation(hObj(h, "program"), memStr(namePtr));
			},
			glGetUniformLocation: function (h, namePtr) {
				return locNew(ctx.getUniformLocation(hObj(h, "program"), memStr(namePtr)));
			},

			/* ── uniforms (pointer args = wasm memory) ── */
			glUniform1i: function (l, v) { var o = locObj(l); if (o !== null) { ctx.uniform1i(o, v); } },
			glUniform1fv: function (l, n, p) { var o = locObj(l); if (o !== null) { ctx.uniform1fv(o, V().F32.subarray(p >> 2, (p + n * 4) >> 2)); } },
			glUniform2fv: function (l, n, p) { var o = locObj(l); if (o !== null) { ctx.uniform2fv(o, V().F32.subarray(p >> 2, (p + n * 8) >> 2)); } },
			glUniform3fv: function (l, n, p) { var o = locObj(l); if (o !== null) { ctx.uniform3fv(o, V().F32.subarray(p >> 2, (p + n * 12) >> 2)); } },
			glUniform4fv: function (l, n, p) { var o = locObj(l); if (o !== null) { ctx.uniform4fv(o, V().F32.subarray(p >> 2, (p + n * 16) >> 2)); } },
			glUniform1iv: function (l, n, p) { var o = locObj(l); if (o !== null) { ctx.uniform1iv(o, V().I32.subarray(p >> 2, (p + n * 4) >> 2)); } },
			glUniform2iv: function (l, n, p) { var o = locObj(l); if (o !== null) { ctx.uniform2iv(o, V().I32.subarray(p >> 2, (p + n * 8) >> 2)); } },
			glUniform3iv: function (l, n, p) { var o = locObj(l); if (o !== null) { ctx.uniform3iv(o, V().I32.subarray(p >> 2, (p + n * 12) >> 2)); } },
			glUniform4iv: function (l, n, p) { var o = locObj(l); if (o !== null) { ctx.uniform4iv(o, V().I32.subarray(p >> 2, (p + n * 16) >> 2)); } },
			glUniformMatrix4fv: function (l, n, tr, p) {
				var o = locObj(l);
				if (o !== null) { ctx.uniformMatrix4fv(o, !!tr, V().F32.subarray(p >> 2, (p + n * 64) >> 2)); }
			},

			/* ── buffers ── */
			glGenBuffers: function (n, ptr) {
				var v = V();
				for (var i = 0; i < n; i++) { v.I32[(ptr >> 2) + i] = hNew("buffer", ctx.createBuffer()); }
			},
			glDeleteBuffers: function (n, ptr) {
				var v = V();
				for (var i = 0; i < n; i++) {
					var h = v.I32[(ptr >> 2) + i];
					var o = hObj(h, "buffer");
					if (o) { ctx.deleteBuffer(o); hDel(h); }
				}
			},
			glBindBuffer: function (t, h) { ctx.bindBuffer(t, hObj(h, "buffer")); },
			glBindBufferBase: function (t, i, h) { ctx.bindBufferBase(t, i, hObj(h, "buffer")); },
			glBindBufferRange: function (t, i, h, off, size) {
				ctx.bindBufferRange(t, i, hObj(h, "buffer"), off, size);
			},
			glBufferData: function (t, size, dataPtr, usage) {
				if (dataPtr) {
					var v = V();
					ctx.bufferData(t, new Uint8Array(v.U8.buffer, dataPtr, size), usage);
				} else {
					ctx.bufferData(t, size, usage);
				}
			},
			glBufferSubData: function (t, off, size, dataPtr) {
				var v = V();
				ctx.bufferSubData(t, off, new Uint8Array(v.U8.buffer, dataPtr, size));
			},

			/* ── textures ── */
			glGenTextures: function (n, ptr) {
				var v = V();
				for (var i = 0; i < n; i++) { v.I32[(ptr >> 2) + i] = hNew("texture", ctx.createTexture()); }
			},
			glDeleteTextures: function (n, ptr) {
				var v = V();
				for (var i = 0; i < n; i++) {
					var h = v.I32[(ptr >> 2) + i];
					var o = hObj(h, "texture");
					if (o) { ctx.deleteTexture(o); hDel(h); }
				}
			},
			glBindTexture: function (t, h) { ctx.bindTexture(t, hObj(h, "texture")); },
			glTexImage2D: function (t, l, it, w, h, b, f, ty, p) {
				if (p) {
					var v = V();
					var bpp = texBpp(f, ty);
					ctx.texImage2D(t, l, it, w, h, b, f, ty, new Uint8Array(v.U8.buffer, p, w * h * bpp));
				} else {
					ctx.texImage2D(t, l, it, w, h, b, f, ty, null);
				}
			},
			glTexImage3D: function (t, l, it, w, h, d, b, f, ty, p) {
				if (p) {
					var v = V();
					var bpp = texBpp(f, ty);
					ctx.texImage3D(t, l, it, w, h, d, b, f, ty, new Uint8Array(v.U8.buffer, p, w * h * d * bpp));
				} else {
					ctx.texImage3D(t, l, it, w, h, d, b, f, ty, null);
				}
			},
			glTexSubImage2D: function (t, l, x, y, w, h, f, ty, p) {
				if (p) {
					var v = V();
					var bpp = (ty === 0x140A || ty === 0x1908) ? 4 : (ty === 0x8051 ? 2 : 1);
					ctx.texSubImage2D(t, l, x, y, w, h, f, ty, new Uint8Array(v.U8.buffer, p, w * h * bpp));
				} else {
					ctx.texSubImage2D(t, l, x, y, w, h, f, ty, null);
				}
			},
			glTexSubImage3D: function (t, l, x, y, z, w, h, d, f, ty, p) {
				if (p) {
					var v = V();
					var bpp = (ty === 0x140A || ty === 0x1908) ? 4 : (ty === 0x8051 ? 2 : 1);
					ctx.texSubImage3D(t, l, x, y, z, w, h, d, f, ty, new Uint8Array(v.U8.buffer, p, w * h * d * bpp));
				} else {
					ctx.texSubImage3D(t, l, x, y, z, w, h, d, f, ty, null);
				}
			},
			glSamplerParameterf: function (h, p, v) { ctx.samplerParameterf(hObj(h, "sampler"), p, v); },
			glSamplerParameteri: function (h, p, v) { ctx.samplerParameteri(hObj(h, "sampler"), p, v); },
			glCompressedTexImage2D: function (t, l, f, w, h, b, imgSize, p) {
				var v = V();
				ctx.compressedTexImage2D(t, l, f, w, h, b, new Uint8Array(v.U8.buffer, p, imgSize));
			},
			glCompressedTexImage3D: function (t, l, f, w, h, d, b, imgSize, p) {
				var v = V();
				ctx.compressedTexImage3D(t, l, f, w, h, d, b, new Uint8Array(v.U8.buffer, p, imgSize));
			},
			glCompressedTexSubImage2D: function (t, l, x, y, w, h, f, imgSize, p) {
				var v = V();
				ctx.compressedTexSubImage2D(t, l, x, y, w, h, f, new Uint8Array(v.U8.buffer, p, imgSize));
			},
			glCompressedTexSubImage3D: function (t, l, x, y, z, w, h, d, f, imgSize, p) {
				var v = V();
				ctx.compressedTexSubImage3D(t, l, x, y, z, w, h, d, f, new Uint8Array(v.U8.buffer, p, imgSize));
			},
			glTexParameteri: function (t, p, v) { ctx.texParameteri(t, p, v); },
			glGenerateMipmap: function (t) { ctx.generateMipmap(t); },

			/* ── framebuffers / renderbuffers ── */
			glGenFramebuffers: function (n, ptr) {
				var v = V();
				for (var i = 0; i < n; i++) { v.I32[(ptr >> 2) + i] = hNew("fbo", ctx.createFramebuffer()); }
			},
			glDeleteFramebuffers: function (n, ptr) {
				var v = V();
				for (var i = 0; i < n; i++) {
					var h = v.I32[(ptr >> 2) + i];
					var o = hObj(h, "fbo");
					if (o) { ctx.deleteFramebuffer(o); hDel(h); }
				}
			},
			glGenRenderbuffers: function (n, ptr) {
				var v = V();
				for (var i = 0; i < n; i++) { v.I32[(ptr >> 2) + i] = hNew("rb", ctx.createRenderbuffer()); }
			},
			glDeleteRenderbuffers: function (n, ptr) {
				var v = V();
				for (var i = 0; i < n; i++) {
					var h = v.I32[(ptr >> 2) + i];
					var o = hObj(h, "rb");
					if (o) { ctx.deleteRenderbuffer(o); hDel(h); }
				}
			},
			glGenSamplers: function (n, ptr) {
				var v = V();
				for (var i = 0; i < n; i++) { v.I32[(ptr >> 2) + i] = hNew("sampler", ctx.createSampler()); }
			},
			glDeleteSamplers: function (n, ptr) {
				var v = V();
				for (var i = 0; i < n; i++) {
					var h = v.I32[(ptr >> 2) + i];
					var o = hObj(h, "sampler");
					if (o) { ctx.deleteSampler(o); hDel(h); }
				}
			},
			glGenVertexArrays: function (n, ptr) {
				var v = V();
				for (var i = 0; i < n; i++) { v.I32[(ptr >> 2) + i] = hNew("vao", ctx.createVertexArray()); }
			},
			glDeleteVertexArrays: function (n, ptr) {
				var v = V();
				for (var i = 0; i < n; i++) {
					var h = v.I32[(ptr >> 2) + i];
					var o = hObj(h, "vao");
					if (o) { ctx.deleteVertexArray(o); hDel(h); }
				}
			},
			glBindFramebuffer: function (t, h) { ctx.bindFramebuffer(t, hObj(h, "fbo")); },
			glBindRenderbuffer: function (t, h) { ctx.bindRenderbuffer(t, hObj(h, "rb")); },
			glBindSampler: function (u, h) { ctx.bindSampler(u, hObj(h, "sampler")); },
			glBindVertexArray: function (h) { ctx.bindVertexArray(hObj(h, "vao")); },
			glCheckFramebufferStatus: function (t) { return ctx.checkFramebufferStatus(t); },
			glFramebufferTexture2D: function (t, a, tt, h, level, off) {
				ctx.framebufferTexture2D(t, a, tt, hObj(h, "texture"), level, off);
			},
			glFramebufferTextureLayer: function (t, a, h, level, layer) {
				ctx.framebufferTextureLayer(t, a, hObj(h, "texture"), level, layer);
			},
			glFramebufferRenderbuffer: function (t, a, rt, h) {
				ctx.framebufferRenderbuffer(t, a, rt, hObj(h, "rb"));
			},
			glRenderbufferStorageMultisample: function (t, s, f, w, h) {
				ctx.renderbufferStorageMultisample(t, s, f, w, h);
			},
			glDrawBuffers: function (n, ptr) {
				var v = V();
				var a = new Array(n);
				for (var i = 0; i < n; i++) { a[i] = v.I32[(ptr >> 2) + i]; }
				ctx.drawBuffers(a);
			},
			glInvalidateFramebuffer: function (t, n, ptr) {
				var v = V();
				var a = new Array(n);
				for (var i = 0; i < n; i++) { a[i] = v.I32[(ptr >> 2) + i]; }
				ctx.invalidateFramebuffer(t, a);
			},
			glClearBufferfi: function (b, db, depth, p) {
				var v = V();
				ctx.clearBufferfi(b, db, depth, v.F32[p >> 2]);
			},
			glClearBufferfv: function (b, db, p) {
				var v = V();
				ctx.clearBufferfv(b, db, v.F32.subarray(p >> 2, (p + 16) >> 2));
			},
			glClearBufferiv: function (b, db, p) {
				var v = V();
				ctx.clearBufferiv(b, db, v.I32.subarray(p >> 2, (p + 16) >> 2));
			},

			/* ── vertex attribs / draws (pointer args are VBO byte
			   offsets in the GL ES calling convention) ── */
			glVertexAttribPointer: function (i, sz, ty, norm, stride, off) {
				ctx.vertexAttribPointer(i, sz, ty, !!norm, stride, off);
			},
			glVertexAttribIPointer: function (i, sz, ty, stride, off) {
				ctx.vertexAttribIPointer(i, sz, ty, stride, off);
			},
			glVertexAttribDivisor: function (i, d) { ctx.vertexAttribDivisor(i, d); },
			glEnableVertexAttribArray: function (i) { ctx.enableVertexAttribArray(i); },
			glDisableVertexAttribArray: function (i) { ctx.disableVertexAttribArray(i); },
			glDrawArrays: function (m, f, c) { ctx.drawArrays(m, f, c); },
			glDrawArraysInstanced: function (m, f, c, n) { ctx.drawArraysInstanced(m, f, c, n); },
			glDrawElements: function (m, c, ty, off) { ctx.drawElements(m, c, ty, off); },
			glDrawElementsInstanced: function (m, c, ty, off, n) {
				ctx.drawElementsInstanced(m, c, ty, off, n);
			},

			/* ── queries ── */
			glGetIntegerv: function (p, ptr) {
				var v = V();
				v.I32[ptr >> 2] = ctx.getParameter(p);
			},
			glGetStringi: function (name, index) {
				var ptr = window.odmCore.data("shim_gl_scratch");
				copyStr(ptr, glString(name), GL_STRING_CAP);
				return ptr;
			}
		};
		return G;
	}

	window.__ODM_BACKEND__ = {
		name: "webgl2",
		prepare: function (canvas) {
			ctx = canvas.getContext("webgl2", {
				alpha: false,
				depth: true,
				stencil: true,
				antialias: false, /* the renderer runs MSAA in its own target */
				powerPreference: "high-performance"
			});
			if (!ctx) {
				return Promise.reject(new Error("WebGL2 context creation failed"));
			}
			/* The renderer's MSAA scene target is RGBA16F (HDR) and the
			   tone-map blends float buffers: WebGL2 needs these extensions
			   to render/blend to float color attachments. */
			ctx.getExtension("EXT_color_buffer_float");
			ctx.getExtension("EXT_color_buffer_half_float");
			ctx.getExtension("EXT_float_blend");
			return Promise.resolve();
		},
		imports: imports,
		/* the default framebuffer presents itself; per-frame work is the
		   swapchain (size) only, which the core handles via
		   shim_js_resize. */
		frame: function () {},
		resize: function () {},
		cleanup: function () {
			if (ctx && ctx.getExtension("WEBGL_lose_context")) {
				ctx.getExtension("WEBGL_lose_context").loseContext();
			}
		}
	};
})();
