//! @file compiler/compile_init.c
//! @brief Implements initializer lowering for the VCSC compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>
#include <limits.h>

#include "ast.h"
#include "compile.h"
#include "compile_init.h"
#include "compile_internal.h"
#include "compile_support.h"
#include "compile_function_registry.h"
#include "compile_type.h"
#include "emit.h"
#include "integer.h"
#include "messages.h"
#include "typename.h"
#include "xray.h"
#include "lextern.h"

typedef struct PendingGlobalInit {
   const char *name;
   const char *symbol;
   const ASTNode *type;
   const ASTNode *declarator;
   ASTNode *expression;
   int size;
   bool is_zeropage;
   bool is_absolute_ref;
   const char *read_expr;
   const char *write_expr;
} PendingGlobalInit;

static PendingGlobalInit *pending_global_inits = NULL;
static bool build_initializer_bytes(unsigned char *buf, int buf_size, int base_offset, const ASTNode *init, const ASTNode *type, const ASTNode *declarator, int total_size);

//! @brief Return whether a constant initializer explicitly names a packed-BCD type.
static bool initializer_expr_mentions_bcd_type(const ASTNode *expr) {
   const ASTNode *literal_type;

   expr = unwrap_expr_node((ASTNode *) expr);
   if (!expr) {
      return false;
   }

   literal_type = literal_annotation_type(expr);
   if (literal_type && type_is_bcd_integer(literal_type)) {
      return true;
   }
   if (!strcmp(expr->name, "cast")) {
      const ASTNode *target_type = cast_expr_target_type(expr);
      if (target_type && type_is_bcd_integer(target_type)) {
         return true;
      }
   }

   for (int i = 0; i < expr->count; i++) {
      if (initializer_expr_mentions_bcd_type(expr->children[i])) {
         return true;
      }
   }
   return false;
}

//! @brief Enforce packed-BCD representation rules before folding a scalar initializer.
static void validate_bcd_scalar_initializer(const ASTNode *expr, const ASTNode *type, const ASTNode *declarator) {
   bool mentions_bcd;

   if (!expr || !type || (declarator && !declarator_is_plain_value(declarator))) {
      return;
   }

   mentions_bcd = initializer_expr_mentions_bcd_type(expr);
   if (!type_is_bcd_integer(type) && !mentions_bcd) {
      return;
   }

   require_valid_bcd_operator_expr((ASTNode *) expr, NULL);

   if (mentions_bcd) {
      const ASTNode *src_type = expr_value_type((ASTNode *) expr, NULL);
      const ASTNode *src_decl = expr_value_declarator((ASTNode *) expr, NULL);
      if (!bcd_implicit_conversion_allowed(type, declarator, src_type, src_decl, expr)) {
         error_user("[%s:%d.%d] packed-BCD and binary integer values cannot be mixed implicitly",
                    expr->file ? expr->file : "<unknown>", expr->line, expr->column);
      }
   }
}

static int pending_global_init_count = 0;
static int pending_global_init_max_size = 0;
static char runtime_global_init_symbol_buf[64];
static bool runtime_global_init_symbol_ready = false;

//! @brief Return whether expr is ternary node in compiler initializer lowering.
static bool expr_is_ternary_node(const ASTNode *expr) {
   if (!expr || strcmp(expr->name, "expr")) {
      return false;
   }
   if (expr->count <= 0) {
      return false;
   }
   return !strcmp(expr->children[0]->name, "question_expr");
}

//! @brief Return expr ternary test data used by compiler initializer lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static ASTNode *expr_ternary_test(ASTNode *expr) {
   ASTNode *question;
   if (!expr_is_ternary_node(expr)) {
      return NULL;
   }
   question = expr->children[0];
   return question->count > 0 ? question->children[0] : NULL;
}

//! @brief Return expr ternary true data used by compiler initializer lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static ASTNode *expr_ternary_true(ASTNode *expr) {
   ASTNode *question;
   if (!expr_is_ternary_node(expr)) {
      return NULL;
   }
   question = expr->children[0];
   return question->count > 1 ? question->children[1] : NULL;
}

//! @brief Return expr ternary false data used by compiler initializer lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static ASTNode *expr_ternary_false(ASTNode *expr) {
   ASTNode *question;
   if (!expr_is_ternary_node(expr)) {
      return NULL;
   }
   question = expr->children[0];
   return question->count > 2 ? question->children[2] : NULL;
}
//! @brief Return whether type is aggregate in compiler initializer lowering.
bool type_is_aggregate(const ASTNode *type) {
   const ASTNode *node;
   if (!type) {
      return false;
   }
   node = get_typename_node(type_name_from_node(type));
   return node && (!strcmp(node->name, "struct_decl_stmt") || !strcmp(node->name, "union_decl_stmt"));
}

//! @brief Return whether initializer is list in compiler initializer lowering.
bool initializer_is_list(const ASTNode *init) {
   if (!init || is_empty(init)) {
      return false;
   }
   return !strcmp(init->name, "expr_list") || !strcmp(init->name, "named_expr");
}

