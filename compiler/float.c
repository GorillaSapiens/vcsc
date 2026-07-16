//! @file compiler/float.c
//! @brief Implements floating-point literal conversion for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>
#include <limits.h>
#include <ctype.h>

#include "messages.h"
#include "xray.h"
#include "float.h"
#include "float_bignat.h"

static_assert(sizeof(double) == 8);


typedef enum FloatSpecialKind {
   FLOAT_SPECIAL_FINITE,
   FLOAT_SPECIAL_INF,
   FLOAT_SPECIAL_NAN,
} FloatSpecialKind;

typedef struct ParsedFloatValue {
   FloatSpecialKind special;
   bool negative;
   BigNat sig;
   long long exp2;
   long long exp5;
} ParsedFloatValue;

//! @brief Handle parsed float init logic for compiler floating-point constants.
static void parsed_float_init(ParsedFloatValue *value) {
   value->special = FLOAT_SPECIAL_FINITE;
   value->negative = false;
   bn_init(&value->sig);
   value->exp2 = 0;
   value->exp5 = 0;
}

//! @brief Release float free storage owned by compiler floating-point constants.
static void parsed_float_free(ParsedFloatValue *value) {
   if (!value) {
      return;
   }
   bn_free(&value->sig);
}

//! @brief Handle string ieq logic for compiler floating-point constants.
static bool string_ieq(const char *a, const char *b) {
   while (*a && *b) {
      if (tolower((unsigned char) *a) != tolower((unsigned char) *b)) {
         return false;
      }
      a++;
      b++;
   }
   return *a == '\0' && *b == '\0';
}

//! @brief Handle hex digit value logic for compiler floating-point constants.
static int hex_digit_value(char c) {
   if (c >= '0' && c <= '9') {
      return c - '0';
   }
   if (c >= 'a' && c <= 'f') {
      return 10 + c - 'a';
   }
   if (c >= 'A' && c <= 'F') {
      return 10 + c - 'A';
   }
   return -1;
}

//! @brief Parse signed decimal text into the normalized representation used by compiler floating-point constants.
static long long parse_signed_decimal_text(const char *text) {
   bool negative = false;
   unsigned long long value = 0;
   bool any_digit = false;
   const char *p = text;

   if (*p == '+' || *p == '-') {
      negative = (*p == '-');
      p++;
   }

   while (*p) {
      unsigned digit;
      if (*p == '_') {
         p++;
         continue;
      }
      if (*p < '0' || *p > '9') {
         error_user("[%s:%d] invalid float exponent '%s'", __FILE__, __LINE__, text);
      }
      digit = (unsigned) (*p - '0');
      any_digit = true;
      if (value > (ULLONG_MAX - digit) / 10ULL) {
         error_user("[%s:%d] float exponent '%s' is too large", __FILE__, __LINE__, text);
      }
      value = value * 10ULL + digit;
      p++;
   }

   if (!any_digit) {
      error_user("[%s:%d] missing float exponent digits", __FILE__, __LINE__);
   }

   if (negative) {
      if (value > (unsigned long long) LLONG_MAX + 1ULL) {
         error_user("[%s:%d] float exponent '%s' is too small", __FILE__, __LINE__, text);
      }
      if (value == (unsigned long long) LLONG_MAX + 1ULL) {
         return LLONG_MIN;
      }
      return -(long long) value;
   }

   if (value > (unsigned long long) LLONG_MAX) {
      error_user("[%s:%d] float exponent '%s' is too large", __FILE__, __LINE__, text);
   }
   return (long long) value;
}

//! @brief Compute parsed float and update compiler floating-point constants state once prerequisite pass data is available.
static void normalize_parsed_float(ParsedFloatValue *value) {
   if (!value || value->special != FLOAT_SPECIAL_FINITE || bn_is_zero(&value->sig)) {
      return;
   }

   while (!bn_is_zero(&value->sig) && (value->sig.words[0] & 1u) == 0) {
      bn_div_small(&value->sig, 2);
      value->exp2++;
   }

   while (!bn_is_zero(&value->sig) && bn_mod_small(&value->sig, 5) == 0) {
      bn_div_small(&value->sig, 5);
      value->exp5++;
   }
}

