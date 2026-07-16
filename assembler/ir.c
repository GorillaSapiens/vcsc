//! @file assembler/ir.c
//! @brief Implements assembler intermediate representation for the n65 assembler.
//! @ingroup assembler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "ir.h"
#include "symtab.h"
#include "util.h"

//! @brief Create upper for assembler IR builder. The returned storage is owned by the caller or the object that immediately records it.
static char *dup_upper(const char *s, size_t n)
{
   size_t i;
   char *p;

   p = (char *)malloc(n + 1);
   if (!p) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   for (i = 0; i < n; i++)
      p[i] = (char)toupper((unsigned char)s[i]);

   p[n] = '\0';
   return p;
}

//! @brief Compare a mode suffix case-insensitively without locale side effects.
static int suffix_equals(const char *suffix, const char *want)
{
   if (!suffix || !want)
      return 0;

   while (*suffix && *want) {
      if (tolower((unsigned char)*suffix) != tolower((unsigned char)*want))
         return 0;
      suffix++;
      want++;
   }

   return *suffix == '\0' && *want == '\0';
}

//! @brief Parse mode spec into the normalized representation used by assembler IR builder.
static mode_spec_t parse_mode_spec(const char *suffix)
{
   if (!suffix || !*suffix)
      return MODE_SPEC_NONE;

   if (suffix_equals(suffix, ".z"))
      return MODE_SPEC_Z;
   if (suffix_equals(suffix, ".zx"))
      return MODE_SPEC_ZX;
   if (suffix_equals(suffix, ".zy"))
      return MODE_SPEC_ZY;
   if (suffix_equals(suffix, ".a"))
      return MODE_SPEC_A;
   if (suffix_equals(suffix, ".ax"))
      return MODE_SPEC_AX;
   if (suffix_equals(suffix, ".ay"))
      return MODE_SPEC_AY;
   if (suffix_equals(suffix, ".i"))
      return MODE_SPEC_I;
   if (suffix_equals(suffix, ".ix"))
      return MODE_SPEC_IX;
   if (suffix_equals(suffix, ".iy"))
      return MODE_SPEC_IY;

   return MODE_SPEC_NONE;
}

//! @brief Return mode spec suffix data used by assembler IR builder; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *mode_spec_suffix(mode_spec_t spec)
{
   switch (spec) {
      case MODE_SPEC_NONE: return "";
      case MODE_SPEC_Z:    return ".z";
      case MODE_SPEC_ZX:   return ".zx";
      case MODE_SPEC_ZY:   return ".zy";
      case MODE_SPEC_A:    return ".a";
      case MODE_SPEC_AX:   return ".ax";
      case MODE_SPEC_AY:   return ".ay";
      case MODE_SPEC_I:    return ".i";
      case MODE_SPEC_IX:   return ".ix";
      case MODE_SPEC_IY:   return ".iy";
   }

   return "";
}

//! @brief Parse opcode text into the normalized representation used by assembler IR builder.
static void split_opcode_text(const char *opcode_text, char **opcode_out, mode_spec_t *spec_out)
{
   const char *dot;
   size_t len;

   dot = strchr(opcode_text, '.');
   if (!dot) {
      *opcode_out = dup_upper(opcode_text, strlen(opcode_text));
      *spec_out = MODE_SPEC_NONE;
      return;
   }

   len = (size_t)(dot - opcode_text);
   *opcode_out = dup_upper(opcode_text, len);
   *spec_out = parse_mode_spec(dot);
}

//! @brief Handle program IR init logic for assembler IR builder.
void program_ir_init(program_ir_t *prog)
{
   prog->head = NULL;
   prog->tail = NULL;
}

//! @brief Handle program IR append logic for assembler IR builder.
void program_ir_append(program_ir_t *prog, stmt_t *stmt)
{
   stmt->next = NULL;

   if (!prog->head) {
      prog->head = stmt;
      prog->tail = stmt;
   } else {
      prog->tail->next = stmt;
      prog->tail = stmt;
   }
}

//! @brief Release free storage owned by assembler IR builder.
static void stmt_free(stmt_t *stmt)
{
   if (!stmt)
      return;

   free((char *)stmt->file);
   free(stmt->label);
   free(stmt->scope);
   free(stmt->segment);

   switch (stmt->kind) {
      case STMT_LABEL:
         break;

      case STMT_INSN:
         free(stmt->u.insn.opcode);
         expr_free(stmt->u.insn.expr);
         break;

      case STMT_DIR:
         directive_free(stmt->u.dir);
         break;

      case STMT_CONST:
         free(stmt->u.cnst.name);
         expr_free(stmt->u.cnst.expr);
         break;
   }

   free(stmt);
}

