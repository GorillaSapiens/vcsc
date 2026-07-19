//! @file compiler/messages.c
//! @brief Implements compiler diagnostics for the VCSC compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#include "ast.h"
#include "lextern.h"
#include "messages.h"
#include "parser.tab.h"
#include "xray.h"

static const char *message_filename = NULL;
static int message_line = 0;
static int message_column = 0;
static char *message_near = NULL;

static char *demangle_unicode_escapes(const char *s);
static char *vformat_demangled(const char *fmt, va_list args);

//! @brief Create near for compiler diagnostic layer. The returned storage is owned by the caller or the object that immediately records it.
static char *dup_near(const char *near) {
   size_t len;

   if (!near) {
      return NULL;
   }

   len = strcspn(near, "\r\n");
   if (len > 120) {
      len = 120;
   }

   return strndup(near, len);
}

//! @brief Handle message set location logic for compiler diagnostic layer.
void message_set_location(const char *filename, int line, int column, const char *near) {
   free(message_near);
   message_filename = filename;
   message_line = line;
   message_column = column;
   message_near = dup_near(near);
}

//! @brief Handle message clear location logic for compiler diagnostic layer.
void message_clear_location(void) {
   free(message_near);
   message_near = NULL;
   message_filename = NULL;
   message_line = 0;
   message_column = 0;
}

//! @brief Handle message logic for compiler diagnostic layer.
void message(const char *fmt, ...) {
   va_list args;
   char *str;
   va_start(args, fmt);
   str = vformat_demangled(fmt, args);
   fprintf(stderr, "%s\n", str);
   free(str);
   va_end(args);
}

//! @brief Handle debug logic for compiler diagnostic layer.
void debug(const char *fmt, ...) {
   if (get_xray(XRAY_DEBUG)) {
      va_list args;
      char *str;
      va_start(args, fmt);
      str = vformat_demangled(fmt, args);
      fprintf(stderr, "Debug: %s\n", str);
      free(str);
      va_end(args);
   }
}

//! @brief Return display filename data used by compiler diagnostic layer; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *display_filename(const char *filename) {
   const char *slash;
   const char *bslash;
   const char *base;

   if (!filename || !*filename || filename[0] == '<') {
      return filename;
   }

   slash = strrchr(filename, '/');
   bslash = strrchr(filename, '\\');
   base = filename;

   if (slash && slash + 1 > base) {
      base = slash + 1;
   }
   if (bslash && bslash + 1 > base) {
      base = bslash + 1;
   }

   return base;
}

static int hex_value(char c) {
   if (c >= '0' && c <= '9') return c - '0';
   if (c >= 'a' && c <= 'f') return c - 'a' + 10;
   if (c >= 'A' && c <= 'F') return c - 'A' + 10;
   return -1;
}

