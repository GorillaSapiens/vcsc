//! @file compiler/compile_type.c
//! @brief Implements type declaration and layout handling for the n65 compiler.
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
#include "compile_internal.h"
#include "compile_type.h"
#include "float.h"
#include "integer.h"
#include "memname.h"
#include "messages.h"
#include "pair.h"
#include "typename.h"
#include "xray.h"
#include "lextern.h"

//! @brief Return whether expr is ternary node in compiler type system.
static bool expr_is_ternary_node(const ASTNode *expr) {
   expr = unwrap_expr_node(expr);

   if (!expr) {
      return false;
   }

   return !strcmp(expr->name, "?:") && expr->count == 3;
}

//! @brief Return expr ternary true data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
static ASTNode *expr_ternary_true(ASTNode *expr) {
   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr_is_ternary_node(expr)) {
      return NULL;
   }
   return expr->children[1];
}

//! @brief Return expr ternary false data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
static ASTNode *expr_ternary_false(ASTNode *expr) {
   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr_is_ternary_node(expr)) {
      return NULL;
   }
   return expr->children[2];
}

//! @brief Extract type name from node for compiler type system.
const char *type_name_from_node(const ASTNode *type) {
   if (!type) {
      return NULL;
   }
   if (type->strval) {
      return type->strval;
   }
   if (type->count > 0 && type->children[0] && type->children[0]->strval) {
      return type->children[0]->strval;
   }
   return NULL;
}

//! @brief Return required typename node data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *required_typename_node(const char *name) {
   const ASTNode *node;

   if (!name) {
      error_unreachable("[%s:%d] internal missing required type name", __FILE__, __LINE__);
   }

   node = get_typename_node(name);
   if (!node) {
      error_user("type %s is not defined", name);
   }

   return node;
}

//! @brief Return bool type node data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *bool_type_node(void) {
   return required_typename_node("bool");
}

//! @brief Return whether type is bool in compiler type system.
bool type_is_bool(const ASTNode *type) {
   const char *name = type_name_from_node(type);
   return name && !strcmp(name, "bool");
}

//! @brief Parse integer style flag text into the normalized representation used by compiler type system.
const char *parse_integer_style_flag_text(const char *text) {
   if (!text || strncmp(text, "$integer:", 9) || !text[9]) {
      return NULL;
   }
   return text + 9;
}

//! @brief Return whether type has integer style in compiler type system.
bool type_has_integer_style(const ASTNode *type, const char *style) {
   const char *name = type_name_from_node(type);
   char buf[64];

   if (!name || !style) {
      return false;
   }

   snprintf(buf, sizeof(buf), "$integer:%s", style);
   return has_flag(name, buf);
}

//! @brief Return whether type is signed integer in compiler type system.
bool type_is_signed_integer(const ASTNode *type) {
   const char *name = type_name_from_node(type);
   const ASTNode *node;

   if (!name || !strcmp(name, "*") || type_is_bool(type) || type_is_float_like(type)) {
      return false;
   }

   if (type_has_integer_style(type, "unsigned")) {
      return false;
   }
   if (type_has_integer_style(type, "signed")) {
      return true;
   }

   node = get_typename_node(name);
   if (node && (!strcmp(node->name, "struct_decl_stmt") || !strcmp(node->name, "union_decl_stmt"))) {
      return false;
   }

   return false;
}

//! @brief Return whether type is unsigned integer in compiler type system.
bool type_is_unsigned_integer(const ASTNode *type) {
   const char *name = type_name_from_node(type);
   return name && strcmp(name, "*") && type_has_integer_style(type, "unsigned");
}

//! @brief Return whether type is promotable integer in compiler type system.
bool type_is_promotable_integer(const ASTNode *type) {
   return type_is_signed_integer(type) || type_is_unsigned_integer(type);
}


//! @brief Handle same named value type logic for compiler type system.
bool same_named_value_type(const ASTNode *lhs_type, const ASTNode *lhs_decl,
                                  const ASTNode *rhs_type, const ASTNode *rhs_decl) {
   const char *lhs_name = type_name_from_node(lhs_type);
   const char *rhs_name = type_name_from_node(rhs_type);

   if (!lhs_name || !rhs_name || strcmp(lhs_name, rhs_name)) {
      return false;
   }
   if ((lhs_decl && declarator_pointer_depth(lhs_decl) > 0) ||
       (rhs_decl && declarator_pointer_depth(rhs_decl) > 0)) {
      return false;
   }
   return true;
}







//! @brief Return type endian name data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *type_endian_name(const ASTNode *type) {
   const char *name = type_name_from_node(type);
   if (!name) {
      return NULL;
   }
   if (has_flag(name, "$endian:big")) {
      return "big";
   }
   if (has_flag(name, "$endian:little")) {
      return "little";
   }
   return NULL;
}

//! @brief Return whether type is big endian in compiler type system.
bool type_is_big_endian(const ASTNode *type) {
   return type && has_flag(type_name_from_node(type), "$endian:big");
}

//! @brief Handle endian mem index for significance logic for compiler type system.
int endian_mem_index_for_significance(int size, bool big_endian, int significance_index) {
   if (significance_index < 0) {
      return 0;
   }
   if (significance_index >= size) {
      significance_index = size - 1;
   }
   return big_endian ? (size - 1 - significance_index) : significance_index;
}

//! @brief Return whether expr is literal node in compiler type system.
bool expr_is_literal_node(const ASTNode *expr) {
   expr = unwrap_expr_node(expr);
   if (!expr) {
      return false;
   }
   if (expr->kind == AST_INTEGER || expr->kind == AST_FLOAT || expr->kind == AST_STRING) {
      return true;
   }
   return expr_is_integer_constant_expr(expr, NULL);
}