//! @brief Handle initializer item count logic for compiler initializer lowering.
static int initializer_item_count(const ASTNode *node) {
   if (!node || is_empty(node)) {
      return 0;
   }
   if (!strcmp(node->name, "expr_list")) {
      int total = 0;
      for (int i = 0; i < node->count; i++) {
         total += initializer_item_count(node->children[i]);
      }
      return total;
   }
   return 1;
}

//! @brief Handle initializer collect items logic for compiler initializer lowering.
static void initializer_collect_items(const ASTNode *node, const ASTNode **items, int *index) {
   if (!node || is_empty(node)) {
      return;
   }
   if (!strcmp(node->name, "expr_list")) {
      for (int i = 0; i < node->count; i++) {
         initializer_collect_items(node->children[i], items, index);
      }
      return;
   }
   items[(*index)++] = node;
}

//! @brief Return scalar braced initializer value data used by compiler initializer lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *scalar_braced_initializer_value(const ASTNode *uinit, const ASTNode *type, const ASTNode *declarator) {
   const ASTNode *item = NULL;
   const ASTNode *items[1] = { NULL };
   int index = 0;

   if (!initializer_is_list(uinit)) {
      return NULL;
   }

   if ((declarator && declarator_array_count(declarator) > 0 && declarator_pointer_depth(declarator) == 0) || type_is_aggregate(type)) {
      return NULL;
   }

   initializer_collect_items(uinit, items, &index);
   if (initializer_item_count(uinit) != 1 || index != 1 || !items[0] || items[0]->count < 2) {
      error_user("[%s:%d.%d] too many initializers for scalar", uinit->file, uinit->line, uinit->column);
   }

   item = items[0];
   if (!is_empty(item->children[0])) {
      error_user("[%s:%d.%d] designated initializer not valid for scalar", item->file, item->line, item->column);
   }

   return item->children[1];
}

//! @brief Handle scalar storage size logic for compiler initializer lowering.
static int scalar_storage_size(const ASTNode *type, const ASTNode *declarator, int total_size) {
   if (total_size > 0) {
      return total_size;
   }
   if (declarator) {
      return declarator_storage_size(type, declarator);
   }
   return get_size(type_name_from_node(type));
}

//! @brief Handle init const truthy logic for compiler initializer lowering.
static bool init_const_truthy(const InitConstValue *value) {
   if (!value) {
      return false;
   }
   switch (value->kind) {
      case INIT_CONST_INT:
         return value->i != 0;
      case INIT_CONST_ADDRESS:
         return value->symbol != NULL || value->addend != 0;
      default:
         break;
   }
   return false;
}

//! @brief Handle constant shift width bits logic for compiler initializer lowering.
static int constant_shift_width_bits(ASTNode *expr) {
   int size = expr_value_size(expr, NULL);

   if (size <= 0) {
      size = (int) sizeof(long long);
   }
   if (size > (int) sizeof(long long)) {
      size = (int) sizeof(long long);
   }
   return size * 8;
}

//! @brief Handle diagnose constant shift count logic for compiler initializer lowering.
void diagnose_constant_shift_count(ASTNode *count_expr, int lhs_bits) {
   InitConstValue value = {0};

   if (!count_expr) {
      return;
   }
   if (lhs_bits <= 0) {
      lhs_bits = (int) (sizeof(long long) * 8);
   }
   if (!eval_constant_initializer_expr(count_expr, &value) || value.kind != INIT_CONST_INT) {
      return;
   }

   if (value.i < 0) {
      error_user("[%s:%d.%d] negative shift count %lld", count_expr->file, count_expr->line, count_expr->column, value.i);
   }
   if (value.i >= lhs_bits) {
      error_user("[%s:%d.%d] shift count %lld exceeds %d-bit left operand", count_expr->file, count_expr->line, count_expr->column, value.i, lhs_bits);
   }
}

//! @brief Handle arithmetic right shift ll logic for compiler initializer lowering.
static long long arithmetic_right_shift_ll(long long value, unsigned int count) {
   unsigned long long bits;

   if (count == 0) {
      return value;
   }
   if (count >= sizeof(long long) * 8U) {
      return value < 0 ? -1LL : 0LL;
   }
   if (value >= 0) {
      return (long long) (((unsigned long long) value) >> count);
   }

   bits = (unsigned long long) value;
   return (long long) (~((~bits) >> count));
}

//! @brief Handle eval constant cast expr logic for compiler initializer lowering.
static bool eval_constant_cast_expr(ASTNode *expr, InitConstValue *out) {
   InitConstValue inner = {0};
   const ASTNode *target_type = cast_expr_target_type(expr);
   const ASTNode *target_decl = cast_expr_target_declarator(expr);
   int target_size;
   bool target_is_pointer;
   bool target_is_signed;
   unsigned long long bits;
   unsigned long long mask;
   long long ival;

   if (!expr || !out || !target_type || expr->count < 2) {
      return false;
   }
   if (!eval_constant_initializer_expr(expr->children[1], &inner)) {
      return false;
   }

   target_size = declarator_storage_size(target_type, target_decl);
   if (target_size <= 0) {
      target_size = type_size_from_node(target_type);
   }
   if (target_size <= 0) {
      return false;
   }

   target_is_pointer = (target_decl && declarator_pointer_depth(target_decl) > 0) ||
      !strcmp(type_name_from_node(target_type), "*");
   target_is_signed = type_is_signed_integer(target_type);

   if (inner.kind == INIT_CONST_ADDRESS) {
      if (target_is_pointer) {
         *out = inner;
         return true;
      }
      return false;
   }

   if (inner.kind == INIT_CONST_INT) {
      ival = inner.i;
   }
   else {
      return false;
   }

   bits = (unsigned long long) ival;
   if (target_size < (int) sizeof(bits)) {
      mask = (1ULL << (target_size * 8)) - 1ULL;
      bits &= mask;
      if (target_is_signed && target_size > 0) {
         unsigned long long sign = 1ULL << (target_size * 8 - 1);
         if (bits & sign) {
            bits |= ~mask;
         }
      }
   }

   out->kind = INIT_CONST_INT;
   out->i = (long long) bits;
   return true;
}

