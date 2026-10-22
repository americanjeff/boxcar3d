#pragma once
/* clang 23's <float.h> (pulled in ahead of <math.h> by box3d's headers)
   already defines INFINITY/NAN; drop them so the libc-shim's definitions
   below don't redeclare them with different replacement lists. */
#undef INFINITY
#undef NAN
#include_next <math.h>
#include "math_ext.h"
