/* ---------- lexer.l ---------- */
%{
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast.h"
#include "enumname.h"
#include "integer.h"
#include "lextern.h"
#include "main.h"
#include "md5seen.h"
#include "memname.h"
#include "messages.h"
#include "typename.h"
#include "xform.h"
#include "xray.h"

#include "parser.tab.h"

static int input(void);

#define MAX_INCLUDE_DEPTH 32
#define MAX_ALIAS_DEPTH 128

char *root_filename = "<stdin>";
char *current_filename = "<stdin>";
char *yyfilename = "<stdin>";
int yycolumn = 1;

typedef struct FileContext {
   FILE *file;
   char *filename;
   char *saved_filename;
   int lineno;
   int column;
   int start;
   int cond_depth;
   YY_BUFFER_STATE buffer;
} FileContext;

typedef struct AliasContext {
   int alias_index;
   int local_owner_depth;
   int local_param_index;
   char *virtual_filename;
   char *saved_filename;
   int lineno;
   int column;
   int start;
   int cond_depth;
   YY_BUFFER_STATE buffer;
   const char **local_names;
   char **local_values;
   int local_count;
} AliasContext;

static FileContext file_stack[MAX_INCLUDE_DEPTH];
static int file_stack_top = -1;
static AliasContext alias_stack[MAX_ALIAS_DEPTH];
static int alias_stack_top = -1;
static int cond_stack_top = -1;
static void pp_require_balanced_at_eof(int saved_depth, const char *context_name);
static int lexer_column_width(const char *text, int len);

static const char *pp_error_filename = NULL;
static const char *pp_error_text = NULL;
static int pp_error_line = 0;
static int pp_error_column = 0;

typedef struct LexerTokenLocation {
   const char *token;
   char *filename;
   int line;
   int column;
} LexerTokenLocation;

static LexerTokenLocation *lexer_token_locations = NULL;
static size_t lexer_token_location_count = 0;
static size_t lexer_token_location_cap = 0;

static void lexer_register_token_location(const char *token) {
   if (!token) {
      return;
   }
   if (lexer_token_location_count == lexer_token_location_cap) {
      lexer_token_location_cap = lexer_token_location_cap ? lexer_token_location_cap * 2 : 128;
      lexer_token_locations = realloc(lexer_token_locations, lexer_token_location_cap * sizeof(*lexer_token_locations));
      if (!lexer_token_locations) {
         fprintf(stderr, "out of memory\n");
         exit(1);
      }
   }
   lexer_token_locations[lexer_token_location_count].token = token;
   lexer_token_locations[lexer_token_location_count].filename = strdup(current_filename ? current_filename : "<stdin>");
   lexer_token_locations[lexer_token_location_count].line = yylloc.first_line;
   lexer_token_locations[lexer_token_location_count].column = yylloc.first_column;
   lexer_token_location_count++;
}

int lexer_lookup_token_location(const char *token, const char **filename, int *line, int *column) {
   if (!token) {
      return 0;
   }
   for (size_t i = lexer_token_location_count; i > 0; i--) {
      LexerTokenLocation *loc = &lexer_token_locations[i - 1];
      if (loc->token == token) {
         if (filename) *filename = loc->filename;
         if (line) *line = loc->line;
         if (column) *column = loc->column;
         return 1;
      }
   }
   return 0;
}

static void lexer_set_error_location(const char *filename, int line, int column, const char *near) {
   message_set_location(filename ? filename : current_filename, line, column < 1 ? 1 : column, near);
}

static void lexer_set_error_here(void) {
   lexer_set_error_location(current_filename, yylloc.first_line, yylloc.first_column, yytext);
}

static void lexer_set_runtime_error_location(const char *near) {
   lexer_set_error_location(current_filename, yylineno, yycolumn, near);
}

static void pp_set_error_base(const char *text) {
   pp_error_filename = current_filename;
   pp_error_text = text;
   pp_error_line = yylloc.first_line;
   pp_error_column = yylloc.first_column;
}

static void pp_set_error_location(const char *p) {
   const char *near;

   if (!pp_error_text) {
      lexer_set_runtime_error_location(p);
      return;
   }

   near = p ? p : pp_error_text;
   while (*near && *near != '\n' && isspace((unsigned char)*near)) {
      near++;
   }

   lexer_set_error_location(pp_error_filename,
                            pp_error_line,
                            pp_error_column + (int) (near - pp_error_text),
                            near);
}

#define LEX_ERROR_HERE(...) do { lexer_set_error_here(); error_user(__VA_ARGS__); } while (0)
#define LEX_RUNTIME_ERROR(near, ...) do { lexer_set_runtime_error_location(near); error_user(__VA_ARGS__); } while (0)
#define PP_ERROR_AT(ptr, ...) do { pp_set_error_location(ptr); error_user(__VA_ARGS__); } while (0)

#define YY_USER_ACTION \
   yyfilename = current_filename; \
   yylloc.first_line = yylineno; \
   yylloc.first_column = yycolumn; \
   yylloc.last_line = yylineno; \
   yycolumn += lexer_column_width(yytext, yyleng); \
   yylloc.last_column = yycolumn;

int push_file(const char *filename) {
   if (file_stack_top + 1 >= MAX_INCLUDE_DEPTH) {
      fprintf(stderr, "include nesting too deep\n");
      return -1;
   }

   filename = search_includes(filename);

   FILE *f = fopen(filename, "r");
   if (!f) {
      lexer_set_error_location(current_filename, yylloc.first_line, yylloc.first_column, filename);
      error_user("cannot open include file: %s", filename);
      return -1;
   }

   if (md5seen(filename, f)) {
      fclose(f);
      return 0;
   }

   file_stack_top++;
   file_stack[file_stack_top].file = f;
   file_stack[file_stack_top].filename = strdup(filename);
   file_stack[file_stack_top].saved_filename = current_filename;
   file_stack[file_stack_top].lineno = yylineno;
   file_stack[file_stack_top].column = yycolumn;
   file_stack[file_stack_top].start = YY_START;
   file_stack[file_stack_top].cond_depth = cond_stack_top;
   file_stack[file_stack_top].buffer = YY_CURRENT_BUFFER;

   YY_BUFFER_STATE new_buffer = yy_create_buffer(f, YY_BUF_SIZE);
   yy_switch_to_buffer(new_buffer);

   BEGIN(0);
   yylineno = 1;
   yycolumn = 1;
   current_filename = file_stack[file_stack_top].filename;
   return 0;
}

void pop_file() {
   if (file_stack_top < 0) return;
   pp_require_balanced_at_eof(file_stack[file_stack_top].cond_depth,
                              current_filename ? current_filename : "file");
   fclose(file_stack[file_stack_top].file);
   free(file_stack[file_stack_top].filename);
   yy_delete_buffer(YY_CURRENT_BUFFER);
   yy_switch_to_buffer(file_stack[file_stack_top].buffer);
   yylineno = file_stack[file_stack_top].lineno;
   yycolumn = file_stack[file_stack_top].column;
   current_filename = file_stack[file_stack_top].saved_filename;
   BEGIN(file_stack[file_stack_top].start);
   file_stack_top--;
}

static char *strip_underscores(const char *p) {
   if (!p) {
      return NULL;
   }

   char *ret = (char *) malloc (strlen(p) + 1);
   char *q = ret;
   
   while (*p) {
      if (*p != '_') {
         *q++ = *p++;
      }
      else {
         p++;
      }
   }
   *q = 0;

   return ret;
}

static int identifier_utf8_decode_one(const unsigned char *s, size_t len, size_t *advance, unsigned int *codepoint) {
   unsigned char c0;
   unsigned char c1;
   unsigned char c2;
   unsigned char c3;

   if (!s || len == 0 || !advance || !codepoint) {
      return 0;
   }

   c0 = s[0];
   if (c0 < 0x80) {
      *advance = 1;
      *codepoint = c0;
      return 1;
   }

   if (c0 >= 0xc2 && c0 <= 0xdf) {
      if (len < 2) return 0;
      c1 = s[1];
      if ((c1 & 0xc0) != 0x80) return 0;
      *advance = 2;
      *codepoint = ((unsigned int)(c0 & 0x1f) << 6) | (unsigned int)(c1 & 0x3f);
      return 1;
   }

   if (c0 >= 0xe0 && c0 <= 0xef) {
      if (len < 3) return 0;
      c1 = s[1];
      c2 = s[2];
      if ((c2 & 0xc0) != 0x80) return 0;
      if (c0 == 0xe0) {
         if (c1 < 0xa0 || c1 > 0xbf) return 0;
      }
      else if (c0 == 0xed) {
         if (c1 < 0x80 || c1 > 0x9f) return 0;
      }
      else if ((c1 & 0xc0) != 0x80) {
         return 0;
      }
      *advance = 3;
      *codepoint = ((unsigned int)(c0 & 0x0f) << 12) |
                   ((unsigned int)(c1 & 0x3f) << 6) |
                   (unsigned int)(c2 & 0x3f);
      return 1;
   }

   if (c0 >= 0xf0 && c0 <= 0xf4) {
      if (len < 4) return 0;
      c1 = s[1];
      c2 = s[2];
      c3 = s[3];
      if ((c2 & 0xc0) != 0x80 || (c3 & 0xc0) != 0x80) return 0;
      if (c0 == 0xf0) {
         if (c1 < 0x90 || c1 > 0xbf) return 0;
      }
      else if (c0 == 0xf4) {
         if (c1 < 0x80 || c1 > 0x8f) return 0;
      }
      else if ((c1 & 0xc0) != 0x80) {
         return 0;
      }
      *advance = 4;
      *codepoint = ((unsigned int)(c0 & 0x07) << 18) |
                   ((unsigned int)(c1 & 0x3f) << 12) |
                   ((unsigned int)(c2 & 0x3f) << 6) |
                   (unsigned int)(c3 & 0x3f);
      return 1;
   }

   return 0;
}

static int lexer_column_width(const char *text, int len) {
   int width = 0;

   for (int i = 0; i < len; ) {
      unsigned char c = (unsigned char) text[i];
      size_t advance = 0;
      unsigned int cp = 0;

      if (c < 0x80) {
         width++;
         i++;
         continue;
      }

      if (identifier_utf8_decode_one((const unsigned char *)text + i, (size_t)(len - i), &advance, &cp)) {
         (void)cp;
         width++;
         i += (int)advance;
      }
      else {
         width++;
         i++;
      }
   }

   return width;
}

static int identifier_utf8_column_offset(size_t byte_offset) {
   int col = 0;
   size_t len = strlen(yytext);

   for (size_t i = 0; i < len && i < byte_offset; ) {
      unsigned char c = (unsigned char) yytext[i];
      size_t advance = 0;
      unsigned int cp = 0;

      if (c < 0x80) {
         col++;
         i++;
      }
      else if (identifier_utf8_decode_one((const unsigned char *)yytext + i, len - i, &advance, &cp)) {
         (void)cp;
         col++;
         i += advance;
      }
      else {
         break;
      }
   }

   return col;
}

static void identifier_utf8_error_at(size_t offset) {
   lexer_set_error_location(current_filename,
                            yylloc.first_line,
                            yylloc.first_column + identifier_utf8_column_offset(offset),
                            yytext + offset);
   error_user("invalid UTF-8 in identifier");
}

static char *mangle_identifier_utf8_or_die(const char *text) {
   size_t len;
   size_t cap;
   size_t out_len = 0;
   char *out;

   if (!text) {
      return NULL;
   }

   len = strlen(text);
   cap = len * 12 + 1;
   out = (char *) malloc(cap);
   if (!out) {
      error_unreachable("out of memory");
   }

   for (size_t i = 0; i < len; ) {
      unsigned char c = (unsigned char) text[i];
      size_t advance = 0;
      unsigned int cp = 0;

      if (c < 0x80) {
         out[out_len++] = (char) c;
         i++;
         continue;
      }

      if (!identifier_utf8_decode_one((const unsigned char *)text + i, len - i, &advance, &cp)) {
         free(out);
         identifier_utf8_error_at(i);
      }

      if (cp <= 0xffff) {
         out_len += (size_t) snprintf(out + out_len, cap - out_len, "?u%04X?", cp);
      }
      else {
         out_len += (size_t) snprintf(out + out_len, cap - out_len, "?u%08X?", cp);
      }
      i += advance;
   }

   out[out_len] = 0;
   return out;
}


/////////////////////////////
///// conditional handling
/////////////////////////////

#define MAX_COND_DEPTH 128

typedef struct CondContext {
   int parent_active;
   int current_active;
   int branch_taken;
   int saw_else;
   char *sourcefile;
   int sourceline;
   int sourcecol;
} CondContext;

static CondContext cond_stack[MAX_COND_DEPTH];
typedef struct alias_entry {
   const char *name;
   const char *rhs;
   const char *sourcefile;
   const char **params;
   int param_count;
   int is_function_like;
   int sourceline;
   int sourcecol;
} alias_entry;

static alias_entry *alias_entries = NULL;
static int alias_count = 0;
static int alias_find(const char *key);

static int pp_is_active(void) {
   if (cond_stack_top < 0) {
      return 1;
   }
   return cond_stack[cond_stack_top].current_active;
}

static void pp_free_top(void) {
   if (cond_stack_top >= 0) {
      free(cond_stack[cond_stack_top].sourcefile);
      cond_stack[cond_stack_top].sourcefile = NULL;
   }
}

static void pp_push_cond(int cond) {
   int parent_active = pp_is_active();

   if (cond_stack_top + 1 >= MAX_COND_DEPTH) {
      PP_ERROR_AT(pp_error_text, "conditional nesting too deep");
   }

   cond_stack_top++;
   cond_stack[cond_stack_top].parent_active = parent_active;
   cond_stack[cond_stack_top].current_active = parent_active && cond;
   cond_stack[cond_stack_top].branch_taken = parent_active && cond;
   cond_stack[cond_stack_top].saw_else = 0;
   cond_stack[cond_stack_top].sourcefile = strdup(pp_error_filename ? pp_error_filename : (current_filename ? current_filename : "<stdin>"));
   cond_stack[cond_stack_top].sourceline = pp_error_line ? pp_error_line : yylineno;
   cond_stack[cond_stack_top].sourcecol = pp_error_column;
}

static void pp_pop_cond(void) {
   if (cond_stack_top < 0) {
      PP_ERROR_AT(pp_error_text, "unexpected #endif");
   }

   pp_free_top();
   cond_stack_top--;
}

static void pp_require_balanced_at_eof(int saved_depth, const char *context_name) {
   if (cond_stack_top > saved_depth) {
      error_user("[%s:%d.%d] unterminated conditional compilation block before end of %s",
                 cond_stack[cond_stack_top].sourcefile,
                 cond_stack[cond_stack_top].sourceline,
                 cond_stack[cond_stack_top].sourcecol,
                 context_name ? context_name : "input");
   }
}

static const char *pp_skip_hspace(const char *p) {
   while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\f' || *p == '\v') {
      p++;
   }
   return p;
}