//! @brief Handle ordinary integer endian conflict logic for compiler type system.
bool ordinary_integer_endian_conflict(const ASTNode *lhs_type, const ASTNode *rhs_type) {
   int lhs_size;
   int rhs_size;
   const char *lhs_endian;
   const char *rhs_endian;

   if (!lhs_type || !rhs_type || !type_is_promotable_integer(lhs_type) || !type_is_promotable_integer(rhs_type) ||
       type_is_bool(lhs_type) || type_is_bool(rhs_type) ||
       type_is_float_like(lhs_type) || type_is_float_like(rhs_type)) {
      return false;
   }

   lhs_size = type_size_from_node(lhs_type);
   rhs_size = type_size_from_node(rhs_type);
   if (lhs_size <= 1 || rhs_size <= 1) {
      return false;
   }

   lhs_endian = type_endian_name(lhs_type);
   rhs_endian = type_endian_name(rhs_type);
   return lhs_endian && rhs_endian && strcmp(lhs_endian, rhs_endian);
}

//! @brief Compute integer type by shape and update compiler type system state once prerequisite pass data is available.
static const ASTNode *select_integer_type_by_shape(int required_size, bool require_signed,
                                                   const char *preferred_endian,
                                                   const ASTNode *prefer_a,
                                                   const ASTNode *prefer_b) {
   const ASTNode *best = NULL;
   int best_size = INT_MAX;
   int best_penalty = INT_MAX;

   for (int i = 0; root && i < root->count; i++) {
      ASTNode *node = root->children[i];
      int penalty = 0;
      const char *cand_endian;
      int cand_size;

      if (!node || strcmp(node->name, "type_decl_stmt")) {
         continue;
      }
      if ( type_is_bool(node) || type_is_float_like(node)) {
         continue;
      }
      if (require_signed) {
         if (!type_is_signed_integer(node)) {
            continue;
         }
      }
      else if (!type_is_unsigned_integer(node)) {
         continue;
      }

      cand_size = type_size_from_node(node);
      if (cand_size < required_size) {
         continue;
      }

      cand_endian = type_endian_name(node);
      if (preferred_endian && cand_size > 1 && cand_endian && strcmp(preferred_endian, cand_endian)) {
         penalty += 8;
      }
      if (node == prefer_a || node == prefer_b) {
         penalty -= 1;
      }

      if (!best || cand_size < best_size || (cand_size == best_size && penalty < best_penalty)) {
         best = node;
         best_size = cand_size;
         best_penalty = penalty;
      }
   }

   return best;
}

//! @brief Return promoted integer type for binary data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *promoted_integer_type_for_binary(const ASTNode *lhs_type, const ASTNode *rhs_type, ASTNode *origin) {
   bool lhs_signed;
   bool rhs_signed;
   int lhs_size;
   int rhs_size;
   int required_size;
   const char *preferred_endian = NULL;
   const ASTNode *best;

   if (!type_is_promotable_integer(lhs_type) || !type_is_promotable_integer(rhs_type) ||
       type_is_bool(lhs_type) || type_is_bool(rhs_type) ||
       type_is_float_like(lhs_type) || type_is_float_like(rhs_type)) {
      return NULL;
   }

   {
      const char *lhs_name = type_name_from_node(lhs_type);
      const char *rhs_name = type_name_from_node(rhs_type);
      if (lhs_name && rhs_name && !strcmp(lhs_name, rhs_name)) {
         return lhs_type;
      }
   }

   lhs_signed = type_is_signed_integer(lhs_type);
   rhs_signed = type_is_signed_integer(rhs_type);
   lhs_size = type_size_from_node(lhs_type);
   rhs_size = type_size_from_node(rhs_type);
   if (lhs_size <= 0 || rhs_size <= 0) {
      return NULL;
   }
   if (lhs_signed != rhs_signed || ordinary_integer_endian_conflict(lhs_type, rhs_type)) {
      return NULL;
   }

   required_size = lhs_size > rhs_size ? lhs_size : rhs_size;

   {
      const char *lhs_endian = type_endian_name(lhs_type);
      const char *rhs_endian = type_endian_name(rhs_type);
      if (lhs_size >= rhs_size) {
         preferred_endian = lhs_endian;
      }
      else {
         preferred_endian = rhs_endian;
      }
      if (!preferred_endian) {
         preferred_endian = lhs_endian;
      }
      if (!preferred_endian) {
         preferred_endian = rhs_endian;
      }
   }

   best = select_integer_type_by_shape(required_size, lhs_signed, preferred_endian, lhs_type, rhs_type);
   if (!best) {
      warning("[%s:%d.%d] no integer promotion type can represent the requested width/sign; keeping existing operand type",
              origin ? origin->file : __FILE__, origin ? origin->line : __LINE__, origin ? origin->column : 0);
      return lhs_size >= rhs_size ? lhs_type : rhs_type;
   }

   return best;
}

//! @brief Return binary integer work type data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *binary_integer_work_type(ASTNode *lhs_expr, ASTNode *rhs_expr, Context *ctx, ASTNode *origin) {
   const ASTNode *lhs_type;
   const ASTNode *rhs_type;
   const ASTNode *lhs_decl;
   const ASTNode *rhs_decl;

   (void) origin;

   lhs_expr = (ASTNode *) unwrap_expr_node(lhs_expr);
   rhs_expr = (ASTNode *) unwrap_expr_node(rhs_expr);
   lhs_type = expr_value_type(lhs_expr, ctx);
   rhs_type = expr_value_type(rhs_expr, ctx);
   lhs_decl = expr_value_declarator(lhs_expr, ctx);
   rhs_decl = expr_value_declarator(rhs_expr, ctx);

   if ((lhs_decl && declarator_pointer_depth(lhs_decl) > 0) ||
       (rhs_decl && declarator_pointer_depth(rhs_decl) > 0)) {
      return NULL;
   }

   if (!lhs_type || !rhs_type || !type_is_promotable_integer(lhs_type) || !type_is_promotable_integer(rhs_type) ||
       type_is_bool(lhs_type) || type_is_bool(rhs_type) ||
       type_is_float_like(lhs_type) || type_is_float_like(rhs_type)) {
      return NULL;
   }

   if (expr_is_literal_node(lhs_expr) && !expr_is_literal_node(rhs_expr)) {
      return rhs_type;
   }
   if (expr_is_literal_node(rhs_expr) && !expr_is_literal_node(lhs_expr)) {
      return lhs_type;
   }
   if (same_named_value_type(lhs_type, lhs_decl, rhs_type, rhs_decl)) {
      return lhs_type;
   }
   return promoted_integer_type_for_binary(lhs_type, rhs_type, origin);
}

