/* C-ext stdio fills: the toolchain's libc-shim defines vfprintf (and the
   inline printf/fprintf/snprintf over it) but not fputs; sokol_log's LINUX
   branch calls it. The definition lands in the wasm module via the apphost
   archive (native never links this file). */
#include <stdio.h>
#include <string.h>
#include "stdio_ext.h"

int fputc(int c, FILE* f) {
	unsigned char ch = (unsigned char)c;
	size_t w = fwrite(&ch, 1, 1, f);
	return (w == 1) ? c : EOF;
}

int fputs(const char* s, FILE* f) {
	size_t n = strlen(s);
	size_t w = fwrite(s, 1, n, f);
	return (w == n) ? (int)n : -1;
}

char *fgets(char *s, int size, FILE *stream) {
	(void)s; (void)size; (void)stream;
	return NULL; /* EOF: no file input on the web target */
}

int fflush(FILE *stream) {
	(void)stream;
	return 0;
}

void rewind(FILE *stream) {
	(void)stream;
}
