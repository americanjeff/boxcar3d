#pragma once
/* Force-include for the ML vendor compiles (kann/cmaes/neat are old C that
   rely on implicit declarations — they call time/labs/difftime/… without
   including the matching header). Pulling the cext headers in up front
   gives the bare-wasm compiles a complete standard surface; native builds
   never compile these files. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