//! @brief Return whether an expression is an ordinary mixed-endian integer binary expression.
bool expr_is_mixed_endian_integer_binary_expr(ASTNode *expr, Context *ctx) {
   const ASTNode *lhs_type;
   const ASTNode *rhs_type;
   const ASTNode *lhs_decl;
   const ASTNode *rhs_decl;
   ASTNode *lhs_expr;
   ASTNode *rhs_expr;

   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || expr->count != 2) {
      return false;
   }
   if (strcmp(expr->name, "+") && strcmp(expr->name, "-") && strcmp(expr->name, "*") && strcmp(expr->name, "/") &&
       strcmp(expr->name, "%") && strcmp(expr->name, "&") && strcmp(expr->name, "|") && strcmp(expr->name, "^") &&
       strcmp(expr->name, "<<") && strcmp(expr->name, ">>") &&
       strcmp(expr->name, "==") && strcmp(expr->name, "!=") && strcmp(expr->name, "<") && strcmp(expr->name, ">") &&
       strcmp(expr->name, "<=") && strcmp(expr->name, ">=")) {
      return false;
   }

   lhs_expr = (ASTNode *) unwrap_expr_node(expr->children[0]);
   rhs_expr = (ASTNode *) unwrap_expr_node(expr->children[1]);
   lhs_type = expr_value_type(lhs_expr, ctx);
   rhs_type = expr_value_type(rhs_expr, ctx);
   lhs_decl = expr_value_declarator(lhs_expr, ctx);
   rhs_decl = expr_value_declarator(rhs_expr, ctx);

   if ((lhs_decl && declarator_pointer_depth(lhs_decl) > 0) ||
       (rhs_decl && declarator_pointer_depth(rhs_decl) > 0)) {
      return false;
   }

   if (!lhs_type || !rhs_type || !type_is_promotable_integer(lhs_type) || !type_is_promotable_integer(rhs_type) ||
       type_is_bool(lhs_type) || type_is_bool(rhs_type) ||
       type_is_float_like(lhs_type) || type_is_float_like(rhs_type)) {
      return false;
   }

   if ((expr_is_literal_node(lhs_expr) && !expr_is_literal_node(rhs_expr)) ||
       (expr_is_literal_node(rhs_expr) && !expr_is_literal_node(lhs_expr)) ||
       same_named_value_type(lhs_type, lhs_decl, rhs_type, rhs_decl)) {
      return false;
   }

   return ordinary_integer_endian_conflict(lhs_type, rhs_type);
}

//! @brief Select a target-endian integer work type for target-typed mixed-endian binary expressions.
const ASTNode *target_endian_integer_binary_work_type(ASTNode *lhs_expr, ASTNode *rhs_expr, Context *ctx, const ASTNode *target_type, ASTNode *origin) {
   const ASTNode *lhs_type;
   const ASTNode *rhs_type;
   const ASTNode *lhs_decl;
   const ASTNode *rhs_decl;
   const char *target_endian;
   int lhs_size;
   int rhs_size;
   int required_size;
   bool require_signed;

   (void) origin;

   lhs_expr = (ASTNode *) unwrap_expr_node(lhs_expr);
   rhs_expr = (ASTNode *) unwrap_expr_node(rhs_expr);
   lhs_type = expr_value_type(lhs_expr, ctx);
   rhs_type = expr_value_type(rhs_expr, ctx);
   lhs_decl = expr_value_declarator(lhs_expr, ctx);
   rhs_decl = expr_value_declarator(rhs_expr, ctx);

   if ((lhs_decl && declarator_pointer_depth(lhs_decl) > 0) ||
       (rhs_decl && declarator_pointer_depth(rhs_decl) > 0)) {
      return NULL;
   }

   if (!lhs_type || !rhs_type || !target_type ||
       !type_is_promotable_integer(lhs_type) || !type_is_promotable_integer(rhs_type) || !type_is_promotable_integer(target_type) ||
       type_is_bool(lhs_type) || type_is_bool(rhs_type) || type_is_bool(target_type) ||
       type_is_float_like(lhs_type) || type_is_float_like(rhs_type) || type_is_float_like(target_type)) {
      return NULL;
   }

   if (!ordinary_integer_endian_conflict(lhs_type, rhs_type)) {
      return NULL;
   }
   if (type_is_signed_integer(lhs_type) != type_is_signed_integer(rhs_type)) {
      return NULL;
   }

   lhs_size = type_size_from_node(lhs_type);
   rhs_size = type_size_from_node(rhs_type);
   if (lhs_size <= 1 || rhs_size <= 1) {
      return NULL;
   }

   target_endian = type_endian_name(target_type);
   if (!target_endian) {
      return NULL;
   }

   required_size = lhs_size > rhs_size ? lhs_size : rhs_size;
   require_signed = type_is_signed_integer(lhs_type);
   return select_integer_type_by_shape(required_size, require_signed, target_endian, target_type, target_type);
}

//! @brief Select a value-comparison work type for mixed-endian integer comparisons.
const ASTNode *value_compare_integer_work_type(ASTNode *lhs_expr, ASTNode *rhs_expr, Context *ctx, ASTNode *origin) {
   const ASTNode *lhs_type;
   const ASTNode *rhs_type;
   const ASTNode *lhs_decl;
   const ASTNode *rhs_decl;
   const char *lhs_endian;
   int lhs_size;
   int rhs_size;
   bool require_signed;

   lhs_expr = (ASTNode *) unwrap_expr_node(lhs_expr);
   rhs_expr = (ASTNode *) unwrap_expr_node(rhs_expr);
   lhs_type = expr_value_type(lhs_expr, ctx);
   rhs_type = expr_value_type(rhs_expr, ctx);
   lhs_decl = expr_value_declarator(lhs_expr, ctx);
   rhs_decl = expr_value_declarator(rhs_expr, ctx);

   if ((lhs_decl && declarator_pointer_depth(lhs_decl) > 0) ||
       (rhs_decl && declarator_pointer_depth(rhs_decl) > 0)) {
      return NULL;
   }

   if (!lhs_type || !rhs_type ||
       !type_is_promotable_integer(lhs_type) || !type_is_promotable_integer(rhs_type) ||
       type_is_bool(lhs_type) || type_is_bool(rhs_type) ||
       type_is_float_like(lhs_type) || type_is_float_like(rhs_type)) {
      return NULL;
   }

   if (!ordinary_integer_endian_conflict(lhs_type, rhs_type)) {
      return binary_integer_work_type(lhs_expr, rhs_expr, ctx, origin);
   }
   if (type_is_signed_integer(lhs_type) != type_is_signed_integer(rhs_type)) {
      return NULL;
   }

   lhs_size = type_size_from_node(lhs_type);
   rhs_size = type_size_from_node(rhs_type);
   if (lhs_size <= 1 || rhs_size <= 1) {
      return binary_integer_work_type(lhs_expr, rhs_expr, ctx, origin);
   }

   lhs_endian = type_endian_name(lhs_type);
   if (!lhs_endian) {
      return NULL;
   }

   require_signed = type_is_signed_integer(lhs_type);
   return select_integer_type_by_shape(lhs_size > rhs_size ? lhs_size : rhs_size,
                                       require_signed, lhs_endian, lhs_type, lhs_type);
}

