//! @file compiler/float_bignat.c
//! @brief Implements big natural integer arithmetic for floats for the n65 compiler.
//! @ingroup compiler

#include <stdlib.h>
#include <string.h>
#include <limits.h>

#include "messages.h"
#include "float_bignat.h"

//! @brief Handle bn init logic for compiler big-natural arithmetic.
void bn_init(BigNat *bn) {
   bn->words = NULL;
   bn->len = 0;
   bn->cap = 0;
}

//! @brief Release free storage owned by compiler big-natural arithmetic.
void bn_free(BigNat *bn) {
   if (!bn) {
      return;
   }
   free(bn->words);
   bn->words = NULL;
   bn->len = 0;
   bn->cap = 0;
}

//! @brief Handle bn normalize logic for compiler big-natural arithmetic.
static void bn_normalize(BigNat *bn) {
   while (bn->len > 0 && bn->words[bn->len - 1] == 0) {
      bn->len--;
   }
}

//! @brief Handle bn reserve logic for compiler big-natural arithmetic.
static void bn_reserve(BigNat *bn, int need) {
   int new_cap;
   uint32_t *tmp;

   if (need <= bn->cap) {
      return;
   }

   new_cap = bn->cap ? bn->cap : 1;
   while (new_cap < need) {
      if (new_cap > INT_MAX / 2) {
         error_user("[%s:%d] float literal is too large", __FILE__, __LINE__);
      }
      new_cap *= 2;
   }

   tmp = (uint32_t *) realloc(bn->words, sizeof(uint32_t) * (size_t) new_cap);
   if (!tmp) {
      error_user("[%s:%d] out of memory", __FILE__, __LINE__);
   }

   if (new_cap > bn->cap) {
      memset(tmp + bn->cap, 0, sizeof(uint32_t) * (size_t) (new_cap - bn->cap));
   }

   bn->words = tmp;
   bn->cap = new_cap;
}

//! @brief Handle bn set zero logic for compiler big-natural arithmetic.
void bn_set_zero(BigNat *bn) {
   if (!bn) {
      return;
   }
   bn->len = 0;
}

//! @brief Extract bn from 32-bit for compiler big-natural arithmetic.
void bn_from_u32(BigNat *bn, uint32_t value) {
   bn_set_zero(bn);
   if (value != 0) {
      bn_reserve(bn, 1);
      bn->words[0] = value;
      bn->len = 1;
   }
}

//! @brief Return whether bn is zero in compiler big-natural arithmetic.
bool bn_is_zero(const BigNat *bn) {
   return !bn || bn->len == 0;
}

//! @brief Handle bn copy logic for compiler big-natural arithmetic.
void bn_copy(BigNat *dst, const BigNat *src) {
   if (!dst || !src) {
      return;
   }
   bn_reserve(dst, src->len);
   if (src->len > 0) {
      memcpy(dst->words, src->words, sizeof(uint32_t) * (size_t) src->len);
   }
   if (dst->cap > src->len) {
      memset(dst->words + src->len, 0, sizeof(uint32_t) * (size_t) (dst->cap - src->len));
   }
   dst->len = src->len;
}

//! @brief Handle bn mul small logic for compiler big-natural arithmetic.
void bn_mul_small(BigNat *bn, uint32_t mul) {
   int i;
   uint64_t carry = 0;

   if (!bn || mul == 1 || bn_is_zero(bn)) {
      return;
   }
   if (mul == 0) {
      bn_set_zero(bn);
      return;
   }

   bn_reserve(bn, bn->len + 1);
   for (i = 0; i < bn->len; i++) {
      uint64_t cur = (uint64_t) bn->words[i] * mul + carry;
      bn->words[i] = (uint32_t) cur;
      carry = cur >> FLOAT_BIGNAT_WORD_BITS;
   }
   if (carry) {
      bn->words[bn->len++] = (uint32_t) carry;
   }
}

//! @brief Handle bn add small logic for compiler big-natural arithmetic.
void bn_add_small(BigNat *bn, uint32_t add) {
   int i;
   uint64_t carry;

   if (!bn || add == 0) {
      return;
   }

   if (bn_is_zero(bn)) {
      bn_from_u32(bn, add);
      return;
   }

   bn_reserve(bn, bn->len + 1);
   carry = add;
   for (i = 0; i < bn->len && carry; i++) {
      uint64_t cur = (uint64_t) bn->words[i] + carry;
      bn->words[i] = (uint32_t) cur;
      carry = cur >> FLOAT_BIGNAT_WORD_BITS;
   }
   if (carry) {
      bn->words[bn->len++] = (uint32_t) carry;
   }
}

