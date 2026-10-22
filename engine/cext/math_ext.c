/* C-ext math fills: the toolchain's libc-shim defines tan/exp (double) but
   not the float forms the renderer C calls; the definitions land in the
   wasm module via the apphost archive (native never links this file). */
#include <math.h>
#include "math_ext.h"

float tanf(float x) { return (float)tan(x); }
float expf(float x) { return (float)exp(x); }
double round(double x) { return x > 0.0 ? floor(x + 0.5) : ceil(x - 0.5); }
float roundf(float x) { return (float)round(x); }

double fmin(double a, double b) {
	return a < b ? a : b;
}

double fmax(double a, double b) {
	return a > b ? a : b;
}

float fminf(float a, float b) {
	return a < b ? a : b;
}

float fmaxf(float a, float b) {
	return a > b ? a : b;
}

/* Hyperbolics over the shim's exp (no libm dependency beyond it). */
double tanh(double x) {
	double e = exp(2.0 * x);
	return (e - 1.0) / (e + 1.0);
}

float tanhf(float x) {
	float e = expf(2.0f * x);
	return (e - 1.0f) / (e + 1.0f);
}

double sinh(double x) {
	double e = exp(x);
	return (e - 1.0 / e) / 2.0;
}

double cosh(double x) {
	double e = exp(x);
	return (e + 1.0 / e) / 2.0;
}