//! @brief Return compound integer work type data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *compound_integer_work_type(const ASTNode *lhs_type, const ASTNode *lhs_decl, ASTNode *rhs_expr, Context *ctx, ASTNode *origin) {
   const ASTNode *rhs_type;
   const ASTNode *rhs_decl;

   rhs_expr = (ASTNode *) unwrap_expr_node(rhs_expr);
   rhs_type = expr_value_type(rhs_expr, ctx);
   rhs_decl = expr_value_declarator(rhs_expr, ctx);

   if (!lhs_type || !rhs_type || !type_is_promotable_integer(lhs_type) || !type_is_promotable_integer(rhs_type) ||
       type_is_bool(lhs_type) || type_is_bool(rhs_type) ||
       type_is_float_like(lhs_type) || type_is_float_like(rhs_type)) {
      return NULL;
   }

   if (expr_is_literal_node(rhs_expr)) {
      return lhs_type;
   }
   if (same_named_value_type(lhs_type, lhs_decl, rhs_type, rhs_decl)) {
      return lhs_type;
   }
   if (ordinary_integer_endian_conflict(lhs_type, rhs_type)) {
      return lhs_type;
   }
   return promoted_integer_type_for_binary(lhs_type, rhs_type, origin);
}

//! @brief Handle require no mixed signed integer binary expr logic for compiler type system.
void require_no_mixed_signed_integer_binary_expr(ASTNode *expr, Context *ctx) {
   const ASTNode *lhs_type;
   const ASTNode *rhs_type;
   const ASTNode *lhs_decl;
   const ASTNode *rhs_decl;
   ASTNode *lhs_expr;
   ASTNode *rhs_expr;

   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || expr->count != 2) {
      return;
   }
   if (strcmp(expr->name, "+") && strcmp(expr->name, "-") && strcmp(expr->name, "*") && strcmp(expr->name, "/") &&
       strcmp(expr->name, "%") && strcmp(expr->name, "&") && strcmp(expr->name, "|") && strcmp(expr->name, "^") &&
       strcmp(expr->name, "==") && strcmp(expr->name, "!=") && strcmp(expr->name, "<") && strcmp(expr->name, ">") &&
       strcmp(expr->name, "<=") && strcmp(expr->name, ">=")) {
      return;
   }

   lhs_expr = (ASTNode *) unwrap_expr_node(expr->children[0]);
   rhs_expr = (ASTNode *) unwrap_expr_node(expr->children[1]);
   lhs_type = expr_value_type(lhs_expr, ctx);
   rhs_type = expr_value_type(rhs_expr, ctx);
   lhs_decl = expr_value_declarator(lhs_expr, ctx);
   rhs_decl = expr_value_declarator(rhs_expr, ctx);

   if ((lhs_decl && declarator_pointer_depth(lhs_decl) > 0) ||
       (rhs_decl && declarator_pointer_depth(rhs_decl) > 0)) {
      return;
   }

   if (!lhs_type || !rhs_type || !type_is_promotable_integer(lhs_type) || !type_is_promotable_integer(rhs_type) ||
       type_is_bool(lhs_type) || type_is_bool(rhs_type) ||
       type_is_float_like(lhs_type) || type_is_float_like(rhs_type)) {
      return;
   }

   if ((expr_is_literal_node(lhs_expr) && !expr_is_literal_node(rhs_expr)) ||
       (expr_is_literal_node(rhs_expr) && !expr_is_literal_node(lhs_expr)) ||
       same_named_value_type(lhs_type, lhs_decl, rhs_type, rhs_decl)) {
      return;
   }

   if (type_is_signed_integer(lhs_type) != type_is_signed_integer(rhs_type)) {
      error_user("[%s:%d.%d] mixed signed/unsigned ordinary integer operator '%s' requires an explicit cast",
                 expr->file, expr->line, expr->column, expr->name);
   }
}

