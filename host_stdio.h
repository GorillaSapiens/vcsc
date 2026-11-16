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

#endif