//! @brief Release IR free storage owned by assembler IR builder.
void program_ir_free(program_ir_t *prog)
{
   stmt_t *stmt;
   stmt_t *next;

   stmt = prog->head;
   while (stmt) {
      next = stmt->next;
      stmt_free(stmt);
      stmt = next;
   }

   prog->head = NULL;
   prog->tail = NULL;
}

//! @brief Return stmt make label data used by assembler IR builder; returned pointers alias existing storage unless explicitly allocated by the function name.
stmt_t *stmt_make_label(const char *file, int line, char *label)
{
   stmt_t *stmt;

   stmt = (stmt_t *)calloc(1, sizeof(*stmt));
   if (!stmt) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   stmt->kind = STMT_LABEL;
   stmt->file = xstrdup(file ? file : "<input>");
   stmt->line = line;
   stmt->address = 0;
   stmt->active = 1;
   stmt->label = xstrdup(label);
   stmt->scope = NULL;
   stmt->segment = NULL;
   return stmt;
}

//! @brief Return stmt make insn data used by assembler IR builder; returned pointers alias existing storage unless explicitly allocated by the function name.
stmt_t *stmt_make_insn(const char *file, int line, char *label, char *opcode_text, addr_mode_t mode, expr_t *expr, int has_operand)
{
   stmt_t *stmt;

   stmt = (stmt_t *)calloc(1, sizeof(*stmt));
   if (!stmt) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   stmt->kind = STMT_INSN;
   stmt->file = xstrdup(file ? file : "<input>");
   stmt->line = line;
   stmt->address = 0;
   stmt->active = 1;
   stmt->label = xstrdup(label);
   stmt->scope = NULL;
   stmt->segment = NULL;
   split_opcode_text(opcode_text, &stmt->u.insn.opcode, &stmt->u.insn.spec);
   stmt->u.insn.mode = mode;
   stmt->u.insn.expr = expr;
   stmt->u.insn.has_operand = has_operand;
   stmt->u.insn.final_mode = EM_IMPLIED;
   stmt->u.insn.size = 1;
   return stmt;
}

//! @brief Return stmt make dir data used by assembler IR builder; returned pointers alias existing storage unless explicitly allocated by the function name.
stmt_t *stmt_make_dir(const char *file, int line, char *label, directive_info_t *dir)
{
   stmt_t *stmt;

   stmt = (stmt_t *)calloc(1, sizeof(*stmt));
   if (!stmt) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   stmt->kind = STMT_DIR;
   stmt->file = xstrdup(file ? file : "<input>");
   stmt->line = line;
   stmt->address = 0;
   stmt->active = 1;
   stmt->label = xstrdup(label);
   stmt->scope = NULL;
   stmt->segment = NULL;
   stmt->u.dir = dir;
   return stmt;
}

//! @brief Return stmt make const data used by assembler IR builder; returned pointers alias existing storage unless explicitly allocated by the function name.
static stmt_t *stmt_make_const_kind(const char *file, int line, char *name, expr_t *expr, const_assign_kind_t assign_kind)
{
   stmt_t *stmt;

   stmt = (stmt_t *)calloc(1, sizeof(*stmt));
   if (!stmt) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   stmt->kind = STMT_CONST;
   stmt->file = xstrdup(file ? file : "<input>");
   stmt->line = line;
   stmt->address = 0;
   stmt->active = 1;
   stmt->label = NULL;
   stmt->scope = NULL;
   stmt->segment = NULL;
   stmt->u.cnst.name = xstrdup(name);
   stmt->u.cnst.expr = expr;
   stmt->u.cnst.assign_kind = assign_kind;
   stmt->u.cnst.applied = 1;
   return stmt;
}

stmt_t *stmt_make_const(const char *file, int line, char *name, expr_t *expr)
{
   return stmt_make_const_kind(file, line, name, expr, CONST_ASSIGN_NORMAL);
}

stmt_t *stmt_make_const_default(const char *file, int line, char *name, expr_t *expr)
{
   return stmt_make_const_kind(file, line, name, expr, CONST_ASSIGN_DEFAULT);
}

stmt_t *stmt_make_const_set(const char *file, int line, char *name, expr_t *expr)
{
   return stmt_make_const_kind(file, line, name, expr, CONST_ASSIGN_SET);
}


