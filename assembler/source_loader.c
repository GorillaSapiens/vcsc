//! @file assembler/source_loader.c
//! @brief Implements assembler source loading for the n65 assembler.
//! @ingroup assembler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <limits.h>
#include "source_loader.h"
#include "util.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define INCLUDE_MAX_DEPTH 64
#define LINEBUF_SIZE      8192
#define MACRO_MAX_PARAMS  32
#define MACRO_MAX_DEPTH   64

typedef struct strlist {
   char **items;
   int count;
   int cap;
} strlist_t;

typedef struct macro_def {
   char *name;
   char *def_file;
   int def_line;
   char **params;
   int param_count;
   strlist_t body_lines;
   struct macro_def *next;
} macro_def_t;

typedef struct macro_table {
   macro_def_t *head;
   long next_expansion_id;
} macro_table_t;

typedef struct def_alias {
   char *name;
   char *replacement;
   char *def_file;
   int def_line;
   struct def_alias *next;
} def_alias_t;

typedef struct def_table {
   def_alias_t *head;
} def_table_t;

typedef struct expand_ctx {
   macro_table_t macros;
   def_table_t defs;
   int macro_depth;
} expand_ctx_t;

//! @brief Handle strlist init logic for assembler source/include loader.
static void strlist_init(strlist_t *lst)
{
   lst->items = NULL;
   lst->count = 0;
   lst->cap = 0;
}

//! @brief Release free storage owned by assembler source/include loader.
static void strlist_free(strlist_t *lst)
{
   int i;

   for (i = 0; i < lst->count; i++)
      free(lst->items[i]);

   free(lst->items);
   lst->items = NULL;
   lst->count = 0;
   lst->cap = 0;
}

//! @brief Handle strlist push logic for assembler source/include loader.
static void strlist_push(strlist_t *lst, const char *s)
{
   if (lst->count == lst->cap) {
      int new_cap;
      char **new_items;

      new_cap = lst->cap ? lst->cap * 2 : 8;
      new_items = (char **)realloc(lst->items, (size_t)new_cap * sizeof(lst->items[0]));
      if (!new_items) {
         fprintf(stderr, "out of memory\n");
         exit(1);
      }

      lst->items = new_items;
      lst->cap = new_cap;
   }

   lst->items[lst->count++] = xstrdup(s);
}

//! @brief Handle macro table init logic for assembler source/include loader.
static void macro_table_init(macro_table_t *tab)
{
   tab->head = NULL;
   tab->next_expansion_id = 1;
}

//! @brief Release table free storage owned by assembler source/include loader.
static void macro_table_free(macro_table_t *tab)
{
   macro_def_t *m;
   macro_def_t *next;
   int i;

   for (m = tab->head; m; m = next) {
      next = m->next;
      free(m->name);
      free(m->def_file);
      for (i = 0; i < m->param_count; i++)
         free(m->params[i]);
      free(m->params);
      strlist_free(&m->body_lines);
      free(m);
   }

   tab->head = NULL;
}

//! @brief Handle def table init logic for assembler source/include loader.
static void def_table_init(def_table_t *tab)
{
   tab->head = NULL;
}

//! @brief Release table free storage owned by assembler source/include loader.
static void def_table_free(def_table_t *tab)
{
   def_alias_t *d;
   def_alias_t *next;

   for (d = tab->head; d; d = next) {
      next = d->next;
      free(d->name);
      free(d->replacement);
      free(d->def_file);
      free(d);
   }

   tab->head = NULL;
}

//! @brief Return def find data used by assembler source/include loader; returned pointers alias existing storage unless explicitly allocated by the function name.
static def_alias_t *def_find(def_table_t *tab, const char *name)
{
   def_alias_t *d;

   for (d = tab->head; d; d = d->next) {
      if (!strcmp(d->name, name))
         return d;
   }

   return NULL;
}

