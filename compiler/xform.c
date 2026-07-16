//! @file compiler/xform.c
//! @brief Implements AST transformation passes for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include "ast.h"
#include "enumname.h"
#include "lextern.h"
#include "memname.h"
#include "messages.h"
#include "pair.h"
#include "typename.h"
#include "xform.h"

static Pair *xforms = NULL;

//! @brief Add xform to compiler string transform table state, growing storage or preserving uniqueness as needed.
int register_xform(const char *name, ASTNode *node) {
   if (!xforms) {
      xforms = pair_create();
   }

   if (memname_exists(name)) {
      ASTNode *previous = get_memname_node(name);
      error_user("xform at %s:%d.%d cannot be the same as existing memname at %s:%d.%d",
         current_filename, yylineno, yycolumn,
         previous->file, previous->line, previous->column);
      return -1;
   }

   if (typename_exists(name)) {
      ASTNode *previous = get_typename_node(name);
      error_user("xform at %s:%d.%d cannot be the same as existing typename at %s:%d.%d",
         current_filename, yylineno, yycolumn,
         previous->file, previous->line, previous->column);
      return -1;
   }

   if (enumname_exists(name)) {
      ASTNode *previous = get_enumname_node(name);
      error_user("xform at %s:%d.%d cannot be the same as existing enum name at %s:%d.%d",
         current_filename, yylineno, yycolumn,
         previous->file, previous->line, previous->column);
      return -1;
   }

   if (pair_exists(xforms, name)) {
      ASTNode *previous = get_xform_node(name);
      error_user("xform at %s:%d.%d already exists at %s:%d.%d",
         current_filename, yylineno, yycolumn,
         previous->file, previous->line, previous->column);
      return -1;
   }

   pair_insert(xforms, name, node);
   return 0;
}

//! @brief Handle xform exists logic for compiler string transform table.
bool xform_exists(const char *name) {
   if (!xforms) {
      xforms = pair_create();
   }

   return pair_exists(xforms, name);
}

//! @brief Handle str append logic for compiler string transform table.
static void str_append(char **sp, int *lp, unsigned char byte) {
   *sp = (char *) realloc(*sp, *lp + 2);
   (*sp)[*lp] = byte;
   *lp = *lp + 1;
   (*sp)[*lp] = 0;
}

static ASTNode *context = NULL;
static ASTNode *working = NULL;

//! @brief Handle describe utf8 bytes logic for compiler string transform table.
static void describe_utf8_bytes(char *buf, size_t buflen, const char *s) {
   size_t used = 0;
   const unsigned char *us = (const unsigned char *) s;

   if (buflen == 0) {
      return;
   }

   buf[0] = '\0';
   for (int i = 0; i < 4 && us[i]; i++) {
      int wrote = snprintf(buf + used, buflen - used,
         "%s0x%02X", i ? " " : "", us[i]);
      if (wrote < 0 || (size_t) wrote >= buflen - used) {
         used = buflen - 1;
         break;
      }
      used += wrote;
   }

   if (used == 0) {
      snprintf(buf, buflen, "<eos>");
   }
}

//! @brief Report invalid utf8 diagnostics with the location/context expected by compiler string transform table callers.
static void error_invalid_utf8(const char *start, const char *s, const char *name) {
   char bytes[32];
   describe_utf8_bytes(bytes, sizeof(bytes), s);
   error_user("[%s:%d.%d] invalid utf8 in string literal at byte offset %d while applying xform '%s' near bytes %s",
      working->file, working->line, working->column,
      (int) (s - start), name[0] ? name : "", bytes);
}

//! @brief Handle str append helper logic for compiler string transform table.
static void str_append_helper(char **sp, int *lp, const char *match) {
   for (int i = 0; i < context->count; i++) {
      ASTNode *item = context->children[i];
      if (!strcmp(match, item->children[0]->strval)) {
         for (int j = 1; j < item->count; j++) {
            str_append(sp, lp, strtol(item->children[j]->strval, NULL, 0));
         }
         return;
      }
   }
   if (match[0] == '\'' && match[1] == '\\') {
      if (match[2] == 'u') {
         warning("no xform translation for %s, using 0xFF at %s:%d.%d",
               match, working->file, working->line, working->column);
         str_append(sp, lp, 0xFF);
      }
      else {
         warning("no xform translation for %s, using 0x%02X%s%c%s at %s:%d.%d",
               match,
               match[2],
               (match[2] >= ' ' && match[2] <= '~') ? "(" : "",
               match[2],
               (match[2] >= ' ' && match[2] <= '~') ? ")" : "",
               working->file, working->line, working->column);
         str_append(sp, lp, match[2]);
      }
   }
}

//! @brief Handle str append codepoint logic for compiler string transform table.
static void str_append_codepoint(char **sp, int *lp, int codepoint) {
   char buf[16];
   sprintf(buf, "'\\u%04x'", codepoint);
   str_append_helper(sp, lp, buf);
}