//! @brief Handle require no mixed endian integer binary expr logic for compiler type system.
void require_no_mixed_endian_integer_binary_expr(ASTNode *expr, Context *ctx) {
   const ASTNode *lhs_type;
   const ASTNode *rhs_type;
   const ASTNode *lhs_decl;
   const ASTNode *rhs_decl;
   ASTNode *lhs_expr;
   ASTNode *rhs_expr;

   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || expr->count != 2) {
      return;
   }
   if (strcmp(expr->name, "+") && strcmp(expr->name, "-") && strcmp(expr->name, "*") && strcmp(expr->name, "/") &&
       strcmp(expr->name, "%") && strcmp(expr->name, "&") && strcmp(expr->name, "|") && strcmp(expr->name, "^") &&
       strcmp(expr->name, "<<") && strcmp(expr->name, ">>") &&
       strcmp(expr->name, "==") && strcmp(expr->name, "!=") && strcmp(expr->name, "<") && strcmp(expr->name, ">") &&
       strcmp(expr->name, "<=") && strcmp(expr->name, ">=")) {
      return;
   }

   lhs_expr = (ASTNode *) unwrap_expr_node(expr->children[0]);
   rhs_expr = (ASTNode *) unwrap_expr_node(expr->children[1]);
   lhs_type = expr_value_type(lhs_expr, ctx);
   rhs_type = expr_value_type(rhs_expr, ctx);
   lhs_decl = expr_value_declarator(lhs_expr, ctx);
   rhs_decl = expr_value_declarator(rhs_expr, ctx);

   if ((lhs_decl && declarator_pointer_depth(lhs_decl) > 0) ||
       (rhs_decl && declarator_pointer_depth(rhs_decl) > 0)) {
      return;
   }

   if (!lhs_type || !rhs_type || !type_is_promotable_integer(lhs_type) || !type_is_promotable_integer(rhs_type) ||
       type_is_bool(lhs_type) || type_is_bool(rhs_type) ||
       type_is_float_like(lhs_type) || type_is_float_like(rhs_type)) {
      return;
   }

   if ((expr_is_literal_node(lhs_expr) && !expr_is_literal_node(rhs_expr)) ||
       (expr_is_literal_node(rhs_expr) && !expr_is_literal_node(lhs_expr)) ||
       same_named_value_type(lhs_type, lhs_decl, rhs_type, rhs_decl)) {
      return;
   }

   if (ordinary_integer_endian_conflict(lhs_type, rhs_type)) {
      error_user("[%s:%d.%d] mixed-endian ordinary integer operator '%s' is not supported; use an explicit cast or matching endianness",
                 expr->file, expr->line, expr->column, expr->name);
   }
}

//! @brief Handle require no mixed endian pointer index expr logic for compiler type system.
void require_no_mixed_endian_pointer_index_expr(ASTNode *origin, ASTNode *idx_expr, Context *ctx, const char *op) {
   const ASTNode *idx_type;
   const ASTNode *ptr_type;
   const char *idx_endian;
   const char *ptr_endian;

   origin = (ASTNode *) unwrap_expr_node(origin);
   idx_expr = (ASTNode *) unwrap_expr_node(idx_expr);
   if (!origin || !idx_expr || expr_is_literal_node(idx_expr)) {
      return;
   }

   idx_type = expr_value_type(idx_expr, ctx);
   ptr_type = required_typename_node("*");
   if (!ptr_type || !idx_type || !type_is_promotable_integer(idx_type) || type_is_bool(idx_type) || type_is_float_like(idx_type) ||
       type_size_from_node(idx_type) <= 1 || type_size_from_node(ptr_type) <= 1) {
      return;
   }

   idx_endian = type_endian_name(idx_type);
   ptr_endian = type_endian_name(ptr_type);
   if (!idx_endian || !ptr_endian || !strcmp(idx_endian, ptr_endian)) {
      return;
   }

   error_user("[%s:%d.%d] pointer operator '%s' does not support %s-endian index with %s-endian pointers; use an explicit cast",
              origin->file, origin->line, origin->column, op ? op : "?", idx_endian, ptr_endian);
}

//! @brief Compute endian variant type and update compiler type system state once prerequisite pass data is available.
const ASTNode *select_endian_variant_type(const ASTNode *src_type, const char *target_endian) {
   int src_size;

   if (!src_type) {
      return NULL;
   }

   src_size = type_size_from_node(src_type);
   if (src_size <= 1) {
      return src_type;
   }

   for (int i = 0; root && i < root->count; i++) {
      ASTNode *node = root->children[i];
      const char *cand_endian;

      if (!node || strcmp(node->name, "type_decl_stmt")) {
         continue;
      }
      if (type_size_from_node(node) != src_size) {
         continue;
      }
      cand_endian = type_endian_name(node);
      if (target_endian && cand_endian && strcmp(target_endian, cand_endian)) {
         continue;
      }
      if (type_is_float_like(src_type)) {
         const char *src_style = type_float_style(src_type);
         const char *cand_style;
         if (!type_is_float_like(node)) {
            continue;
         }
         cand_style = type_float_style(node);
         if ((!src_style || !cand_style || strcmp(src_style, cand_style))) {
            continue;
         }
         return node;
      }
      if (type_is_promotable_integer(src_type) && !type_is_bool(src_type) && !type_is_float_like(src_type)) {
         if (!type_is_promotable_integer(node) || type_is_bool(node) || type_is_float_like(node)) {
            continue;
         }
         if (type_is_signed_integer(node) != type_is_signed_integer(src_type)) {
            continue;
         }
         return node;
      }
   }

   return NULL;
}