//! @brief Parse decimal float literal into the normalized representation used by compiler floating-point constants.
static void parse_decimal_float_literal(const char *text, ParsedFloatValue *value) {
   const char *exp_mark = strchr(text, 'e');
   const char *exp_mark_upper = strchr(text, 'E');
   const char *exp_ptr = exp_mark;
   const char *p = text;
   long long frac_digits = 0;
   long long exp10 = 0;
   bool seen_digit = false;
   bool after_dot = false;

   if (!exp_ptr || (exp_mark_upper && exp_mark_upper < exp_ptr)) {
      exp_ptr = exp_mark_upper;
   }

   while (*p && p != exp_ptr) {
      if (*p == '_') {
         p++;
         continue;
      }
      if (*p == '.') {
         if (after_dot) {
            error_user("[%s:%d] malformed float literal '%s'", __FILE__, __LINE__, text);
         }
         after_dot = true;
         p++;
         continue;
      }
      if (*p < '0' || *p > '9') {
         error_user("[%s:%d] malformed float literal '%s'", __FILE__, __LINE__, text);
      }
      bn_mul_small(&value->sig, 10);
      bn_add_small(&value->sig, (uint32_t) (*p - '0'));
      seen_digit = true;
      if (after_dot) {
         frac_digits++;
      }
      p++;
   }

   if (!seen_digit) {
      error_user("[%s:%d] malformed float literal '%s'", __FILE__, __LINE__, text);
   }

   if (exp_ptr) {
      exp10 = parse_signed_decimal_text(exp_ptr + 1);
   }

   value->exp2 = exp10 - frac_digits;
   value->exp5 = exp10 - frac_digits;
}

//! @brief Parse hex float literal into the normalized representation used by compiler floating-point constants.
static void parse_hex_float_literal(const char *text, ParsedFloatValue *value) {
   const char *p = text;
   const char *exp_ptr;
   long long frac_nibbles = 0;
   long long exp2 = 0;
   bool seen_digit = false;
   bool after_dot = false;

   if (!(p[0] == '0' && (p[1] == 'x' || p[1] == 'X'))) {
      error_user("[%s:%d] malformed hex float literal '%s'", __FILE__, __LINE__, text);
   }
   p += 2;

   exp_ptr = strchr(p, 'p');
   if (!exp_ptr) {
      exp_ptr = strchr(p, 'P');
   }
   if (!exp_ptr) {
      error_user("[%s:%d] malformed hex float literal '%s'", __FILE__, __LINE__, text);
   }

   while (*p && p != exp_ptr) {
      int digit;
      if (*p == '_') {
         p++;
         continue;
      }
      if (*p == '.') {
         if (after_dot) {
            error_user("[%s:%d] malformed hex float literal '%s'", __FILE__, __LINE__, text);
         }
         after_dot = true;
         p++;
         continue;
      }
      digit = hex_digit_value(*p);
      if (digit < 0) {
         error_user("[%s:%d] malformed hex float literal '%s'", __FILE__, __LINE__, text);
      }
      bn_mul_small(&value->sig, 16);
      bn_add_small(&value->sig, (uint32_t) digit);
      seen_digit = true;
      if (after_dot) {
         frac_nibbles++;
      }
      p++;
   }

   if (!seen_digit) {
      error_user("[%s:%d] malformed hex float literal '%s'", __FILE__, __LINE__, text);
   }

   exp2 = parse_signed_decimal_text(exp_ptr + 1);
   value->exp2 = exp2 - 4 * frac_nibbles;
   value->exp5 = 0;
}