static int append_utf8(char *out, unsigned int cp) {
   if (cp <= 0x7f) {
      out[0] = (char)cp;
      return 1;
   }
   if (cp <= 0x7ff) {
      out[0] = (char)(0xc0 | (cp >> 6));
      out[1] = (char)(0x80 | (cp & 0x3f));
      return 2;
   }
   if (cp <= 0xffff) {
      out[0] = (char)(0xe0 | (cp >> 12));
      out[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
      out[2] = (char)(0x80 | (cp & 0x3f));
      return 3;
   }
   if (cp <= 0x10ffff) {
      out[0] = (char)(0xf0 | (cp >> 18));
      out[1] = (char)(0x80 | ((cp >> 12) & 0x3f));
      out[2] = (char)(0x80 | ((cp >> 6) & 0x3f));
      out[3] = (char)(0x80 | (cp & 0x3f));
      return 4;
   }
   return 0;
}

static bool parse_unicode_escape(const char *s, size_t *consumed, unsigned int *cp) {
   size_t i;
   unsigned int value = 0;

   if (!s || s[0] != '?' || s[1] != 'u') {
      return false;
   }

   for (i = 2; i < 10 && s[i] && s[i] != '?'; i++) {
      int hv = hex_value(s[i]);
      if (hv < 0) {
         return false;
      }
      value = (value << 4) | (unsigned int)hv;
   }

   if (s[i] != '?' || i == 2) {
      return false;
   }
   if (i != 6 && i != 10) {
      return false;
   }
   if (value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) {
      return false;
   }

   *consumed = i + 1;
   *cp = value;
   return true;
}

static char *demangle_unicode_escapes(const char *s) {
   size_t len;
   char *out;
   size_t o = 0;

   if (!s) {
      return NULL;
   }

   len = strlen(s);
   out = malloc(len + 1);
   if (!out) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   for (size_t i = 0; i < len; ) {
      size_t consumed = 0;
      unsigned int cp = 0;

      if (parse_unicode_escape(s + i, &consumed, &cp)) {
         int written = append_utf8(out + o, cp);
         if (written > 0) {
            o += (size_t)written;
            i += consumed;
            continue;
         }
      }

      out[o++] = s[i++];
   }

   out[o] = 0;
   return out;
}

static char *vformat_demangled(const char *fmt, va_list args) {
   va_list args_copy;
   int size;
   char *raw;
   char *ret;

   va_copy(args_copy, args);
   size = 1 + vsnprintf(NULL, 0, fmt, args_copy);
   va_end(args_copy);

   raw = malloc((size_t)size);
   if (!raw) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   va_copy(args_copy, args);
   vsnprintf(raw, (size_t)size, fmt, args_copy);
   va_end(args_copy);

   ret = demangle_unicode_escapes(raw);
   free(raw);
   return ret;
}

//! @brief Handle format location header logic for compiler diagnostic layer.
static void format_location_header(const char *preamble,
                                   const char *filename,
                                   int line,
                                   int column,
                                   const char *near) {
   if (filename && line > 0) {
      fprintf(stderr, "%s at %s:%d.%d", preamble, display_filename(filename), line, column);
      if (near && *near) {
         char *display_near = demangle_unicode_escapes(near);
         fprintf(stderr, " (near '%s')", display_near ? display_near : near);
         free(display_near);
      }
      fprintf(stderr, "\n");
   }
   else {
      fprintf(stderr, "%s: ", preamble);
   }
}

//! @brief Handle verror impl logic for compiler diagnostic layer.
static void noreturn verror_impl(const char *fmt, va_list args) {
   char *str = vformat_demangled(fmt, args);

   if (message_filename && message_line > 0) {
      format_location_header("Error", message_filename, message_line, message_column, message_near);
      fprintf(stderr, "   %s\n", str);
   }
   else {
      fprintf(stderr, "Error: %s\n", str);
   }
   free(str);
   message_clear_location();
   exit(-1);
}

//! @brief Report user diagnostics with the location/context expected by compiler diagnostic layer callers.
void error_user(const char *fmt, ...) {
   va_list args;
   va_start(args, fmt);
   verror_impl(fmt, args);
   va_end(args);
}

//! @brief Report unimplemented diagnostics with the location/context expected by compiler diagnostic layer callers.
void error_unimplemented(const char *fmt, ...) {
   va_list args;
   va_start(args, fmt);
   verror_impl(fmt, args);
   va_end(args);
}

//! @brief Report unreachable diagnostics with the location/context expected by compiler diagnostic layer callers.
void error_unreachable(const char *fmt, ...) {
   va_list args;
   va_start(args, fmt);
   verror_impl(fmt, args);
   va_end(args);
}

//! @brief Handle warning logic for compiler diagnostic layer.
void warning(const char *fmt, ...) {
   va_list args;
   char *str;
   va_start(args, fmt);
   str = vformat_demangled(fmt, args);
   fprintf(stderr, "Warning: %s\n", str);
   free(str);
   va_end(args);
}

//! @brief Handle isident logic for compiler diagnostic layer.
static bool isident(const char *p) {
   return (*p >= 'A' && *p <= 'Z') ||
          (*p >= 'a' && *p <= 'z') ||
          (*p >= '0' && *p <= '9') ||
          (*p == '_');
}

//! @brief Handle replace in place logic for compiler diagnostic layer.
static void replace_in_place(char *s, const char *l, const char *r) {
    size_t len_l = strlen(l);
    size_t len_r = strlen(r);
    char *pos;

    while ((pos = strstr(s, l)) != NULL && (pos == s || !isident(pos-1)) && !isident(pos + len_l)) {
        size_t tail_len = strlen(pos + len_l);
        if (len_r > len_l) {
            memmove(pos + len_r, pos + len_l, tail_len + 1);
        } else if (len_r < len_l) {
            memmove(pos + len_r, pos + len_l, tail_len + 1);
        }
        memcpy(pos, r, len_r);
        s = pos + len_r;
    }
}

static const char *replacements[] = {
#include "delexer.h"
};

//! @brief Run the replacements stage of the compiler tool pipeline.
static void do_replacements(char *s) {
   for (size_t i = 0; i < sizeof(replacements) / sizeof(replacements[0]); i += 2) {
      replace_in_place(s, replacements[i], replacements[i+1]);
   }
}

//! @brief Handle yymessage logic for compiler diagnostic layer.
static void yymessage(const char *preamble, const char *fmt, va_list args) {
   va_list args_copy;
   int size;
   char *str;
   const char *filename;
   int line;
   int column;

   va_copy(args_copy, args);
   size = 1 + vsnprintf(NULL, 0, fmt, args_copy);
   va_end(args_copy);

   str = (char *) malloc(sizeof(char) * size);
   va_copy(args_copy, args);
   vsnprintf(str, size, fmt, args_copy);
   va_end(args_copy);

   for (char *p = str; *p; p++) {
      for (size_t i = 0; i < sizeof(replacements) / sizeof(replacements[0]); i += 2) {
         size_t len_l = strlen(replacements[i]);
         size_t len_r = strlen(replacements[i + 1]);
         if (!strncmp(p, replacements[i], len_l)) {
            size += len_r;
         }
      }
   }
   str = realloc(str, size);

   do_replacements(str);
   {
      char *display_str = demangle_unicode_escapes(str);
      free(str);
      str = display_str;
   }

   filename = yyfilename ? yyfilename : current_filename;
   line = yylloc.first_line;
   column = yylloc.first_column;

   if (filename && line > 0) {
      format_location_header(preamble, filename, line, column, yytext);
      fprintf(stderr, "   %s\n", str);
   }
   else {
      fprintf(stderr, "%s: %s\n", preamble, str);
   }

   free(str);
}

//! @brief Handle yyerror logic for compiler diagnostic layer.
void yyerror(const char *fmt, ...) {
   va_list ap;
   va_start(ap, fmt);
   yymessage("Error", fmt, ap);
   va_end(ap);
   exit(-1);
}

//! @brief Handle yywarn logic for compiler diagnostic layer.
void yywarn(const char *fmt, ...) {
   va_list ap;
   va_start(ap, fmt);
   yymessage("Warning", fmt, ap);
   va_end(ap);
}
