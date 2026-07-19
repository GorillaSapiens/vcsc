//! @file assembler/asm_state.c
//! @brief Implements assembler state management for the VCSC assembler.
//! @ingroup assembler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdarg.h>
#include "asm_state.h"
#include "util.h"

//! @brief Emit loc for assembler symbol, scope, and segment state diagnostics or output files.
static void print_loc(FILE *fp, const stmt_t *stmt)
{
   fprintf(fp, "%s:%d", stmt->file ? stmt->file : "<input>", stmt->line);
}

//! @brief Handle asm error logic for assembler symbol, scope, and segment state.
void asm_error(asm_context_t *ctx, const stmt_t *stmt, const char *fmt, ...)
{
   va_list ap;

   ctx->error_count++;

   print_loc(stderr, stmt);
   fprintf(stderr, ": ");

   va_start(ap, fmt);
   vfprintf(stderr, fmt, ap);
   va_end(ap);

   fprintf(stderr, "\n");
}

//! @brief Handle asm warning logic for assembler symbol, scope, and segment state.
void asm_warning(const stmt_t *stmt, const char *fmt, ...)
{
   va_list ap;

   print_loc(stderr, stmt);
   fprintf(stderr, ": warning: ");

   va_start(ap, fmt);
   vfprintf(stderr, fmt, ap);
   va_end(ap);

   fprintf(stderr, "\n");
}

//! @brief Return unquote string data used by assembler symbol, scope, and segment state; returned pointers alias existing storage unless explicitly allocated by the function name.
static char *unquote_string(const char *s)
{
   size_t n;
   char *out;

   if (!s)
      return NULL;

   n = strlen(s);
   if (n >= 2 && s[0] == '"' && s[n - 1] == '"') {
      out = (char *)malloc(n - 2 + 1);
      if (!out) {
         fprintf(stderr, "out of memory\n");
         exit(1);
      }
      memcpy(out, s + 1, n - 2);
      out[n - 2] = '\0';
      return out;
   }

   return xstrdup(s);
}
//! @brief Release imports storage owned by assembler symbol, scope, and segment state.
static void free_imports(import_name_t *head)
{
   import_name_t *p;
   import_name_t *next;

   for (p = head; p; p = next) {
      next = p->next;
      free(p->name);
      free(p);
   }
}

//! @brief Find import in assembler symbol, scope, and segment state tables without transferring ownership.
static import_name_t *find_import(asm_context_t *ctx, const char *name)
{
   import_name_t *p;

   for (p = ctx->imports; p; p = p->next) {
      if (!strcmp(p->name, name))
         return p;
   }

   return NULL;
}

//! @brief Find import const in assembler symbol, scope, and segment state tables without transferring ownership.
static const import_name_t *find_import_const(const asm_context_t *ctx, const char *name)
{
   const import_name_t *p;

   for (p = ctx->imports; p; p = p->next) {
      if (!strcmp(p->name, name))
         return p;
   }

   return NULL;
}

//! @brief Return whether import is zero-page in assembler symbol, scope, and segment state.
int import_is_zp(const asm_context_t *ctx, const char *name)
{
   const import_name_t *p = find_import_const(ctx, name);
   return p ? p->addr_size_zp : 0;
}

//! @brief Release weaks storage owned by assembler symbol, scope, and segment state.
static void free_weaks(weak_name_t *head)
{
   weak_name_t *p;
   weak_name_t *next;

   for (p = head; p; p = next) {
      next = p->next;
      free(p->name);
      free(p);
   }
}

//! @brief Find weak in assembler symbol, scope, and segment state tables without transferring ownership.
static weak_name_t *find_weak(asm_context_t *ctx, const char *name)
{
   weak_name_t *p;

   for (p = ctx->weaks; p; p = p->next) {
      if (!strcmp(p->name, name))
         return p;
   }

   return NULL;
}

//! @brief Handle asm add weak logic for assembler symbol, scope, and segment state.
void asm_add_weak(asm_context_t *ctx, const stmt_t *stmt, const char *name)
{
   weak_name_t *p;

   p = find_weak(ctx, name);
   if (p)
      return;

   p = (weak_name_t *)calloc(1, sizeof(*p));
   if (!p) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   p->name = xstrdup(name);
   p->file = stmt->file;
   p->line = stmt->line;
   p->next = ctx->weaks;
   ctx->weaks = p;
}

