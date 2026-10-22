#pragma once
/* Declaration the toolchain's libc-shim stdlib.h lacks; see stdlib_ext.c. */
void* calloc(unsigned long nmemb, unsigned long size);
long labs(long v);
#ifndef EXIT_SUCCESS
#define EXIT_SUCCESS 0
#endif
#ifndef EXIT_FAILURE
#define EXIT_FAILURE 1
#endif