//! @brief Handle eval constant initializer expr logic for compiler initializer lowering.
bool eval_constant_initializer_expr(ASTNode *expr, InitConstValue *out) {
   InitConstValue lhs = {0};
   InitConstValue rhs = {0};

   if (!out) {
      return false;
   }
   memset(out, 0, sizeof(*out));
   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || is_empty(expr)) {
      return false;
   }

   if (!strcmp(expr->name, "comma_expr") && expr->count > 0) {
      return eval_constant_initializer_expr(expr->children[expr->count - 1], out);
   }

   if (!strcmp(expr->name, "cast")) {
      return eval_constant_cast_expr(expr, out);
   }

   if (expr->kind == AST_INTEGER) {
      out->kind = INIT_CONST_INT;
      out->i = parse_int(expr->strval);
      out->int_text = expr->strval;
      return true;
   }

   if (expr->kind == AST_STRING) {
      long long ch_value = 0;

      if (decode_char_constant_value(expr->strval, &ch_value)) {
         out->kind = INIT_CONST_INT;
         out->i = ch_value;
         return true;
      }

      out->kind = INIT_CONST_ADDRESS;
      out->symbol = remember_string_literal(expr->strval);
      out->addend = 0;
      return true;
   }

   {
      const char *ident = (expr->kind == AST_IDENTIFIER) ? expr->strval : NULL;
      if (ident) {
         const ASTNode *fn = resolve_function_designator_target(ident);
         if (fn) {
            error_user("[%s:%d.%d] function pointers are not supported; call '%s' directly",
                       expr->file, expr->line, expr->column, ident);
         }
      }
   }

   if (expr_is_ternary_node(expr)) {
      InitConstValue cond = {0};
      ASTNode *test = expr_ternary_test(expr);
      ASTNode *iftrue = expr_ternary_true(expr);
      ASTNode *iffalse = expr_ternary_false(expr);

      if (!test || !iftrue || !iffalse) {
         return false;
      }
      if (!eval_constant_initializer_expr(test, &cond)) {
         return false;
      }
      if (init_const_truthy(&cond)) {
         return eval_constant_initializer_expr(iftrue, out);
      }
      return eval_constant_initializer_expr(iffalse, out);
   }

   if (expr->count == 1) {
      ASTNode *child = expr->children[0];
      if (!strcmp(expr->name, "+")) {
         return eval_constant_initializer_expr(child, out);
      }
      if (!strcmp(expr->name, "-")) {
         if (!eval_constant_initializer_expr(child, &lhs)) {
            return false;
         }
         if (lhs.kind == INIT_CONST_INT) {
            out->kind = INIT_CONST_INT;
            out->i = -lhs.i;
            return true;
         }
         return false;
      }
      if (!strcmp(expr->name, "~")) {
         if (!eval_constant_initializer_expr(child, &lhs) || lhs.kind != INIT_CONST_INT) {
            return false;
         }
         out->kind = INIT_CONST_INT;
         out->i = ~lhs.i;
         return true;
      }
      if (!strcmp(expr->name, "!")) {
         if (!eval_constant_initializer_expr(child, &lhs)) {
            return false;
         }
         out->kind = INIT_CONST_INT;
         out->i = init_const_truthy(&lhs) ? 0 : 1;
         return true;
      }
      if (!strcmp(expr->name, "&")) {
         ASTNode *inner = (ASTNode *) unwrap_expr_node(child);
         LValueRef lv;
         if (inner && !strcmp(inner->name, "lvalue") && resolve_lvalue(NULL, inner, &lv) && !lv.indirect) {
            static char symbuf[512];
            if (!entry_symbol_name(NULL, &(ContextEntry){ .name = lv.name, .type = lv.type, .declarator = lv.declarator, .is_static = lv.is_static, .is_zeropage = lv.is_zeropage, .is_global = lv.is_global, .offset = lv.offset, .size = lv.size }, symbuf, sizeof(symbuf))) {
               return false;
            }
            out->kind = INIT_CONST_ADDRESS;
            out->symbol = strdup(symbuf);
            out->addend = lv.offset + lv.ptr_adjust;
            return true;
         }
         {
            const char *ident = (inner && inner->kind == AST_IDENTIFIER) ? inner->strval : NULL;
            const ASTNode *fn = ident ? resolve_function_designator_target(ident) : NULL;
            if (fn) {
               error_user("[%s:%d.%d] function pointers are not supported; call '%s' directly",
                          inner->file, inner->line, inner->column, ident);
            }
         }
         if (eval_constant_initializer_expr(inner, &lhs) && lhs.kind == INIT_CONST_INT) {
            out->kind = INIT_CONST_INT;
            out->i = lhs.i;
            return true;
         }
         return false;
      }
   }

   if (expr->count == 2) {
      if (!strcmp(expr->name, "&&") || !strcmp(expr->name, "||")) {
         bool lhs_truthy;

         if (!eval_constant_initializer_expr(expr->children[0], &lhs)) {
            return false;
         }
         lhs_truthy = init_const_truthy(&lhs);
         out->kind = INIT_CONST_INT;
         if (!strcmp(expr->name, "&&") && !lhs_truthy) {
            out->i = 0;
            return true;
         }
         if (!strcmp(expr->name, "||") && lhs_truthy) {
            out->i = 1;
            return true;
         }
         if (!eval_constant_initializer_expr(expr->children[1], &rhs)) {
            return false;
         }
         out->i = init_const_truthy(&rhs) ? 1 : 0;
         return true;
      }

      if (!eval_constant_initializer_expr(expr->children[0], &lhs) ||
          !eval_constant_initializer_expr(expr->children[1], &rhs)) {
         return false;
      }

      if (!strcmp(expr->name, "+") || !strcmp(expr->name, "-")) {
         bool add = !strcmp(expr->name, "+");
         if (lhs.kind == INIT_CONST_ADDRESS && rhs.kind == INIT_CONST_INT) {
            out->kind = INIT_CONST_ADDRESS;
            out->symbol = lhs.symbol;
            out->addend = lhs.addend + (add ? rhs.i : -rhs.i);
            return true;
         }
         if (lhs.kind == INIT_CONST_INT && rhs.kind == INIT_CONST_ADDRESS && add) {
            out->kind = INIT_CONST_ADDRESS;
            out->symbol = rhs.symbol;
            out->addend = rhs.addend + lhs.i;
            return true;
         }
         if (lhs.kind == INIT_CONST_INT && rhs.kind == INIT_CONST_INT) {
            out->kind = INIT_CONST_INT;
            out->i = add ? (lhs.i + rhs.i) : (lhs.i - rhs.i);
            return true;
         }
         return false;
      }

      if (!strcmp(expr->name, "*") || !strcmp(expr->name, "/") || !strcmp(expr->name, "%")) {
         if (lhs.kind == INIT_CONST_INT && rhs.kind == INIT_CONST_INT) {
            if ((!strcmp(expr->name, "/") || !strcmp(expr->name, "%")) && rhs.i == 0) {
               return false;
            }
            out->kind = INIT_CONST_INT;
            if (!strcmp(expr->name, "*")) out->i = lhs.i * rhs.i;
            else if (!strcmp(expr->name, "/")) out->i = lhs.i / rhs.i;
            else out->i = lhs.i % rhs.i;
            return true;
         }
         return false;
      }

      if (!strcmp(expr->name, "<<") || !strcmp(expr->name, ">>") ||
          !strcmp(expr->name, "&") || !strcmp(expr->name, "|") || !strcmp(expr->name, "^")) {
         if (lhs.kind != INIT_CONST_INT || rhs.kind != INIT_CONST_INT) {
            return false;
         }
         out->kind = INIT_CONST_INT;
         if (!strcmp(expr->name, "<<") || !strcmp(expr->name, ">>")) {
            int lhs_bits = constant_shift_width_bits(expr->children[0]);
            unsigned int shift_count;

            if (rhs.i < 0) {
               error_user("[%s:%d.%d] negative shift count %lld", expr->children[1]->file, expr->children[1]->line, expr->children[1]->column, rhs.i);
            }
            if (rhs.i >= lhs_bits) {
               error_user("[%s:%d.%d] shift count %lld exceeds %d-bit left operand", expr->children[1]->file, expr->children[1]->line, expr->children[1]->column, rhs.i, lhs_bits);
            }
            shift_count = (unsigned int) rhs.i;
            if (!strcmp(expr->name, "<<")) {
               out->i = (long long) (((unsigned long long) lhs.i) << shift_count);
            }
            else {
               const ASTNode *lhs_type = expr_value_type(expr->children[0], NULL);
               if (lhs_type && type_is_promotable_integer(lhs_type) && !type_is_signed_integer(lhs_type)) {
                  out->i = (long long) (((unsigned long long) lhs.i) >> shift_count);
               }
               else {
                  out->i = arithmetic_right_shift_ll(lhs.i, shift_count);
               }
            }
         }
         else if (!strcmp(expr->name, "&")) out->i = lhs.i & rhs.i;
         else if (!strcmp(expr->name, "|")) out->i = lhs.i | rhs.i;
         else out->i = lhs.i ^ rhs.i;
         return true;
      }

      if (!strcmp(expr->name, "==") || !strcmp(expr->name, "!=") ||
          !strcmp(expr->name, "<") || !strcmp(expr->name, ">") ||
          !strcmp(expr->name, "<=") || !strcmp(expr->name, ">=")) {
         bool result;
         if (lhs.kind == INIT_CONST_ADDRESS || rhs.kind == INIT_CONST_ADDRESS) {
            if (lhs.kind != INIT_CONST_ADDRESS || rhs.kind != INIT_CONST_ADDRESS) {
               return false;
            }
            if ((lhs.symbol == NULL) != (rhs.symbol == NULL)) {
               return false;
            }
            if (lhs.symbol && rhs.symbol && strcmp(lhs.symbol, rhs.symbol)) {
               return false;
            }
            if (!strcmp(expr->name, "==")) result = lhs.addend == rhs.addend;
            else if (!strcmp(expr->name, "!=")) result = lhs.addend != rhs.addend;
            else if (!strcmp(expr->name, "<")) result = lhs.addend < rhs.addend;
            else if (!strcmp(expr->name, ">")) result = lhs.addend > rhs.addend;
            else if (!strcmp(expr->name, "<=")) result = lhs.addend <= rhs.addend;
            else result = lhs.addend >= rhs.addend;
            out->kind = INIT_CONST_INT;
            out->i = result ? 1 : 0;
            return true;
         }
         if (lhs.kind == INIT_CONST_INT && rhs.kind == INIT_CONST_INT) {
            if (!strcmp(expr->name, "==")) result = lhs.i == rhs.i;
            else if (!strcmp(expr->name, "!=")) result = lhs.i != rhs.i;
            else if (!strcmp(expr->name, "<")) result = lhs.i < rhs.i;
            else if (!strcmp(expr->name, ">")) result = lhs.i > rhs.i;
            else if (!strcmp(expr->name, "<=")) result = lhs.i <= rhs.i;
            else result = lhs.i >= rhs.i;
            out->kind = INIT_CONST_INT;
            out->i = result ? 1 : 0;
            return true;
         }
         return false;
      }
   }

   return false;
}

