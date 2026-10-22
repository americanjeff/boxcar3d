#pragma once
/* Declarations the toolchain's libc-shim math.h lacks; see math_ext.c. */
float tanf(float);
float expf(float);
float roundf(float);
double round(double);
double fmin(double a, double b);
double fmax(double a, double b);
float fminf(float a, float b);
float fmaxf(float a, float b);
double tanh(double x);
float tanhf(float x);
double sinh(double x);
double cosh(double x);
