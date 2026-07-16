//! @file assembler/expr.c
//! @brief Implements assembler expression parsing and evaluation for the n65 assembler.
//! @ingroup assembler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include "expr.h"
#include "symtab.h"
#include "util.h"

//! @brief Return expr alloc data used by assembler expression evaluator; returned pointers alias existing storage unless explicitly allocated by the function name.
static expr_t *expr_alloc(expr_kind_t kind)
{
   expr_t *e;

   e = (expr_t *)calloc(1, sizeof(*e));
   if (!e) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   e->kind = kind;
   return e;
}

//! @brief Return expr make number data used by assembler expression evaluator; returned pointers alias existing storage unless explicitly allocated by the function name.
expr_t *expr_make_number(long value)
{
   expr_t *e;

   e = expr_alloc(EXPR_NUMBER);
   e->u.number = value;
   return e;
}

//! @brief Return expr make ident data used by assembler expression evaluator; returned pointers alias existing storage unless explicitly allocated by the function name.
expr_t *expr_make_ident(const char *name)
{
   expr_t *e;

   e = expr_alloc(EXPR_IDENT);
   e->u.ident = xstrdup(name);
   return e;
}

//! @brief Return expr make char data used by assembler expression evaluator; returned pointers alias existing storage unless explicitly allocated by the function name.
expr_t *expr_make_char(int value)
{
   expr_t *e;

   e = expr_alloc(EXPR_CHARCONST);
   e->u.char_value = value;
   return e;
}

//! @brief Return expr make program counter data used by assembler expression evaluator; returned pointers alias existing storage unless explicitly allocated by the function name.
expr_t *expr_make_pc(void)
{
   return expr_alloc(EXPR_PC);
}

//! @brief Return expr make unary data used by assembler expression evaluator; returned pointers alias existing storage unless explicitly allocated by the function name.
expr_t *expr_make_unary(expr_unary_op_t op, expr_t *child)
{
   expr_t *e;

   e = expr_alloc(EXPR_UNARY);
   e->u.unary.op = op;
   e->u.unary.child = child;
   return e;
}

//! @brief Return expr make binary data used by assembler expression evaluator; returned pointers alias existing storage unless explicitly allocated by the function name.
expr_t *expr_make_binary(expr_binary_op_t op, expr_t *left, expr_t *right)
{
   expr_t *e;

   e = expr_alloc(EXPR_BINARY);
   e->u.binary.op = op;
   e->u.binary.left = left;
   e->u.binary.right = right;
   return e;
}

//! @brief Release free storage owned by assembler expression evaluator.
void expr_free(expr_t *expr)
{
   if (!expr)
      return;

   switch (expr->kind) {
      case EXPR_IDENT:
         free(expr->u.ident);
         break;

      case EXPR_UNARY:
         expr_free(expr->u.unary.child);
         break;

      case EXPR_BINARY:
         expr_free(expr->u.binary.left);
         expr_free(expr->u.binary.right);
         break;

      default:
         break;
   }

   free(expr);
}