//! @brief Handle encode integer initializer value logic for compiler initializer lowering.
bool encode_integer_initializer_value(long long value, unsigned char *buf, int size, const ASTNode *type) {
   char tmp[128];
   unsigned long long mag;

   if (!buf || size < 0 || !type) {
      return false;
   }

   if (type_is_bcd_integer(type)) {
      unsigned long long remaining;
      unsigned long long max_value = bcd_max_value_for_size(size);

      if (value < 0 || (unsigned long long) value > max_value) {
         error_user("packed-BCD value %lld is outside the range 0..%llu for a %d-byte type",
                    value, max_value, size);
      }
      memset(buf, 0, (size_t) size);
      remaining = (unsigned long long) value;
      for (int i = 0; i < size; i++) {
         unsigned int pair = (unsigned int) (remaining % 100ULL);
         buf[i] = (unsigned char) (((pair / 10U) << 4) | (pair % 10U));
         remaining /= 100ULL;
      }
      return true;
   }

   mag = value < 0 ? (unsigned long long) (-(value + 1)) + 1ULL : (unsigned long long) value;
   snprintf(tmp, sizeof(tmp), "%llu", mag);
   make_le_int(tmp, buf, size);
   if (value < 0) {
      negate_le_int(buf, size);
   }
   return true;
}