static int pp_is_ident_start(unsigned char c) {
   return isalpha(c) || c == '_' || c >= 0x80;
}

static int pp_is_ident_char(unsigned char c) {
   return isalnum(c) || c == '_' || c >= 0x80;
}

static char *pp_parse_identifier_dup(const char **pp) {
   const char *p = pp_skip_hspace(*pp);
   const char *start = p;

   if (!pp_is_ident_start((unsigned char)*p)) {
      return NULL;
   }

   p++;
   while (pp_is_ident_char((unsigned char)*p)) {
      p++;
   }

   *pp = p;
   return strndup(start, p - start);
}

static int pp_has_trailing_junk(const char *p) {
   p = pp_skip_hspace(p);
   return *p != 0;
}

static int pp_match_op(const char **pp, const char *op) {
   const char *p = pp_skip_hspace(*pp);
   size_t n = strlen(op);

   if (!strncmp(p, op, n)) {
      *pp = p + n;
      return 1;
   }

   return 0;
}

static long long pp_eval_expr(const char *text);
static int alias_find(const char *key);

typedef long long (*pp_parse_fn)(const char **pp);

static long long pp_eval_alias_rhs(int index) {
   static int eval_stack[MAX_ALIAS_DEPTH];
   static int eval_top = -1;

   if (index < 0 || index >= alias_count) {
      error_unreachable("bad alias index in conditional (%d)", index);
   }

   if (alias_entries[index].is_function_like) {
      return 0;
   }

   for (int i = 0; i <= eval_top; i++) {
      if (eval_stack[i] == index) {
         PP_ERROR_AT(pp_error_text, "recursive alias expansion for '%s' in conditional",
                     alias_entries[index].name);
      }
   }

   if (eval_top + 1 >= MAX_ALIAS_DEPTH) {
      PP_ERROR_AT(pp_error_text, "conditional alias expansion nesting too deep");
   }

   eval_stack[++eval_top] = index;
   long long value = pp_eval_expr(alias_entries[index].rhs);
   eval_top--;
   return value;
}