//! @brief Handle bn mod small logic for compiler big-natural arithmetic.
uint32_t bn_mod_small(const BigNat *bn, uint32_t div) {
   int i;
   uint64_t rem = 0;

   if (!bn || div == 0) {
      error_unreachable("[%s:%d] invalid small modulus", __FILE__, __LINE__);
   }

   for (i = bn->len - 1; i >= 0; i--) {
      rem = ((rem << FLOAT_BIGNAT_WORD_BITS) | bn->words[i]) % div;
   }
   return (uint32_t) rem;
}

//! @brief Handle bn div small logic for compiler big-natural arithmetic.
uint32_t bn_div_small(BigNat *bn, uint32_t div) {
   int i;
   uint64_t rem = 0;

   if (!bn || div == 0) {
      error_unreachable("[%s:%d] invalid small division", __FILE__, __LINE__);
   }

   for (i = bn->len - 1; i >= 0; i--) {
      uint64_t cur = (rem << FLOAT_BIGNAT_WORD_BITS) | bn->words[i];
      bn->words[i] = (uint32_t) (cur / div);
      rem = cur % div;
   }
   bn_normalize(bn);
   return (uint32_t) rem;
}

//! @brief Handle bn mul pow5 logic for compiler big-natural arithmetic.
void bn_mul_pow5(BigNat *bn, long long exp) {
   long long i;
   for (i = 0; i < exp; i++) {
      bn_mul_small(bn, 5);
   }
}

//! @brief Handle bn shift left bits logic for compiler big-natural arithmetic.
void bn_shift_left_bits(BigNat *bn, long long shift) {
   int word_shift;
   int bit_shift;
   int old_len;
   int i;
   uint32_t carry = 0;

   if (!bn || shift <= 0 || bn_is_zero(bn)) {
      return;
   }
   if (shift > INT_MAX / 2) {
      error_user("[%s:%d] float literal shift is too large", __FILE__, __LINE__);
   }

   word_shift = (int) (shift / FLOAT_BIGNAT_WORD_BITS);
   bit_shift = (int) (shift % FLOAT_BIGNAT_WORD_BITS);
   old_len = bn->len;

   bn_reserve(bn, old_len + word_shift + 2);

   if (word_shift > 0) {
      memmove(bn->words + word_shift, bn->words, sizeof(uint32_t) * (size_t) old_len);
      memset(bn->words, 0, sizeof(uint32_t) * (size_t) word_shift);
      bn->len += word_shift;
   }

   if (bit_shift > 0) {
      carry = 0;
      for (i = word_shift; i < bn->len; i++) {
         uint64_t cur = ((uint64_t) bn->words[i] << bit_shift) | carry;
         bn->words[i] = (uint32_t) cur;
         carry = (uint32_t) (cur >> FLOAT_BIGNAT_WORD_BITS);
      }
      if (carry) {
         bn->words[bn->len++] = carry;
      }
   }
}

//! @brief Handle bn shift right one logic for compiler big-natural arithmetic.
void bn_shift_right_one(BigNat *bn) {
   int i;
   uint32_t carry = 0;

   if (!bn || bn_is_zero(bn)) {
      return;
   }

   for (i = bn->len - 1; i >= 0; i--) {
      uint32_t new_carry = (uint32_t) ((bn->words[i] & 1u) << (FLOAT_BIGNAT_WORD_BITS - 1));
      bn->words[i] = (bn->words[i] >> 1) | carry;
      carry = new_carry;
   }
   bn_normalize(bn);
}

//! @brief Handle bn bit length logic for compiler big-natural arithmetic.
int bn_bit_length(const BigNat *bn) {
   uint32_t top;
   int bits = 0;

   if (!bn || bn_is_zero(bn)) {
      return 0;
   }

   top = bn->words[bn->len - 1];
   while (top) {
      bits++;
      top >>= 1;
   }
   return (bn->len - 1) * FLOAT_BIGNAT_WORD_BITS + bits;
}

//! @brief Handle bn cmp logic for compiler big-natural arithmetic.
int bn_cmp(const BigNat *a, const BigNat *b) {
   int i;

   if (a->len != b->len) {
      return a->len < b->len ? -1 : 1;
   }
   for (i = a->len - 1; i >= 0; i--) {
      if (a->words[i] != b->words[i]) {
         return a->words[i] < b->words[i] ? -1 : 1;
      }
   }
   return 0;
}

//! @brief Handle bn cmp shifted logic for compiler big-natural arithmetic.
int bn_cmp_shifted(const BigNat *a, const BigNat *b, int shift_bits) {
   BigNat tmp;
   int cmp;

   bn_init(&tmp);
   bn_copy(&tmp, b);
   bn_shift_left_bits(&tmp, shift_bits);
   cmp = bn_cmp(a, &tmp);
   bn_free(&tmp);
   return cmp;
}