//! @brief Encode an integer literal according to the destination representation.
bool encode_integer_literal_text(const char *text, unsigned char *buf, int size, const ASTNode *type) {
   if (!text || !buf || size < 0 || !type) {
      return false;
   }
   if (type_is_bcd_integer(type)) {
      return encode_integer_initializer_value(parse_int(text), buf, size, type);
   }
   make_le_int(text, buf, size);
   return true;
}

//! @brief Handle encode init const int value logic for compiler initializer lowering.
bool encode_init_const_int_value(const InitConstValue *value, unsigned char *buf, int size, const ASTNode *type) {
   if (!value) {
      return false;
   }

   if (type_is_bcd_integer(type)) {
      return encode_integer_initializer_value(value->i, buf, size, type);
   }

   if (value->int_text && value->i >= 0) {
      make_le_int(value->int_text, buf, size);
      return true;
   }

   return encode_integer_initializer_value(value->i, buf, size, type);
}

//! @brief Emit symbol address initializer for compiler initializer lowering diagnostics or output files.
static bool emit_symbol_address_initializer(EmitSink *es, int size, const ASTNode *type, const char *symbol, long long addend) {
   if (!es || !type || !symbol || size <= 0) {
      return false;
   }
   if (size != 2) {
      return false;
   }
   emit(es, "\t.byte <{%s%+lld}, >{%s%+lld}\n", symbol, addend, symbol, addend);
   return true;
}

//! @brief Emit initializer bytes line for compiler initializer lowering diagnostics or output files.
void emit_initializer_bytes_line(EmitSink *es, const unsigned char *bytes, int size) {
   emit(es, "\t.byte $%02x", bytes[0]);
   for (int i = 1; i < size; i++) {
      emit(es, ", $%02x", bytes[i]);
   }
   emit(es, "\n");
}