static void pp_skip_invocation_text(const char **pp) {
   const char *p = pp_skip_hspace(*pp);
   int depth = 0;

   if (*p != '(') {
      *pp = p;
      return;
   }

   for (;;) {
      char c = *p++;

      if (!c) {
         PP_ERROR_AT(p - 1, "unterminated function-like alias invocation in conditional");
      }

      if (c == '\'' || c == '"') {
         char quote = c;
         while (*p) {
            c = *p++;
            if (c == '\\' && *p) {
               p++;
               continue;
            }
            if (c == quote) {
               break;
            }
         }
         if (!c) {
            PP_ERROR_AT(p - 1, "unterminated quoted text in conditional");
         }
         continue;
      }

      if (c == '(') {
         depth++;
         continue;
      }

      if (c == ')') {
         if (depth == 0) {
            *pp = p;
            return;
         }
         depth--;
      }
   }
}

static long long pp_parse_or(const char **pp);

static long long pp_parse_primary(const char **pp) {
   const char *p = pp_skip_hspace(*pp);
   long long value;

   if (*p == '(') {
      p++;
      value = pp_parse_or(&p);
      p = pp_skip_hspace(p);
      if (*p != ')') {
         PP_ERROR_AT(p, "expected ')' in conditional expression");
      }
      p++;
      *pp = p;
      return value;
   }

   if (isdigit((unsigned char)*p)) {
      const char *start = p;
      char *token;
      char *clean;

      while (isalnum((unsigned char)*p) || *p == '_') {
         p++;
      }

      token = strndup(start, p - start);
      clean = strip_underscores(token);
      free(token);
      value = parse_int(clean);
      free(clean);
      *pp = p;
      return value;
   }

   if (pp_is_ident_start((unsigned char)*p)) {
      char *name = pp_parse_identifier_dup(&p);

      if (!strcmp(name, "defined")) {
         char *target;

         p = pp_skip_hspace(p);
         if (*p == '(') {
            p++;
            target = pp_parse_identifier_dup(&p);
            if (!target) {
               PP_ERROR_AT(p, "expected identifier after defined(");
            }
            p = pp_skip_hspace(p);
            if (*p != ')') {
               PP_ERROR_AT(p, "expected ')' after defined(identifier)");
            }
            p++;
         }
         else {
            target = pp_parse_identifier_dup(&p);
            if (!target) {
               PP_ERROR_AT(p, "expected identifier after defined");
            }
         }

         value = alias_find(target) != -1;
         free(target);
         free(name);
         *pp = p;
         return value;
      }

      if (!strcmp(name, "true")) {
         free(name);
         *pp = p;
         return 1;
      }
      if (!strcmp(name, "false")) {
         free(name);
         *pp = p;
         return 0;
      }

      int index = alias_find(name);
      if (index != -1) {
         if (alias_entries[index].is_function_like) {
            const char *q = pp_skip_hspace(p);
            if (*q == '(') {
               p = q;
               pp_skip_invocation_text(&p);
            }
            value = 0;
         }
         else {
            value = pp_eval_alias_rhs(index);
         }
      }
      else {
         value = 0;
      }

      free(name);
      *pp = p;
      return value;
   }

   PP_ERROR_AT(p, "unexpected text in conditional expression near '%s'", pp_skip_hspace(p));
   return 0;
}

static long long pp_parse_unary(const char **pp) {
   if (pp_match_op(pp, "!")) {
      return !pp_parse_unary(pp);
   }
   if (pp_match_op(pp, "-")) {
      return -pp_parse_unary(pp);
   }
   if (pp_match_op(pp, "+")) {
      return pp_parse_unary(pp);
   }

   return pp_parse_primary(pp);
}

static long long pp_parse_cmp(const char **pp) {
   long long lhs = pp_parse_unary(pp);

   for (;;) {
      if (pp_match_op(pp, "==")) {
         lhs = lhs == pp_parse_unary(pp);
      }
      else if (pp_match_op(pp, "!=")) {
         lhs = lhs != pp_parse_unary(pp);
      }
      else if (pp_match_op(pp, "<=")) {
         lhs = lhs <= pp_parse_unary(pp);
      }
      else if (pp_match_op(pp, ">=")) {
         lhs = lhs >= pp_parse_unary(pp);
      }
      else if (pp_match_op(pp, "<")) {
         lhs = lhs < pp_parse_unary(pp);
      }
      else if (pp_match_op(pp, ">")) {
         lhs = lhs > pp_parse_unary(pp);
      }
      else {
         return lhs;
      }
   }
}

