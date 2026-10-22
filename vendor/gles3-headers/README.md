# gles3-headers

Khronos OpenGL ES 3.0 API headers (`GLES3/gl3.h`, `GLES3/gl3platform.h`,
`KHR/khrplatform.h`), the minimum set the renderer's GLES3 backend needs
on wasm (sokol's platform branches match none, so the build force-includes
`GLES3/gl3.h`).