//! @brief Handle bn sub inplace logic for compiler big-natural arithmetic.
void bn_sub_inplace(BigNat *a, const BigNat *b) {
   int i;
   uint64_t borrow = 0;

   if (!a || !b || bn_cmp(a, b) < 0) {
      error_unreachable("[%s:%d] invalid bigint subtraction", __FILE__, __LINE__);
   }

   for (i = 0; i < a->len; i++) {
      uint64_t av = a->words[i];
      uint64_t bv = (i < b->len) ? b->words[i] : 0;
      uint64_t sub = bv + borrow;
      if (av < sub) {
         a->words[i] = (uint32_t) (((uint64_t) 1 << FLOAT_BIGNAT_WORD_BITS) + av - sub);
         borrow = 1;
      }
      else {
         a->words[i] = (uint32_t) (av - sub);
         borrow = 0;
      }
   }

   if (borrow) {
      error_unreachable("[%s:%d] bigint subtraction underflow", __FILE__, __LINE__);
   }

   bn_normalize(a);
}

//! @brief Handle bn set bit logic for compiler big-natural arithmetic.
void bn_set_bit(BigNat *bn, long long bit_index) {
   int word_index;
   int bit_in_word;

   if (!bn || bit_index < 0) {
      return;
   }
   if (bit_index > INT_MAX / 2) {
      error_user("[%s:%d] float literal is too wide", __FILE__, __LINE__);
   }

   word_index = (int) (bit_index / FLOAT_BIGNAT_WORD_BITS);
   bit_in_word = (int) (bit_index % FLOAT_BIGNAT_WORD_BITS);
   bn_reserve(bn, word_index + 1);
   if (word_index >= bn->len) {
      memset(bn->words + bn->len, 0, sizeof(uint32_t) * (size_t) (word_index + 1 - bn->len));
      bn->len = word_index + 1;
   }
   bn->words[word_index] |= (uint32_t) (1u << bit_in_word);
}

//! @brief Handle bn test bit logic for compiler big-natural arithmetic.
int bn_test_bit(const BigNat *bn, int bit_index) {
   int word_index;
   int bit_in_word;

   if (!bn || bit_index < 0) {
      return 0;
   }

   word_index = bit_index / FLOAT_BIGNAT_WORD_BITS;
   bit_in_word = bit_index % FLOAT_BIGNAT_WORD_BITS;
   if (word_index >= bn->len) {
      return 0;
   }
   return (int) ((bn->words[word_index] >> bit_in_word) & 1u);
}

//! @brief Handle bn divmod logic for compiler big-natural arithmetic.
void bn_divmod(const BigNat *numerator, const BigNat *denominator, BigNat *quotient, BigNat *remainder) {
   BigNat shifted;
   int shift;
   int i;

   if (!numerator || !denominator || !quotient || !remainder || bn_is_zero(denominator)) {
      error_unreachable("[%s:%d] invalid bigint division", __FILE__, __LINE__);
   }

   bn_set_zero(quotient);
   bn_copy(remainder, numerator);
   if (bn_cmp(remainder, denominator) < 0) {
      return;
   }

   shift = bn_bit_length(remainder) - bn_bit_length(denominator);
   bn_init(&shifted);
   bn_copy(&shifted, denominator);
   bn_shift_left_bits(&shifted, shift);

   for (i = shift; i >= 0; i--) {
      if (bn_cmp(remainder, &shifted) >= 0) {
         bn_sub_inplace(remainder, &shifted);
         bn_set_bit(quotient, i);
      }
      bn_shift_right_one(&shifted);
   }

   bn_free(&shifted);
}

//! @brief Return whether bn is odd in compiler big-natural arithmetic.
bool bn_is_odd(const BigNat *bn) {
   return bn && bn->len > 0 && (bn->words[0] & 1u);
}

//! @brief Handle bn round ratio shift logic for compiler big-natural arithmetic.
void bn_round_ratio_shift(BigNat *out, const BigNat *numerator, const BigNat *denominator, long long shift) {
   BigNat num;
   BigNat den;
   BigNat rem;
   BigNat twice;
   int cmp;

   bn_init(&num);
   bn_init(&den);
   bn_init(&rem);
   bn_init(&twice);

   bn_copy(&num, numerator);
   bn_copy(&den, denominator);
   if (shift > 0) {
      bn_shift_left_bits(&num, shift);
   }
   else if (shift < 0) {
      bn_shift_left_bits(&den, -shift);
   }

   bn_divmod(&num, &den, out, &rem);

   bn_copy(&twice, &rem);
   bn_shift_left_bits(&twice, 1);
   cmp = bn_cmp(&twice, &den);
   if (cmp > 0 || (cmp == 0 && bn_is_odd(out))) {
      bn_add_small(out, 1);
   }

   bn_free(&num);
   bn_free(&den);
   bn_free(&rem);
   bn_free(&twice);
}