//! @brief Handle def add logic for assembler source/include loader.
static int def_add(def_table_t *tab, const char *name, const char *replacement, const char *file, int line)
{
   def_alias_t *d;

   d = def_find(tab, name);
   if (d) {
      fprintf(stderr, "%s:%d: duplicate .def '%s' (first defined at %s:%d)\n",
              file, line, name, d->def_file, d->def_line);
      return 0;
   }

   d = (def_alias_t *)calloc(1, sizeof(*d));
   if (!d) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   d->name = xstrdup(name);
   d->replacement = xstrdup(replacement);
   d->def_file = xstrdup(file);
   d->def_line = line;
   d->next = tab->head;
   tab->head = d;
   return 1;
}

//! @brief Return macro find data used by assembler source/include loader; returned pointers alias existing storage unless explicitly allocated by the function name.
static macro_def_t *macro_find(macro_table_t *tab, const char *name)
{
   macro_def_t *m;

   for (m = tab->head; m; m = m->next) {
      if (!strcmp(m->name, name))
         return m;
   }

   return NULL;
}

//! @brief Return macro create data used by assembler source/include loader; returned pointers alias existing storage unless explicitly allocated by the function name.
static macro_def_t *macro_create(const char *name, const char *file, int line)
{
   macro_def_t *m;

   m = (macro_def_t *)calloc(1, sizeof(*m));
   if (!m) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   m->name = xstrdup(name);
   m->def_file = xstrdup(file);
   m->def_line = line;
   strlist_init(&m->body_lines);
   return m;
}

//! @brief Handle macro add logic for assembler source/include loader.
static void macro_add(macro_table_t *tab, macro_def_t *m)
{
   m->next = tab->head;
   tab->head = m;
}

//! @brief Copy the directory component of a path into a bounded buffer.
static void path_dirname(const char *path, char *out_dir, size_t out_sz)
{
   const char *slash;
   size_t len;

   slash = strrchr(path, '/');
   if (!slash) {
      snprintf(out_dir, out_sz, ".");
      return;
   }

   len = (size_t)(slash - path);
   if (len == 0)
      len = 1;

   if (len >= out_sz)
      len = out_sz - 1;

   memcpy(out_dir, path, len);
   out_dir[len] = '\0';
}

//! @brief Return whether path is absolute in assembler source/include loader.
static int path_is_absolute(const char *path)
{
   return path[0] == '/';
}

//! @brief Handle path join logic for assembler source/include loader.
static void path_join(const char *base_dir, const char *child, char *out_path, size_t out_sz)
{
   if (path_is_absolute(child)) {
      snprintf(out_path, out_sz, "%s", child);
      return;
   }

   if (!strcmp(base_dir, "."))
      snprintf(out_path, out_sz, "%s", child);
   else
      snprintf(out_path, out_sz, "%s/%s", base_dir, child);
}

static strlist_t g_include_dirs = { NULL, 0, 0 };

//! @brief Handle source loader add include dir logic for assembler source/include loader.
void source_loader_add_include_dir(const char *dir)
{
   strlist_push(&g_include_dirs, dir);
}

//! @brief Handle source loader clear include dirs logic for assembler source/include loader.
void source_loader_clear_include_dirs(void)
{
   strlist_free(&g_include_dirs);
}

//! @brief Compute include path and update assembler source/include loader state once prerequisite pass data is available.
static int resolve_include_path(const char *base_dir, const char *include_name, char *resolved_path, size_t resolved_path_sz)
{
   FILE *fp;

   if (path_is_absolute(include_name)) {
      snprintf(resolved_path, resolved_path_sz, "%s", include_name);
      return 1;
   }

   path_join(base_dir, include_name, resolved_path, resolved_path_sz);
   fp = fopen(resolved_path, "r");
   if (fp) {
      fclose(fp);
      return 1;
   }

   for (int i = 0; i < g_include_dirs.count; i++) {
      path_join(g_include_dirs.items[i], include_name, resolved_path, resolved_path_sz);
      fp = fopen(resolved_path, "r");
      if (fp) {
         fclose(fp);
         return 1;
      }
   }

   path_join(base_dir, include_name, resolved_path, resolved_path_sz);
   return 1;
}