//! @brief Clone an expression tree for IR rewriting.
static expr_t *expr_clone(const expr_t *expr)
{
   if (!expr)
      return NULL;

   switch (expr->kind) {
      case EXPR_NUMBER:
         return expr_make_number(expr->u.number);

      case EXPR_IDENT:
         return expr_make_ident(expr->u.ident);

      case EXPR_CHARCONST:
         return expr_make_char(expr->u.char_value);

      case EXPR_PC:
         return expr_make_pc();

      case EXPR_UNARY:
         return expr_make_unary(expr->u.unary.op, expr_clone(expr->u.unary.child));

      case EXPR_BINARY:
         return expr_make_binary(expr->u.binary.op,
                                 expr_clone(expr->u.binary.left),
                                 expr_clone(expr->u.binary.right));
   }

   return NULL;
}

//! @brief Clone a directive expression list for IR rewriting.
static expr_list_node_t *expr_list_clone(const expr_list_node_t *list)
{
   expr_list_node_t *out;
   const expr_list_node_t *node;

   out = NULL;
   for (node = list; node; node = node->next)
      out = expr_list_append(out, expr_clone(node->expr));

   return out;
}

//! @brief Clone directive payload for IR rewriting.
static directive_info_t *directive_clone(const directive_info_t *dir)
{
   if (!dir)
      return NULL;

   switch (dir->kind) {
      case DIRARG_NONE:
         return directive_make_empty(dir->name);

      case DIRARG_EXPR_LIST:
         return directive_make_exprs(dir->name, expr_list_clone(dir->exprs));

      case DIRARG_STRING:
         return directive_make_string(dir->name, dir->string);

      case DIRARG_STRING_AND_EXPR_LIST:
         return directive_make_string_exprs(dir->name, dir->string, expr_list_clone(dir->exprs));
   }

   return NULL;
}

//! @brief Clone an assembler statement for IR rewriting.
static stmt_t *stmt_clone(const stmt_t *stmt)
{
   stmt_t *out;

   if (!stmt)
      return NULL;

   out = (stmt_t *)calloc(1, sizeof(*out));
   if (!out) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   out->kind = stmt->kind;
   out->file = xstrdup(stmt->file ? stmt->file : "<input>");
   out->line = stmt->line;
   out->address = stmt->address;
   out->emit_address = stmt->emit_address;
   out->rorg_active = stmt->rorg_active;
   out->active = stmt->active;
   out->label = xstrdup(stmt->label);
   out->scope = xstrdup(stmt->scope);
   out->segment = xstrdup(stmt->segment);

   switch (stmt->kind) {
      case STMT_LABEL:
         break;

      case STMT_INSN:
         out->u.insn.opcode = xstrdup(stmt->u.insn.opcode);
         out->u.insn.spec = stmt->u.insn.spec;
         out->u.insn.mode = stmt->u.insn.mode;
         out->u.insn.expr = expr_clone(stmt->u.insn.expr);
         out->u.insn.has_operand = stmt->u.insn.has_operand;
         out->u.insn.final_mode = stmt->u.insn.final_mode;
         out->u.insn.size = stmt->u.insn.size;
         break;

      case STMT_DIR:
         out->u.dir = directive_clone(stmt->u.dir);
         break;

      case STMT_CONST:
         out->u.cnst.name = xstrdup(stmt->u.cnst.name);
         out->u.cnst.expr = expr_clone(stmt->u.cnst.expr);
         out->u.cnst.assign_kind = stmt->u.cnst.assign_kind;
         out->u.cnst.applied = stmt->u.cnst.applied;
         break;
   }

   return out;
}

//! @brief Return whether a statement is a specific directive name.
static int stmt_is_dir(const stmt_t *stmt, const char *name)
{
   return stmt && stmt->kind == STMT_DIR && stmt->u.dir && stmt->u.dir->name && !strcmp(stmt->u.dir->name, name);
}

//! @brief Return the single expression argument for repeat directives.
static expr_t *repeat_single_expr(const directive_info_t *dir)
{
   if (!dir || dir->string || !dir->exprs || dir->exprs->next)
      return NULL;
   return dir->exprs->expr;
}