static long long pp_parse_and(const char **pp) {
   long long lhs = pp_parse_cmp(pp);

   while (pp_match_op(pp, "&&")) {
      long long rhs = pp_parse_cmp(pp);
      lhs = lhs && rhs;
   }

   return lhs;
}

static long long pp_parse_or(const char **pp) {
   long long lhs = pp_parse_and(pp);

   while (pp_match_op(pp, "||")) {
      long long rhs = pp_parse_and(pp);
      lhs = lhs || rhs;
   }

   return lhs;
}

static long long pp_eval_expr(const char *text) {
   const char *p = text;
   long long value = pp_parse_or(&p);

   if (pp_has_trailing_junk(p)) {
      PP_ERROR_AT(p, "unexpected trailing text in conditional expression near '%s'", pp_skip_hspace(p));
   }

   return value;
}

static void pp_handle_directive(const char *text) {
   const char *p = pp_skip_hspace(text);
   char keyword[32];
   size_t klen = 0;

   pp_set_error_base(text);

   if (*p != '#') {
      return;
   }
   p++;
   p = pp_skip_hspace(p);

   while (isalpha((unsigned char)*p)) {
      if (klen + 1 >= sizeof(keyword)) {
         PP_ERROR_AT(p, "preprocessor directive too long");
      }
      keyword[klen++] = *p++;
   }
   keyword[klen] = 0;

   if (!strcmp(keyword, "if")) {
      int cond = 0;

      if (pp_is_active()) {
         cond = pp_eval_expr(pp_skip_hspace(p)) != 0;
      }
      pp_push_cond(cond);
   }
   else if (!strcmp(keyword, "ifdef")) {
      char *name = pp_parse_identifier_dup(&p);
      int cond = 0;

      if (!name || pp_has_trailing_junk(p)) {
         PP_ERROR_AT(p, "expected identifier after #ifdef");
      }
      if (pp_is_active()) {
         cond = alias_find(name) != -1;
      }
      pp_push_cond(cond);
      free(name);
   }
   else if (!strcmp(keyword, "ifndef")) {
      char *name = pp_parse_identifier_dup(&p);
      int cond = 0;

      if (!name || pp_has_trailing_junk(p)) {
         PP_ERROR_AT(p, "expected identifier after #ifndef");
      }
      if (pp_is_active()) {
         cond = alias_find(name) == -1;
      }
      pp_push_cond(cond);
      free(name);
   }
   else if (!strcmp(keyword, "elif")) {
      if (cond_stack_top < 0) {
         PP_ERROR_AT(pp_error_text, "unexpected #elif");
      }
      if (cond_stack[cond_stack_top].saw_else) {
         PP_ERROR_AT(pp_error_text, "#elif after #else");
      }

      if (!cond_stack[cond_stack_top].parent_active || cond_stack[cond_stack_top].branch_taken) {
         cond_stack[cond_stack_top].current_active = 0;
      }
      else {
         int cond = pp_eval_expr(pp_skip_hspace(p)) != 0;
         cond_stack[cond_stack_top].current_active = cond;
         if (cond) {
            cond_stack[cond_stack_top].branch_taken = 1;
         }
      }
   }
   else if (!strcmp(keyword, "else")) {
      if (cond_stack_top < 0) {
         PP_ERROR_AT(pp_error_text, "unexpected #else");
      }
      if (cond_stack[cond_stack_top].saw_else) {
         PP_ERROR_AT(pp_error_text, "duplicate #else");
      }
      if (pp_has_trailing_junk(p)) {
         PP_ERROR_AT(p, "unexpected trailing text after #else");
      }
      cond_stack[cond_stack_top].saw_else = 1;
      cond_stack[cond_stack_top].current_active = cond_stack[cond_stack_top].parent_active && !cond_stack[cond_stack_top].branch_taken;
      cond_stack[cond_stack_top].branch_taken = 1;
   }
   else if (!strcmp(keyword, "endif")) {
      if (pp_has_trailing_junk(p)) {
         PP_ERROR_AT(p, "unexpected trailing text after #endif");
      }
      pp_pop_cond();
   }
   else {
      PP_ERROR_AT(text, "unknown preprocessor directive '#%s'", keyword);
   }
}

////////////////////
///// alias handling
////////////////////

static char *alias_build_virtual_filename(const alias_entry *entry) {
   char buf[1024];

   snprintf(buf, sizeof(buf),
            "<alias %s from %s:%d.%d>",
            entry->name ? entry->name : "?",
            entry->sourcefile ? entry->sourcefile : "?",
            entry->sourceline,
            entry->sourcecol);

   return strdup(buf);
}

static const char *alias_name = NULL;
static const char *alias_rhs = NULL;
static const char *alias_sourcefile = NULL;
static const char **alias_params = NULL;
static int alias_param_count = 0;
static int alias_is_function_like = 0;
static int alias_rhs_continues = 0;
static int alias_sourceline;
static int alias_sourcecol;
static const char *alias_invoke_filename = NULL;
static const char *alias_invoke_near = NULL;
static int alias_invoke_line = 0;
static int alias_invoke_column = 0;

static void alias_reset(void) {
   if (alias_name) {
      free((char *)alias_name);
      alias_name = NULL;
   }
   if (alias_rhs) {
      free((char *)alias_rhs);
      alias_rhs = NULL;
   }
   if (alias_sourcefile) {
      free((char *)alias_sourcefile);
      alias_sourcefile = NULL;
   }
   if (alias_params) {
      for (int i = 0; i < alias_param_count; i++) {
         free((char *)alias_params[i]);
      }
      free((char **)alias_params);
      alias_params = NULL;
   }
   alias_param_count = 0;
   alias_is_function_like = 0;
   alias_rhs_continues = 0;
}

static void alias_error(const char *msg) {
   lexer_set_error_here();
   error_user("%s", msg);
}

static void alias_set_name(const char *name) {
   int existing_index;

   if (!strcmp(name, "true") || !strcmp(name, "false")) {
      alias_error("alias 'true' and 'false' are not allowed.");
   }

   if (xform_exists(name)) {
      alias_error("alias name cannot override xform name.");
   }

   if (memname_exists(name)) {
      alias_error("alias name cannot override mem name.");
   }

   if (typename_exists(name)) {
      alias_error("alias name cannot override type name.");
   }

   if (enumname_exists(name)) {
      alias_error("alias name cannot override enum name.");
   }

   existing_index = alias_find(name);
   if (existing_index != -1) {
      error_user("[%s:%d.%d] vs [%s:%d.%d] multiple definitions for alias '%s'",
                 current_filename,
                 yylloc.first_line,
                 yylloc.first_column,
                 alias_entries[existing_index].sourcefile,
                 alias_entries[existing_index].sourceline,
                 alias_entries[existing_index].sourcecol,
                 name);
   }

   alias_name = strdup(name);
   alias_sourcefile = strdup(current_filename);
   alias_sourceline = yylloc.first_line;
   alias_sourcecol = yylloc.first_column;
}

