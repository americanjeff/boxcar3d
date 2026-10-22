#pragma once
/* Declaration the toolchain's libc-shim lacks (time.h has time/clock but
   not localtime/asctime). Demo-logging only on the web target — the stubs
   in time_ext.c return a fixed stamp. */
#include_next <time.h>
#ifndef CLOCKS_PER_SEC
#define CLOCKS_PER_SEC 1000000
#endif
char *ctime(const time_t *timer);
time_t time(time_t *t);
double difftime(time_t stop, time_t start);
struct tm;
struct tm *localtime(const time_t *timer);
char *asctime(const struct tm *timeptr);