//! @brief Return skip ws data used by assembler source/include loader; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *skip_ws(const char *p)
{
   while (*p == ' ' || *p == '\t' || *p == '\r')
      p++;
   return p;
}

//! @brief Return whether ident start applies in assembler source/include loader.
static int is_ident_start(int c)
{
   return isalpha(c) || c == '_' || c == '@' || c == '?';
}

//! @brief Return whether ident char applies in assembler source/include loader.
static int is_ident_char(int c)
{
   return isalnum(c) || c == '_' || c == '@' || c == '?';
}

//! @brief Emit marker for assembler source/include loader diagnostics or output files.
static int emit_marker(FILE *out_fp, const char *path, long line_no)
{
   return fprintf(out_fp, "@@FILE %ld %s\n", line_no, path) > 0;
}


//! @brief Handle rtrim inplace logic for assembler source/include loader.
static void rtrim_inplace(char *s)
{
   size_t n;

   n = strlen(s);
   while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r' || s[n - 1] == '\n'))
      s[--n] = '\0';
}

//! @brief Parse def line into the normalized representation used by assembler source/include loader.
static int parse_def_line(const char *line, char *name_out, size_t name_out_sz, char *repl_out, size_t repl_out_sz)
{
   const char *p;
   size_t n;

   p = skip_ws(line);
   if (strncmp(p, ".def", 4) != 0)
      return 0;

   p += 4;
   if (!isspace((unsigned char)*p))
      return 0;

   p = skip_ws(p);
   if (!is_ident_start((unsigned char)*p))
      return 0;

   n = 0;
   while (is_ident_char((unsigned char)*p) && n + 1 < name_out_sz)
      name_out[n++] = *p++;
   name_out[n] = '\0';

   if (n == 0)
      return 0;

   p = skip_ws(p);
   if (*p == '\0' || *p == '\n' || *p == '\r' || *p == ';')
      return 0;

   n = 0;
   while (*p && *p != '\n' && *p != '\r' && *p != ';') {
      if (n + 1 < repl_out_sz)
         repl_out[n++] = *p;
      p++;
   }
   repl_out[n] = '\0';
   rtrim_inplace(repl_out);

   return repl_out[0] != '\0';
}

//! @brief Handle rewrite with defs logic for assembler source/include loader.
static int rewrite_with_defs(def_table_t *defs, const char *line, char *out, size_t out_sz)
{
   size_t oi;
   size_t i;
   int in_string;

   oi = 0;
   in_string = 0;

   for (i = 0; line[i] != '\0' && oi + 2 < out_sz; ) {
      if (!in_string && line[i] == ';')
         break;

      if (line[i] == '"') {
         out[oi++] = line[i++];
         in_string = !in_string;
         continue;
      }

      if (!in_string && is_ident_start((unsigned char)line[i])) {
         char tok[512];
         size_t ti;
         def_alias_t *d;

         ti = 0;
         while (is_ident_char((unsigned char)line[i]) && ti + 1 < sizeof(tok))
            tok[ti++] = line[i++];
         tok[ti] = '\0';

         d = def_find(defs, tok);
         if (d) {
            size_t len = strlen(d->replacement);
            if (oi + len + 1 >= out_sz)
               return 0;
            memcpy(out + oi, d->replacement, len);
            oi += len;
         } else {
            if (oi + ti + 1 >= out_sz)
               return 0;
            memcpy(out + oi, tok, ti);
            oi += ti;
         }
         continue;
      }

      out[oi++] = line[i++];
   }

   if (!in_string) {
      while (line[i] != '\0') {
         if (oi + 2 >= out_sz)
            return 0;
         out[oi++] = line[i++];
      }
   }

   out[oi] = '\0';
   return 1;
}

