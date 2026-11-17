//! @file host_stdio.h
//! @brief Select C99 stdio formats consistently for native and MinGW host tools.

#ifndef VCSC_HOST_STDIO_H
#define VCSC_HOST_STDIO_H

/* Older MinGW defaults to MSVCRT printf, which does not support the C99 z
 * length modifier. Select the compatible implementation before ANY system
 * header, including inttypes.h, can choose its format macros/declarations.
 * Host tools require C99 formatting even when the toolchain defaults to 0. */
#ifdef __MINGW32__
#undef __USE_MINGW_ANSI_STDIO
#define __USE_MINGW_ANSI_STDIO 1
#endif

#include <stdio.h>

/* GCC PR95130 (fixed in GCC 14): built-in format checking on the standard
 * printf names can ignore their explicit gnu_printf attributes. MinGW 13
 * exposes this with its extern/asm redirects instead of inline wrappers.
 * Name the same C99 implementations directly to retain correct checking and
 * runtime formatting on older GCC. Do not suppress -Wformat. */
#if defined(__MINGW32__) && defined(__GNUC__) && __GNUC__ < 14 && !defined(__clang__)
#undef printf
#undef fprintf
#undef sprintf
#undef snprintf
#undef vprintf
#undef vfprintf
#undef vsprintf
#undef vsnprintf
#define printf __mingw_printf
#define fprintf __mingw_fprintf
#define sprintf __mingw_sprintf
#define snprintf __mingw_snprintf
#define vprintf __mingw_vprintf
#define vfprintf __mingw_vfprintf
#define vsprintf __mingw_vsprintf
#define vsnprintf __mingw_vsnprintf
#endif

#endif