//! @brief Emit global initializer for compiler initializer lowering diagnostics or output files.
bool emit_global_initializer(EmitSink *es, const ASTNode *type, const ASTNode *declarator, ASTNode *expression, int size) {
   ASTNode *uexpr = (ASTNode *) unwrap_expr_node(expression);
   unsigned char *bytes;
   InitConstValue value = {0};

   if (!es || !type || size < 0) {
      return false;
   }

   if (uexpr) {
      const char *label = emit_pointer_initializer_backing_object(type, declarator, uexpr);
      if (label) {
         return emit_symbol_address_initializer(es, size, type, label, 0);
      }
   }

   bytes = (unsigned char *) calloc(size ? size : 1, sizeof(unsigned char));
   if (!bytes) {
      return false;
   }

   if (build_initializer_bytes(bytes, size, 0, uexpr ? uexpr : expression, type, declarator, size)) {
      emit_initializer_bytes_line(es, bytes, size);
      free(bytes);
      return true;
   }
   free(bytes);

   if (!initializer_is_list(uexpr ? uexpr : expression) && eval_constant_initializer_expr(uexpr ? uexpr : expression, &value)) {
      if (value.kind == INIT_CONST_ADDRESS) {
         return emit_symbol_address_initializer(es, size, type, value.symbol, value.addend);
      }
   }

   return false;
}

//! @brief Emit sink append for compiler initializer lowering diagnostics or output files.
void emit_sink_append(EmitSink *dst, const EmitSink *src) {
   if (!dst || !src) {
      return;
   }
   for (EmitPiece *piece = src->head; piece; piece = piece->next) {
      emit(dst, "%s", piece->txt);
   }
}

//! @brief Add pending global init to compiler initializer lowering state, growing storage or preserving uniqueness as needed.
void remember_pending_global_init(const char *name, const char *symbol, const ASTNode *type, const ASTNode *declarator, ASTNode *expression, int size, bool is_zeropage, bool is_absolute_ref, const char *read_expr, const char *write_expr) {
   PendingGlobalInit *items;
   PendingGlobalInit *entry;

   items = (PendingGlobalInit *) realloc(pending_global_inits,
                                         sizeof(*pending_global_inits) * (pending_global_init_count + 1));
   if (!items) {
      error_unreachable("out of memory");
   }
   pending_global_inits = items;

   entry = &pending_global_inits[pending_global_init_count++];
   entry->name = strdup(name);
   entry->symbol = strdup(symbol ? symbol : name);
   entry->type = type;
   entry->declarator = declarator;
   entry->expression = expression;
   entry->size = size;
   entry->is_zeropage = is_zeropage;
   entry->is_absolute_ref = is_absolute_ref;
   entry->read_expr = read_expr ? strdup(read_expr) : NULL;
   entry->write_expr = write_expr ? strdup(write_expr) : NULL;

   if (size > pending_global_init_max_size) {
      pending_global_init_max_size = size;
   }
}

//! @brief Handle hash runtime init name logic for compiler initializer lowering.
static unsigned long hash_runtime_init_name(const char *text) {
   unsigned long hash = 2166136261u;

   if (!text) {
      return 0u;
   }

   for (const unsigned char *p = (const unsigned char *) text; *p; ++p) {
      hash ^= (unsigned long) *p;
      hash *= 16777619u;
   }

   return hash;
}

//! @brief Return runtime global init symbol data used by compiler initializer lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *runtime_global_init_symbol(void) {
   if (!runtime_global_init_symbol_ready) {
      unsigned long hash = hash_runtime_init_name(root_filename ? root_filename : "<stdin>");
      snprintf(runtime_global_init_symbol_buf, sizeof(runtime_global_init_symbol_buf), "__init_%08lx", hash & 0xfffffffful);
      runtime_global_init_symbol_ready = true;
   }
   return runtime_global_init_symbol_buf;
}

//! @brief Emit runtime global init function for compiler initializer lowering diagnostics or output files.
void emit_runtime_global_init_function(void) {
   Context ctx;
   const char *sym;
   CompilerScratchLease scratch;

   if (pending_global_init_count <= 0) {
      return;
   }

   sym = runtime_global_init_symbol();
   emit(&es_export, ".export %s\n", sym);

   ctx.name = sym;
   ctx.locals = 0;
   ctx.locals_high_water = 0;
   ctx.params = 0;
   ctx.vars = new_set();
   ctx.break_label = NULL;
   ctx.continue_label = NULL;

   compiler_scratch_acquire(&ctx, pending_global_init_max_size, &scratch);
   emit(&es_code, ".proc %s\n", sym);
   compiler_scratch_activate(&ctx, &scratch);

   for (int i = 0; i < pending_global_init_count; i++) {
      PendingGlobalInit *entry = &pending_global_inits[i];

      if (entry->size > 0) {
         emit_fill_scratch_bytes(0, 0, entry->size, 0x00);
      }
      if (!compile_initializer_to_scratch(entry->expression, &ctx, entry->type, entry->declarator, 0, entry->size)) {
         error_user("[%s:%d.%d] invalid runtime global initializer for '%s'",
               entry->expression->file, entry->expression->line, entry->expression->column, entry->name);
      }
      if (entry->is_absolute_ref) {
         LValueRef lv = { .name = entry->name, .type = entry->type, .declarator = entry->declarator, .base_type = entry->type, .base_declarator = entry->declarator, .is_static = false, .is_zeropage = false, .is_global = true, .is_ref = true, .is_absolute_ref = true, .read_expr = entry->read_expr, .write_expr = entry->write_expr, .offset = 0, .size = entry->size };
         if (!emit_copy_scratch_to_lvalue(&ctx, &lv, 0, entry->size)) {
            error_user("[%s:%d.%d] could not store runtime initializer for absolute ref '%s'",
                  entry->expression->file, entry->expression->line, entry->expression->column, entry->name);
         }
      }
      else {
         if (!entry->symbol) {
            error_unreachable("[%s:%d.%d] missing runtime initializer symbol for '%s'",
                  entry->expression->file, entry->expression->line, entry->expression->column, entry->name);
         }

         emit_copy_scratch_to_symbol(entry->symbol, 0, entry->size);
      }
   }

   compiler_scratch_deactivate(&ctx, &scratch);
   compiler_scratch_release(&scratch);
   emit(&es_code, "    rts\n");
   emit(&es_code, ".endproc\n");
}

