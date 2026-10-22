/* C-ext time fills: see time.h. cmaes's demo main logs timestamps; the
   web build never runs the demo — a fixed stamp is fine. */
#include <time.h>
#include <string.h>
#include "time_ext.h"

struct tm {
	int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year,
	tm_wday, tm_yday, tm_isdst;
};

static struct tm g_tm;
static char g_stamp[64];

time_t time(time_t *t) {
	(void)t;
	return 0;
}

double difftime(time_t stop, time_t start) {
	(void)stop; (void)start;
	return 0.0;
}

char *ctime(const time_t *timer) {
	(void)timer;
	memcpy(g_stamp, "Thu Jan  1 00:00:00 1970\n", sizeof("Thu Jan  1 00:00:00 1970\n"));
	return g_stamp;
}

struct tm *localtime(const time_t *timer) {
	(void)timer;
	memset(&g_tm, 0, sizeof(g_tm));
	return &g_tm;
}

char *asctime(const struct tm *timeptr) {
	(void)timeptr;
	memcpy(g_stamp, "Thu Jan  1 00:00:00 1970\n", sizeof("Thu Jan  1 00:00:00 1970\n"));
	return g_stamp;
}