static void alias_mark_function_like(void) {
   alias_is_function_like = 1;
}

static void alias_set_invoke_location(void) {
   alias_invoke_filename = current_filename;
   alias_invoke_near = yytext;
   alias_invoke_line = yylloc.first_line;
   alias_invoke_column = yylloc.first_column;
}

static void alias_set_invoke_error_location(void) {
   lexer_set_error_location(alias_invoke_filename,
                            alias_invoke_line,
                            alias_invoke_column,
                            alias_invoke_near);
}

static char *strip_trailing_comments_preserving_quotes(const char *text) {
   size_t len;
   char *ret;
   size_t i = 0;
   size_t j = 0;

   if (!text) {
      return NULL;
   }

   len = strlen(text);
   ret = malloc(len + 1);

   while (text[i]) {
      if (text[i] == '/' && text[i + 1] == '/') {
         break;
      }

      if (text[i] == '/' && text[i + 1] == '*') {
         i += 2;
         while (text[i] && !(text[i] == '*' && text[i + 1] == '/')) {
            i++;
         }
         if (text[i]) {
            i += 2;
         }
         continue;
      }

      if (text[i] == '\'' || text[i] == '"') {
         char quote = text[i++];
         ret[j++] = quote;
         while (text[i]) {
            ret[j++] = text[i];
            if (text[i] == '\\' && text[i + 1]) {
               i++;
               ret[j++] = text[i];
            }
            else if (text[i] == quote) {
               i++;
               break;
            }
            i++;
         }
         continue;
      }

      ret[j++] = text[i++];
   }

   while (j > 0 && (ret[j - 1] == ' ' || ret[j - 1] == '\t' || ret[j - 1] == '\r' || ret[j - 1] == '\f' || ret[j - 1] == '\v')) {
      j--;
   }

   ret[j] = 0;
   return ret;
}

static void alias_add_param(const char *name) {
   for (int i = 0; i < alias_param_count; i++) {
      if (!strcmp(alias_params[i], name)) {
         LEX_ERROR_HERE("duplicate alias parameter '%s'", name);
      }
   }

   alias_params = realloc((char **)alias_params, sizeof(const char *) * (alias_param_count + 1));
   alias_params[alias_param_count] = strdup(name);
   alias_param_count++;
}

static void alias_finish(void) {
   alias_entries = realloc(alias_entries, sizeof(alias_entry) * (alias_count + 1));

   alias_entries[alias_count].name = alias_name;
   alias_name = NULL;

   if (!alias_rhs) {
      alias_rhs = strdup("");
   }
   alias_entries[alias_count].rhs = alias_rhs;
   alias_rhs = NULL;

   alias_entries[alias_count].sourcefile = alias_sourcefile;
   alias_sourcefile = NULL;

   alias_entries[alias_count].params = alias_params;
   alias_params = NULL;
   alias_entries[alias_count].param_count = alias_param_count;
   alias_param_count = 0;
   alias_entries[alias_count].is_function_like = alias_is_function_like;
   alias_is_function_like = 0;

   alias_entries[alias_count].sourceline = alias_sourceline;

   alias_entries[alias_count].sourcecol = alias_sourcecol;

   alias_count++;
}

static int alias_find(const char *key) {
   for (int i = 0; i < alias_count; i++) {
      if (!strcmp(alias_entries[i].name, key)) {
         return i;
      }
   }
   return -1;
}

static int command_line_define_ident_valid(const char *name) {
   size_t i = 0;

   if (!name || !*name) {
      return 0;
   }

   while (name[i]) {
      unsigned char c = (unsigned char) name[i];
      size_t advance = 0;
      unsigned int cp = 0;

      if (c < 0x80) {
         if (i == 0) {
            if (!(isalpha(c) || c == '_')) {
               return 0;
            }
         }
         else if (!(isalnum(c) || c == '_')) {
            return 0;
         }
         i++;
         continue;
      }

      if (!identifier_utf8_decode_one((const unsigned char *)name + i, strlen(name + i), &advance, &cp)) {
         return 0;
      }
      (void)cp;
      i += advance;
   }

   return 1;
}

static void alias_add_object_like_definition(const char *name,
                                             const char *rhs,
                                             const char *sourcefile,
                                             int sourceline,
                                             int sourcecol) {
   int existing_index;

   if (!strcmp(name, "true") || !strcmp(name, "false")) {
      error_user("alias 'true' and 'false' are not allowed.");
   }

   if (xform_exists(name)) {
      error_user("alias name cannot override xform name.");
   }

   if (memname_exists(name)) {
      error_user("alias name cannot override mem name.");
   }

   if (typename_exists(name)) {
      error_user("alias name cannot override type name.");
   }

   if (enumname_exists(name)) {
      error_user("alias name cannot override enum name.");
   }

   existing_index = alias_find(name);
   if (existing_index != -1) {
      error_user("[%s:%d.%d] vs [%s:%d.%d] multiple definitions for alias '%s'",
                 sourcefile,
                 sourceline,
                 sourcecol,
                 alias_entries[existing_index].sourcefile,
                 alias_entries[existing_index].sourceline,
                 alias_entries[existing_index].sourcecol,
                 name);
   }

   alias_entries = realloc(alias_entries, sizeof(alias_entry) * (alias_count + 1));
   if (!alias_entries) {
      error_unreachable("out of memory");
   }

   alias_entries[alias_count].name = strdup(name);
   alias_entries[alias_count].rhs = strdup(rhs ? rhs : "1");
   alias_entries[alias_count].sourcefile = strdup(sourcefile ? sourcefile : "<command-line>");
   alias_entries[alias_count].params = NULL;
   alias_entries[alias_count].param_count = 0;
   alias_entries[alias_count].is_function_like = 0;
   alias_entries[alias_count].sourceline = sourceline;
   alias_entries[alias_count].sourcecol = sourcecol;
   alias_count++;
}

void lexer_define_alias_from_command_line(const char *spec) {
   char *copy;
   char *eq;
   char *name;
   char *mangled;
   const char *rhs;

   if (!spec || !*spec) {
      error_user("-D requires NAME or NAME=value");
   }

   if (strchr(spec, '\n') || strchr(spec, '\r')) {
      error_user("newline is not allowed in -D definition");
   }

   copy = strdup(spec);
   if (!copy) {
      error_unreachable("out of memory");
   }

   eq = strchr(copy, '=');
   if (eq) {
      *eq = '\0';
      rhs = eq + 1;
      if (!*rhs) {
         free(copy);
         error_user("-D%s= is missing a value", spec);
      }
   }
   else {
      rhs = "1";
   }

   name = copy;
   if (!command_line_define_ident_valid(name)) {
      free(copy);
      error_user("invalid -D name '%s'", spec);
   }

   mangled = mangle_identifier_utf8_or_die(name);
   alias_add_object_like_definition(mangled, rhs, "<command-line>", 1, 1);
   free(mangled);
   free(copy);
}