//! @brief Parse addrsize keyword into the normalized representation used by assembler source/include loader.
static int parse_addrsize_keyword(const char *text, size_t len)
{
   if (len == 2 && !strncasecmp(text, "zp", 2))
      return 1;
   if (len == 8 && !strncasecmp(text, "zeropage", 8))
      return 1;
   return 0;
}

//! @brief Handle maybe emit addrsize directive logic for assembler source/include loader.
static int maybe_emit_addrsize_directive(FILE *out_fp, const char *line)
{
   const char *p;
   const char *dir_start;
   const char *comment_start;
   char indent[256];
   char dir[32];
   int indent_len;
   int dir_len;
   int emitted;

   p = line;
   indent_len = 0;
   while (*p == ' ' || *p == '\t') {
      if (indent_len + 1 < (int)sizeof(indent))
         indent[indent_len++] = *p;
      p++;
   }
   indent[indent_len] = '\0';

   dir_start = p;
   while (*p && !isspace((unsigned char)*p))
      p++;
   dir_len = (int)(p - dir_start);
   if (dir_len <= 0 || dir_len >= (int)sizeof(dir))
      return 0;

   memcpy(dir, dir_start, (size_t)dir_len);
   dir[dir_len] = '\0';

   if (strcmp(dir, ".global") && strcmp(dir, ".import") && strcmp(dir, ".export"))
      return 0;

   while (*p == ' ' || *p == '\t')
      p++;

   comment_start = p;
   while (*comment_start && *comment_start != ';' && *comment_start != '\n' && *comment_start != '\r')
      comment_start++;

   emitted = 0;
   while (p < comment_start) {
      const char *name_start;
      const char *name_end;
      int is_zp;

      while (p < comment_start && isspace((unsigned char)*p))
         p++;
      if (p >= comment_start)
         break;

      if (!is_ident_start((unsigned char)*p))
         return 0;
      name_start = p;
      p++;
      while (p < comment_start && is_ident_char((unsigned char)*p))
         p++;
      name_end = p;

      while (p < comment_start && isspace((unsigned char)*p))
         p++;

      is_zp = 0;
      if (p < comment_start && *p == ':') {
         const char *kw_start;
         const char *kw_end;

         p++;
         while (p < comment_start && isspace((unsigned char)*p))
            p++;
         if (p >= comment_start || !is_ident_start((unsigned char)*p))
            return 0;

         kw_start = p;
         p++;
         while (p < comment_start && is_ident_char((unsigned char)*p))
            p++;
         kw_end = p;

         if (!parse_addrsize_keyword(kw_start, (size_t)(kw_end - kw_start)))
            return 0;

         is_zp = 1;
         while (p < comment_start && isspace((unsigned char)*p))
            p++;
      }

      if (fprintf(out_fp, "%s.%s%s ", indent, dir + 1, is_zp ? "zp" : "") < 0)
         return -1;
      if (fwrite(name_start, 1, (size_t)(name_end - name_start), out_fp) != (size_t)(name_end - name_start))
         return -1;
      if (*comment_start == ';' && !emitted) {
         if (fputc(' ', out_fp) == EOF)
            return -1;
         if (fputs(comment_start, out_fp) == EOF)
            return -1;
      } else if (fputc('\n', out_fp) == EOF) {
         return -1;
      }

      emitted = 1;
      while (p < comment_start && isspace((unsigned char)*p))
         p++;
      if (p >= comment_start)
         break;
      if (*p != ',')
         return 0;
      p++;
   }

   return emitted;
}

//! @brief Emit normalized line for assembler source/include loader diagnostics or output files.
static int emit_normalized_line(FILE *out_fp, def_table_t *defs, const char *line)
{
   int rc;
   char rewritten[LINEBUF_SIZE * 4];

   if (!rewrite_with_defs(defs, line, rewritten, sizeof(rewritten)))
      return 0;

   rc = maybe_emit_addrsize_directive(out_fp, rewritten);
   if (rc < 0)
      return 0;
   if (rc > 0)
      return 1;

   if (fputs(rewritten, out_fp) == EOF)
      return 0;
   if (rewritten[0] == '\0' || rewritten[strlen(rewritten) - 1] != '\n') {
      if (fputc('\n', out_fp) == EOF)
         return 0;
   }
   return 1;
}