//! @brief Return flag cast target type data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *flag_cast_target_type(ASTNode *expr, Context *ctx) {
   ASTNode *operand;
   ASTNode *flag;
   const ASTNode *src_type;
   const ASTNode *src_decl;
   const char *src_endian;
   const char *target_endian;
   const char *flag_text;
   bool want_signed;
   bool signedness_cast;
   bool endian_cast;
   int src_size;

   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || strcmp(expr->name, "flag_cast") || expr->count < 2) {
      return NULL;
   }

   flag = expr->children[0];
   operand = (ASTNode *) unwrap_expr_node(expr->children[1]);
   flag_text = flag ? flag->strval : NULL;
   signedness_cast = flag_text && (!strcmp(flag_text, "$signed") || !strcmp(flag_text, "$unsigned"));
   endian_cast = flag_text && (!strcmp(flag_text, "$big") || !strcmp(flag_text, "$little"));
   if (!flag_text || (!signedness_cast && !endian_cast)) {
      error_user("[%s:%d.%d] invalid shortcut cast flag", expr->file, expr->line, expr->column);
   }
   if (!operand || expr_is_literal_node(operand)) {
      if (signedness_cast) {
         error_user("[%s:%d.%d] shortcut cast '%s' is only legal on already-typed ordinary fixed-width integer expressions",
                    expr->file, expr->line, expr->column, flag_text);
      }
      error_user("[%s:%d.%d] shortcut cast '%s' is only legal on already-typed fixed-width integer or float expressions",
                 expr->file, expr->line, expr->column, flag_text);
   }

   src_type = expr_value_type(operand, ctx);
   src_decl = expr_value_declarator(operand, ctx);
   if (signedness_cast) {
      if (!src_type || (src_decl && !declarator_is_plain_value(src_decl)) ||
          !type_is_promotable_integer(src_type) || type_is_bool(src_type) || type_is_float_like(src_type)) {
         error_user("[%s:%d.%d] shortcut cast '%s' is only legal on already-typed ordinary fixed-width integer expressions",
                    expr->file, expr->line, expr->column, flag_text);
      }
   }
   else {
      if (!src_type || (src_decl && !declarator_is_plain_value(src_decl)) || type_is_bool(src_type) ||
          (!type_is_promotable_integer(src_type) && !type_is_float_like(src_type))) {
         error_user("[%s:%d.%d] shortcut cast '%s' is only legal on already-typed fixed-width integer or float expressions",
                    expr->file, expr->line, expr->column, flag_text);
      }
   }

   src_size = type_size_from_node(src_type);
   if (src_size <= 0) {
      error_user("[%s:%d.%d] shortcut cast '%s' requires a fixed-width %s operand",
                 expr->file, expr->line, expr->column, flag_text,
                 signedness_cast ? "integer" : "integer or float");
   }

   if (signedness_cast) {
      want_signed = !strcmp(flag_text, "$signed");
      if (type_is_signed_integer(src_type) == want_signed) {
         return src_type;
      }

      src_endian = type_endian_name(src_type);
      {
         const ASTNode *dst_type = select_integer_type_by_shape(src_size, want_signed, src_endian, NULL, NULL);
         if (!dst_type || type_size_from_node(dst_type) != src_size) {
            error_user("[%s:%d.%d] shortcut cast '%s' has no matching %d-byte %s integer type",
                       expr->file, expr->line, expr->column, flag_text, src_size,
                       want_signed ? "signed" : "unsigned");
         }
         return dst_type;
      }
   }

   target_endian = !strcmp(flag_text, "$big") ? "big" : "little";
   src_endian = type_endian_name(src_type);
   if (src_size <= 1 || !src_endian || !strcmp(src_endian, target_endian)) {
      return src_type;
   }

   {
      const ASTNode *dst_type = select_endian_variant_type(src_type, target_endian);
      if (!dst_type) {
         error_user("[%s:%d.%d] shortcut cast '%s' has no matching %d-byte %s-endian %s type",
                    expr->file, expr->line, expr->column, flag_text, src_size, target_endian,
                    type_is_float_like(src_type) ? "float" : "integer");
      }
      return dst_type;
   }
}

//! @brief Return flag cast target declarator data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *flag_cast_target_declarator(ASTNode *expr, Context *ctx) {
   ASTNode *operand;

   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || strcmp(expr->name, "flag_cast") || expr->count < 2) {
      return NULL;
   }
   operand = (ASTNode *) unwrap_expr_node(expr->children[1]);
   if (!operand) {
      return NULL;
   }
   return expr_value_declarator(operand, ctx);
}

//! @brief Handle flag cast target size logic for compiler type system.
int flag_cast_target_size(ASTNode *expr, Context *ctx) {
   const ASTNode *type = flag_cast_target_type(expr, ctx);
   const ASTNode *decl = flag_cast_target_declarator(expr, ctx);
   int size;

   if (!type) {
      return 0;
   }
   size = declarator_storage_size(type, decl);
   if (size <= 0) {
      size = type_size_from_node(type);
   }
   return size;
}

//! @brief Return literal annotation type data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *literal_annotation_type(const ASTNode *expr) {
   if (!expr) {
      return NULL;
   }
   if ((expr->kind == AST_INTEGER || expr->kind == AST_FLOAT) && expr->count > 0 && expr->children[0]) {
      return expr->children[0];
   }
   return NULL;
}

//! @brief Handle integer literal min size logic for compiler type system.
int integer_literal_min_size(const ASTNode *expr) {
   unsigned long long value;
   int size = 1;
   char *end = NULL;

   if (!expr || expr->kind != AST_INTEGER || !expr->strval) {
      return 0;
   }

   value = strtoull(expr->strval, &end, 0);
   if (end == expr->strval || (end && *end != 0)) {
      return 1;
   }

   while (size < (int) sizeof(value) && value > ((1ULL << (size * 8)) - 1ULL)) {
      size++;
   }

   return size;
}

//! @brief Return whether expr is integer constant expr in compiler type system.
bool expr_is_integer_constant_expr(const ASTNode *expr, long long *value_out) {
   InitConstValue value = {0};

   expr = unwrap_expr_node(expr);
   if (!expr) {
      return false;
   }
   if (expr->kind == AST_INTEGER) {
      if (value_out) {
         *value_out = parse_int(expr->strval);
      }
      return true;
   }
   if (!eval_constant_initializer_expr((ASTNode *) expr, &value) || value.kind != INIT_CONST_INT) {
      return false;
   }
   if (value_out) {
      *value_out = value.i;
   }
   return true;
}

//! @brief Return whether expr is untyped integer literal in compiler type system.
bool expr_is_untyped_integer_literal(const ASTNode *expr) {
   expr = unwrap_expr_node(expr);
   return expr && expr->kind == AST_INTEGER && !literal_annotation_type(expr);
}

//! @brief Return whether integer literal is zero expr in compiler type system.
bool integer_literal_is_zero_expr(const ASTNode *expr) {
   char *end = NULL;
   unsigned long long value;

   expr = unwrap_expr_node(expr);
   if (!expr_is_untyped_integer_literal(expr) || !expr->strval) {
      return false;
   }

   value = strtoull(expr->strval, &end, 0);
   return end && end != expr->strval && *end == 0 && value == 0;
}

//! @brief Handle integer literal fits plain integer type logic for compiler type system.
bool integer_literal_fits_plain_integer_type(const ASTNode *expr, const ASTNode *formal_type, const ASTNode *formal_decl) {
   unsigned long long value;
   unsigned long long max_value;
   int formal_size;
   char *end = NULL;

   expr = unwrap_expr_node(expr);
   if (!expr_is_untyped_integer_literal(expr) || !formal_type || !declarator_is_plain_value(formal_decl) ||
       !type_is_promotable_integer(formal_type) || !expr->strval) {
      return false;
   }

   value = strtoull(expr->strval, &end, 0);
   if (!end || end == expr->strval || *end != 0) {
      return false;
   }

   formal_size = type_size_from_node(formal_type);
   if (formal_size <= 0) {
      return false;
   }

   if (type_is_signed_integer(formal_type)) {
      int bits = formal_size * 8;
      if (bits >= 64) {
         max_value = (unsigned long long) LLONG_MAX;
      }
      else {
         max_value = (1ULL << (bits - 1)) - 1ULL;
      }
   }
   else {
      int bits = formal_size * 8;
      if (bits >= 64) {
         max_value = ULLONG_MAX;
      }
      else {
         max_value = (1ULL << bits) - 1ULL;
      }
   }

   return value <= max_value;
}