static int alias_find_local(const char *key, int *owner_depth, int *param_index) {
   int masked_owner_depth = -1;

   if (alias_stack_top >= 0 && alias_stack[alias_stack_top].local_owner_depth >= 0) {
      masked_owner_depth = alias_stack[alias_stack_top].local_owner_depth;
   }

   for (int depth = alias_stack_top; depth >= 0; depth--) {
      if (depth == masked_owner_depth) {
         continue;
      }

      for (int i = 0; i < alias_stack[depth].local_count; i++) {
         if (!strcmp(alias_stack[depth].local_names[i], key)) {
            if (owner_depth) {
               *owner_depth = depth;
            }
            if (param_index) {
               *param_index = i;
            }
            return 1;
         }
      }
   }

   return 0;
}

static char *alias_build_local_virtual_filename(int owner_depth, int param_index) {
   char buf[1024];
   const char *param_name = alias_stack[owner_depth].local_names[param_index];
   const char *base = current_filename ? current_filename : "?";

   snprintf(buf, sizeof(buf),
            "<alias-param %s from %s>",
            param_name ? param_name : "?",
            base);

   return strdup(buf);
}

static void alias_push_text(const char *text,
                            int alias_index,
                            int local_owner_depth,
                            int local_param_index,
                            char *virtual_filename,
                            const char **local_names,
                            char **local_values,
                            int local_count) {
   if (alias_stack_top + 1 >= MAX_ALIAS_DEPTH) {
      LEX_RUNTIME_ERROR(NULL, "alias nesting too deep");
   }

   alias_stack_top++;
   alias_stack[alias_stack_top].alias_index = alias_index;
   alias_stack[alias_stack_top].local_owner_depth = local_owner_depth;
   alias_stack[alias_stack_top].local_param_index = local_param_index;
   alias_stack[alias_stack_top].virtual_filename = virtual_filename;
   alias_stack[alias_stack_top].saved_filename = current_filename;
   alias_stack[alias_stack_top].lineno = yylineno;
   alias_stack[alias_stack_top].column = yycolumn;
   alias_stack[alias_stack_top].start = YY_START;
   alias_stack[alias_stack_top].cond_depth = cond_stack_top;
   alias_stack[alias_stack_top].buffer = YY_CURRENT_BUFFER;
   alias_stack[alias_stack_top].local_names = local_names;
   alias_stack[alias_stack_top].local_values = local_values;
   alias_stack[alias_stack_top].local_count = local_count;

   yy_scan_string(text);

   BEGIN(0);
   current_filename = alias_stack[alias_stack_top].virtual_filename;
   yylineno = 1;
   yycolumn = 1;
}

static void alias_scan_string(int index) {
   if (index < 0 || index >= alias_count) {
      error_unreachable("bad internal alias index (%d).", index);
   }

   for (int i = 0; i <= alias_stack_top; i++) {
      if (alias_stack[i].alias_index == index) {
         LEX_ERROR_HERE("recursive alias expansion for '%s'", alias_entries[index].name);
      }
   }

   alias_push_text(alias_entries[index].rhs,
                   index,
                   -1,
                   -1,
                   alias_build_virtual_filename(&alias_entries[index]),
                   alias_entries[index].params,
                   NULL,
                   0);
}

static void alias_scan_local_binding(int owner_depth, int param_index) {
   if (owner_depth < 0 || owner_depth > alias_stack_top) {
      error_unreachable("bad local alias owner depth (%d).", owner_depth);
   }

   if (param_index < 0 || param_index >= alias_stack[owner_depth].local_count) {
      error_unreachable("bad local alias parameter index (%d).", param_index);
   }

   for (int i = 0; i <= alias_stack_top; i++) {
      if (alias_stack[i].local_owner_depth == owner_depth &&
          alias_stack[i].local_param_index == param_index) {
         LEX_ERROR_HERE("recursive alias parameter expansion for '%s'",
                        alias_stack[owner_depth].local_names[param_index]);
      }
   }

   alias_push_text(alias_stack[owner_depth].local_values[param_index],
                   -1,
                   owner_depth,
                   param_index,
                   alias_build_local_virtual_filename(owner_depth, param_index),
                   NULL,
                   NULL,
                   0);
}

static void alias_append_char(char **buf, size_t *len, size_t *cap, int c) {
   if (*cap == 0) {
      *cap = 64;
      *buf = malloc(*cap);
   }

   if (*len + 2 > *cap) {
      *cap *= 2;
      *buf = realloc(*buf, *cap);
   }

   (*buf)[(*len)++] = (char) c;
   (*buf)[*len] = 0;
}

static int alias_buffer_is_blank(const char *buf) {
   if (!buf) {
      return 1;
   }

   while (*buf) {
      if (!isspace((unsigned char)*buf)) {
         return 0;
      }
      buf++;
   }

   return 1;
}

static void alias_add_invocation_arg(char ***argv, int *argc, char *arg) {
   *argv = realloc(*argv, sizeof(char *) * (*argc + 1));
   (*argv)[*argc] = arg ? arg : strdup("");
   (*argc)++;
}

static int alias_read_char(void) {
   int c = input();

   if (c == '\n') {
      yylineno++;
      yycolumn = 1;
   }
   else if (c != EOF) {
      yycolumn++;
   }

   return c;
}

static void alias_collect_quoted(char quote, char **buf, size_t *len, size_t *cap) {
   for (;;) {
      int c = alias_read_char();

      if (c == EOF) {
         LEX_RUNTIME_ERROR(NULL, "unterminated quoted text in alias invocation");
      }

      alias_append_char(buf, len, cap, c);

      if (c == '\\') {
         c = alias_read_char();
         if (c == EOF) {
            LEX_RUNTIME_ERROR(NULL, "unterminated quoted text in alias invocation");
         }
         alias_append_char(buf, len, cap, c);
         continue;
      }

      if (c == quote) {
         return;
      }
   }
}

static char **alias_parse_invocation_args(const alias_entry *entry, int *out_argc) {
   char **argv = NULL;
   int argc = 0;
   char *current = NULL;
   size_t cur_len = 0;
   size_t cur_cap = 0;
   int depth = 0;
   int c;

   c = alias_read_char();
   if (c != '(') {
      alias_set_invoke_error_location();
      error_user("function-like alias '%s' must be invoked as %s(...)",
                 entry->name,
                 entry->name);
   }

   for (;;) {
      c = alias_read_char();
      if (c == EOF) {
         LEX_RUNTIME_ERROR(NULL, "unterminated invocation of alias '%s'", entry->name);
      }

      if (c == '\'' || c == '"') {
         alias_append_char(&current, &cur_len, &cur_cap, c);
         alias_collect_quoted((char) c, &current, &cur_len, &cur_cap);
         continue;
      }

      if (c == '(') {
         depth++;
         alias_append_char(&current, &cur_len, &cur_cap, c);
         continue;
      }

      if (c == ')') {
         if (depth > 0) {
            depth--;
            alias_append_char(&current, &cur_len, &cur_cap, c);
            continue;
         }

         if (argc == 0 && alias_buffer_is_blank(current)) {
            free(current);
            current = NULL;
         }
         else {
            alias_add_invocation_arg(&argv, &argc, current ? current : strdup(""));
            current = NULL;
         }
         break;
      }

      if (c == ',' && depth == 0) {
         alias_add_invocation_arg(&argv, &argc, current ? current : strdup(""));
         current = NULL;
         cur_len = 0;
         cur_cap = 0;
         continue;
      }

      alias_append_char(&current, &cur_len, &cur_cap, c);
   }

   if (argc != entry->param_count) {
      alias_set_invoke_error_location();
      error_user("alias '%s' expects %d argument%s but got %d",
                 entry->name,
                 entry->param_count,
                 entry->param_count == 1 ? "" : "s",
                 argc);
   }

   *out_argc = argc;
   return argv;
}