//! @brief Return whether asm symbol is weak in assembler symbol, scope, and segment state.
int asm_symbol_is_weak(const asm_context_t *ctx, const char *name)
{
   const weak_name_t *p;

   for (p = ctx->weaks; p; p = p->next) {
      if (!strcmp(p->name, name))
         return 1;
   }

   return 0;
}

//! @brief Handle directive name implies zero-page logic for assembler symbol, scope, and segment state.
static int directive_name_implies_zp(const char *name)
{
   return name && (!strcmp(name, ".importzp") || !strcmp(name, ".exportzp") || !strcmp(name, ".globalzp") ||
                   !strcmp(name, ".zpimport") || !strcmp(name, ".zpexport") || !strcmp(name, ".zpglobal"));
}

//! @brief Return whether directive is import family in assembler symbol, scope, and segment state.
static int directive_is_import_family(const char *name)
{
   return name && (!strcmp(name, ".import") || !strcmp(name, ".importzp") || !strcmp(name, ".global") || !strcmp(name, ".globalzp") ||
                   !strcmp(name, ".zpimport") || !strcmp(name, ".zpglobal"));
}

//! @brief Return whether directive is export family in assembler symbol, scope, and segment state.
static int directive_is_export_family(const char *name)
{
   return name && (!strcmp(name, ".global") || !strcmp(name, ".globalzp") || !strcmp(name, ".export") || !strcmp(name, ".exportzp") ||
                   !strcmp(name, ".zpglobal") || !strcmp(name, ".zpexport"));
}

//! @brief Add import to assembler symbol, scope, and segment state state, growing storage or preserving uniqueness as needed.
static void add_import(asm_context_t *ctx, const stmt_t *stmt, const char *name, int addr_size_zp)
{
   import_name_t *p;

   p = find_import(ctx, name);
   if (p) {
      if (addr_size_zp)
         p->addr_size_zp = 1;
      return;
   }

   p = (import_name_t *)calloc(1, sizeof(*p));
   if (!p) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   p->name = xstrdup(name);
   p->file = stmt->file;
   p->line = stmt->line;
   p->addr_size_zp = addr_size_zp ? 1 : 0;
   p->next = ctx->imports;
   ctx->imports = p;
}

//! @brief Handle segment name matches logic for assembler symbol, scope, and segment state.
static int segment_name_matches(const char *name, const char *base)
{
   size_t n;

   if (!name || !base)
      return 0;

   n = strlen(base);
   return strncasecmp(name, base, n) == 0 && (name[n] == '\0' || name[n] == '.');
}

//! @brief Handle segment name to o65 logic for assembler symbol, scope, and segment state.
int segment_name_to_o65(const char *name)
{
   if (!name || !strcasecmp(name, DEFAULT_SEGMENT_NAME) || segment_name_matches(name, "TEXT") || segment_name_matches(name, "CODE") || segment_name_matches(name, "RODATA"))
      return O65_SEG_TEXT;
   if (segment_name_matches(name, "DATA"))
      return O65_SEG_DATA;
   if (segment_name_matches(name, "BSS"))
      return O65_SEG_BSS;
   if (segment_name_matches(name, "ZP") || segment_name_matches(name, "ZEROPAGE") || segment_name_matches(name, "ZERO"))
      return O65_SEG_ZP;
   return O65_SEG_TEXT;
}

//! @brief Return segment find data used by assembler symbol, scope, and segment state; returned pointers alias existing storage unless explicitly allocated by the function name.
asm_segment_t *segment_find(asm_context_t *ctx, const char *name)
{
   asm_segment_t *seg;

   for (seg = ctx->segments; seg; seg = seg->next) {
      if (!strcmp(seg->name, name))
         return seg;
   }

   return NULL;
}

//! @brief Return segment get or create data used by assembler symbol, scope, and segment state; returned pointers alias existing storage unless explicitly allocated by the function name.
static asm_segment_t *segment_get_or_create(asm_context_t *ctx, const char *name)
{
   asm_segment_t *seg;

   seg = segment_find(ctx, name);
   if (seg)
      return seg;

   seg = (asm_segment_t *)calloc(1, sizeof(*seg));
   if (!seg) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   seg->name = xstrdup(name);
   seg->base = 0;
   seg->size = 0x10000L;
   seg->pc = 0;
   seg->used_size = 0;
   seg->rorg_active = 0;
   seg->rorg_pc = 0;
   seg->defined = 0;
   seg->overflow_warned = 0;
   seg->next = ctx->segments;
   ctx->segments = seg;
   return seg;
}

