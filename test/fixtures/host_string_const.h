/* Test-only C23-style const propagation, including on older C libraries.
 * Force-include this header for host C translation-unit syntax checks. */
#ifndef VCSC_TEST_HOST_STRING_CONST_H
#define VCSC_TEST_HOST_STRING_CONST_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <string.h>

static inline const char *vcsc_const_strchr(const char *s, int c) {
   return strchr(s, c);
}
static inline const char *vcsc_const_strrchr(const char *s, int c) {
   return strrchr(s, c);
}
static inline const char *vcsc_const_strstr(const char *s, const char *needle) {
   return strstr(s, needle);
}
static inline const char *vcsc_const_strpbrk(const char *s, const char *accept) {
   return strpbrk(s, accept);
}
static inline const void *vcsc_const_memchr(const void *s, int c, size_t n) {
   return memchr(s, c, n);
}

/* The conditional expression converts object pointers to void pointers while
 * preserving const, also covering arrays and non-char buffers for memchr.
 * Use a non-null void pointer so the null-pointer-constant exception does not
 * preserve the original char-pointer type. The expression is never evaluated.
 * Mutable inputs keep the ordinary mutable-returning declarations. */
#undef strchr
#undef strrchr
#undef strstr
#undef strpbrk
#undef memchr
#define strchr(s, c) _Generic((1 ? (s) : (void *)1), const void *: vcsc_const_strchr, default: strchr)((s), (c))
#define strrchr(s, c) _Generic((1 ? (s) : (void *)1), const void *: vcsc_const_strrchr, default: strrchr)((s), (c))
#define strstr(s, n) _Generic((1 ? (s) : (void *)1), const void *: vcsc_const_strstr, default: strstr)((s), (n))
#define strpbrk(s, a) _Generic((1 ? (s) : (void *)1), const void *: vcsc_const_strpbrk, default: strpbrk)((s), (a))
#define memchr(s, c, n) _Generic((1 ? (s) : (void *)1), const void *: vcsc_const_memchr, default: memchr)((s), (c), (n))

#endif
