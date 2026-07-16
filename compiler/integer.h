//! @file compiler/integer.h
//! @brief Declares integer literal conversion for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_INTEGER_H_
#define _INCLUDE_INTEGER_H_

// convert a string to integer
long long parse_int(const char *p);

// NOTE:
// 'p' may be binary (0b*), octal(0*), hex (0x*), or decimal
// returns 'size' on success

// convert the string 'p' to a 'size' little endian int at 'target'
// see NOTE above
int make_le_int(const char *p, unsigned char *target, int size);

// take the 2s complement of the 'size' little endian int at 'target'
void negate_le_int(unsigned char *target, int size);

// convert the string 'p' to a 'size' big endian int at 'target'
// see NOTE above
int make_be_int(const char *p, unsigned char *target, int size);

// take the 2s complement of the 'size' big endian int at 'target'
void negate_be_int(unsigned char *target, int size);

#endif