//! @brief Parse include line into the normalized representation used by assembler source/include loader.
static int parse_include_line(const char *line, char *included_path, size_t included_path_sz)
{
   const char *p;
   const char *start;
   size_t len;

   p = skip_ws(line);

   if (strncmp(p, ".include", 8) != 0)
      return 0;

   p += 8;
   if (!isspace((unsigned char)*p))
      return 0;

   p = skip_ws(p);
   if (*p != '"')
      return 0;

   p++;
   start = p;

   while (*p && *p != '"' && *p != '\n' && *p != '\r')
      p++;

   if (*p != '"')
      return 0;

   len = (size_t)(p - start);
   if (len == 0 || len >= included_path_sz)
      return 0;

   memcpy(included_path, start, len);
   included_path[len] = '\0';

   p++;
   p = skip_ws(p);

   if (*p == ';') {
      while (*p && *p != '\n')
         p++;
   }

   p = skip_ws(p);
   return *p == '\0' || *p == '\n';
}

//! @brief Parse macro header into the normalized representation used by assembler source/include loader.
static int parse_macro_header(const char *line,
                              char *name_out,
                              size_t name_out_sz,
                              char ***params_out,
                              int *param_count_out)
{
   const char *p;
   char **params;
   int param_count;
   char ident[256];

   p = skip_ws(line);
   if (strncasecmp(p, "MACRO", 5) != 0)
      return 0;

   p += 5;
   if (!isspace((unsigned char)*p))
      return 0;

   p = skip_ws(p);
   if (!is_ident_start((unsigned char)*p))
      return 0;

   {
      size_t n = 0;
      while (is_ident_char((unsigned char)*p) && n + 1 < sizeof(ident))
         ident[n++] = *p++;
      ident[n] = '\0';
   }

   if (strlen(ident) >= name_out_sz)
      return 0;
   strcpy(name_out, ident);

   params = NULL;
   param_count = 0;

   p = skip_ws(p);
   if (*p == ';' || *p == '\0' || *p == '\n' || *p == '\r') {
      *params_out = NULL;
      *param_count_out = 0;
      return 1;
   }

   while (*p && *p != '\n' && *p != '\r' && *p != ';') {
      char param[256];
      size_t n = 0;
      char **new_params;

      p = skip_ws(p);
      if (!is_ident_start((unsigned char)*p))
         break;

      while (is_ident_char((unsigned char)*p) && n + 1 < sizeof(param))
         param[n++] = *p++;
      param[n] = '\0';

      new_params = (char **)realloc(params, (size_t)(param_count + 1) * sizeof(params[0]));
      if (!new_params) {
         fprintf(stderr, "out of memory\n");
         exit(1);
      }
      params = new_params;
      params[param_count++] = xstrdup(param);

      p = skip_ws(p);
      if (*p == ',') {
         p++;
         continue;
      }
      break;
   }

   *params_out = params;
   *param_count_out = param_count;
   return 1;
}

//! @brief Return whether endm line applies in assembler source/include loader.
static int is_endm_line(const char *line)
{
   const char *p;

   p = skip_ws(line);
   if (strncasecmp(p, "ENDM", 4) != 0)
      return 0;

   p += 4;
   p = skip_ws(p);
   return *p == '\0' || *p == '\n' || *p == '\r' || *p == ';';
}

