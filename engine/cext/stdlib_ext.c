/* C-ext stdlib fills: the toolchain's libc-shim defines malloc/realloc but
   not calloc; the definition lands in the wasm module via the apphost
   archive (native never links this file). */
#include <stdlib.h>
#include <string.h>
#include "stdlib_ext.h"

void* calloc(unsigned long nmemb, unsigned long size) {
	void* p = malloc(nmemb * size);
	if (p) {
		memset(p, 0, nmemb * size);
	}
	return p;
}

long labs(long v) {
	return v < 0 ? -v : v;
}