//! @brief Handle str append utf8 logic for compiler string transform table.
static void str_append_utf8(char **sp, int *lp, int codepoint) {
   char buf[16];

   if (codepoint <= 0x7F) {
      buf[0] = codepoint;
      buf[1] = 0;
   } else if (codepoint <= 0x7FF) {
      buf[0] = 0xC0 | ((codepoint >> 6) & 0x1F);
      buf[1] = 0x80 | (codepoint & 0x3F);
      buf[2] = 0;
   } else if (codepoint <= 0xFFFF) {
      buf[0] = 0xE0 | ((codepoint >> 12) & 0x0F);
      buf[1] = 0x80 | ((codepoint >> 6) & 0x3F);
      buf[2] = 0x80 | (codepoint & 0x3F);
      buf[3] = 0;
   } else if (codepoint <= 0x10FFFF) {
      buf[0] = 0xF0 | ((codepoint >> 18) & 0x07);
      buf[1] = 0x80 | ((codepoint >> 12) & 0x3F);
      buf[2] = 0x80 | ((codepoint >> 6) & 0x3F);
      buf[3] = 0x80 | (codepoint & 0x3F);
      buf[4] = 0;
   } else {
      buf[0] = 0; // invalid code point
   }

   for (char *p = buf; *p; p++) {
      str_append(sp, lp, *p);
   }
}

//! @brief Handle str append esc logic for compiler string transform table.
static void str_append_esc(char **sp, int *lp, char c) {
   char buf[16];
   sprintf(buf, "'\\%c'", c);
   str_append_helper(sp, lp, buf);
}

//! @brief Parse utf8 into the normalized representation used by compiler string transform table.
static int decode_utf8(const char *s, int *codepoint) {
    *codepoint = 0;
    const unsigned char *us = (const unsigned char *)s;

    if ((us[0] & 0x80) == 0) {
        // 1-byte ASCII
        *codepoint = us[0];
        return 1;
    } else if ((us[0] & 0xE0) == 0xC0) {
        // 2-byte sequence
        if ((us[1] & 0xC0) != 0x80) return 0;
        *codepoint = ((us[0] & 0x1F) << 6) | (us[1] & 0x3F);
        return 2;
    } else if ((us[0] & 0xF0) == 0xE0) {
        // 3-byte sequence
        if ((us[1] & 0xC0) != 0x80 || (us[2] & 0xC0) != 0x80) return 0;
        *codepoint = ((us[0] & 0x0F) << 12) |
                ((us[1] & 0x3F) << 6) |
                (us[2] & 0x3F);
        return 3;
    } else if ((us[0] & 0xF8) == 0xF0) {
        // 4-byte sequence
        if ((us[1] & 0xC0) != 0x80 || (us[2] & 0xC0) != 0x80 || (us[3] & 0xC0) != 0x80) return 0;
        *codepoint = ((us[0] & 0x07) << 18) |
                ((us[1] & 0x3F) << 12) |
                ((us[2] & 0x3F) << 6) |
                (us[3] & 0x3F);
        return 4;
    }

    // Invalid or overlong
    return 0;
}

//! @brief Handle fromhex logic for compiler string transform table.
static int fromhex(int len, const char *p) {
   int ret = 0;
   const char *op = p;
   for (int i = 0; i < len; i++) {
      ret <<= 4;
      if (*p >= '0' && *p <= '9') {
         ret |= (*p - '0');
      }
      else if (*p >= 'A' && *p <= 'F') {
         ret |= (*p - 'A' + 10);
      }
      else if (*p >= 'a' && *p <= 'f') {
         ret |= (*p - 'a' + 10);
      }
      else {
         warning("malformed hex '%s'\n", op);
      }
      p++;
   }
   return ret;
}

//! @brief Run the xform stage of the compiler tool pipeline.
ASTNode *do_xform(ASTNode *node, const char *name) {
   const char *s = node->strval;
   char *ret = NULL;
   int retlen = 0;
   int codepoint;

   working = node;

   if (!name) {
      name = "";
   }

   context = pair_get(xforms, name);
   if (!context) {
      if (!name || (name && !name[0])) {
         warning("default xform context not defined");
      }
      else {
         warning("could not find xform context '%s'", name);
      }
      return node;
   }

   while (*s) {
      if (*s == '\\') {
         if (s[1] == 'x') {
            // \x?? is raw no matter what
            unsigned char byte = fromhex(2, s+2);
            str_append(&ret, &retlen, byte);
            s += 4;
         }
         else if (s[1] == 'u') {
            codepoint = fromhex(4, s+2);
            s += 6;
            if (name[0]) {
               // named xform, \u???? is a lookup
               str_append_codepoint(&ret, &retlen, codepoint);
            }
            else {
               // unnamed xform, \u???? is utf8
               str_append_utf8(&ret, &retlen, codepoint);
            }
         }
         else {
            // \? an escaped character
            str_append_esc(&ret, &retlen, s[1]);
            s += 2;
         }
      }
      else {
         if (name[0]) {
            // named xform, utf8 is a lookup
            int skip = decode_utf8(s, &codepoint);
            if (skip == 0) {
               error_invalid_utf8(node->strval, s, name);
            }
            s += skip;
            str_append_codepoint(&ret, &retlen, codepoint);
         }
         else {
            // unnamed xform, raw characters
            str_append(&ret, &retlen, *s++);
         }
      }
   }

   node->strval = ret;
   return node;
}

//! @brief Return get xform node data used by compiler string transform table; returned pointers alias existing storage unless explicitly allocated by the function name.
ASTNode *get_xform_node(const char *name) {
   if (!xforms) {
      xforms = pair_create();
   }

   return pair_get(xforms, name);
}