//! @brief Parse invocation into the normalized representation used by assembler source/include loader.
static int parse_invocation(const char *line,
                            char *name_out,
                            size_t name_out_sz,
                            strlist_t *args_out)
{
   const char *p;
   char ident[256];

   strlist_init(args_out);

   p = skip_ws(line);
   if (!is_ident_start((unsigned char)*p))
      return 0;

   {
      size_t n = 0;
      while (is_ident_char((unsigned char)*p) && n + 1 < sizeof(ident))
         ident[n++] = *p++;
      ident[n] = '\0';
   }

   if (strlen(ident) >= name_out_sz)
      return 0;
   strcpy(name_out, ident);

   p = skip_ws(p);
   if (*p == '\0' || *p == '\n' || *p == '\r' || *p == ';')
      return 1;

   while (*p && *p != '\n' && *p != '\r') {
      const char *start;
      const char *end;
      int depth;
      size_t len;
      char *arg;

      p = skip_ws(p);
      if (*p == ';' || *p == '\0' || *p == '\n' || *p == '\r')
         break;

      start = p;
      end = p;
      depth = 0;

      while (*end && *end != '\n' && *end != '\r') {
         if (*end == ';' && depth == 0)
            break;
         if (*end == '(')
            depth++;
         else if (*end == ')' && depth > 0)
            depth--;
         else if (*end == ',' && depth == 0)
            break;
         end++;
      }

      while (end > start && (end[-1] == ' ' || end[-1] == '\t'))
         end--;

      len = (size_t)(end - start);
      arg = (char *)malloc(len + 1);
      if (!arg) {
         fprintf(stderr, "out of memory\n");
         exit(1);
      }

      memcpy(arg, start, len);
      arg[len] = '\0';
      strlist_push(args_out, arg);
      free(arg);

      p = end;
      if (*p == ',')
         p++;
      else
         break;
   }

   return 1;
}

//! @brief Return param lookup data used by assembler source/include loader; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *param_lookup(const macro_def_t *m, const strlist_t *args, const char *name)
{
   int i;

   for (i = 0; i < m->param_count; i++) {
      if (!strcmp(m->params[i], name)) {
         if (i < args->count)
            return args->items[i];
         return "";
      }
   }

   return NULL;
}

//! @brief Return rewrite macro line data used by assembler source/include loader; returned pointers alias existing storage unless explicitly allocated by the function name.
static char *rewrite_macro_line(const macro_def_t *m,
                                const strlist_t *args,
                                const char *line,
                                long expansion_id)
{
   char out[LINEBUF_SIZE * 2];
   size_t oi;
   size_t i;

   oi = 0;

   for (i = 0; line[i] != '\0' && oi + 2 < sizeof(out); ) {
      if (is_ident_start((unsigned char)line[i])) {
         char tok[512];
         size_t ti;
         const char *subst;

         ti = 0;
         while (is_ident_char((unsigned char)line[i]) && ti + 1 < sizeof(tok))
            tok[ti++] = line[i++];
         tok[ti] = '\0';

         if (tok[0] == '@') {
            char local_buf[1024];
            snprintf(local_buf, sizeof(local_buf), "@__M%ld_%s", expansion_id, tok + 1);
            subst = local_buf;

            if (oi + strlen(subst) + 1 >= sizeof(out))
               break;
            memcpy(out + oi, subst, strlen(subst));
            oi += strlen(subst);
         } else {
            subst = param_lookup(m, args, tok);
            if (!subst)
               subst = tok;

            if (oi + strlen(subst) + 1 >= sizeof(out))
               break;
            memcpy(out + oi, subst, strlen(subst));
            oi += strlen(subst);
         }
      } else {
         out[oi++] = line[i++];
      }
   }

   out[oi] = '\0';
   return xstrdup(out);
}

static int expand_text_lines(expand_ctx_t *ctx,
                             const char *logical_file,
                             int logical_line,
                             const strlist_t *lines,
                             FILE *out_fp);