//! @brief Release segments storage owned by assembler symbol, scope, and segment state.
static void free_segments(asm_segment_t *head)
{
   asm_segment_t *seg;
   asm_segment_t *next;

   for (seg = head; seg; seg = next) {
      next = seg->next;
      free(seg->name);
      free(seg);
   }
}

//! @brief Handle reset segment pcs logic for assembler symbol, scope, and segment state.
void reset_segment_pcs(asm_context_t *ctx)
{
   asm_segment_t *seg;

   for (seg = ctx->segments; seg; seg = seg->next) {
      seg->pc = 0;
      seg->rorg_active = 0;
      seg->rorg_pc = 0;
      seg->overflow_warned = 0;
   }
}

//! @brief Collect segment used sizes from existing assembler symbol, scope, and segment state state for a later pass.
void snapshot_segment_used_sizes(asm_context_t *ctx)
{
   asm_segment_t *seg;

   for (seg = ctx->segments; seg; seg = seg->next)
      seg->used_size = seg->pc;
}

//! @brief Handle ensure default segment logic for assembler symbol, scope, and segment state.
void ensure_default_segment(asm_context_t *ctx)
{
   asm_segment_t *seg;

   seg = segment_get_or_create(ctx, DEFAULT_SEGMENT_NAME);
   seg->base = 0;
   seg->size = 0x10000L;
   seg->defined = 1;
}



//! @brief Return whether local name applies in assembler symbol, scope, and segment state.
static int is_local_name(const char *name)
{
   return name && name[0] == '@';
}

//! @brief Create scoped name for assembler symbol, scope, and segment state. The returned storage is owned by the caller or the object that immediately records it.
static char *make_scoped_name(const char *scope, const char *name)
{
   char buf[4096];

   snprintf(buf, sizeof(buf), "%s::%s", scope ? scope : "__root__", name);
   return xstrdup(buf);
}

//! @brief Create file scoped name for assembler symbol, scope, and segment state. The returned storage is owned by the caller or the object that immediately records it.
static char *make_file_scoped_name(const char *file, const char *name)
{
   char buf[4096];

   snprintf(buf, sizeof(buf), "%s::%s", file ? file : "<input>", name);
   return xstrdup(buf);
}

//! @brief Return whether global label name applies in assembler symbol, scope, and segment state.
static int is_global_label_name(const char *name)
{
   return name && !is_local_name(name);
}

//! @brief Return whether directive expr is ident in assembler symbol, scope, and segment state.
static int directive_expr_is_ident(const expr_t *expr, const char **name_out)
{
   if (!expr || expr->kind != EXPR_IDENT)
      return 0;

   *name_out = expr->u.ident;
   return 1;
}

//! @brief Return proc decl name data used by assembler symbol, scope, and segment state; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *proc_decl_name(const stmt_t *stmt)
{
   const char *name;

   if (!stmt || stmt->kind != STMT_DIR || !stmt->u.dir)
      return NULL;
   if (strcmp(stmt->u.dir->name, ".proc"))
      return NULL;
   if (!stmt->u.dir->exprs || stmt->u.dir->exprs->next)
      return NULL;
   if (!directive_expr_is_ident(stmt->u.dir->exprs->expr, &name))
      return NULL;
   return name;
}

//! @brief Return whether exported name applies in assembler symbol, scope, and segment state.
static int is_exported_name(const program_ir_t *prog, const char *file, const char *name)
{
   const stmt_t *stmt;
   const expr_list_node_t *node;

   for (stmt = prog->head; stmt; stmt = stmt->next) {
      if (stmt->kind != STMT_DIR)
         continue;
      if (!stmt->file || strcmp(stmt->file, file))
         continue;
      if (!directive_is_export_family(stmt->u.dir->name))
         continue;

      for (node = stmt->u.dir->exprs; node; node = node->next) {
         const char *n;
         if (directive_expr_is_ident(node->expr, &n) && !strcmp(n, name))
            return 1;
      }
   }

   return 0;
}

