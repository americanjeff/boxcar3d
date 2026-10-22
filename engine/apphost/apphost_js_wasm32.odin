package apphost

// The bare-wasm build (the odin driver's final link) resolves the
// engine C objects' libc undefineds (malloc, snprintf, tanf, ...)
// in-module: the toolchain's libc-shim defines them over the odin
// runtime. The target suffix limits this file to js_wasm32 builds — on
// native the real libc is linked and the shim's strong symbols would
// collide. (Imports cannot sit in target conditionals, hence the
// suffixed file instead of a `when` in apphost.odin.)
@(require) import _ "vendor:libc-shim"