static void alias_invoke(int index) {
   char **argv = NULL;
   int argc = 0;

   if (index < 0 || index >= alias_count) {
      error_unreachable("bad internal alias index (%d).", index);
   }

   if (!alias_entries[index].is_function_like) {
      alias_scan_string(index);
      return;
   }

   alias_set_invoke_location();
   argv = alias_parse_invocation_args(&alias_entries[index], &argc);

   alias_push_text(alias_entries[index].rhs,
                   index,
                   -1,
                   -1,
                   alias_build_virtual_filename(&alias_entries[index]),
                   alias_entries[index].params,
                   argv,
                   argc);
}

static void pop_alias(void) {
   if (alias_stack_top < 0) {
      return;
   }

   pp_require_balanced_at_eof(alias_stack[alias_stack_top].cond_depth,
                              current_filename ? current_filename : "alias expansion");

   yy_delete_buffer(YY_CURRENT_BUFFER);
   yy_switch_to_buffer(alias_stack[alias_stack_top].buffer);

   current_filename = alias_stack[alias_stack_top].saved_filename;
   yylineno = alias_stack[alias_stack_top].lineno;
   yycolumn = alias_stack[alias_stack_top].column;
   BEGIN(alias_stack[alias_stack_top].start);

   if (alias_stack[alias_stack_top].local_values) {
      for (int i = 0; i < alias_stack[alias_stack_top].local_count; i++) {
         free(alias_stack[alias_stack_top].local_values[i]);
      }
      free(alias_stack[alias_stack_top].local_values);
   }

   free(alias_stack[alias_stack_top].virtual_filename);
   alias_stack_top--;
}

static void alias_append_rhs(const char *rhs) {
   char *clean_rhs;
   size_t clean_len;
   size_t old_len;

   clean_rhs = strip_trailing_comments_preserving_quotes(rhs);
   clean_len = strlen(clean_rhs);

   while (clean_len > 0 &&
          (clean_rhs[clean_len - 1] == ' ' ||
           clean_rhs[clean_len - 1] == '\t' ||
           clean_rhs[clean_len - 1] == '\r' ||
           clean_rhs[clean_len - 1] == '\f' ||
           clean_rhs[clean_len - 1] == '\v')) {
      clean_len--;
   }

   alias_rhs_continues = 0;
   if (clean_len > 0 && clean_rhs[clean_len - 1] == '\\') {
      alias_rhs_continues = 1;
      clean_len--;
   }

   old_len = alias_rhs ? strlen(alias_rhs) : 0;
   alias_rhs = realloc((char *)alias_rhs, old_len + clean_len + 1);
   memcpy((char *)alias_rhs + old_len, clean_rhs, clean_len);
   ((char *)alias_rhs)[old_len + clean_len] = 0;

   free(clean_rhs);
}

%}

%option nounput noyywrap

HEXINT    0[xX][0-9a-fA-F]((_)?[0-9a-fA-F])*
BININT    0[bB][01]((_)?[01])*
OCTINT    0[1-7]((_)?[0-7])*
DECINT    [1-9]((_)?[0-9])*
ZERO      0
INT       {HEXINT}|{BININT}|{OCTINT}|{DECINT}|{ZERO}

DECFLOAT  [0-9]((_)?[0-9])*(\.([0-9]((_)?[0-9])*)?)?([eE][+-]?[0-9]+)?
DOTFLOAT  \.[0-9]((_)?[0-9])*([eE][+-]?[0-9]+)?
HEXFLOAT  0[xX][0-9a-fA-F]((_)?[0-9a-fA-F_])*(\.([0-9a-fA-F]((_)?[0-9a-fA-F])*)?)?[pP][+-]?[0-9_]+
HOTFLOAT  0[xX]\.[0-9a-fA-F]((_)?[0-9a-fA-F])*[pP][+-]?[0-9_]+
FLOAT     {DECFLOAT}|{DOTFLOAT}|{HEXFLOAT}|{HOTFLOAT}

