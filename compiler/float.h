//! @file compiler/float.h
//! @brief Declares floating-point literal conversion for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_FLOAT_H_
#define _INCLUDE_FLOAT_H_

#include <stdbool.h>

// convert a string to float
// 'p' may be hex (0x*) or decimal
// returns 0 on success for packers below

double parse_float(const char *p);

// true if 'style' names a supported float packing style.
bool float_style_is_known(const char *style);

// exponent-bit count for the given style and storage size in bytes.
// returns -1 if that style does not support that size.
int float_style_expbits_for_size(const char *style, int size);

// convert the string 'p' to a 'size' little-endian float at 'target'
// using the requested style.
int make_le_float_style(const char *p, unsigned char *target, int size, const char *style);

// negate the 'size' little-endian float at 'target'
void negate_le_float(unsigned char *target, int size);

// convert the string 'p' to a 'size' big-endian float at 'target'
// using the requested style.
int make_be_float_style(const char *p, unsigned char *target, int size, const char *style);

// negate the 'size' big-endian float at 'target'
void negate_be_float(unsigned char *target, int size);

#endif
