/* glue-webgpu.js — WebGPU backend table for the bare-wasm web build.
 * Shipped as index.js (the template loads it when the browser has WebGPU,
 * or ?gl=webgpu forces it).
 *
 * The renderer C (sokol_gfx WGPU backend) calls the webgpu.h C API; every
 * call lands here as an `env.wgpu*` import, hand-rolled over the browser
 * WebGPU JS API — the classic wgpu* entry points are the WebGPU ABI
 * sokol's WGPU backend is built against:
 *   (a) the C handles (WGPUDevice, WGPUBuffer, ...) are opaque pointers
 *       the renderer never dereferences — they are mapped through the
 *       refcounted handle table below (0 = NULL, the wgpu convention);
 *   (b) the descriptor structs are read by field offset from wasm linear
 *       memory — wasm32 offsets per the webgpu.h layout (tools note:
 *       WGPUColor is 4 x double, WGPUStringView is {data, length});
 *   (c) the swapchain is the canvas WebGPU context: prepare() requests
 *       the adapter/device, frame() configures the context once, then
 *       hands a fresh color view + the depth-stencil view to the C shim
 *       (shim_js_set_swapchain) before each frame's draws; the browser
 *       presents at end of frame.
 *
 * Readback (sokol's only path: a mappedAtCreation buffer ->
 * GetMappedRange -> C memcpy -> Unmap) needs the "mapped range" to live
 * in wasm memory, so the bytes are staged in a scratch region grown at
 * the TOP of the wasm linear memory (the odin wasm allocator also takes
 * fresh top pages, so the two never collide) and copied into the
 * browser's ArrayBuffer on Unmap.
 */