//! @brief Parse float literal into the normalized representation used by compiler floating-point constants.
static void parse_float_literal(const char *text, ParsedFloatValue *value) {
   const char *p = text;

   parsed_float_init(value);

   if (*p == '+' || *p == '-') {
      value->negative = (*p == '-');
      p++;
   }

   if (string_ieq(p, "inf") || string_ieq(p, "infinity")) {
      value->special = FLOAT_SPECIAL_INF;
      return;
   }
   if (!strncasecmp(p, "nan", 3)) {
      value->special = FLOAT_SPECIAL_NAN;
      return;
   }

   if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
      parse_hex_float_literal(p, value);
   }
   else {
      parse_decimal_float_literal(p, value);
   }

   if (bn_is_zero(&value->sig)) {
      value->exp2 = 0;
      value->exp5 = 0;
      return;
   }

   normalize_parsed_float(value);
}

//! @brief Handle set little-endian bit logic for compiler floating-point constants.
static void set_le_bit(unsigned char *target, int bit_index, int bit_value) {
   int byte_index;
   int bit_in_byte;

   if (!target || bit_index < 0) {
      return;
   }

   byte_index = bit_index / 8;
   bit_in_byte = bit_index % 8;
   if (bit_value) {
      target[byte_index] |= (unsigned char) (1u << bit_in_byte);
   }
   else {
      target[byte_index] &= (unsigned char) ~(1u << bit_in_byte);
   }
}

//! @brief Handle set little-endian bits u64 logic for compiler floating-point constants.
static void set_le_bits_u64(unsigned char *target, int start_bit, int bit_count, uint64_t value) {
   int i;

   if (!target || bit_count <= 0) {
      return;
   }

   for (i = 0; i < bit_count; i++) {
      set_le_bit(target, start_bit + i, (int) ((value >> i) & 1ULL));
   }
}

//! @brief Handle set little-endian bits all ones logic for compiler floating-point constants.
static void set_le_bits_all_ones(unsigned char *target, int start_bit, int bit_count) {
   int i;

   if (!target || bit_count <= 0) {
      return;
   }

   for (i = 0; i < bit_count; i++) {
      set_le_bit(target, start_bit + i, 1);
   }
}

//! @brief Extract set little-endian bits from bignat for compiler floating-point constants.
static void set_le_bits_from_bignat(unsigned char *target, int start_bit, int bit_count, const BigNat *value) {
   int i;

   if (!target || bit_count <= 0 || !value) {
      return;
   }

   for (i = 0; i < bit_count; i++) {
      if (bn_test_bit(value, i)) {
         set_le_bit(target, start_bit + i, 1);
      }
   }
}

//! @brief Handle increment little-endian field logic for compiler floating-point constants.
static void increment_le_field(unsigned char *target, int start_bit, int bit_count) {
   int i;
   for (i = 0; i < bit_count; i++) {
      int bit_index = start_bit + i;
      int byte_index = bit_index / 8;
      int bit_in_byte = bit_index % 8;
      int current = (target[byte_index] >> bit_in_byte) & 1;
      if (!current) {
         target[byte_index] |= (unsigned char) (1u << bit_in_byte);
         return;
      }
      target[byte_index] &= (unsigned char) ~(1u << bit_in_byte);
   }
}

//! @brief Handle decrement little-endian field logic for compiler floating-point constants.
static void decrement_le_field(unsigned char *target, int start_bit, int bit_count) {
   int i;
   for (i = 0; i < bit_count; i++) {
      int bit_index = start_bit + i;
      int byte_index = bit_index / 8;
      int bit_in_byte = bit_index % 8;
      int current = (target[byte_index] >> bit_in_byte) & 1;
      if (current) {
         target[byte_index] &= (unsigned char) ~(1u << bit_in_byte);
         return;
      }
      target[byte_index] |= (unsigned char) (1u << bit_in_byte);
   }
}