//! @brief Return aggregate initializer target name data used by compiler initializer lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *aggregate_initializer_target_name(const ASTNode *type) {
   const char *name = type ? type_name_from_node(type) : NULL;
   return name ? name : "aggregate";
}

//! @brief Lower initializer to scratch from AST/semantic state into generated assembly or linker-visible metadata.
bool compile_initializer_to_scratch(const ASTNode *init, Context *ctx, const ASTNode *type, const ASTNode *declarator, int base_offset, int total_size) {
   const ASTNode *uinit = unwrap_expr_node((ASTNode *) init);
   int size = scalar_storage_size(type, declarator, total_size);

   if (!uinit || is_empty(uinit)) {
      return true;
   }

   if (uinit->kind == AST_STRING && !string_literal_is_char_constant(uinit->strval)) {
      return emit_string_initializer_to_scratch(type, declarator, base_offset, size, uinit->strval);
   }

   if (!initializer_is_list(uinit)) {
      ContextEntry dst = { .name = "$init", .type = type, .declarator = declarator, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = true, .offset = base_offset, .size = size };
      return compile_expr_to_slot((ASTNode *) uinit, ctx, &dst);
   }

   {
      const ASTNode *scalar_init = scalar_braced_initializer_value(uinit, type, declarator);
      if (scalar_init) {
         return compile_initializer_to_scratch(scalar_init, ctx, type, declarator, base_offset, total_size);
      }
   }

   if (declarator && declarator_array_count(declarator) > 0 && declarator_pointer_depth(declarator) == 0) {
      int item_count = initializer_item_count(uinit);
      const ASTNode **items = (const ASTNode **) calloc(item_count ? item_count : 1, sizeof(*items));
      int index = 0;
      int elem_count = atoi(declarator->children[2]->strval);
      int elem_size = declarator_first_element_size(type, declarator);
      bool ok = true;
      initializer_collect_items(uinit, items, &index);
      for (int i = 0; i < index && i < elem_count; i++) {
         const ASTNode *item = items[i];
         if (!item || item->count < 2) {
            continue;
         }
         if (!is_empty(item->children[0])) {
            ok = false;
            break;
         }
         ok = compile_initializer_to_scratch(item->children[1], ctx, type, NULL, base_offset + i * elem_size, elem_size);
         if (!ok) {
            break;
         }
      }
      free(items);
      return ok;
   }

   if (type_is_aggregate(type)) {
      const ASTNode *agg = get_typename_node(type_name_from_node(type));
      int item_count = initializer_item_count(uinit);
      const ASTNode **items = (const ASTNode **) calloc(item_count ? item_count : 1, sizeof(*items));
      int index = 0;
      int field_pos = 1;
      bool is_union = agg && !strcmp(agg->name, "union_decl_stmt");
      bool ok = true;

      initializer_collect_items(uinit, items, &index);
      if (is_union && index > 1) {
         free(items);
         error_user("[%s:%d.%d] too many initializers for '%s'", uinit->file, uinit->line, uinit->column,
               aggregate_initializer_target_name(type));
      }
      for (int i = 0; i < index; i++) {
         const ASTNode *item = items[i];
         const ASTNode *ftype = NULL;
         const ASTNode *fdecl = NULL;
         int offset = 0;
         if (!item || item->count < 2) {
            continue;
         }
         if (!is_empty(item->children[0])) {
            if (!find_aggregate_member(type, item->children[0]->strval, &ftype, &fdecl, &offset)) {
               free(items);
               error_user("[%s:%d.%d] unknown initializer field '%s' for '%s'",
                     item->children[0]->file ? item->children[0]->file : item->file,
                     item->children[0]->line,
                     item->children[0]->column,
                     item->children[0]->strval ? item->children[0]->strval : "<unknown>",
                     aggregate_initializer_target_name(type));
            }
         }
         else {
            for (; agg && field_pos < agg->count; field_pos++) {
               const ASTNode *field = agg->children[field_pos];
               if (!field || field->count < 3) {
                  continue;
               }
               ftype = field->children[1];
               fdecl = field->children[2];
               find_aggregate_member(type, declarator_name(fdecl), NULL, NULL, &offset);
               field_pos++;
               break;
            }
            if (!ftype || !fdecl) {
               free(items);
               error_user("[%s:%d.%d] too many initializers for '%s'", item->file, item->line, item->column,
                     aggregate_initializer_target_name(type));
            }
         }
         ok = compile_initializer_to_scratch(item->children[1], ctx, ftype, fdecl, base_offset + offset, declarator_storage_size(ftype, fdecl));
         if (!ok || is_union) {
            break;
         }
      }
      free(items);
      return ok;
   }

   return false;
}

