/* C-ext syslog stub: see syslog.h for why. No-op — sokol's logger is
   overridden by the apphost shim on every target, so this never runs. */
#include <syslog.h>

void syslog(int priority, const char* format, ...) {
	(void)priority;
	(void)format;
}
