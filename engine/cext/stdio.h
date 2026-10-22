#pragma once
/* Declaration the toolchain's libc-shim stdio.h lacks; see stdio_ext.c. */
#include_next <stdio.h>
/* the shim defines stdout/stderr but not stdin */
#ifndef stdin
#define stdin ((FILE *)1)
#endif
int fputc(int c, FILE *f);
int fputs(const char *s, FILE *f);
/* file-loading APIs: the shim's FILE is opaque and the web build never
   reads model files (the app embeds its weights), so these stub in
   stdio_ext.c fail immediately (EOF / no-op) rather than read. */
char *fgets(char *s, int size, FILE *stream);
/* fscanf: declaration only. The definition comes from the box3d prebuilt
   (wasm_compat.c ships a real one); defining it here would duplicate. */
int fscanf(FILE *stream, const char *format, ...);
int fflush(FILE *stream);
void rewind(FILE *stream);
