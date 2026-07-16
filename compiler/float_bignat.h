//! @file compiler/float_bignat.h
//! @brief Declares big natural integer arithmetic for floats for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_FLOAT_BIGNAT_H_
#define _INCLUDE_FLOAT_BIGNAT_H_

#include <stdbool.h>
#include <stdint.h>

//! Number of bits stored in each BigNat word.
#define FLOAT_BIGNAT_WORD_BITS 32

//! Heap-backed unsigned big integer used during exact float literal conversion.
typedef struct BigNat {
   uint32_t *words;
   int len;
   int cap;
} BigNat;

void bn_init(BigNat *bn);
void bn_free(BigNat *bn);
void bn_set_zero(BigNat *bn);
void bn_from_u32(BigNat *bn, uint32_t value);
bool bn_is_zero(const BigNat *bn);
void bn_copy(BigNat *dst, const BigNat *src);
void bn_mul_small(BigNat *bn, uint32_t mul);
void bn_add_small(BigNat *bn, uint32_t add);
uint32_t bn_mod_small(const BigNat *bn, uint32_t div);
uint32_t bn_div_small(BigNat *bn, uint32_t div);
void bn_mul_pow5(BigNat *bn, long long exp);
void bn_shift_left_bits(BigNat *bn, long long shift);
void bn_shift_right_one(BigNat *bn);
int bn_bit_length(const BigNat *bn);
int bn_cmp(const BigNat *a, const BigNat *b);
int bn_cmp_shifted(const BigNat *a, const BigNat *b, int shift_bits);
void bn_sub_inplace(BigNat *a, const BigNat *b);
void bn_set_bit(BigNat *bn, long long bit_index);
int bn_test_bit(const BigNat *bn, int bit_index);
void bn_divmod(const BigNat *numerator, const BigNat *denominator, BigNat *quotient, BigNat *remainder);
bool bn_is_odd(const BigNat *bn);
void bn_round_ratio_shift(BigNat *out, const BigNat *numerator, const BigNat *denominator, long long shift);

#endif