//! @brief Handle expand macro invocation logic for assembler source/include loader.
static int expand_macro_invocation(expand_ctx_t *ctx,
                                   const macro_def_t *m,
                                   const strlist_t *args,
                                   const char *invoke_file,
                                   int invoke_line,
                                   FILE *out_fp)
{
   strlist_t rewritten;
   int i;
   long expansion_id;
   int ok;

   if (ctx->macro_depth >= MACRO_MAX_DEPTH) {
      fprintf(stderr, "%s:%d: macro expansion too deep\n", invoke_file, invoke_line);
      return 0;
   }

   if (args->count != m->param_count) {
      fprintf(stderr,
              "%s:%d: macro '%s' expects %d args, got %d\n",
              invoke_file, invoke_line, m->name, m->param_count, args->count);
      return 0;
   }

   expansion_id = ctx->macros.next_expansion_id++;
   strlist_init(&rewritten);

   /*
      Macro expansion is done before lexing/parsing for the same reason as
      .include: it keeps the real assembler simple.

      Parameters are substituted on identifier boundaries, and macro-local
      labels beginning with '@' are renamed uniquely per expansion so repeated
      macro calls do not collide.
   */
   for (i = 0; i < m->body_lines.count; i++) {
      char *rw;

      rw = rewrite_macro_line(m, args, m->body_lines.items[i], expansion_id);
      strlist_push(&rewritten, rw);
      free(rw);
   }

   ctx->macro_depth++;
   ok = expand_text_lines(ctx, invoke_file, invoke_line, &rewritten, out_fp);
   ctx->macro_depth--;

   strlist_free(&rewritten);
   return ok;
}

//! @brief Handle expand text lines logic for assembler source/include loader.
static int expand_text_lines(expand_ctx_t *ctx,
                             const char *logical_file,
                             int logical_line,
                             const strlist_t *lines,
                             FILE *out_fp)
{
   int i;

   for (i = 0; i < lines->count; i++) {
      char name[256];
      strlist_t args;
      macro_def_t *m;
      int this_line;

      this_line = logical_line + i;

      if (!emit_marker(out_fp, logical_file, this_line))
         return 0;

      if (!parse_invocation(lines->items[i], name, sizeof(name), &args))
         name[0] = '\0';

      m = name[0] ? macro_find(&ctx->macros, name) : NULL;
      if (m) {
         if (!expand_macro_invocation(ctx, m, &args, logical_file, this_line, out_fp)) {
            strlist_free(&args);
            return 0;
         }
         strlist_free(&args);
         continue;
      }

      strlist_free(&args);

      if (!emit_normalized_line(out_fp, &ctx->defs, lines->items[i]))
         return 0;
   }

   return 1;
}

//! @brief Read macro definition from the current input position and advance the reader on success.
static int read_macro_definition(FILE *in_fp,
                                 expand_ctx_t *ctx,
                                 const char *cur_file,
                                 int *line_no_io,
                                 const char *macro_name,
                                 char **params,
                                 int param_count)
{
   char line[LINEBUF_SIZE];
   macro_def_t *m;

   if (macro_find(&ctx->macros, macro_name)) {
      fprintf(stderr, "%s:%d: duplicate macro '%s'\n", cur_file, *line_no_io, macro_name);
      for (int i = 0; i < param_count; i++)
         free(params[i]);
      free(params);
      return 0;
   }

   m = macro_create(macro_name, cur_file, *line_no_io);
   m->params = params;
   m->param_count = param_count;

   while (fgets(line, sizeof(line), in_fp) != NULL) {
      (*line_no_io)++;

      if (is_endm_line(line)) {
         macro_add(&ctx->macros, m);
         return 1;
      }

      strlist_push(&m->body_lines, line);
   }

   fprintf(stderr, "%s:%d: unterminated MACRO '%s'\n", cur_file, m->def_line, m->name);
   return 0;
}