//! @brief Evaluate a repeat count during the IR repeat-expansion phase.
static int repeat_eval_count(symtab_t *symbols, const stmt_t *stmt, long *count_out)
{
   expr_t *expr;
   expr_eval_status_t rc;
   long value;

   if (stmt->label) {
      fprintf(stderr, "%s:%d: .repeat cannot have a label\n",
              stmt->file ? stmt->file : "<input>", stmt->line);
      return 0;
   }

   expr = repeat_single_expr(stmt->u.dir);
   if (!expr) {
      fprintf(stderr, "%s:%d: .repeat expects exactly one expression\n",
              stmt->file ? stmt->file : "<input>", stmt->line);
      return 0;
   }

   rc = expr_eval(expr, symbols, NULL, NULL, 0, &value);
   if (rc != EXPR_EVAL_OK) {
      if (rc == EXPR_EVAL_UNRESOLVED) {
         fprintf(stderr, "%s:%d: .repeat count must resolve before assembly passes\n",
                 stmt->file ? stmt->file : "<input>", stmt->line);
      } else {
         fprintf(stderr, "%s:%d: %s\n",
                 stmt->file ? stmt->file : "<input>", stmt->line,
                 expr_eval_status_message(rc));
      }
      return 0;
   }
   if (value < 0) {
      fprintf(stderr, "%s:%d: .repeat count must be non-negative\n",
              stmt->file ? stmt->file : "<input>", stmt->line);
      return 0;
   }

   *count_out = value;
   return 1;
}

//! @brief Record simple constants and mutable values that can be used by later .repeat counts.
static int repeat_note_const(symtab_t *symbols, const stmt_t *stmt)
{
   symbol_t *sym;
   long value;

   if (!symbols || !stmt || stmt->kind != STMT_CONST || !stmt->u.cnst.name)
      return 1;

   if (stmt->u.cnst.assign_kind == CONST_ASSIGN_DEFAULT) {
      sym = symtab_find(symbols, stmt->u.cnst.name);
      if (sym)
         return 1;
   }

   if (expr_eval(stmt->u.cnst.expr, symbols, NULL, NULL, 0, &value) != EXPR_EVAL_OK)
      return 1;

   sym = symtab_find(symbols, stmt->u.cnst.name);

   if (stmt->u.cnst.assign_kind == CONST_ASSIGN_SET) {
      if (sym && !sym->mutable) {
         fprintf(stderr, "%s:%d: .set cannot update immutable symbol '%s'\n",
                 stmt->file ? stmt->file : "<input>", stmt->line, stmt->u.cnst.name);
         return 0;
      }
      if (!sym)
         sym = symtab_declare(symbols, stmt->u.cnst.name, stmt->file, stmt->line);
      if (sym) {
         symtab_set_mutable(sym, 1);
         symtab_set_value(sym, value);
      }
      return 1;
   }

   if (!sym)
      sym = symtab_declare(symbols, stmt->u.cnst.name, stmt->file, stmt->line);
   if (sym)
      symtab_set_value(sym, value);
   return 1;
}

static int repeat_expand_block(stmt_t **cursor_io, const stmt_t *repeat_start, program_ir_t *out, symtab_t *symbols);

//! @brief Append cloned block contents to a program IR.
static void repeat_append_cloned_block(program_ir_t *out, const program_ir_t *body)
{
   const stmt_t *stmt;

   for (stmt = body->head; stmt; stmt = stmt->next)
      program_ir_append(out, stmt_clone(stmt));
}

//! @brief Expand .repeat/.endrepeat blocks in a statement range.
static int repeat_expand_block(stmt_t **cursor_io, const stmt_t *repeat_start, program_ir_t *out, symtab_t *symbols)
{
   stmt_t *stmt;

   stmt = *cursor_io;
   while (stmt) {
      if (stmt_is_dir(stmt, ".endrepeat")) {
         if (!repeat_start) {
            fprintf(stderr, "%s:%d: .endrepeat without matching .repeat\n",
                    stmt->file ? stmt->file : "<input>", stmt->line);
            return 0;
         }
         if (stmt->label) {
            fprintf(stderr, "%s:%d: .endrepeat cannot have a label\n",
                    stmt->file ? stmt->file : "<input>", stmt->line);
            return 0;
         }
         if (stmt->u.dir->exprs || stmt->u.dir->string) {
            fprintf(stderr, "%s:%d: .endrepeat expects no arguments\n",
                    stmt->file ? stmt->file : "<input>", stmt->line);
            return 0;
         }
         *cursor_io = stmt->next;
         return 1;
      }

      if (stmt_is_dir(stmt, ".repeat")) {
         program_ir_t body;
         long count;
         long i;
         stmt_t *body_cursor;

         if (!repeat_eval_count(symbols, stmt, &count))
            return 0;

         program_ir_init(&body);
         body_cursor = stmt->next;
         if (!repeat_expand_block(&body_cursor, stmt, &body, symbols)) {
            program_ir_free(&body);
            return 0;
         }

         for (i = 0; i < count; i++)
            repeat_append_cloned_block(out, &body);

         program_ir_free(&body);
         stmt = body_cursor;
         continue;
      }

      if (stmt->kind == STMT_CONST && !repeat_note_const(symbols, stmt))
         return 0;
      program_ir_append(out, stmt_clone(stmt));
      stmt = stmt->next;
   }

   if (repeat_start) {
      fprintf(stderr, "%s:%d: .repeat without matching .endrepeat\n",
              repeat_start->file ? repeat_start->file : "<input>", repeat_start->line);
      return 0;
   }

   *cursor_io = NULL;
   return 1;
}