//! @brief Handle build initializer bytes logic for compiler initializer lowering.
static bool build_initializer_bytes(unsigned char *buf, int buf_size, int base_offset, const ASTNode *init, const ASTNode *type, const ASTNode *declarator, int total_size) {
   const ASTNode *uinit = unwrap_expr_node((ASTNode *) init);
   int size = scalar_storage_size(type, declarator, total_size);

   if (!uinit || is_empty(uinit)) {
      return true;
   }
   if (base_offset < 0 || base_offset + size > buf_size) {
      return false;
   }

   if (uinit->kind == AST_STRING && !string_literal_is_char_constant(uinit->strval)) {
      return emit_string_initializer_bytes(buf, buf_size, base_offset, type, declarator, size, uinit->strval);
   }

   if (pointer_initializer_uses_backing_object(type, declarator, uinit)) {
      return false;
   }

   if (!initializer_is_list(uinit)) {
      InitConstValue value = {0};
      validate_bcd_scalar_initializer(uinit, type, declarator);
      if (!eval_constant_initializer_expr((ASTNode *) uinit, &value)) {
         return false;
      }
      if (value.kind != INIT_CONST_INT) {
         return false;
      }
      return encode_init_const_int_value(&value, buf + base_offset, size, type);
   }

   {
      const ASTNode *scalar_init = scalar_braced_initializer_value(uinit, type, declarator);
      if (scalar_init) {
         return build_initializer_bytes(buf, buf_size, base_offset, scalar_init, type, declarator, total_size);
      }
   }

   if (declarator && declarator_array_count(declarator) > 0 && declarator_pointer_depth(declarator) == 0) {
      int item_count = initializer_item_count(uinit);
      const ASTNode **items = (const ASTNode **) calloc(item_count ? item_count : 1, sizeof(*items));
      int index = 0;
      int elem_count = atoi(declarator->children[2]->strval);
      int elem_size = declarator_first_element_size(type, declarator);
      bool ok = true;
      initializer_collect_items(uinit, items, &index);
      for (int i = 0; i < index && i < elem_count; i++) {
         const ASTNode *item = items[i];
         if (!item || item->count < 2) {
            continue;
         }
         if (!is_empty(item->children[0])) {
            ok = false;
            break;
         }
         ok = build_initializer_bytes(buf, buf_size, base_offset + i * elem_size, item->children[1], type, NULL, elem_size);
         if (!ok) {
            break;
         }
      }
      free(items);
      return ok;
   }

   if (type_is_aggregate(type)) {
      const ASTNode *agg = get_typename_node(type_name_from_node(type));
      int item_count = initializer_item_count(uinit);
      const ASTNode **items = (const ASTNode **) calloc(item_count ? item_count : 1, sizeof(*items));
      int index = 0;
      int field_pos = 1;
      bool is_union = agg && !strcmp(agg->name, "union_decl_stmt");
      bool ok = true;

      initializer_collect_items(uinit, items, &index);
      if (is_union && index > 1) {
         free(items);
         error_user("[%s:%d.%d] too many initializers for '%s'", uinit->file, uinit->line, uinit->column,
               aggregate_initializer_target_name(type));
      }
      for (int i = 0; i < index; i++) {
         const ASTNode *item = items[i];
         const ASTNode *ftype = NULL;
         const ASTNode *fdecl = NULL;
         int offset = 0;
         if (!item || item->count < 2) {
            continue;
         }
         if (!is_empty(item->children[0])) {
            if (!find_aggregate_member(type, item->children[0]->strval, &ftype, &fdecl, &offset)) {
               free(items);
               error_user("[%s:%d.%d] unknown initializer field '%s' for '%s'",
                     item->children[0]->file ? item->children[0]->file : item->file,
                     item->children[0]->line,
                     item->children[0]->column,
                     item->children[0]->strval ? item->children[0]->strval : "<unknown>",
                     aggregate_initializer_target_name(type));
            }
         }
         else {
            for (; agg && field_pos < agg->count; field_pos++) {
               const ASTNode *field = agg->children[field_pos];
               if (!field || field->count < 3) {
                  continue;
               }
               ftype = field->children[1];
               fdecl = field->children[2];
               find_aggregate_member(type, declarator_name(fdecl), NULL, NULL, &offset);
               field_pos++;
               break;
            }
            if (!ftype || !fdecl) {
               free(items);
               error_user("[%s:%d.%d] too many initializers for '%s'", item->file, item->line, item->column,
                     aggregate_initializer_target_name(type));
            }
         }
         ok = build_initializer_bytes(buf, buf_size, base_offset + offset, item->children[1], ftype, fdecl, declarator_storage_size(ftype, fdecl));
         if (!ok || is_union) {
            break;
         }
      }
      free(items);
      return ok;
   }

   return false;
}