static int is_command_line_file(const char *file)
{
   return file && !strcmp(file, "<command-line>");
}

static int is_command_line_defined_name(const program_ir_t *prog, const char *name)
{
   const stmt_t *stmt;

   if (!prog || !name)
      return 0;

   for (stmt = prog->head; stmt; stmt = stmt->next) {
      if (stmt->kind == STMT_CONST &&
          is_command_line_file(stmt->file) &&
          stmt->u.cnst.name &&
          !strcmp(stmt->u.cnst.name, name))
         return 1;
   }

   return 0;
}

//! @brief Return symbol storage name data used by assembler symbol, scope, and segment state; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *symbol_storage_name(const program_ir_t *prog, const stmt_t *stmt, const char *name, char **owned_out)
{
   *owned_out = NULL;

   if (is_local_name(name)) {
      *owned_out = make_scoped_name(stmt->scope, name);
      return *owned_out;
   }

   if (is_command_line_defined_name(prog, name))
      return name;

   if (is_exported_name(prog, stmt->file, name))
      return name;

   *owned_out = make_file_scoped_name(stmt->file, name);
   return *owned_out;
}

//! @brief Compute segments and update assembler symbol, scope, and segment state state once prerequisite pass data is available.
static void assign_segments(program_ir_t *prog)
{
   stmt_t *stmt;
   char *current_segment;

   current_segment = xstrdup(DEFAULT_SEGMENT_NAME);

   for (stmt = prog->head; stmt; stmt = stmt->next) {
      free(stmt->segment);
      stmt->segment = xstrdup(current_segment);

      if (stmt->kind == STMT_DIR &&
          stmt->u.dir &&
          !strcmp(stmt->u.dir->name, ".segment") &&
          stmt->u.dir->string) {
         char *segname;

         segname = unquote_string(stmt->u.dir->string);
         free(current_segment);
         current_segment = xstrdup(segname);

         free(stmt->segment);
         stmt->segment = xstrdup(segname);

         free(segname);
      }
   }

   free(current_segment);
}

//! @brief Compute scopes and update assembler symbol, scope, and segment state state once prerequisite pass data is available.
static void assign_scopes(program_ir_t *prog)
{
   typedef struct scope_stack {
      char *name;
      struct scope_stack *next;
   } scope_stack_t;

   stmt_t *stmt;
   char *current_scope;
   scope_stack_t *proc_stack;

   current_scope = xstrdup("__root__");
   proc_stack = NULL;

   for (stmt = prog->head; stmt; stmt = stmt->next) {
      const char *proc_name;

      free(stmt->scope);
      stmt->scope = xstrdup(current_scope);

      if (stmt->kind == STMT_LABEL && stmt->label && is_global_label_name(stmt->label)) {
         char *owned;
         const char *name_key;

         name_key = symbol_storage_name(prog, stmt, stmt->label, &owned);
         free(current_scope);
         current_scope = xstrdup(name_key);
         free(stmt->scope);
         stmt->scope = xstrdup(current_scope);
         free(owned);
         continue;
      }

      if (stmt->label && is_global_label_name(stmt->label)) {
         char *owned;
         const char *name_key;

         name_key = symbol_storage_name(prog, stmt, stmt->label, &owned);
         free(current_scope);
         current_scope = xstrdup(name_key);
         free(stmt->scope);
         stmt->scope = xstrdup(current_scope);
         free(owned);
         continue;
      }

      proc_name = proc_decl_name(stmt);
      if (proc_name) {
         scope_stack_t *frame;
         char *owned;
         const char *name_key;

         frame = (scope_stack_t *)calloc(1, sizeof(*frame));
         if (!frame) {
            fprintf(stderr, "out of memory\n");
            exit(1);
         }
         frame->name = current_scope;
         frame->next = proc_stack;
         proc_stack = frame;

         name_key = symbol_storage_name(prog, stmt, proc_name, &owned);
         current_scope = xstrdup(name_key);
         free(owned);
         continue;
      }

      if (stmt->kind == STMT_DIR && stmt->u.dir && !strcmp(stmt->u.dir->name, ".endproc")) {
         if (proc_stack) {
            scope_stack_t *frame = proc_stack;
            free(current_scope);
            current_scope = frame->name;
            proc_stack = frame->next;
            free(frame);
         } else {
            free(current_scope);
            current_scope = xstrdup("__root__");
         }
      }
   }

   while (proc_stack) {
      scope_stack_t *frame = proc_stack->next;
      free(proc_stack->name);
      free(proc_stack);
      proc_stack = frame;
   }
   free(current_scope);
}