(function () {
	"use strict";

	var E = null; /* wasm exports (set in init) */
	var canvas = null;
	var device = null;
	var queue = null;
	var queueHandle = 0;
	var deviceHandle = 0;
	var gpuCtx = null;
	var ctxConfigured = false;
	var depthTex = null, depthW = 0, depthH = 0;
	var prevColorH = 0, prevDepthH = 0;

	/* Handle table: 1-based int handle -> {t, o, refs}. Every wgpu*
	   create* returns a fresh entry (refs 1); the renderer's AddRef/
	   Release move refs, and Release at 0 drops the entry (the browser
	   object is then owned only by the GPU). */
	var H = { next: 1, m: new Map() };

	function hNew(kind, o) {
		var h = H.next++;
		H.m.set(h, { t: kind, o: o, refs: 1, unmaps: null });
		return h;
	}
	function hEntry(h) { return h ? H.m.get(h) : undefined; }
	function hObj(h) {
		var e = hEntry(h);
		return e ? e.o : undefined;
	}
	function hAddRef(h) {
		var e = hEntry(h);
		if (e) { e.refs++; }
	}
	function hRelease(h) {
		var e = hEntry(h);
		if (!e) { return; }
		if (--e.refs > 0) { return; }
		if (e.t === "buffer" && e.unmaps) {
			/* released while still mapped: flush best-effort so the
			   scratch region does not leak. */
			var v = V();
			for (var i = 0; i < e.unmaps.length; i++) {
				var c = e.unmaps[i];
				try { new Uint8Array(c.mapped).set(v.U8.subarray(c.ptr, c.ptr + c.n)); }
				catch (ex) { /* buffer may already be unusable */ }
				scratchFree(c.ptr, c.n);
			}
			try { e.o.unmap(); } catch (ex) { /* same */ }
		}
		H.m.delete(h);
	}

	function V() { return window.odmCore.views(); }

	/* ── scratch region for GetMappedRange (see file header) ──
	   The odin wasm allocator takes pages from the fresh top of the
	   linear memory on each grow; growing here and bumping within the
	   slice we just claimed is safe against it for the same reason. */
	var scratch = { blockEnd: 0, cursor: 0, free: [] };
	var SCRATCH_PAGE = 65536;
	var SCRATCH_QUANTUM = 32; /* pages (2 MiB) claimed per grow */

	function scratchAlloc(n) {
		n = (n + 15) & ~15;
		for (var i = 0; i < scratch.free.length; i++) {
			var f = scratch.free[i];
			if (f.n >= n) {
				if (f.n - n >= SCRATCH_PAGE) {
					scratch.free[i] = { p: f.p + n, n: f.n - n };
				} else {
					scratch.free.splice(i, 1);
				}
				return f.p;
			}
		}
		if (scratch.cursor + n > scratch.blockEnd) {
			var mem = E.memory;
			var old = mem.buffer.byteLength;
			var pages = Math.ceil(n / SCRATCH_PAGE) + SCRATCH_QUANTUM;
			mem.grow(pages);
			scratch.cursor = old;
			scratch.blockEnd = old + pages * SCRATCH_PAGE;
		}
		var p = scratch.cursor;
		scratch.cursor += n;
		return p;
	}
	function scratchFree(p, n) {
		n = (n + 15) & ~15;
		if (p + n === scratch.cursor) { scratch.cursor = p; return; }
		scratch.free.push({ p: p, n: n });
	}

	/* ── memory readers ── */
	var decoder = new TextDecoder();

	/* WGPUStringView {data, length} at ptr ("" for a null view). */
	function sv(ptr) {
		if (!ptr) { return ""; }
		var v = V();
		var data = v.I32[ptr >> 2] >>> 0;
		var len = v.I32[(ptr + 4) >> 2] >>> 0;
		if (!data) { return ""; }
		return decoder.decode(v.U8.subarray(data, data + len));
	}

	/* WGPUColor is 4 x double in this port's webgpu.h (32 bytes); decode
	   by copy so no 8-byte alignment is assumed. */
	var colorBuf = new Uint8Array(32);
	var colorF64 = new Float64Array(colorBuf.buffer);
	function colorAt(p) {
		var v = V();
		colorBuf.set(v.U8.subarray(p, p + 32));
		return { r: colorF64[0], g: colorF64[1], b: colorF64[2], a: colorF64[3] };
	}

	/* uint64_t in memory: low + high word. The WGPU_WHOLE_* sentinels
	   (both words 0xFFFFFFFF) come back as undefined. */
	function u64(p) {
		var v = V();
		var lo = v.I32[p >> 2] >>> 0;
		var hi = v.I32[(p + 4) >> 2] >>> 0;
		if (lo === 0xFFFFFFFF && hi === 0xFFFFFFFF) { return undefined; }
		return lo + hi * 4294967296;
	}
	function u64raw(p) {
		var v = V();
		return (v.I32[p >> 2] >>> 0) + ((v.I32[(p + 4) >> 2] >>> 0) * 4294967296);
	}

	/* ── enum tables (int -> browser string; a hole = undefined/omit) ──
	   Copied from the emdawnwebgpu port's generated tables. */
	var ENUM = {
		LoadOp: [, "load", "clear"],
		StoreOp: [, "store", "discard"],
		TextureFormat: [,
			"r8unorm", "r8snorm", "r8uint", "r8sint",
			"r16unorm", "r16snorm", "r16uint", "r16sint", "r16float",
			"rg8unorm", "rg8snorm", "rg8uint", "rg8sint",
			"r32float", "r32uint", "r32sint",
			"rg16unorm", "rg16snorm", "rg16uint", "rg16sint", "rg16float",
			"rgba8unorm", "rgba8unorm-srgb", "rgba8snorm", "rgba8uint",
			"rgba8sint", "bgra8unorm", "bgra8unorm-srgb",
			"rgb10a2uint", "rgb10a2unorm", "rg11b10ufloat", "rgb9e5ufloat",
			"rg32float", "rg32uint", "rg32sint",
			"rgba16unorm", "rgba16snorm", "rgba16uint", "rgba16sint",
			"rgba16float", "rgba32float", "rgba32uint", "rgba32sint",
			"stencil8", "depth16unorm", "depth24plus",
			"depth24plus-stencil8", "depth32float", "depth32float-stencil8",
			"bc1-rgba-unorm", "bc1-rgba-unorm-srgb",
			"bc2-rgba-unorm", "bc2-rgba-unorm-srgb",
			"bc3-rgba-unorm", "bc3-rgba-unorm-srgb",
			"bc4-r-unorm", "bc4-r-snorm", "bc5-rg-unorm", "bc5-rg-snorm",
			"bc6h-rgb-ufloat", "bc6h-rgb-float",
			"bc7-rgba-unorm", "bc7-rgba-unorm-srgb",
			"etc2rgb8unorm", "etc2rgb8unorm-srgb",
			"etc2rgb8a1unorm", "etc2rgb8a1unorm-srgb",
			"etc2rgba8unorm", "etc2rgba8unorm-srgb",
			"eacr11unorm", "eacr11snorm", "eacrg11unorm", "eacrg11snorm",
			"astc4x4unorm", "astc4x4unorm-srgb",
			"astc5x4unorm", "astc5x4unorm-srgb",
			"astc5x5unorm", "astc5x5unorm-srgb",
			"astc6x5unorm", "astc6x5unorm-srgb",
			"astc6x6unorm", "astc6x6unorm-srgb",
			"astc8x5unorm", "astc8x5unorm-srgb",
			"astc8x6unorm", "astc8x6unorm-srgb",
			"astc8x8unorm", "astc8x8unorm-srgb",
			"astc10x5unorm", "astc10x5unorm-srgb",
			"astc10x6unorm", "astc10x6unorm-srgb",
			"astc10x8unorm", "astc10x8unorm-srgb",
			"astc10x10unorm", "astc10x10unorm-srgb",
			"astc12x10unorm", "astc12x10unorm-srgb",
			"astc12x12unorm", "astc12x12unorm-srgb"
		],
		TextureDimension: [, "1d", "2d", "3d"],
		TextureViewDimension: [, "1d", "2d", "2d-array", "cube", "cube-array", "3d"],
		TextureAspect: [, "all", "stencil-only", "depth-only"],
		FilterMode: [, "nearest", "linear"],
		MipmapFilterMode: [, "nearest", "linear"],
		AddressMode: [, "clamp-to-edge", "repeat", "mirror-repeat"],
		CompareFunction: [, "never", "less", "equal", "less-equal", "greater",
			"not-equal", "greater-equal", "always"],
		BlendFactor: [, "zero", "one", "src", "one-minus-src", "src-alpha",
			"one-minus-src-alpha", "dst", "one-minus-dst", "dst-alpha",
			"one-minus-dst-alpha", "src-alpha-saturated", "constant",
			"one-minus-constant", "src1", "one-minus-src1", "src1-alpha",
			"one-minus-src1-alpha"],
		BlendOperation: [, "add", "subtract", "reverse-subtract", "min", "max"],
		StencilOperation: [, "keep", "zero", "replace", "invert",
			"increment-clamp", "decrement-clamp", "increment-wrap",
			"decrement-wrap"],
		VertexFormat: [, "uint8", "uint8x2", "uint8x4", "sint8", "sint8x2",
			"sint8x4", "unorm8", "unorm8x2", "unorm8x4", "snorm8", "snorm8x2",
			"snorm8x4", "uint16", "uint16x2", "uint16x4", "sint16", "sint16x2",
			"sint16x4", "unorm16", "unorm16x2", "unorm16x4", "snorm16",
			"snorm16x2", "snorm16x4", "float16", "float16x2", "float16x4",
			"float32", "float32x2", "float32x3", "float32x4", "uint32",
			"uint32x2", "uint32x3", "uint32x4", "sint32", "sint32x2",
			"sint32x3", "sint32x4", "unorm10-10-10-2", "unorm8x4-bgra"],
		VertexStepMode: [, "vertex", "instance"],
		IndexFormat: [, "uint16", "uint32"],
		PrimitiveTopology: [, "point-list", "line-list", "line-strip",
			"triangle-list", "triangle-strip"],
		CullMode: [, "none", "front", "back"],
		FrontFace: [, "ccw", "cw"],
		BufferBindingType: [,, "uniform", "storage", "read-only-storage"],
		SamplerBindingType: [,, "filtering", "non-filtering", "comparison"],
		TextureSampleType: [,, "float", "unfilterable-float", "depth",
			"sint", "uint"],
		StorageTextureAccess: [,, "write-only", "read-only", "read-write"],
		FeatureName: {
			1: "core-features-and-limits",
			2: "depth-clip-control",
			3: "depth32float-stencil8",
			4: "texture-compression-bc",
			5: "texture-compression-bc-sliced-3d",
			6: "texture-compression-etc2",
			7: "texture-compression-astc",
			8: "texture-compression-astc-sliced-3d",
			9: "timestamp-query",
			10: "indirect-first-instance",
			11: "shader-f16",
			12: "rg11b10ufloat-renderable",
			13: "bgra8unorm-storage",
			14: "float32-filterable",
			15: "float32-blendable",
			16: "clip-distances",
			17: "dual-source-blending",
			18: "subgroups",
			19: "texture-formats-tier1",
			20: "texture-formats-tier2",
			21: "primitive-index",
			22: "texture-component-swizzle"
		}
	};

	/* ── descriptor field readers (offsets from the port's structInfo32)
	   The flag fields (usage, visibility, writeMask, sample mask) are
	   passed through as raw u32 bitfields — exactly as the emdawnwebgpu
	   bindings do, and as the target browsers (Chromium/Dawn, Firefox)
	   accept them. WGPUOptionalBool is this port's False=0/True=1/
	   Undefined=2, so !!() is the mapping the bindings use. */

	function makeBufferBindingLayout(p) {
		var v = V();
		var t = v.I32[(p + 4) >> 2];
		if (!t) { return undefined; }
		return {
			type: ENUM.BufferBindingType[t],
			hasDynamicOffset: !!v.I32[(p + 8) >> 2],
			minBindingSize: u64raw(p + 16)
		};
	}
	function makeSamplerBindingLayout(p) {
		var v = V();
		var t = v.I32[(p + 4) >> 2];
		if (!t) { return undefined; }
		return { type: ENUM.SamplerBindingType[t] };
	}
	function makeTextureBindingLayout(p) {
		var v = V();
		var st = v.I32[(p + 4) >> 2];
		if (!st) { return undefined; }
		return {
			sampleType: ENUM.TextureSampleType[st],
			viewDimension: ENUM.TextureViewDimension[v.I32[(p + 8) >> 2]],
			multisampled: !!v.I32[(p + 12) >> 2]
		};
	}
	function makeStorageTextureBindingLayout(p) {
		var v = V();
		var a = v.I32[(p + 4) >> 2];
		if (!a) { return undefined; }
		return {
			access: ENUM.StorageTextureAccess[a],
			format: ENUM.TextureFormat[v.I32[(p + 8) >> 2]],
			viewDimension: ENUM.TextureViewDimension[v.I32[(p + 12) >> 2]]
		};
	}

	function makeStencilFace(p) {
		var v = V();
		return {
			compare: ENUM.CompareFunction[v.I32[p >> 2]],
			failOp: ENUM.StencilOperation[v.I32[(p + 4) >> 2]],
			depthFailOp: ENUM.StencilOperation[v.I32[(p + 8) >> 2]],
			passOp: ENUM.StencilOperation[v.I32[(p + 12) >> 2]]
		};
	}
	function makeDepthStencilState(p) {
		var v = V();
		return {
			format: ENUM.TextureFormat[v.I32[(p + 4) >> 2]],
			depthWriteEnabled: !!v.I32[(p + 8) >> 2],
			depthCompare: ENUM.CompareFunction[v.I32[(p + 12) >> 2]],
			stencilFront: makeStencilFace(p + 16),
			stencilBack: makeStencilFace(p + 32),
			stencilReadMask: v.I32[(p + 48) >> 2] >>> 0,
			stencilWriteMask: v.I32[(p + 52) >> 2] >>> 0,
			depthBias: v.I32[(p + 56) >> 2],
			depthBiasSlopeScale: v.F32[(p + 60) >> 2],
			depthBiasClamp: v.F32[(p + 64) >> 2]
		};
	}

	function makeBlendComponent(p) {
		var v = V();
		return {
			operation: ENUM.BlendOperation[v.I32[p >> 2]],
			srcFactor: ENUM.BlendFactor[v.I32[(p + 4) >> 2]],
			dstFactor: ENUM.BlendFactor[v.I32[(p + 8) >> 2]]
		};
	}
	function makeBlendState(p) {
		return { color: makeBlendComponent(p), alpha: makeBlendComponent(p + 12) };
	}
	function makeColorTargetState(p) {
		var v = V();
		var format = ENUM.TextureFormat[v.I32[(p + 4) >> 2]];
		if (!format) { return undefined; }
		var t = { format: format };
		var bl = v.I32[(p + 8) >> 2] >>> 0;
		if (bl) { t.blend = makeBlendState(bl); }
		t.writeMask = v.I32[(p + 16) >> 2] >>> 0;
		return t;
	}

	function makeVertexState(p) {
		var v = V();
		var s = {
			module: hObj(v.I32[(p + 4) >> 2]),
			entryPoint: sv(p + 8)
		};
		var bc = v.I32[(p + 24) >> 2] >>> 0;
		if (!bc) { return s; }
		var bp = v.I32[(p + 28) >> 2] >>> 0;
		var vbs = [];
		for (var i = 0; i < bc; i++) {
			var b = bp + i * 24; /* WGPUVertexBufferLayout */
			var step = v.I32[(b + 4) >> 2];
			var ac = v.I32[(b + 16) >> 2] >>> 0;
			if (!step && !ac) { vbs.push(null); continue; }
			var ap = v.I32[(b + 20) >> 2] >>> 0;
			var attrs = [];
			for (var j = 0; j < ac; j++) {
				var a = ap + j * 24; /* WGPUVertexAttribute */
				attrs.push({
					format: ENUM.VertexFormat[v.I32[(a + 4) >> 2]],
					offset: u64raw(a + 8),
					shaderLocation: v.I32[(a + 16) >> 2] >>> 0
				});
			}
			vbs.push({
				arrayStride: u64raw(b + 8),
				stepMode: ENUM.VertexStepMode[step],
				attributes: attrs
			});
		}
		s.buffers = vbs;
		return s;
	}
	function makePrimitiveState(p) {
		var v = V();
		return {
			topology: ENUM.PrimitiveTopology[v.I32[(p + 4) >> 2]],
			stripIndexFormat: ENUM.IndexFormat[v.I32[(p + 8) >> 2]],
			frontFace: ENUM.FrontFace[v.I32[(p + 12) >> 2]],
			cullMode: ENUM.CullMode[v.I32[(p + 16) >> 2]],
			unclippedDepth: !!v.I32[(p + 20) >> 2]
		};
	}
	function makeMultisampleState(p) {
		var v = V();
		return {
			count: v.I32[(p + 4) >> 2] >>> 0,
			mask: v.I32[(p + 8) >> 2] >>> 0,
			alphaToCoverageEnabled: !!v.I32[(p + 12) >> 2]
		};
	}
	function makeFragmentState(p) {
		var v = V();
		var tc = v.I32[(p + 24) >> 2] >>> 0;
		var tp = v.I32[(p + 28) >> 2] >>> 0;
		var targets = [];
		for (var i = 0; i < tc; i++) {
			targets.push(makeColorTargetState(tp + i * 24));
		}
		return {
			module: hObj(v.I32[(p + 4) >> 2]),
			entryPoint: sv(p + 8),
			targets: targets
		};
	}
	function makeComputeState(p) {
		var v = V();
		return {
			module: hObj(v.I32[(p + 4) >> 2]),
			entryPoint: sv(p + 8)
		};
	}

	/* the WGPU_WHOLE_MAP_SIZE / copy-stride sentinel (size_t on wasm32) */
	var WHOLE32 = 0xFFFFFFFF;

	/* The odin wasm driver passes i64 (C uint64_t) params to the glue as
	   BigInt; the browser WebGPU API wants plain numbers. Convert a wasm i64
	   to a JS number (safe: scene offsets/sizes are far below 2^53). The
	   WGPU_WHOLE_SIZE sentinel (0xFFFFFFFFFFFFFFFF) crosses the wasm i64 as
	   -1n, or the unsigned 64-bit max - both map to undefined (WebGPU's
	   "no bound" for a size). */
	var WHOLE64 = 0xFFFFFFFFFFFFFFFFn;
	function whole64(s) {
		if (typeof s === "bigint") {
			if (s === -1n || s === WHOLE64) { return undefined; }
			return Number(s);
		}
		if (s === -1 || s === 18446744073709551615 || s === WHOLE32) {
			return undefined;
		}
		return s;
	}
	/* a concrete i64 offset: BigInt -> number; a whole-sentinel offset is
	   nonsensical, so coerce to 0 (defensive, never expected). */
	function i64num(s) {
		if (typeof s === "bigint") {
			if (s === -1n || s === WHOLE64) { return 0; }
			return Number(s);
		}
		if (s === -1 || s === WHOLE32) { return 0; }
		return s;
	}

	function imports() {
		var G = {
			/* ── device: resource creation ── */
			wgpuDeviceCreateBuffer: function (dev, desc) {
				var v = V();
				try {
					var b = hObj(dev).createBuffer({
						label: sv(desc + 4),
						usage: v.I32[(desc + 16) >> 2] >>> 0,
						size: v.I32[(desc + 24) >> 2] >>> 0,
						mappedAtCreation: !!v.I32[(desc + 32) >> 2]
					});
					return hNew("buffer", b);
				} catch (ex) {
					console.error("webgpu createBuffer:", ex);
					return 0;
				}
			},

			wgpuDeviceCreateShaderModule: function (dev, desc) {
				var v = V();
				var chain = v.I32[desc >> 2] >>> 0; /* WGPUShaderSource{WGSL,SPIRV} */
				var sType = v.I32[(chain + 4) >> 2];
				var code;
				if (sType === 2) { /* WGPUShaderSourceWGSL: code StringView at +8 */
					code = sv(chain + 8);
				} else if (sType === 1) { /* SPIRV: u32 words at +12 */
					code = new Uint32Array(v.U8.buffer, v.I32[(chain + 12) >> 2] >>> 0,
						v.I32[(chain + 8) >> 2] >>> 0);
				} else {
					throw new Error("webgpu: unknown shader sType " + sType);
				}
				try {
					return hNew("shader_module", hObj(dev).createShaderModule({
						label: sv(desc + 4),
						code: code
					}));
				} catch (ex) {
					console.error("webgpu createShaderModule:", ex);
					return 0;
				}
			},

			wgpuDeviceCreateTexture: function (dev, desc) {
				var v = V();
				var t = {
					label: sv(desc + 4),
					size: [
						v.I32[(desc + 28) >> 2] >>> 0,
						v.I32[(desc + 32) >> 2] >>> 0,
						v.I32[(desc + 36) >> 2] >>> 0
					],
					mipLevelCount: v.I32[(desc + 44) >> 2] >>> 0,
					sampleCount: v.I32[(desc + 48) >> 2] >>> 0 || undefined,
					dimension: ENUM.TextureDimension[v.I32[(desc + 24) >> 2]],
					format: ENUM.TextureFormat[v.I32[(desc + 40) >> 2]],
					usage: v.I32[(desc + 16) >> 2] >>> 0
				};
				var vfc = v.I32[(desc + 52) >> 2] >>> 0;
				if (vfc) {
					var vf = v.I32[(desc + 56) >> 2] >>> 0;
					var formats = [];
					for (var i = 0; i < vfc; i++) {
						formats.push(ENUM.TextureFormat[v.I32[(vf + i * 4) >> 2]]);
					}
					t.viewFormats = formats;
				}
				try {
					var ht = hNew("texture", hObj(dev).createTexture(t));
					if (ht) { H.m.get(ht).format = t.format; }
					return ht;
				} catch (ex) {
					console.error("webgpu createTexture:", ex);
					return 0;
				}
			},

			wgpuDeviceCreateSampler: function (dev, desc) {
				var d = hObj(dev);
				if (!desc) { return hNew("sampler", d.createSampler()); }
				var v = V();
				try {
					return hNew("sampler", d.createSampler({
						label: sv(desc + 4),
						addressModeU: ENUM.AddressMode[v.I32[(desc + 12) >> 2]],
						addressModeV: ENUM.AddressMode[v.I32[(desc + 16) >> 2]],
						addressModeW: ENUM.AddressMode[v.I32[(desc + 20) >> 2]],
						magFilter: ENUM.FilterMode[v.I32[(desc + 24) >> 2]],
						minFilter: ENUM.FilterMode[v.I32[(desc + 28) >> 2]],
						mipmapFilter: ENUM.MipmapFilterMode[v.I32[(desc + 32) >> 2]],
						lodMinClamp: v.F32[(desc + 36) >> 2],
						lodMaxClamp: v.F32[(desc + 40) >> 2],
						compare: ENUM.CompareFunction[v.I32[(desc + 44) >> 2]],
						maxAnisotropy: v.I32[(desc + 48) >> 2] & 0xFFFF
					}));
				} catch (ex) {
					console.error("webgpu createSampler:", ex);
					return 0;
				}
			},

			wgpuDeviceCreatePipelineLayout: function (dev, desc) {
				var v = V();
				var n = v.I32[(desc + 12) >> 2] >>> 0;
				var arr = v.I32[(desc + 16) >> 2] >>> 0;
				var bgls = [];
				for (var i = 0; i < n; i++) {
					bgls.push(hObj(v.I32[(arr + i * 4) >> 2]));
				}
				var hpl = 0;
				try {
					hpl = hNew("pipeline_layout", hObj(dev).createPipelineLayout({
						label: sv(desc + 4),
						bindGroupLayouts: bgls
					}));
				} catch (ex) {
					console.error("webgpu createPipelineLayout:", ex);
					return 0;
				}
				return hpl;
			},

			wgpuDeviceCreateBindGroupLayout: function (dev, desc) {
				var v = V();
				var n = v.I32[(desc + 12) >> 2] >>> 0;
				var ep = v.I32[(desc + 16) >> 2] >>> 0;
				var entries = [];
				for (var i = 0; i < n; i++) {
					var e = ep + i * 88; /* WGPUBindGroupLayoutEntry */
					var b = v.I32[(e + 4) >> 2] >>> 0;
					entries.push({
						binding: b,
						visibility: v.I32[(e + 8) >> 2] >>> 0,
						buffer: makeBufferBindingLayout(e + 24),
						sampler: makeSamplerBindingLayout(e + 48),
						texture: makeTextureBindingLayout(e + 56),
						storageTexture: makeStorageTextureBindingLayout(e + 72)
					});
				}
				try {
					return hNew("bind_group_layout", hObj(dev).createBindGroupLayout({
						label: sv(desc + 4),
						entries: entries
					}));
				} catch (ex) {
					console.error("webgpu createBindGroupLayout:", ex);
					return 0;
				}
			},

			wgpuDeviceCreateBindGroup: function (dev, desc) {
				var v = V();
				var n = v.I32[(desc + 16) >> 2] >>> 0;
				var ep = v.I32[(desc + 20) >> 2] >>> 0;
				var entries = [];
				for (var i = 0; i < n; i++) {
					var e = ep + i * 40; /* WGPUBindGroupEntry */
					var bufH = v.I32[(e + 8) >> 2];
					var samH = v.I32[(e + 32) >> 2];
					var texH = v.I32[(e + 36) >> 2];
					var resource;
					if (bufH) {
						resource = { buffer: hObj(bufH) };
						var off = u64raw(e + 16);
						if (off) { resource.offset = off; }
						var size = u64(e + 24); /* UINT64_MAX sentinel */
						if (size !== undefined) { resource.size = size; }
					} else if (samH) {
						resource = hObj(samH);
					} else if (texH) {
						resource = hObj(texH);
					} else {
						resource = null;
					}
					entries.push({
						binding: v.I32[(e + 4) >> 2] >>> 0,
						resource: resource
					});
				}
				var layoutH = v.I32[(desc + 12) >> 2];
				var hbg = 0;
				try {
					hbg = hNew("bind_group", hObj(dev).createBindGroup({
						label: sv(desc + 4),
						layout: hObj(layoutH),
						entries: entries
					}));
				} catch (ex) {
					console.error("webgpu createBindGroup:", ex);
					return 0;
				}
				return hbg;
			},

			wgpuDeviceCreateCommandEncoder: function (dev, desc) {
				return hNew("encoder", hObj(dev).createCommandEncoder(
					desc ? { label: sv(desc + 4) } : undefined));
			},

			wgpuDeviceCreateRenderPipeline: function (dev, desc) {
				var v = V();
				var p = { label: sv(desc + 4) };
				var layoutH = v.I32[(desc + 12) >> 2];
				p.layout = layoutH ? hObj(layoutH) : "auto";
				p.vertex = makeVertexState(desc + 16);
				p.primitive = makePrimitiveState(desc + 48);
				var ds = v.I32[(desc + 72) >> 2] >>> 0;
				if (ds) { p.depthStencil = makeDepthStencilState(ds); }
				p.multisample = makeMultisampleState(desc + 76);
				var fg = v.I32[(desc + 92) >> 2] >>> 0;
				if (fg) { p.fragment = makeFragmentState(fg); }
				try {
					var hp = hNew("render_pipeline", hObj(dev).createRenderPipeline(p));
					return hp;
				} catch (ex) {
					console.error("webgpu createRenderPipeline:", ex);
					return 0;
				}
			},

			wgpuDeviceCreateComputePipeline: function (dev, desc) {
				var v = V();
				var layoutH = v.I32[(desc + 12) >> 2];
				try {
					return hNew("compute_pipeline", hObj(dev).createComputePipeline({
						label: sv(desc + 4),
						layout: layoutH ? hObj(layoutH) : "auto",
						compute: makeComputeState(desc + 16)
					}));
				} catch (ex) {
					console.error("webgpu createComputePipeline:", ex);
					return 0;
				}
			},

			/* ── device: queries ── */
			wgpuDeviceGetLimits: function (dev, out) {
				var v = V();
				var L = hObj(dev).limits;
				function u32(name, off) {
					v.I32[(out + off) >> 2] = (typeof L[name] === "number") ? L[name] : 0;
				}
				function u64(name, off) {
					var n = (typeof L[name] === "number") ? L[name] : 0;
					v.I32[(out + off) >> 2] = n >>> 0;
					v.I32[(out + off + 4) >> 2] = Math.floor(n / 4294967296) >>> 0;
				}
				u32("maxTextureDimension1D", 4);
				u32("maxTextureDimension2D", 8);
				u32("maxTextureDimension3D", 12);
				u32("maxTextureArrayLayers", 16);
				u32("maxBindGroups", 20);
				u32("maxBindGroupsPlusVertexBuffers", 24);
				u32("maxBindingsPerBindGroup", 28);
				u32("maxDynamicUniformBuffersPerPipelineLayout", 32);
				u32("maxDynamicStorageBuffersPerPipelineLayout", 36);
				u32("maxSampledTexturesPerShaderStage", 40);
				u32("maxSamplersPerShaderStage", 44);
				u32("maxStorageBuffersPerShaderStage", 48);
				u32("maxStorageTexturesPerShaderStage", 52);
				u32("maxUniformBuffersPerShaderStage", 56);
				u64("maxUniformBufferBindingSize", 64);
				u64("maxStorageBufferBindingSize", 72);
				u32("minUniformBufferOffsetAlignment", 80);
				u32("minStorageBufferOffsetAlignment", 84);
				u32("maxVertexBuffers", 88);
				u64("maxBufferSize", 96);
				u32("maxVertexAttributes", 104);
				u32("maxVertexBufferArrayStride", 108);
				u32("maxInterStageShaderVariables", 112);
				u32("maxColorAttachments", 116);
				u32("maxColorAttachmentBytesPerSample", 120);
				u32("maxComputeWorkgroupStorageSize", 124);
				u32("maxComputeInvocationsPerWorkgroup", 128);
				u32("maxComputeWorkgroupSizeX", 132);
				u32("maxComputeWorkgroupSizeY", 136);
				u32("maxComputeWorkgroupSizeZ", 140);
				u32("maxComputeWorkgroupsPerDimension", 144);
				u32("maxImmediateSize", 148);
				return 1; /* WGPUStatus_Success */
			},

			wgpuDeviceGetQueue: function (dev) {
				if (!hEntry(queueHandle)) { queueHandle = hNew("queue", queue); }
				return queueHandle;
			},

			wgpuDeviceHasFeature: function (dev, feature) {
				var name = ENUM.FeatureName[feature];
				return name && hObj(dev).features.has(name) ? 1 : 0;
			},

			/* ── buffers: mapped readback ── */
			wgpuBufferGetMappedRange: function (h, offset, size) {
				var e = hEntry(h);
				if (!e) { return 0; }
				var o = (typeof offset === "bigint") ? Number(offset) : offset;
				var s = (typeof size === "bigint") ? Number(size) : size;
				var off = (o >>> 0) === WHOLE32 ? undefined : (o >>> 0);
				var sz = (s >>> 0) === WHOLE32 ? undefined : (s >>> 0);
				var mapped;
				try {
					mapped = e.o.getMappedRange(off, sz);
				} catch (ex) {
					console.error("webgpu getMappedRange:", ex);
					return 0;
				}
				var n = mapped.byteLength;
				if (!n) { return 0; }
				var ptr = scratchAlloc(n);
				var v = V();
				v.U8.fill(0, ptr, n);
				if (!e.unmaps) { e.unmaps = []; }
				e.unmaps.push({ mapped: mapped, ptr: ptr, n: n });
				return ptr;
			},

			wgpuBufferUnmap: function (h) {
				var e = hEntry(h);
				if (!e) { return; }
				if (e.unmaps) {
					var v = V();
					for (var i = 0; i < e.unmaps.length; i++) {
						var c = e.unmaps[i];
						try {
							new Uint8Array(c.mapped).set(v.U8.subarray(c.ptr, c.ptr + c.n));
						} catch (ex) { console.error("webgpu unmap copy:", ex); }
						scratchFree(c.ptr, c.n);
					}
					e.unmaps = null;
				}
				e.o.unmap();
			},

			wgpuBufferAddRef: function (h) { hAddRef(h); },
			wgpuBufferRelease: function (h) { hRelease(h); },

			/* ── command encoder / passes ── */
			wgpuCommandEncoderBeginRenderPass: function (enc, desc) {
				var v = V();
				var n = v.I32[(desc + 12) >> 2] >>> 0;
				var ap = v.I32[(desc + 16) >> 2] >>> 0;
				var atts = [];
				for (var i = 0; i < n; i++) {
					var a = ap + i * 56; /* WGPURenderPassColorAttachment */
					var viewH = v.I32[(a + 4) >> 2];
					if (!viewH) { atts.push(undefined); continue; }
					atts.push({
						view: hObj(viewH),
						depthSlice: (v.I32[(a + 8) >> 2] >>> 0) === WHOLE32 ? undefined : v.I32[(a + 8) >> 2] >>> 0,
						resolveTarget: hObj(v.I32[(a + 12) >> 2]),
						loadOp: ENUM.LoadOp[v.I32[(a + 16) >> 2]],
						storeOp: ENUM.StoreOp[v.I32[(a + 20) >> 2]],
						clearValue: colorAt(a + 24)
					});
				}
				var rpd = {
					label: sv(desc + 4),
					colorAttachments: atts
				};
				var dsp = v.I32[(desc + 20) >> 2] >>> 0;
				if (dsp) {
					/* WGPURenderPassDepthStencilAttachment */
					rpd.depthStencilAttachment = {
						view: hObj(v.I32[(dsp + 4) >> 2]),
						depthLoadOp: ENUM.LoadOp[v.I32[(dsp + 8) >> 2]],
						depthStoreOp: ENUM.StoreOp[v.I32[(dsp + 12) >> 2]],
						depthClearValue: v.F32[(dsp + 16) >> 2],
						depthReadOnly: !!v.I32[(dsp + 20) >> 2],
						stencilLoadOp: ENUM.LoadOp[v.I32[(dsp + 24) >> 2]],
						stencilStoreOp: ENUM.StoreOp[v.I32[(dsp + 28) >> 2]],
						stencilClearValue: v.I32[(dsp + 32) >> 2] >>> 0,
						stencilReadOnly: !!v.I32[(dsp + 36) >> 2]
					};
				}
				return hNew("render_pass", hObj(enc).beginRenderPass(rpd));
			},

			wgpuCommandEncoderBeginComputePass: function (enc, desc) {
				return hNew("compute_pass", hObj(enc).beginComputePass(
					desc ? { label: sv(desc + 4) } : undefined));
			},

			wgpuCommandEncoderFinish: function (enc, desc) {
				return hNew("command_buffer", hObj(enc).finish(
					desc ? { label: sv(desc + 4) } : undefined));
			},

			wgpuCommandEncoderRelease: function (h) { hRelease(h); },

			/* render pass encoder */
			wgpuRenderPassEncoderSetBindGroup: function (pass, slot, group, count, offs) {
				if (!count) {
					hObj(pass).setBindGroup(slot, hObj(group));
					return;
				}
				/* dynamic offsets: `offs` points at `count` u32 values in wasm
				   memory; the JS API takes a single sequence (no count arg). */
				var v = V();
				var data = new Array(count);
				for (var i = 0; i < count; i++) {
					data[i] = v.I32[(offs + i * 4) >> 2] >>> 0;
				}
				hObj(pass).setBindGroup(slot, hObj(group), data);
			},
			wgpuRenderPassEncoderSetVertexBuffer: function (pass, slot, buffer, offset, size) {
				hObj(pass).setVertexBuffer(slot, hObj(buffer), i64num(offset), whole64(size));
			},
			wgpuRenderPassEncoderSetIndexBuffer: function (pass, buffer, format, offset, size) {
				hObj(pass).setIndexBuffer(hObj(buffer), ENUM.IndexFormat[format], i64num(offset),
					whole64(size));
			},
			wgpuRenderPassEncoderSetPipeline: function (pass, pipeline) {
				hObj(pass).setPipeline(hObj(pipeline));
			},
			wgpuRenderPassEncoderSetBlendConstant: function (pass, color) {
				hObj(pass).setBlendConstant(colorAt(color));
			},
			wgpuRenderPassEncoderSetViewport: function (pass, x, y, w, h, zmin, zmax) {
				hObj(pass).setViewport(x, y, w, h, zmin, zmax);
			},
			wgpuRenderPassEncoderSetScissorRect: function (pass, x, y, w, h) {
				hObj(pass).setScissorRect(x >>> 0, y >>> 0, w >>> 0, h >>> 0);
			},
			wgpuRenderPassEncoderSetStencilReference: function (pass, ref) {
				hObj(pass).setStencilReference(ref >>> 0);
			},
			wgpuRenderPassEncoderDraw: function (pass, vc, ic, fv, fi) {
				hObj(pass).draw(vc, ic, fv, fi);
			},
			wgpuRenderPassEncoderDrawIndexed: function (pass, ic, iCount, fi, bv, fInst) {
				hObj(pass).drawIndexed(ic, iCount, fi, bv, fInst);
			},
			wgpuRenderPassEncoderEnd: function (pass) { hObj(pass).end(); },
			wgpuRenderPassEncoderRelease: function (h) { hRelease(h); },

			/* compute pass encoder */
			wgpuComputePassEncoderSetBindGroup: function (pass, slot, group, count, offs) {
				if (!count) {
					hObj(pass).setBindGroup(slot, hObj(group));
					return;
				}
				/* dynamic offsets: `offs` points at `count` u32 values in wasm
				   memory; the JS API takes a single sequence (no count arg). */
				var v = V();
				var data = new Array(count);
				for (var i = 0; i < count; i++) {
					data[i] = v.I32[(offs + i * 4) >> 2] >>> 0;
				}
				hObj(pass).setBindGroup(slot, hObj(group), data);
			},
			wgpuComputePassEncoderSetPipeline: function (pass, pipeline) {
				hObj(pass).setPipeline(hObj(pipeline));
			},
			wgpuComputePassEncoderDispatchWorkgroups: function (pass, x, y, z) {
				hObj(pass).dispatchWorkgroups(x, y, z);
			},
			wgpuComputePassEncoderEnd: function (pass) { hObj(pass).end(); },
			wgpuComputePassEncoderRelease: function (h) { hRelease(h); },

			/* ── queue ── */
			wgpuQueueSubmit: function (q, count, cmds) {
				var v = V();
				var arr = [];
				for (var i = 0; i < count; i++) {
					arr.push(hObj(v.I32[(cmds + i * 4) >> 2]));
				}
				hObj(q).submit(arr);
			},
			wgpuQueueWriteBuffer: function (q, buffer, bufferOffset, data, size) {
				var v = V();
				var n = i64num(size);
				hObj(q).writeBuffer(hObj(buffer), i64num(bufferOffset),
					v.U8.subarray(data, data + n), 0, n);
			},
			wgpuQueueWriteTexture: function (q, dest, data, dataSize, layout, size) {
				var v = V();
				var origin = dest + 8; /* WGPUOrigin3D */
				hObj(q).writeTexture(
					{
						texture: hObj(v.I32[dest >> 2]),
						mipLevel: v.I32[(dest + 4) >> 2] >>> 0,
						origin: [
							v.I32[origin >> 2] >>> 0,
							v.I32[(origin + 4) >> 2] >>> 0,
							v.I32[(origin + 8) >> 2] >>> 0
						],
						aspect: ENUM.TextureAspect[v.I32[(dest + 20) >> 2]]
					},
					v.U8.subarray(data, data + dataSize),
					{
						offset: u64raw(layout),
						bytesPerRow: (v.I32[(layout + 8) >> 2] >>> 0) === WHOLE32 ?
							undefined : v.I32[(layout + 8) >> 2] >>> 0,
						rowsPerImage: (v.I32[(layout + 12) >> 2] >>> 0) === WHOLE32 ?
							undefined : v.I32[(layout + 12) >> 2] >>> 0
					},
					{
						width: v.I32[size >> 2] >>> 0,
						height: v.I32[(size + 4) >> 2] >>> 0,
						depthOrArrayLayers: v.I32[(size + 8) >> 2] >>> 0
					});
			},
			wgpuQueueRelease: function (h) { hRelease(h); },

			/* ── texture / view ── */
			wgpuTextureCreateView: function (tex, desc) {
				var t = hObj(tex);
				var h;
				if (!desc) {
					h = hNew("texture_view", t.createView());
					H.m.get(h).format = (H.m.get(tex) || {}).format;
					return h;
				}
				var v = V();
				var mv = v.I32[(desc + 24) >> 2] >>> 0;
				var av = v.I32[(desc + 32) >> 2] >>> 0;
				var fmt = ENUM.TextureFormat[v.I32[(desc + 12) >> 2]];
				h = hNew("texture_view", t.createView({
					label: sv(desc + 4),
					format: fmt,
					dimension: ENUM.TextureViewDimension[v.I32[(desc + 16) >> 2]],
					baseMipLevel: v.I32[(desc + 20) >> 2] >>> 0,
					mipLevelCount: mv === WHOLE32 ? undefined : mv,
					baseArrayLayer: v.I32[(desc + 28) >> 2] >>> 0,
					arrayLayerCount: av === WHOLE32 ? undefined : av,
					aspect: ENUM.TextureAspect[v.I32[(desc + 36) >> 2]],
					usage: v.I32[(desc + 40) >> 2] >>> 0
				}));
				H.m.get(h).format = fmt;
				return h;
			},

			/* ── refcount (renderer-managed) ── */
			wgpuSamplerAddRef: function (h) { hAddRef(h); },
			wgpuSamplerRelease: function (h) { hRelease(h); },
			wgpuTextureAddRef: function (h) { hAddRef(h); },
			wgpuTextureRelease: function (h) { hRelease(h); },
			wgpuTextureViewRelease: function (h) { hRelease(h); },
			wgpuBindGroupRelease: function (h) { hRelease(h); },
			wgpuBindGroupLayoutRelease: function (h) { hRelease(h); },
			wgpuCommandBufferRelease: function (h) { hRelease(h); },
			wgpuComputePipelineRelease: function (h) { hRelease(h); },
			wgpuRenderPipelineRelease: function (h) { hRelease(h); },
			wgpuShaderModuleRelease: function (h) { hRelease(h); },
			wgpuPipelineLayoutRelease: function (h) { hRelease(h); }
		};
		return G;
	}

	window.__ODM_BACKEND__ = {
		name: "webgpu",
		prepare: function (cvs) {
			canvas = cvs;
			if (!window.navigator || !window.navigator.gpu) {
				return Promise.reject(new Error("WebGPU not available in this browser"));
			}
			gpuCtx = cvs.getContext("webgpu");
			if (!gpuCtx) {
				return Promise.reject(new Error("WebGPU canvas context unavailable"));
			}
			return window.navigator.gpu
				.requestAdapter({ powerPreference: "high-performance" })
				.then(function (adapter) {
					if (!adapter) {
						return Promise.reject(new Error("WebGPU: no adapter available"));
					}
					return adapter.requestDevice({ label: "wasm webgpu" });
				})
				.then(function (dev) {
					device = dev;
					/* surface the browser's validation/uncaptured errors
					   (sokol has no error-callback wiring on this path). */
					device.onuncapturederror = function (ev) {
						var msg = "WebGPU device error: " +
							(ev && ev.error ? ev.error.message : String(ev));
						console.error(msg);
					};
					queue = device.queue;
					deviceHandle = hNew("device", dev);
					queueHandle = hNew("queue", queue);
				});
		},
		/* push the device handle into the C shim before _start so the
		   app's init (inside _start) finds it via sglue_environment. */
		init: function (exports) {
			E = exports;
			E.shim_js_set_wgpu_device(deviceHandle);
		},
		imports: imports,
		/* per frame: fresh swapchain views for the C shim. The previous
		   frame's views are released first (the renderer used them
		   within that frame only; the queue submission already went
		   out in the previous tick). */
		frame: function () {
			if (!device || !gpuCtx) { return; }
			if (!ctxConfigured) {
				gpuCtx.configure({ device: device, format: "rgba8unorm", alphaMode: "opaque" });
				ctxConfigured = true;
			}
			if (prevColorH) { hRelease(prevColorH); prevColorH = 0; }
			if (prevDepthH) { hRelease(prevDepthH); prevDepthH = 0; }
			var colorH = hNew("texture_view", gpuCtx.getCurrentTexture().createView());
			var w = canvas.width, h = canvas.height;
			if (!depthTex || depthW !== w || depthH !== h) {
				if (depthTex) { depthTex.destroy(); }
				/* depth-stencil render target: the JS WebGPU usage is a
				   numeric bitmask (GPUTextureUsageBit), not a string array -
				   it must carry RENDER_ATTACHMENT (16) for the render pass
				   depth-stencil attachment (this is a swapchain target, not a
				   sampled/storage texture). */
				depthTex = device.createTexture({
					label: "wasm depth",
					size: [w, h, 1],
					format: "depth24plus",
					usage: 16 /* GPUTextureUsageBit.RENDER_ATTACHMENT */
				});
				depthW = w;
				depthH = h;
			}
			var depthH2 = hNew("texture_view", depthTex.createView());
			E.shim_js_set_swapchain(colorH, depthH2);
			prevColorH = colorH;
			prevDepthH = depthH2;
		},
		/* the context tracks the canvas size; the depth texture is
		   recreated on the next frame (canvas.width/height are already
		   set by the core when this is called). */
		resize: function () {},
		cleanup: function () {
			if (depthTex) {
				try { depthTex.destroy(); } catch (ex) { /* page teardown */ }
				depthTex = null;
			}
			device = null;
			queue = null;
			ctxConfigured = false;
			prevColorH = 0;
			prevDepthH = 0;
		}
	};
})();