//! @brief Expand all .repeat/.endrepeat blocks in the parsed program.
int program_ir_expand_repeats(program_ir_t *prog)
{
   program_ir_t old_prog;
   program_ir_t new_prog;
   stmt_t *cursor;

   if (!prog)
      return 1;

   old_prog = *prog;
   program_ir_init(&new_prog);
   cursor = old_prog.head;

   symtab_t repeat_symbols;

   symtab_init(&repeat_symbols);

   if (!repeat_expand_block(&cursor, NULL, &new_prog, &repeat_symbols)) {
      program_ir_free(&new_prog);
      symtab_free(&repeat_symbols);
      *prog = old_prog;
      return 0;
   }

   symtab_free(&repeat_symbols);
   program_ir_free(&old_prog);
   *prog = new_prog;
   return 1;
}

//! @brief Return the textual operator used by a constant-like statement.
static const char *const_assign_operator(const const_info_t *cnst)
{
   if (!cnst)
      return "=";

   switch (cnst->assign_kind) {
      case CONST_ASSIGN_NORMAL:  return "=";
      case CONST_ASSIGN_DEFAULT: return "?=";
      case CONST_ASSIGN_SET:     return ".set";
   }

   return "=";
}

//! @brief Return addr mode name data used by assembler IR builder; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *addr_mode_name(addr_mode_t mode)
{
   switch (mode) {
      case AM_NONE: return "none";
      case AM_IMPLIED: return "implied";
      case AM_ACCUMULATOR: return "accumulator";
      case AM_IMMEDIATE: return "immediate";
      case AM_ZP_OR_ABS: return "zp/abs";
      case AM_ZPX_OR_ABSX: return "zp,x/abs,x";
      case AM_ZPY_OR_ABSY: return "zp,y/abs,y";
      case AM_INDIRECT: return "indirect";
      case AM_INDEXED_INDIRECT: return "(zp,x)";
      case AM_INDIRECT_INDEXED: return "(zp),y";
      case AM_RELATIVE: return "relative";
   }

   return "unknown";
}

//! @brief Handle stmt print logic for assembler IR builder.
void stmt_print(const stmt_t *stmt)
{
   if (!stmt)
      return;

   printf("%s:%d: ", stmt->file ? stmt->file : "<input>", stmt->line);

   if (stmt->label)
      printf("label=%s ", stmt->label);
   if (stmt->scope)
      printf("scope=%s ", stmt->scope);
   if (stmt->segment)
      printf("segment=%s ", stmt->segment);

   switch (stmt->kind) {
      case STMT_LABEL:
         printf("label-only");
         break;

      case STMT_INSN:
         printf("insn %s%s %s size=%d emode=%d",
                stmt->u.insn.opcode,
                mode_spec_suffix(stmt->u.insn.spec),
                addr_mode_name(stmt->u.insn.mode),
                stmt->u.insn.size,
                (int)stmt->u.insn.final_mode);
         if (stmt->u.insn.expr) {
            printf(" expr=");
            expr_print(stmt->u.insn.expr);
         }
         break;

      case STMT_DIR:
         directive_print(stmt->u.dir);
         return;

      case STMT_CONST:
         if (stmt->u.cnst.assign_kind == CONST_ASSIGN_SET)
            printf("set %s = ", stmt->u.cnst.name);
         else
            printf("const %s %s ", stmt->u.cnst.name, const_assign_operator(&stmt->u.cnst));
         expr_print(stmt->u.cnst.expr);
         break;
   }

   printf("\n");
}

//! @brief Handle program IR print logic for assembler IR builder.
void program_ir_print(const program_ir_t *prog)
{
   const stmt_t *stmt;

   for (stmt = prog->head; stmt; stmt = stmt->next)
      stmt_print(stmt);
}