//! @brief Handle expr fprint inner logic for assembler expression evaluator.
static void expr_fprint_inner(FILE *fp, const expr_t *expr)
{
   if (!expr) {
      fprintf(fp, "<null>");
      return;
   }

   switch (expr->kind) {
      case EXPR_NUMBER:
         fprintf(fp, "%ld", expr->u.number);
         break;

      case EXPR_IDENT:
         fprintf(fp, "%s", expr->u.ident);
         break;

      case EXPR_CHARCONST:
         fprintf(fp, "'%d", expr->u.char_value);
         break;

      case EXPR_PC:
         fprintf(fp, "*");
         break;

      case EXPR_UNARY:
         fprintf(fp, "(");
         switch (expr->u.unary.op) {
            case EXPR_UOP_POS:
               fprintf(fp, "+");
               break;

            case EXPR_UOP_NEG:
               fprintf(fp, "-");
               break;

            case EXPR_UOP_LOG_NOT:
               fprintf(fp, "!");
               break;

            case EXPR_UOP_BIT_NOT:
               fprintf(fp, "~");
               break;

            case EXPR_UOP_LO:
               fprintf(fp, "<");
               break;

            case EXPR_UOP_HI:
               fprintf(fp, ">");
               break;
         }
         expr_fprint_inner(fp, expr->u.unary.child);
         fprintf(fp, ")");
         break;

      case EXPR_BINARY:
         fprintf(fp, "(");
         expr_fprint_inner(fp, expr->u.binary.left);
         switch (expr->u.binary.op) {
            case EXPR_BOP_ADD:
               fprintf(fp, " + ");
               break;

            case EXPR_BOP_SUB:
               fprintf(fp, " - ");
               break;

            case EXPR_BOP_MUL:
               fprintf(fp, " * ");
               break;

            case EXPR_BOP_DIV:
               fprintf(fp, " / ");
               break;

            case EXPR_BOP_MOD:
               fprintf(fp, " %% ");
               break;

            case EXPR_BOP_SHL:
               fprintf(fp, " << ");
               break;

            case EXPR_BOP_SHR:
               fprintf(fp, " >> ");
               break;

            case EXPR_BOP_LT:
               fprintf(fp, " < ");
               break;

            case EXPR_BOP_LE:
               fprintf(fp, " <= ");
               break;

            case EXPR_BOP_GT:
               fprintf(fp, " > ");
               break;

            case EXPR_BOP_GE:
               fprintf(fp, " >= ");
               break;

            case EXPR_BOP_EQ:
               fprintf(fp, " == ");
               break;

            case EXPR_BOP_NE:
               fprintf(fp, " != ");
               break;

            case EXPR_BOP_BIT_AND:
               fprintf(fp, " & ");
               break;

            case EXPR_BOP_BIT_XOR:
               fprintf(fp, " ^ ");
               break;

            case EXPR_BOP_BIT_OR:
               fprintf(fp, " | ");
               break;

            case EXPR_BOP_LOG_AND:
               fprintf(fp, " && ");
               break;

            case EXPR_BOP_LOG_OR:
               fprintf(fp, " || ");
               break;
         }
         expr_fprint_inner(fp, expr->u.binary.right);
         fprintf(fp, ")");
         break;
   }
}

//! @brief Handle expr print logic for assembler expression evaluator.
void expr_print(const expr_t *expr)
{
   expr_fprint_inner(stdout, expr);
}

//! @brief Handle expr fprint logic for assembler expression evaluator.
void expr_fprint(FILE *fp, const expr_t *expr)
{
   expr_fprint_inner(fp, expr);
}

//! @brief Parse number token into the normalized representation used by assembler expression evaluator.
long parse_number_token(const char *text)
{
   char *end;
   int base;

   if (!text || !*text)
      return 0;

   if (text[0] == '$') {
      base = 16;
      text++;
   } else if (text[0] == '%') {
      base = 2;
      text++;
   } else {
      base = 10;
   }

   return strtol(text, &end, base);
}

//! @brief Parse charconst token into the normalized representation used by assembler expression evaluator.
int parse_charconst_token(const char *text)
{
   if (!text || text[0] != '\'')
      return 0;

   text++;

   if (*text == '\\') {
      text++;
      switch (*text) {
         case 'n':
            return '\n';

         case 'r':
            return '\r';

         case 't':
            return '\t';

         case '0':
            return '\0';

         case '\'':
            return '\'';

         case '"':
            return '"';

         case '\\':
            return '\\';

         default:
            return (unsigned char)*text;
      }
   }

   return (unsigned char)*text;
}

//! @brief Find scoped ident in assembler expression evaluator tables without transferring ownership.
static const symbol_t *find_scoped_ident(const symtab_t *symtab,
                                         const char *scope,
                                         const char *file_scope,
                                         const char *ident)
{
   char buf[4096];
   const symbol_t *sym;

   if (!symtab)
      return NULL;

   if (ident[0] == '@') {
      snprintf(buf, sizeof(buf), "%s::%s", scope ? scope : "__root__", ident);
      return symtab_find_const(symtab, buf);
   }

   if (file_scope && *file_scope) {
      snprintf(buf, sizeof(buf), "%s::%s", file_scope, ident);
      sym = symtab_find_const(symtab, buf);
      if (sym)
         return sym;
   }

   return symtab_find_const(symtab, ident);
}

//! @brief Handle expr eval logic for assembler expression evaluator.
const char *expr_eval_status_message(expr_eval_status_t status)
{
   switch (status) {
      case EXPR_EVAL_OK:
         return "ok";

      case EXPR_EVAL_UNRESOLVED:
         return "unresolved expression";

      case EXPR_EVAL_DIVZERO:
         return "divide by zero in expression";

      case EXPR_EVAL_BADSHIFT:
         return "invalid shift count in expression";
   }

   return "expression evaluation error";
}

static int shift_count_valid(long count)
{
   return count >= 0 && count < (long)(sizeof(long) * CHAR_BIT);
}

