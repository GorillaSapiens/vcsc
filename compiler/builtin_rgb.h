//! @file compiler/builtin_rgb.h
//! @brief Declares reusable compile-time RGB palette matching helpers.
//! @ingroup compiler

#ifndef _INCLUDE_BUILTIN_RGB_H_
#define _INCLUDE_BUILTIN_RGB_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

//! One hardware color value and its reference RGB rendering.
typedef struct BuiltinRgbColor {
   uint8_t value;
   uint8_t r;
   uint8_t g;
   uint8_t b;
} BuiltinRgbColor;

//! Find the nearest palette entry by squared RGB distance; lower values win ties.
bool builtin_rgb_nearest(const BuiltinRgbColor *palette, size_t count,
                         long long r, long long g, long long b,
                         long long *value_out);

//! Evaluate __builtin_ntsc_rgb after generic constant-argument validation.
bool builtin_ntsc_rgb_eval(long long r, long long g, long long b,
                           long long *value_out);

//! Evaluate __builtin_pal_rgb after generic constant-argument validation.
bool builtin_pal_rgb_eval(long long r, long long g, long long b,
                          long long *value_out);

//! Evaluate __builtin_secam_rgb after generic constant-argument validation.
bool builtin_secam_rgb_eval(long long r, long long g, long long b,
                            long long *value_out);

#endif // _INCLUDE_BUILTIN_RGB_H_