//! @brief Handle set little-endian exponent bias plus e logic for compiler floating-point constants.
static void set_le_exponent_bias_plus_e(unsigned char *target, int start_bit, int expbits, long long e) {
   int i;

   if (!target || expbits <= 0) {
      return;
   }

   for (i = 0; i < expbits - 1; i++) {
      set_le_bit(target, start_bit + i, 1);
   }
   set_le_bit(target, start_bit + expbits - 1, 0);

   if (e >= 0) {
      for (i = 0; i < e; i++) {
         increment_le_field(target, start_bit, expbits);
      }
   }
   else {
      for (i = 0; i < -e; i++) {
         decrement_le_field(target, start_bit, expbits);
      }
   }
}

//! @brief Handle reverse bytes logic for compiler floating-point constants.
static void reverse_bytes(unsigned char *target, int size) {
   int i;

   if (!target || size <= 1) {
      return;
   }

   for (i = 0; i < size / 2; i++) {
      unsigned char tmp = target[i];
      target[i] = target[size - 1 - i];
      target[size - 1 - i] = tmp;
   }
}

//! @brief Handle floor log2 ratio logic for compiler floating-point constants.
static long long floor_log2_ratio(const BigNat *numerator, const BigNat *denominator) {
   long long q = (long long) bn_bit_length(numerator) - (long long) bn_bit_length(denominator);

   if (q >= 0) {
      return bn_cmp_shifted(numerator, denominator, (int) q) < 0 ? q - 1 : q;
   }

   return bn_cmp_shifted(denominator, numerator, (int) (-q)) > 0 ? q - 1 : q;
}

//! @brief Handle encode special value logic for compiler floating-point constants.
static void encode_special_value(unsigned char *target, int mbits, int expbits, bool negative, FloatSpecialKind special) {
   if (negative) {
      set_le_bit(target, mbits + expbits, 1);
   }
   set_le_bits_all_ones(target, mbits, expbits);
   if (special == FLOAT_SPECIAL_NAN && mbits > 0) {
      set_le_bit(target, 0, 1);
   }
}