//! @brief Collect segment uses from existing assembler symbol, scope, and segment state state for a later pass.
static void gather_segment_uses(asm_context_t *ctx)
{
   stmt_t *stmt;

   ensure_default_segment(ctx);

   for (stmt = ctx->prog->head; stmt; stmt = stmt->next) {
      if (stmt->segment)
         segment_get_or_create(ctx, stmt->segment);
   }
}

//! @brief Handle define or update abs symbol logic for assembler symbol, scope, and segment state.
static void define_or_update_abs_symbol(symtab_t *tab, const char *name, long value)
{
   symbol_t *sym;

   sym = symtab_find(tab, name);
   if (!sym)
      sym = symtab_declare(tab, name, "<segments>", 0);

   if (sym)
      symtab_set_value_segment(sym, value, O65_SEG_ABS);
}

//! @brief Compute segment symbols and update assembler symbol, scope, and segment state state once prerequisite pass data is available.
void publish_segment_symbols(asm_context_t *ctx)
{
   asm_segment_t *seg;
   char buf[4096];

   for (seg = ctx->segments; seg; seg = seg->next) {
      snprintf(buf, sizeof(buf), "%s_BASE", seg->name);
      define_or_update_abs_symbol(&ctx->symbols, buf, seg->base);

      snprintf(buf, sizeof(buf), "%s_SIZE", seg->name);
      define_or_update_abs_symbol(&ctx->symbols, buf, seg->used_size);

      snprintf(buf, sizeof(buf), "%s_END", seg->name);
      define_or_update_abs_symbol(&ctx->symbols, buf, seg->base + seg->used_size);

      snprintf(buf, sizeof(buf), "%s_CAPACITY", seg->name);
      define_or_update_abs_symbol(&ctx->symbols, buf, seg->size);
   }
}

//! @brief Collect segment defs from existing assembler symbol, scope, and segment state state for a later pass.
void gather_segment_defs(asm_context_t *ctx)
{
   stmt_t *stmt;

   for (stmt = ctx->prog->head; stmt; stmt = stmt->next) {
      const directive_info_t *dir;
      const expr_list_node_t *node;
      asm_segment_t *seg;
      char *segname;
      long base;
      long size;
      expr_eval_status_t rc;

      if (stmt->kind != STMT_DIR)
         continue;

      dir = stmt->u.dir;
      if (strcmp(dir->name, ".segmentdef"))
         continue;

      if (!dir->string) {
         asm_error(ctx, stmt, ".segmentdef expects a quoted segment name");
         continue;
      }

      if (!dir->exprs || !dir->exprs->next || dir->exprs->next->next) {
         asm_error(ctx, stmt, ".segmentdef expects exactly two expressions: base, size");
         continue;
      }

      segname = unquote_string(dir->string);
      seg = segment_get_or_create(ctx, segname);

      node = dir->exprs;
      rc = expr_eval(node->expr, &ctx->symbols, stmt->scope, stmt->file, 0, &base);
      if (rc != EXPR_EVAL_OK) {
         asm_error(ctx, stmt, ".segmentdef base could not be resolved");
         free(segname);
         continue;
      }

      node = node->next;
      rc = expr_eval(node->expr, &ctx->symbols, stmt->scope, stmt->file, 0, &size);
      if (rc != EXPR_EVAL_OK) {
         asm_error(ctx, stmt, ".segmentdef size could not be resolved");
         free(segname);
         continue;
      }

      if (base < 0 || size < 0) {
         asm_error(ctx, stmt, ".segmentdef base and size must be non-negative");
         free(segname);
         continue;
      }

      seg->base = base;
      seg->size = size;
      seg->defined = 1;

      publish_segment_symbols(ctx);
      free(segname);
   }
}