//! @brief Handle expr eval logic for assembler expression evaluator.
expr_eval_status_t expr_eval(const expr_t *expr,
                             const symtab_t *symtab,
                             const char *scope,
                             const char *file_scope,
                             long pc,
                             long *value)
{
   long left;
   long right;
   expr_eval_status_t rc_left;
   expr_eval_status_t rc_right;
   const symbol_t *sym;

   if (!expr || !value)
      return EXPR_EVAL_UNRESOLVED;

   switch (expr->kind) {
      case EXPR_NUMBER:
         *value = expr->u.number;
         return EXPR_EVAL_OK;

      case EXPR_IDENT:
         if (!symtab)
            return EXPR_EVAL_UNRESOLVED;

         sym = find_scoped_ident(symtab, scope, file_scope, expr->u.ident);
         if (!sym || !sym->defined)
            return EXPR_EVAL_UNRESOLVED;

         *value = sym->value;
         return EXPR_EVAL_OK;

      case EXPR_CHARCONST:
         *value = expr->u.char_value;
         return EXPR_EVAL_OK;

      case EXPR_PC:
         *value = pc;
         return EXPR_EVAL_OK;

      case EXPR_UNARY:
         rc_left = expr_eval(expr->u.unary.child, symtab, scope, file_scope, pc, &left);
         if (rc_left != EXPR_EVAL_OK)
            return rc_left;

         switch (expr->u.unary.op) {
            case EXPR_UOP_POS:
               *value = left;
               return EXPR_EVAL_OK;

            case EXPR_UOP_NEG:
               *value = -left;
               return EXPR_EVAL_OK;

            case EXPR_UOP_LOG_NOT:
               *value = !left;
               return EXPR_EVAL_OK;

            case EXPR_UOP_BIT_NOT:
               *value = ~left;
               return EXPR_EVAL_OK;

            case EXPR_UOP_LO:
               *value = left & 0xFF;
               return EXPR_EVAL_OK;

            case EXPR_UOP_HI:
               *value = (left >> 8) & 0xFF;
               return EXPR_EVAL_OK;
         }
         return EXPR_EVAL_UNRESOLVED;

      case EXPR_BINARY:
         rc_left = expr_eval(expr->u.binary.left, symtab, scope, file_scope, pc, &left);
         if (rc_left != EXPR_EVAL_OK)
            return rc_left;

         if (expr->u.binary.op == EXPR_BOP_LOG_AND) {
            if (!left) {
               *value = 0;
               return EXPR_EVAL_OK;
            }
            rc_right = expr_eval(expr->u.binary.right, symtab, scope, file_scope, pc, &right);
            if (rc_right != EXPR_EVAL_OK)
               return rc_right;
            *value = right != 0;
            return EXPR_EVAL_OK;
         }

         if (expr->u.binary.op == EXPR_BOP_LOG_OR) {
            if (left) {
               *value = 1;
               return EXPR_EVAL_OK;
            }
            rc_right = expr_eval(expr->u.binary.right, symtab, scope, file_scope, pc, &right);
            if (rc_right != EXPR_EVAL_OK)
               return rc_right;
            *value = right != 0;
            return EXPR_EVAL_OK;
         }

         rc_right = expr_eval(expr->u.binary.right, symtab, scope, file_scope, pc, &right);
         if (rc_right != EXPR_EVAL_OK)
            return rc_right;

         switch (expr->u.binary.op) {
            case EXPR_BOP_ADD:
               *value = left + right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_SUB:
               *value = left - right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_MUL:
               *value = left * right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_DIV:
               if (right == 0)
                  return EXPR_EVAL_DIVZERO;
               *value = left / right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_MOD:
               if (right == 0)
                  return EXPR_EVAL_DIVZERO;
               *value = left % right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_SHL:
               if (!shift_count_valid(right))
                  return EXPR_EVAL_BADSHIFT;
               *value = left << right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_SHR:
               if (!shift_count_valid(right))
                  return EXPR_EVAL_BADSHIFT;
               *value = left >> right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_LT:
               *value = left < right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_LE:
               *value = left <= right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_GT:
               *value = left > right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_GE:
               *value = left >= right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_EQ:
               *value = left == right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_NE:
               *value = left != right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_BIT_AND:
               *value = left & right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_BIT_XOR:
               *value = left ^ right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_BIT_OR:
               *value = left | right;
               return EXPR_EVAL_OK;

            case EXPR_BOP_LOG_AND:
            case EXPR_BOP_LOG_OR:
               break;
         }
         return EXPR_EVAL_UNRESOLVED;
   }

   return EXPR_EVAL_UNRESOLVED;
}

//! @brief Return whether expr is byte value in assembler expression evaluator.
int expr_is_byte_value(long value)
{
   return value >= 0 && value <= 0xFF;
}