//! @brief Handle expand file recursive logic for assembler source/include loader.
static int expand_file_recursive(expand_ctx_t *ctx,
                                 const char *path,
                                 FILE *out_fp,
                                 int depth)
{
   FILE *in_fp;
   char line[LINEBUF_SIZE];
   char base_dir[PATH_MAX];
   char include_name[PATH_MAX];
   int line_no;

   if (depth > INCLUDE_MAX_DEPTH) {
      fprintf(stderr, "include nesting too deep near %s\n", path);
      return 0;
   }

   in_fp = fopen(path, "r");
   if (!in_fp) {
      perror(path);
      return 0;
   }

   path_dirname(path, base_dir, sizeof(base_dir));
   line_no = 0;

   while (fgets(line, sizeof(line), in_fp) != NULL) {
      char macro_name[256];
      char **params;
      int param_count;
      char invoke_name[256];
      strlist_t invoke_args;
      macro_def_t *m;

      line_no++;

      if (parse_include_line(line, include_name, sizeof(include_name))) {
         char include_path[PATH_MAX];

         resolve_include_path(base_dir, include_name, include_path, sizeof(include_path));
         if (!expand_file_recursive(ctx, include_path, out_fp, depth + 1)) {
            fclose(in_fp);
            return 0;
         }
         continue;
      }

      {
         char def_name[256];
         char def_repl[LINEBUF_SIZE];

         if (parse_def_line(line, def_name, sizeof(def_name), def_repl, sizeof(def_repl))) {
            if (!def_add(&ctx->defs, def_name, def_repl, path, line_no)) {
               fclose(in_fp);
               return 0;
            }
            continue;
         }
      }

      params = NULL;
      param_count = 0;
      if (parse_macro_header(line, macro_name, sizeof(macro_name), &params, &param_count)) {
         if (!read_macro_definition(in_fp, ctx, path, &line_no, macro_name, params, param_count)) {
            fclose(in_fp);
            return 0;
         }
         continue;
      }

      if (parse_invocation(line, invoke_name, sizeof(invoke_name), &invoke_args)) {
         m = macro_find(&ctx->macros, invoke_name);
         if (m) {
            if (!emit_marker(out_fp, path, line_no)) {
               strlist_free(&invoke_args);
               fclose(in_fp);
               return 0;
            }

            if (!expand_macro_invocation(ctx, m, &invoke_args, path, line_no, out_fp)) {
               strlist_free(&invoke_args);
               fclose(in_fp);
               return 0;
            }

            strlist_free(&invoke_args);
            continue;
         }
         strlist_free(&invoke_args);
      }

      if (!emit_marker(out_fp, path, line_no)) {
         fclose(in_fp);
         return 0;
      }

      if (!emit_normalized_line(out_fp, &ctx->defs, line)) {
         fprintf(stderr, "write error while expanding input\n");
         fclose(in_fp);
         return 0;
      }
   }

   fclose(in_fp);
   return 1;
}

//! @brief Return source loader open expanded data used by assembler source/include loader; returned pointers alias existing storage unless explicitly allocated by the function name.
FILE *source_loader_open_expanded_with_defines(const char *root_path, const char *const *defines, int define_count)
{
   FILE *tmp_fp;
   expand_ctx_t ctx;
   int i;

   tmp_fp = tmpfile();
   if (!tmp_fp) {
      perror("tmpfile");
      return NULL;
   }

   macro_table_init(&ctx.macros);
   def_table_init(&ctx.defs);
   ctx.macro_depth = 0;

   for (i = 0; i < define_count; i++) {
      if (!emit_marker(tmp_fp, "<command-line>", i + 1) ||
          fputs(defines[i], tmp_fp) == EOF ||
          fputc('\n', tmp_fp) == EOF) {
         fprintf(stderr, "write error while expanding command-line definitions\n");
         macro_table_free(&ctx.macros);
         def_table_free(&ctx.defs);
         source_loader_clear_include_dirs();
         fclose(tmp_fp);
         return NULL;
      }
   }

   if (!expand_file_recursive(&ctx, root_path, tmp_fp, 0)) {
      macro_table_free(&ctx.macros);
      def_table_free(&ctx.defs);
      source_loader_clear_include_dirs();
      fclose(tmp_fp);
      return NULL;
   }

   macro_table_free(&ctx.macros);
   def_table_free(&ctx.defs);
   source_loader_clear_include_dirs();
   rewind(tmp_fp);
   return tmp_fp;
}

FILE *source_loader_open_expanded(const char *root_path)
{
   return source_loader_open_expanded_with_defines(root_path, NULL, 0);
}