// for parameterless flags (e.g. "$signed")
// also for complete flags (e.g. "$endian:little")
//! @brief Return enum backing type name data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *enum_backing_type_name(const char *type) {
   if (!type || !enumbackings || !pair_exists(enumbackings, type)) {
      return NULL;
   }
   return pair_get(enumbackings, type);
}

//! @brief Return whether flag applies in compiler type system.
bool has_flag(const char *type, const char *flag) {
   const ASTNode *node;
   const char *backing;

   if (!type || !flag) {
      return false;
   }

   backing = enum_backing_type_name(type);
   if (backing) {
      return has_flag(backing, flag);
   }

   node = get_typename_node(type);
   if (!node || node->count < 2 || is_empty(node->children[1])) {
      return false;
   }

   const ASTNode *flags = node->children[1];
   for (int i = 0; i < flags->count; i++) {
      if (flags->children[i] && flags->children[i]->strval && !strcmp(flags->children[i]->strval, flag)) {
         return true;
      }
   }
   return false;
}

//! @brief Return whether flag prefix applies in compiler type system.
bool has_flag_prefix(const char *type, const char *prefix) {
   const ASTNode *node;
   const char *backing;
   size_t prefix_len;

   if (!type || !prefix) {
      return false;
   }

   backing = enum_backing_type_name(type);
   if (backing) {
      return has_flag_prefix(backing, prefix);
   }

   node = get_typename_node(type);
   if (!node || node->count < 2 || is_empty(node->children[1])) {
      return false;
   }

   prefix_len = strlen(prefix);
   const ASTNode *flags = node->children[1];
   for (int i = 0; i < flags->count; i++) {
      const char *text;
      if (!flags->children[i] || !flags->children[i]->strval) {
         continue;
      }
      text = flags->children[i]->strval;
      if (!strncmp(text, prefix, prefix_len)) {
         return true;
      }
   }
   return false;
}

//! @brief Parse float style flag text into the normalized representation used by compiler type system.
const char *parse_float_style_flag_text(const char *text) {
   if (!text || strncmp(text, "$float:", 7) || !text[7]) {
      return NULL;
   }
   return text + 7;
}

//! @brief Return whether type is float like in compiler type system.
bool type_is_float_like(const ASTNode *type) {
   const char *name = type_name_from_node(type);
   return name && has_flag_prefix(name, "$float:");
}

//! @brief Return type float style data used by compiler type system; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *type_float_style(const ASTNode *type) {
   const ASTNode *node;
   const ASTNode *flags;

   if (!type) {
      return NULL;
   }

   node = get_typename_node(type_name_from_node(type));
   if (!node || node->count < 2 || is_empty(node->children[1])) {
      return NULL;
   }

   flags = node->children[1];
   for (int i = 0; i < flags->count; i++) {
      const char *style;
      if (!flags->children[i] || !flags->children[i]->strval) {
         continue;
      }
      style = parse_float_style_flag_text(flags->children[i]->strval);
      if (style) {
         return style;
      }
   }

   return NULL;
}

//! @brief Handle type float expbits logic for compiler type system.
int type_float_expbits(const ASTNode *type) {
   const char *style;
   int size;

   if (!type) {
      return -1;
   }

   style = type_float_style(type);
   if (!style) {
      return -1;
   }

   size = type_size_from_node(type);
   return float_style_expbits_for_size(style, size);
}

//! @brief Return whether modifier applies in compiler type system.
bool has_modifier(ASTNode *node, const char *modifier) {
   if (!node || is_empty(node)) {
      return false;
   }

   for (int i = 0; i < node->count; i++) {
      if (!strcmp(modifier, node->children[i]->strval)) {
         return true;
      }
   }
   return false;
}

//! @brief Handle declaration const applies to object logic for compiler type system.
bool declaration_const_applies_to_object(const ASTNode *modifiers, const ASTNode *declarator) {
   if (!has_modifier((ASTNode *) modifiers, "const")) {
      return false;
   }

   return declarator_pointer_depth(declarator) <= 0;
}

//! @brief Parse flag u64 into the normalized representation used by compiler type system.
static bool parse_flag_u64(const ASTNode *flags, const char *prefix, unsigned long long *out) {
   size_t prefix_len;

   if (!flags || is_empty(flags) || !prefix || !out) {
      return false;
   }

   prefix_len = strlen(prefix);
   for (int i = 0; i < flags->count; i++) {
      char *end = NULL;
      unsigned long long value;
      const char *text;

      if (!flags->children[i] || !flags->children[i]->strval) {
         continue;
      }
      text = flags->children[i]->strval;
      if (strncmp(text, prefix, prefix_len)) {
         continue;
      }
      value = strtoull(text + prefix_len, &end, 0);
      if (end && *end == '\0') {
         *out = value;
         return true;
      }
   }
   return false;
}

//! @brief Find mem modifier name in compiler type system tables without transferring ownership.
const char *find_mem_modifier_name(const ASTNode *modifiers) {
   const char *found = NULL;

   if (!modifiers || is_empty(modifiers)) {
      return NULL;
   }

   for (int i = 0; i < modifiers->count; i++) {
      const char *name;
      if (!modifiers->children[i] || !modifiers->children[i]->strval) {
         continue;
      }
      name = modifiers->children[i]->strval;
      if (!memname_exists(name)) {
         continue;
      }
      if (found && strcmp(found, name)) {
         error_user("[%s:%d.%d] multiple mem modifiers '%s' and '%s' are not allowed",
               modifiers->file, modifiers->line, modifiers->column,
               found, name);
      }
      found = name;
   }

   return found;
}

//! @brief Find mem modifier node in compiler type system tables without transferring ownership.
const ASTNode *find_mem_modifier_node(const ASTNode *modifiers) {
   const char *name = find_mem_modifier_name(modifiers);

   if (!name) {
      return NULL;
   }
   return get_memname_node(name);
}