//! @brief Extract make little-endian float layout from parsed for compiler floating-point constants.
static int make_le_float_layout_from_parsed(const ParsedFloatValue *value, unsigned char *target, int size, int expbits) {
   int total_bits;
   int mbits;
   BigNat numerator;
   BigNat denominator;
   long long ratio_exp;
   long long e;

   if (!target) {
      return -1;
   }

   total_bits = size * 8;
   if (size <= 0 || expbits <= 0 || 1 + expbits >= total_bits) {
      error_unreachable("[%s:%d] invalid float layout size=%d expbits=%d", __FILE__, __LINE__, size, expbits);
   }

   mbits = total_bits - 1 - expbits;
   memset(target, 0, (size_t) size);

   if (!value) {
      return -1;
   }

   if (value->special != FLOAT_SPECIAL_FINITE) {
      encode_special_value(target, mbits, expbits, value->negative, value->special);
      return 0;
   }

   if (bn_is_zero(&value->sig)) {
      if (value->negative) {
         set_le_bit(target, total_bits - 1, 1);
      }
      return 0;
   }

   bn_init(&numerator);
   bn_init(&denominator);
   bn_copy(&numerator, &value->sig);
   bn_from_u32(&denominator, 1);

   if (value->exp5 > 0) {
      bn_mul_pow5(&numerator, value->exp5);
   }
   else if (value->exp5 < 0) {
      bn_mul_pow5(&denominator, -value->exp5);
   }

   ratio_exp = floor_log2_ratio(&numerator, &denominator);
   e = ratio_exp + value->exp2;

   if (expbits <= 63) {
      uint64_t bias = (1ULL << (expbits - 1)) - 1ULL;
      long long min_normal_e = 1 - (long long) bias;
      long long max_normal_e = (long long) bias;

      if (e > max_normal_e) {
         encode_special_value(target, mbits, expbits, value->negative, FLOAT_SPECIAL_INF);
         bn_free(&numerator);
         bn_free(&denominator);
         return 0;
      }

      if (e >= min_normal_e) {
         BigNat rounded;
         long long shift = (long long) mbits - ratio_exp;
         uint64_t raw_exp = (uint64_t) ((long long) bias + e);

         bn_init(&rounded);
         bn_round_ratio_shift(&rounded, &numerator, &denominator, shift);
         if (bn_bit_length(&rounded) > mbits + 1) {
            bn_shift_right_one(&rounded);
            e++;
            if (e > max_normal_e) {
               bn_free(&rounded);
               encode_special_value(target, mbits, expbits, value->negative, FLOAT_SPECIAL_INF);
               bn_free(&numerator);
               bn_free(&denominator);
               return 0;
            }
            raw_exp = (uint64_t) ((long long) bias + e);
         }

         set_le_bits_u64(target, mbits, expbits, raw_exp);
         set_le_bits_from_bignat(target, 0, mbits, &rounded);
         if (value->negative) {
            set_le_bit(target, total_bits - 1, 1);
         }
         bn_free(&rounded);
         bn_free(&numerator);
         bn_free(&denominator);
         return 0;
      }
      else {
         BigNat rounded;
         long long shift = value->exp2 + mbits + (long long) bias - 1;

         bn_init(&rounded);
         bn_round_ratio_shift(&rounded, &numerator, &denominator, shift);

         if (bn_is_zero(&rounded)) {
            if (value->negative) {
               set_le_bit(target, total_bits - 1, 1);
            }
            bn_free(&rounded);
            bn_free(&numerator);
            bn_free(&denominator);
            return 0;
         }

         if (bn_bit_length(&rounded) > mbits) {
            set_le_bits_u64(target, mbits, expbits, 1);
         }
         else {
            set_le_bits_from_bignat(target, 0, mbits, &rounded);
         }

         if (value->negative) {
            set_le_bit(target, total_bits - 1, 1);
         }

         bn_free(&rounded);
         bn_free(&numerator);
         bn_free(&denominator);
         return 0;
      }
   }
   else {
      BigNat rounded;
      long long shift = (long long) mbits - ratio_exp;

      bn_init(&rounded);
      bn_round_ratio_shift(&rounded, &numerator, &denominator, shift);
      if (bn_bit_length(&rounded) > mbits + 1) {
         bn_shift_right_one(&rounded);
         e++;
      }

      set_le_exponent_bias_plus_e(target, mbits, expbits, e);
      set_le_bits_from_bignat(target, 0, mbits, &rounded);
      if (value->negative) {
         set_le_bit(target, total_bits - 1, 1);
      }

      bn_free(&rounded);
      bn_free(&numerator);
      bn_free(&denominator);
      return 0;
   }
}

//! @brief Parse float into the normalized representation used by compiler floating-point constants.
double parse_float(const char *p) {
   ParsedFloatValue value;
   unsigned char bytes[8];
   uint64_t bits = 0;
   double ret;
   int i;

   parse_float_literal(p, &value);
   make_le_float_layout_from_parsed(&value, bytes, 8, 11);
   for (i = 0; i < 8; i++) {
      bits |= (uint64_t) bytes[i] << (8 * i);
   }
   memcpy(&ret, &bits, sizeof(ret));
   parsed_float_free(&value);
   return ret;
}

//! @brief Handle ieee754 float expbits for size logic for compiler floating-point constants.
static int ieee754_float_expbits_for_size(int size) {
   switch (size) {
      case 2: return 5;
      case 4: return 8;
      case 8: return 11;
      default:
         return -1;
   }
}

//! @brief Handle simple float expbits for size logic for compiler floating-point constants.
static int simple_float_expbits_for_size(int size) {
   int total_bits;
   int expbits;
   double raw;

   if (size <= 0) {
      return -1;
   }

   total_bits = size * 8;
   raw = 3.0 * (log((double) size) / log(2.0)) + 2.0;
   expbits = (int) floor(raw + 0.5);
   if (expbits < 1) {
      expbits = 1;
   }
   if (1 + expbits >= total_bits) {
      expbits = total_bits - 2;
   }
   return expbits > 0 ? expbits : -1;
}