//! @brief Validate segment defs invariants before later assembler stages depend on them.
void validate_segment_defs(asm_context_t *ctx)
{
   asm_segment_t *seg;

   for (seg = ctx->segments; seg; seg = seg->next) {
      if (!seg->defined) {
         ctx->error_count++;
         fprintf(stderr, "segment '%s' was used but never defined with .segmentdef\n", seg->name);
      }
   }
}
//! @brief Handle declare symbol or report logic for assembler symbol, scope, and segment state.
int declare_symbol_or_report(asm_context_t *ctx, const char *name, const stmt_t *stmt)
{
   symbol_t *sym;
   const symbol_t *prev;
   char *owned;
   const char *lookup_name;

   lookup_name = symbol_storage_name(ctx->prog, stmt, name, &owned);

   sym = symtab_declare(&ctx->symbols, lookup_name, stmt->file, stmt->line);
   if (sym) {
      free(owned);
      return 1;
   }

   prev = symtab_find_const(&ctx->symbols, lookup_name);
   asm_error(ctx, stmt, "duplicate symbol '%s'", name);
   if (prev && prev->def_file) {
      fprintf(stderr, "%s:%d: first defined here\n",
              prev->def_file, prev->def_line);
   }

   free(owned);
   return 0;
}

//! @brief Find declared symbol in assembler symbol, scope, and segment state tables without transferring ownership.
symbol_t *find_declared_symbol(symtab_t *tab, const program_ir_t *prog, const stmt_t *stmt, const char *name)
{
   char *owned;
   symbol_t *sym;
   const char *lookup_name;

   lookup_name = symbol_storage_name(prog, stmt, name, &owned);
   sym = symtab_find(tab, lookup_name);
   free(owned);
   return sym;
}

//! @brief Collect imports from existing assembler symbol, scope, and segment state state for a later pass.
void gather_imports(asm_context_t *ctx)
{
   stmt_t *stmt;
   const expr_list_node_t *node;

   free_imports(ctx->imports);
   free_weaks(ctx->weaks);
   ctx->imports = NULL;
   ctx->weaks = NULL;

   for (stmt = ctx->prog->head; stmt; stmt = stmt->next) {
      if (stmt->kind != STMT_DIR || !stmt->active)
         continue;

      if (!strcmp(stmt->u.dir->name, ".weak")) {
         for (node = stmt->u.dir->exprs; node; node = node->next) {
            const char *name;
            if (!directive_expr_is_ident(node->expr, &name)) {
               asm_error(ctx, stmt, ".weak expects identifier names");
               continue;
            }
            if (is_local_name(name)) {
               asm_error(ctx, stmt, ".weak does not allow local labels");
               continue;
            }
            asm_add_weak(ctx, stmt, name);
         }
         continue;
      }

      if (!directive_is_import_family(stmt->u.dir->name))
         continue;

      for (node = stmt->u.dir->exprs; node; node = node->next) {
         const char *name;
         int want_zp = directive_name_implies_zp(stmt->u.dir->name);

         if (!directive_expr_is_ident(node->expr, &name)) {
            asm_error(ctx, stmt, "%s expects identifier names", stmt->u.dir->name);
            continue;
         }
         if (is_local_name(name)) {
            asm_error(ctx, stmt, "%s does not allow local labels", stmt->u.dir->name);
            continue;
         }
         add_import(ctx, stmt, name, want_zp);
      }
   }
}

//! @brief Validate imports invariants before later assembler stages depend on them.
void validate_imports(asm_context_t *ctx)
{
   import_name_t *p;
   const symbol_t *sym;

   if (ctx->object_mode_o65)
      return;

   for (p = ctx->imports; p; p = p->next) {
      sym = symtab_find_const(&ctx->symbols, p->name);
      if (!sym || !sym->defined) {
         ctx->error_count++;
         fprintf(stderr, "%s:%d: imported symbol '%s' was not resolved\n",
                 p->file ? p->file : "<input>", p->line, p->name);
      }
   }
}

//! @brief Handle asm prepare context state logic for assembler symbol, scope, and segment state.
void asm_prepare_context_state(asm_context_t *ctx)
{
   assign_segments(ctx->prog);
   assign_scopes(ctx->prog);
   gather_segment_uses(ctx);
   ensure_default_segment(ctx);
}

//! @brief Handle asm free context state logic for assembler symbol, scope, and segment state.
void asm_free_context_state(asm_context_t *ctx)
{
   free_imports(ctx->imports);
   free_weaks(ctx->weaks);
   ctx->imports = NULL;
   ctx->weaks = NULL;
   free_segments(ctx->segments);
   ctx->segments = NULL;
}