//! @brief Return whether mem decl is zeropage in compiler type system.
bool mem_decl_is_zeropage(const ASTNode *mem_decl) {
   const ASTNode *flags;
   unsigned long long start = 0;
   unsigned long long size = 0;
   unsigned long long end = 0;
   bool have_start;
   bool have_size;
   bool have_end;

   if (!mem_decl || strcmp(mem_decl->name, "mem_decl_stmt") || mem_decl->count < 2) {
      return false;
   }

   flags = mem_decl->children[1];
   have_start = parse_flag_u64(flags, "$start:", &start);
   have_size = parse_flag_u64(flags, "$size:", &size);
   have_end = parse_flag_u64(flags, "$end:", &end);

   if (!have_start) {
      return false;
   }

   if (have_size) {
      return start <= 0xFFull && size <= 0x100ull && start + size <= 0x100ull;
   }

   if (have_end) {
      return start <= 0xFFull && end <= 0x100ull && start <= end;
   }

   return false;
}

//! @brief Handle modifiers imply zeropage logic for compiler type system.
bool modifiers_imply_zeropage(const ASTNode *modifiers) {
   return mem_decl_is_zeropage(find_mem_modifier_node(modifiers));
}

//! @brief Handle modifiers imply mem storage logic for compiler type system.
bool modifiers_imply_mem_storage(const ASTNode *modifiers) {
   return find_mem_modifier_name(modifiers) != NULL;
}

//! @brief Handle modifiers imply named nonzeropage logic for compiler type system.
bool modifiers_imply_named_nonzeropage(const ASTNode *modifiers) {
   return modifiers_imply_mem_storage(modifiers) && !modifiers_imply_zeropage(modifiers);
}

//! @brief Handle build named storage segment logic for compiler type system.
void build_named_storage_segment(char *buf, size_t bufsize, const ASTNode *modifiers, const char *base_segment) {
   const char *memname = find_mem_modifier_name(modifiers);

   if (!buf || bufsize == 0) {
      return;
   }

   if (modifiers_imply_mem_storage(modifiers) && memname && *memname) {
      snprintf(buf, bufsize, "%s.%s", base_segment, memname);
   }
   else {
      snprintf(buf, bufsize, "%s", base_segment);
   }
}

//! @brief Handle get size logic for compiler type system.
int get_size(const char *type) {
   const ASTNode *node;
   const char *backing;

   if (!type) {
      error_unreachable("[%s:%d] internal could not find NULL type", __FILE__, __LINE__);
   }

   if (typesizes && pair_exists(typesizes, type)) {
      return (int)(intptr_t) pair_get(typesizes, type);
   }

   backing = enum_backing_type_name(type);
   if (backing) {
      return get_size(backing);
   }

   node = get_typename_node(type);
   if (!node) {
      error_unreachable("[%s:%d] internal could not find '%s'", __FILE__, __LINE__, type);
   }

   if (!strcmp(node->name, "type_decl_stmt")) {
      if (node->count < 2 || is_empty(node->children[1])) {
         error_unreachable("[%s:%d] internal could not find '%s'", __FILE__, __LINE__, type);
      }

      const ASTNode *flags = node->children[1];
      for (int i = 0; i < flags->count; i++) {
         if (!strncmp(flags->children[i]->strval, "$size:", 6)) {
            return atoi(flags->children[i]->strval + 6);
         }
      }
   }
   else if (!strcmp(node->name, "struct_decl_stmt") || !strcmp(node->name, "union_decl_stmt")) {
      calculate_struct_union_sizes(root);
      if (typesizes && pair_exists(typesizes, type)) {
         return (int)(intptr_t) pair_get(typesizes, type);
      }
   }

   error_unreachable("[%s:%d] internal could not find '%s'", __FILE__, __LINE__, type);
   return -1;
}


//! @brief Extract type size from node for compiler type system.
int type_size_from_node(const ASTNode *type) {
   const char *name = type_name_from_node(type);

   if (!name) {
      return 0;
   }

   return get_size(name);
}

//! @brief Handle declarator value size logic for compiler type system.
int declarator_value_size(const ASTNode *type, const ASTNode *declarator) {
   int size;
   int mult = 1;

   if (!type) {
      return 0;
   }

   size = declarator_pointer_depth(declarator) > 0 ? get_size("*") : get_size(type_name_from_node(type));

   if (!declarator) {
      return size;
   }

   for (int i = 2; i < declarator->count; i++) {
      if (declarator->children[i] && declarator->children[i]->kind == AST_INTEGER) {
         mult *= atoi(declarator->children[i]->strval);
      }
   }

   return size * mult;
}

//! @brief Handle expr value size logic for compiler type system.
int expr_value_size(ASTNode *expr, Context *ctx) {
   const ASTNode *type;
   const ASTNode *declarator;
   int lhs_size;
   int rhs_size;

   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || is_empty(expr)) {
      return 0;
   }

   if (expr->kind == AST_INTEGER) {
      type = literal_annotation_type(expr);
      return type ? type_size_from_node(type) : integer_literal_min_size(expr);
   }

   if (expr->kind == AST_FLOAT) {
      type = literal_annotation_type(expr);
      return type ? type_size_from_node(type) : 0;
   }

   if (!strcmp(expr->name, "sizeof")) {
      return get_size("int");
   }

   type = expr_value_type(expr, ctx);
   declarator = expr_value_declarator(expr, ctx);
   if (type) {
      return declarator ? declarator_value_size(type, declarator) : type_size_from_node(type);
   }

   if (expr_is_ternary_node(expr)) {
      lhs_size = expr_value_size(expr_ternary_true(expr), ctx);
      rhs_size = expr_value_size(expr_ternary_false(expr), ctx);
      return lhs_size > rhs_size ? lhs_size : rhs_size;
   }

   lhs_size = (expr->count >= 1) ? expr_value_size(expr->children[0], ctx) : 0;
   rhs_size = (expr->count >= 2) ? expr_value_size(expr->children[1], ctx) : 0;
   return lhs_size > rhs_size ? lhs_size : rhs_size;
}