//! @brief Handle pack little-endian float layout logic for compiler floating-point constants.
static int pack_le_float_layout(const char *p, unsigned char *target, int size, int expbits) {
   ParsedFloatValue value;
   int ret;

   parse_float_literal(p, &value);
   ret = make_le_float_layout_from_parsed(&value, target, size, expbits);
   parsed_float_free(&value);
   return ret;
}

//! @brief Handle pack little-endian ieee754 float logic for compiler floating-point constants.
static int pack_le_ieee754_float(const char *p, unsigned char *target, int size) {
   int expbits = ieee754_float_expbits_for_size(size);

   if (expbits < 0) {
      error_user("[%s:%d] $float:ieee754 only supports $size:2, $size:4, and $size:8", __FILE__, __LINE__);
   }

   return pack_le_float_layout(p, target, size, expbits);
}

//! @brief Handle pack little-endian simple float logic for compiler floating-point constants.
static int pack_le_simple_float(const char *p, unsigned char *target, int size) {
   int expbits = simple_float_expbits_for_size(size);

   if (expbits < 0) {
      error_user("[%s:%d] $float:simple requires a positive $size", __FILE__, __LINE__);
   }

   return pack_le_float_layout(p, target, size, expbits);
}

typedef struct FloatStyleDef {
   const char *name;
   int (*expbits_for_size)(int size);
   int (*pack_le)(const char *p, unsigned char *target, int size);
} FloatStyleDef;

static const FloatStyleDef FLOAT_STYLE_TABLE[] = {
   { "ieee754", ieee754_float_expbits_for_size, pack_le_ieee754_float },
   { "simple",  simple_float_expbits_for_size,  pack_le_simple_float  },
};

//! @brief Find float style in compiler floating-point constants tables without transferring ownership.
static const FloatStyleDef *find_float_style(const char *style) {
   int i;

   if (!style) {
      return NULL;
   }

   for (i = 0; i < (int) (sizeof(FLOAT_STYLE_TABLE) / sizeof(FLOAT_STYLE_TABLE[0])); i++) {
      if (!strcmp(FLOAT_STYLE_TABLE[i].name, style)) {
         return &FLOAT_STYLE_TABLE[i];
      }
   }

   return NULL;
}

//! @brief Return whether float style is known in compiler floating-point constants.
bool float_style_is_known(const char *style) {
   return find_float_style(style) != NULL;
}

//! @brief Handle float style expbits for size logic for compiler floating-point constants.
int float_style_expbits_for_size(const char *style, int size) {
   const FloatStyleDef *def = find_float_style(style);
   if (!def) {
      return -1;
   }
   return def->expbits_for_size(size);
}

//! @brief Create little-endian float style for compiler floating-point constants.
int make_le_float_style(const char *p, unsigned char *target, int size, const char *style) {
   const FloatStyleDef *def = find_float_style(style);

   if (!def) {
      error_unreachable("[%s:%d] unknown float style '%s'", __FILE__, __LINE__, style ? style : "(null)");
   }

   return def->pack_le(p, target, size);
}

//! @brief Handle negate little-endian float logic for compiler floating-point constants.
void negate_le_float(unsigned char *target, int size) {
   target[size-1] |= 0x80;
}

//! @brief Create big-endian float style for compiler floating-point constants.
int make_be_float_style(const char *p, unsigned char *target, int size, const char *style) {
   int ret = make_le_float_style(p, target, size, style);
   reverse_bytes(target, size);
   return ret;
}

//! @brief Handle negate big-endian float logic for compiler floating-point constants.
void negate_be_float(unsigned char *target, int size) {
   (void) size;
   target[0] |= 0x80;
}
