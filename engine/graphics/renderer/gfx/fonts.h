// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

#pragma once

#ifdef __cplusplus
extern "C"
{
#endif

// TTF bytes, valid for the life of the program. Covers printable ASCII, which
// is all the apps emit. Anything outside that draws as '?'.
const unsigned char* GetFontBytes( int* outSize );

// Short name for logs.
const char* GetFontName( void );

#ifdef __cplusplus
} // extern "C"
#endif
