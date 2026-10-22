#pragma once
/* Minimal syslog.h for the bare-wasm target: the toolchain's libc-shim has
   no syslog; sokol_log's LINUX branch includes it unconditionally. The
   app overrides sokol's logger, so the stub is never called (see the
   comment in math_ext.c for how the definition reaches the module). */
#define LOG_EMERG 0
#define LOG_ALERT 1
#define LOG_CRIT  2
#define LOG_ERR   3
#define LOG_WARNING 4
#define LOG_NOTICE 5
#define LOG_INFO  6
#define LOG_DEBUG 7

void syslog(int priority, const char* format, ...);