ANY_CHAR  [^'\\]
ESC_CHAR  \\[^xu]
HEX_CHAR  \\x[0-9a-fA-F]{2}
UNI_CHAR  \\u[0-9a-fA-F]{4}
CHAR      \'({ANY_CHAR}|{ESC_CHAR}|{HEX_CHAR}|{UNI_CHAR})\'

FLAG      \$[A-Za-z0-9_]+(:[A-Za-z0-9_]+)?

ANY_STR   [^\"\\]
ESC_STR   \\.
STRING    \"({ANY_STR}|{ESC_STR})*\"

IDENT     [a-zA-Z_\x80-\xff][a-zA-Z0-9_\x80-\xff]*

CBLOCK    \/\*([^*]|\*+[^*/])*\*+\/ 

%x ALIAS_NAME ALIAS_AFTER_NAME ALIAS_PARAMS ALIAS_PARAM_TAIL ALIAS_AFTER_PARAMS ALIAS_RHS PP_SKIP

%%

<INITIAL,PP_SKIP>^[ \t]*#[^\n]*\n? {
   int has_newline = yyleng > 0 && yytext[yyleng - 1] == '\n';
   char *directive_text;

   if (has_newline) {
      yytext[yyleng - 1] = 0;
   }

   directive_text = strip_trailing_comments_preserving_quotes(yytext);
   pp_handle_directive(directive_text);
   free(directive_text);

   if (has_newline) {
      yylineno++;
      yycolumn = 1;
   }

   BEGIN(pp_is_active() ? INITIAL : PP_SKIP);
}

"alias"[[:space:]]+        { alias_reset(); BEGIN(ALIAS_NAME); }

<ALIAS_NAME>[[:space:]]+   ;
<ALIAS_NAME>{IDENT}        { char *ident = mangle_identifier_utf8_or_die(yytext); alias_set_name(ident); free(ident); BEGIN(ALIAS_AFTER_NAME); }
<ALIAS_NAME>.|\n           { alias_error("expected alias name"); BEGIN(INITIAL); }

<ALIAS_AFTER_NAME>"("     { alias_mark_function_like(); BEGIN(ALIAS_PARAMS); }
<ALIAS_AFTER_NAME>\n      { alias_finish(); yylineno++; yycolumn = 1; BEGIN(INITIAL); }
<ALIAS_AFTER_NAME>[^\n]    { BEGIN(ALIAS_RHS); yyless(0); }

<ALIAS_PARAMS>[ \t\r\f\v]+ ;
<ALIAS_PARAMS>")"         { BEGIN(ALIAS_AFTER_PARAMS); }
<ALIAS_PARAMS>{IDENT}      { char *ident = mangle_identifier_utf8_or_die(yytext); alias_add_param(ident); free(ident); BEGIN(ALIAS_PARAM_TAIL); }
<ALIAS_PARAMS>.|\n        { alias_error("expected alias parameter name or ')'"); BEGIN(INITIAL); }

<ALIAS_PARAM_TAIL>[ \t\r\f\v]+ ;
<ALIAS_PARAM_TAIL>","     { BEGIN(ALIAS_PARAMS); }
<ALIAS_PARAM_TAIL>")"     { BEGIN(ALIAS_AFTER_PARAMS); }
<ALIAS_PARAM_TAIL>.|\n     { alias_error("expected ',' or ')' in alias parameter list"); BEGIN(INITIAL); }

<ALIAS_AFTER_PARAMS>[ \t\r\f\v]+ ;
<ALIAS_AFTER_PARAMS>\n     { alias_finish(); yylineno++; yycolumn = 1; BEGIN(INITIAL); }
<ALIAS_AFTER_PARAMS>[^\n]  { BEGIN(ALIAS_RHS); yyless(0); }

<ALIAS_RHS>\n              {
                             yylineno++;
                             yycolumn = 1;
                             if (alias_rhs_continues) {
                                alias_rhs_continues = 0;
                             }
                             else {
                                alias_finish();
                                BEGIN(INITIAL);
                             }
                          }
<ALIAS_RHS>[^\n]+          { alias_append_rhs(yytext); }

"break"         return BREAK;
"case"          return CASE;
"const"         return CONST;
"continue"      return CONTINUE;
"default"       return DEFAULT;
"do"            return DO;
"else"          return ELSE;
"enum"          return ENUM;
"extern"        return EXTERN;
"for"           return FOR;
"goto"          return GOTO;
"if"            return IF;
"include"       return INCLUDE;
"mem"           return MEM;
"ref"           return REF;
"return"        return RETURN;
"sizeof"        return SIZEOF;
"static"        return STATIC;
"struct"        return STRUCT;
"switch"        return SWITCH;
"to"            return TO;
"type"          return TYPE;
"union"         return UNION;
"while"         return WHILE;
"xform"         return XFORM;

operator(\{\}|==|!=|<=|>=|<<|>>|\+\+|--|[-+|^&<>\*/%~]) {
   LEX_ERROR_HERE("operator overloading is not supported");
}

"+="            return ADD_ASSIGN;
"&&"            return AND;
"&="            return AND_ASSIGN;
"->"            return ARROW;
":="            return ASSIGN;
"--"            return DEC;
"/="            return DIV_ASSIGN;
"=="            return EQ;
">="            return GE;
"++"            return INC;
"<="            return LE;
"<<"            return LSHIFT;
"<<="           return LSHIFT_ASSIGN;
"%="            return MOD_ASSIGN;
"*="            return MUL_ASSIGN;
"!="            return NE;
"||"            return OR;
"|="            return OR_ASSIGN;
">>"            return RSHIFT;
">>="           return RSHIFT_ASSIGN;
"-="            return SUB_ASSIGN;
"^="            return XOR_ASSIGN;
"..."           { LEX_ERROR_HERE("variadic declarations are not supported"); }
"$exactops"     { LEX_ERROR_HERE("$exactops is not supported"); }
"$$"            return DOLLAR_DOLLAR;

{FLAG} {
   yylval.str = strdup(yytext);
   return FLAG;
}

{CHAR} {
   yylval.str = strdup(yytext);
   return CHAR;
}

{STRING} {
   yylval.str = strdup(yytext + 1);
   yylval.str[strlen(yylval.str) - 1] = 0;
   // we do not process backslash escapes here.
   // that along with character set translation in xform.c
   return STRING;
}

{INT} {
   yylval.str = strip_underscores(yytext);
   return INTEGER;
}

{FLOAT} {
   error_user("[%s:%d.%d] floating-point literals are not supported", current_filename, yylineno, yycolumn);
}

{IDENT} {
   int owner_depth;
   int param_index;
   int i;
   char *ident = mangle_identifier_utf8_or_die(yytext);

   if (alias_find_local(ident, &owner_depth, &param_index)) {
      free(ident);
      alias_scan_local_binding(owner_depth, param_index);
   }
   else {
      i = alias_find(ident);
      if (i != -1) {
         free(ident);
         alias_invoke(i);
      }
      else {
         yylval.str = ident;
         lexer_register_token_location(ident);
         if (!strcmp(ident, "true") || !strcmp(ident, "false")) return INTEGER;
         if (xform_exists(ident)) return XFORMNAME;
         if (memname_exists(ident)) return MEMNAME;
         if (typename_exists(ident)) return TYPENAME;
         if (enumname_exists(ident)) return ENUMNAME;
         return IDENTIFIER;
      }
   }
}

{CBLOCK} {   // C style block comments
   int line = yylloc.first_line;
   int col = yylloc.first_column;

   for (char *p = yytext; *p; ) {
      if (*p == '\n') {
         line++;
         col = 0;
         p++;
      }
      else {
         unsigned char c = (unsigned char)*p;
         size_t advance = 0;
         unsigned int cp = 0;
         if (c >= 0x80 && identifier_utf8_decode_one((const unsigned char *)p, strlen(p), &advance, &cp)) {
            (void)cp;
            p += advance;
         }
         else {
            p++;
         }
         col++;
      }
   }

   yylineno = line;
   yycolumn = col;
}

"asm "[^;\n]* {
   yylval.str = strdup(yytext + 4);
   return ASM;
}

<PP_SKIP>[^\n]+               ;
<PP_SKIP>\n                  {
                                yylineno++;
                                yycolumn = 1;
                                if (pp_is_active()) {
                                   BEGIN(INITIAL);
                                }
                             }

\/\/[^\n]*                ;   // skip line comments

[ \t\r]+                  ;   // skip whitespace

[\n]                      {
                             yylineno++;
                             yycolumn = 1;
                             if (YY_START == PP_SKIP && pp_is_active()) {
                                BEGIN(INITIAL);
                             }
                          }

.                         return yytext[0]; // return single-character tokens

<<EOF>> {
   if (alias_stack_top >= 0) {
      pop_alias();
   }
   else if (file_stack_top >= 0) {
      pop_file();
   }
   else {
      pp_require_balanced_at_eof(-1, current_filename ? current_filename : "input");
      yyterminate();
   }
}

%%

/*
int yyparse_file(const char *filename) {
fprintf(stderr, "%s:%d\n", __FILE__, __LINE__);
   FILE *f = fopen(filename, "r");
   if (!f) {
      fprintf(stderr, "cannot open file: %s\n", filename);
      return 1;
   }

   YY_BUFFER_STATE buf = yy_create_buffer(f, YY_BUF_SIZE);
   yy_switch_to_buffer(buf);
   yylineno = 1;
   yycolumn = 1;
   current_filename = (char *)filename;

   int result = yyparse();

   yy_delete_buffer(buf);
   fclose(f);
   return result;
}
*/
