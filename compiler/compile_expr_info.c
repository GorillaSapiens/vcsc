//! @file compiler/compile_expr_info.c
//! @brief Implements expression type and value-size queries for the n65 compiler.
//! @ingroup compiler

#include <string.h>

#include "ast.h"
#include "compile_expr_info.h"
#include "compile_function.h"
#include "compile_internal.h"
#include "compile_overload.h"
#include "compile_type.h"
#include "messages.h"
#include "typename.h"

//! @brief Return whether expr is ternary node in compile expr info.
bool expr_is_ternary_node(const ASTNode *expr) {
   expr = unwrap_expr_node(expr);

   if (!expr) {
      return false;
   }

   if ((!strcmp(expr->name, "conditional_expr") || !strcmp(expr->name, "case_conditional_expr")) &&
       expr->count == 4 && expr->children[0] && expr->children[0]->kind == AST_IDENTIFIER &&
       !strcmp(expr->children[0]->strval, "?:")) {
      return true;
   }

   if (!strcmp(expr->name, "?:") && expr->count >= 3) {
      return true;
   }

   return false;
}

//! @brief Return expr ternary test data used by compile expr info; returned pointers alias existing storage unless explicitly allocated by the function name.
ASTNode *expr_ternary_test(ASTNode *expr) {
   expr = (ASTNode *) unwrap_expr_node(expr);

   if (!expr_is_ternary_node(expr)) {
      return NULL;
   }

   return (!strcmp(expr->name, "?:")) ? expr->children[0] : expr->children[1];
}

//! @brief Return expr ternary true data used by compile expr info; returned pointers alias existing storage unless explicitly allocated by the function name.
ASTNode *expr_ternary_true(ASTNode *expr) {
   expr = (ASTNode *) unwrap_expr_node(expr);

   if (!expr_is_ternary_node(expr)) {
      return NULL;
   }

   return (!strcmp(expr->name, "?:")) ? expr->children[1] : expr->children[2];
}

//! @brief Return expr ternary false data used by compile expr info; returned pointers alias existing storage unless explicitly allocated by the function name.
ASTNode *expr_ternary_false(ASTNode *expr) {
   expr = (ASTNode *) unwrap_expr_node(expr);

   if (!expr_is_ternary_node(expr)) {
      return NULL;
   }

   return (!strcmp(expr->name, "?:")) ? expr->children[2] : expr->children[3];
}

//! @brief Return cast expression target type data used by compile expr info; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *cast_expr_target_type(const ASTNode *expr) {
   const ASTNode *cast_type;
   const ASTNode *specifiers;

   expr = unwrap_expr_node(expr);
   if (!expr || strcmp(expr->name, "cast") || expr->count < 2) {
      return NULL;
   }

   cast_type = expr->children[0];
   if (!cast_type || strcmp(cast_type->name, "cast_type") || cast_type->count < 2) {
      return NULL;
   }

   specifiers = cast_type->children[0];
   if (!specifiers || specifiers->count < 2) {
      return NULL;
   }

   return specifiers->children[1];
}

//! @brief Return cast expression target declarator data used by compile expr info; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *cast_expr_target_declarator(const ASTNode *expr) {
   const ASTNode *cast_type;

   expr = unwrap_expr_node(expr);
   if (!expr || strcmp(expr->name, "cast") || expr->count < 2) {
      return NULL;
   }

   cast_type = expr->children[0];
   if (!cast_type || strcmp(cast_type->name, "cast_type") || cast_type->count < 2) {
      return NULL;
   }

   return cast_type->children[1];
}

//! @brief Return whether identifier spelling applies in compile expr info.
bool is_identifier_spelling(const char *s) {
   int i;

   if (!s || !*s) {
      return false;
   }
   if (!((s[0] >= 'A' && s[0] <= 'Z') || (s[0] >= 'a' && s[0] <= 'z') || s[0] == '_')) {
      return false;
   }
   for (i = 1; s[i]; i++) {
      if (!((s[i] >= 'A' && s[i] <= 'Z') || (s[i] >= 'a' && s[i] <= 'z') || (s[i] >= '0' && s[i] <= '9') || s[i] == '_')) {
         return false;
      }
   }
   return true;
}

//! @brief Return expr bare identifier name data used by compile expr info; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *expr_bare_identifier_name(ASTNode *expr) {
   ASTNode *base;

   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || is_empty(expr)) {
      return NULL;
   }
   if (expr->kind == AST_IDENTIFIER) {
      return expr->strval;
   }
   if (strcmp(expr->name, "lvalue") || expr->count != 2) {
      return NULL;
   }

   base = expr->children[0];
   if (!base || strcmp(base->name, "lvalue_base") || base->count <= 0 || !base->children[0] || base->children[0]->kind != AST_IDENTIFIER) {
      return NULL;
   }
   if (!expr->children[1] || !is_empty(expr->children[1])) {
      return NULL;
   }

   return base->children[0]->strval;
}

//! @brief Return expr value type data used by compile expr info; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *expr_value_type(ASTNode *expr, Context *ctx) {
   const ASTNode *lhs_type;
   const ASTNode *rhs_type;

   expr = (ASTNode *) unwrap_expr_node(expr);

   if (!expr || is_empty(expr)) {
      return NULL;
   }

   if (expr->kind == AST_INTEGER) {
      const ASTNode *annotated = literal_annotation_type(expr);
      if (annotated) {
         return annotated;
      }
      if (typename_exists("int")) {
         return required_typename_node("int");
      }
      return NULL;
   }

   if (expr->kind == AST_FLOAT) {
      const ASTNode *annotated = literal_annotation_type(expr);
      if (annotated) {
         return annotated;
      }
      if (typename_exists("float")) {
         return required_typename_node("float");
      }
      return NULL;
   }

   if (expr->kind == AST_STRING) {
      if (string_literal_is_char_constant(expr->strval)) {
         return required_typename_node("char");
      }
      return required_typename_node("*");
   }

   if (!strcmp(expr->name, "cast")) {
      return cast_expr_target_type(expr);
   }

   if (!strcmp(expr->name, "flag_cast")) {
      return flag_cast_target_type(expr, ctx);
   }

   if (!strcmp(expr->name, "sizeof")) {
      return required_typename_node("int");
   }

   {
      const char *ident = expr_bare_identifier_name(expr);
      if (ident) {
         ContextEntry *entry = ctx_lookup(ctx, ident);
         if (entry) {
            return entry->type;
         }
         {
            const ASTNode *g = global_decl_lookup(ident);
            if (g && g->count >= 3) {
               return g->children[1];
            }
         }
         {
            const ASTNode *fn = resolve_function_designator_target(ident, NULL, NULL);
            if (fn) {
               return function_return_type(fn);
            }
         }
      }
   }

   if (expr->count == 1 && !strcmp(expr->name, "&")) {
      LValueRef lv;
      ASTNode *inner = (ASTNode *) unwrap_expr_node(expr->children[0]);
      if (inner && !strcmp(inner->name, "lvalue") && resolve_lvalue(ctx, inner, &lv)) {
         return lv.type;
      }
      return required_typename_node("*");
   }

   if (!strcmp(expr->name, "lvalue") && expr->count > 0) {
      LValueRef lv;
      if (resolve_lvalue(ctx, expr, &lv)) {
         return lv.type;
      }
   }

   if (!strcmp(expr->name, "()")) {
      ASTNode *callee = expr->children[0];
      ASTNode *args = (expr->count > 1) ? expr->children[1] : NULL;
      const ASTNode *fn = NULL;
      {
         const char *callee_name = expr_bare_identifier_name(callee);
         if (callee_name && builtin_variadic_call_name(callee_name)) {
            return required_typename_node("void");
         }
         if (callee_name) {
            fn = resolve_function_call_target(callee_name, expr, args, ctx);
         }
      }
      if (fn) {
         const ASTNode *ret = function_return_type(fn);
         if (ret) {
            return ret;
         }
      }
      else {
         const ASTNode *callable_decl = expr_value_declarator(callee, ctx);
         const ASTNode *callable_type = expr_value_type(callee, ctx);
         if (callable_decl && declarator_has_parameter_list(callable_decl) && declarator_function_pointer_depth(callable_decl) > 0) {
            return callable_type;
         }
      }
   }

   if (!strcmp(expr->name, "comma_expr") && expr->count > 0) {
      return expr_value_type(expr->children[expr->count - 1], ctx);
   }

   if (expr_is_ternary_node(expr)) {
      lhs_type = expr_value_type(expr_ternary_true(expr), ctx);
      rhs_type = expr_value_type(expr_ternary_false(expr), ctx);
      return lhs_type ? lhs_type : rhs_type;
   }

   if ((expr->count == 1 && !strcmp(expr->name, "!")) ||
       (expr->count == 2 && (!strcmp(expr->name, "==") || !strcmp(expr->name, "!=") ||
        !strcmp(expr->name, "<") || !strcmp(expr->name, ">") || !strcmp(expr->name, "<=") || !strcmp(expr->name, ">=") ||
        !strcmp(expr->name, "&&") || !strcmp(expr->name, "||")))) {
      return bool_type_node();
   }

   if (expr->count == 2 && !strcmp(expr->name, "-")) {
      const ASTNode *lhs_decl = expr_value_declarator(expr->children[0], ctx);
      const ASTNode *rhs_decl = expr_value_declarator(expr->children[1], ctx);
      if (lhs_decl && rhs_decl && declarator_pointer_depth(lhs_decl) > 0 && declarator_pointer_depth(rhs_decl) > 0) {
         lhs_type = expr_value_type(expr->children[0], ctx);
         rhs_type = expr_value_type(expr->children[1], ctx);
         return lhs_type ? lhs_type : rhs_type;
      }
   }

   if (expr->count == 2 && (!strcmp(expr->name, "+") || !strcmp(expr->name, "-") ||
                            !strcmp(expr->name, "&") || !strcmp(expr->name, "|") || !strcmp(expr->name, "^") ||
                            !strcmp(expr->name, "*") || !strcmp(expr->name, "/") || !strcmp(expr->name, "%") ||
                            !strcmp(expr->name, "<<") || !strcmp(expr->name, ">>"))) {
      const ASTNode *lhs_decl = expr_value_declarator(expr->children[0], ctx);
      const ASTNode *rhs_decl = expr_value_declarator(expr->children[1], ctx);
      lhs_type = expr_value_type(expr->children[0], ctx);
      rhs_type = expr_value_type(expr->children[1], ctx);
      if ((!strcmp(expr->name, "+") || !strcmp(expr->name, "-")) && lhs_decl && declarator_pointer_depth(lhs_decl) > 0) {
         return lhs_type;
      }
      if (!strcmp(expr->name, "+") && rhs_decl && declarator_pointer_depth(rhs_decl) > 0) {
         return rhs_type;
      }
      if (!strcmp(expr->name, "<<") || !strcmp(expr->name, ">>")) {
         if (expr_is_literal_node(expr->children[0]) && rhs_type && type_is_promotable_integer(rhs_type) &&
             !type_is_bool(rhs_type) && !type_has_exactops(rhs_type) && !type_is_float_like(rhs_type)) {
            return rhs_type;
         }
         return lhs_type ? lhs_type : rhs_type;
      }
      {
         const ASTNode *work_type = binary_integer_work_type(expr->children[0], expr->children[1], ctx, expr);
         if (work_type) {
            return work_type;
         }
      }
   }

   if (expr->count >= 1) {
      lhs_type = expr_value_type(expr->children[0], ctx);
      if (lhs_type) {
         return lhs_type;
      }
   }

   if (expr->count >= 2) {
      rhs_type = expr_value_type(expr->children[1], ctx);
      if (rhs_type) {
         return rhs_type;
      }
   }

   return NULL;
}

//! @brief Return expr value declarator data used by compile expr info; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *expr_value_declarator(ASTNode *expr, Context *ctx) {
   expr = (ASTNode *) unwrap_expr_node(expr);

   if (!expr || is_empty(expr)) {
      return NULL;
   }

   {
      const char *ident = expr_bare_identifier_name(expr);
      if (ident) {
         ContextEntry *entry = ctx_lookup(ctx, ident);
         if (entry) {
            return entry->declarator;
         }
         {
            const ASTNode *g = global_decl_lookup(ident);
            if (g && g->count >= 3) {
               return g->children[2];
            }
         }
         {
            const ASTNode *fn = resolve_function_designator_target(ident, NULL, NULL);
            if (fn) {
               return function_pointer_declarator_from_callable(function_declarator_node(fn));
            }
         }
      }
   }

   if (!strcmp(expr->name, "cast")) {
      return cast_expr_target_declarator(expr);
   }

   if (!strcmp(expr->name, "flag_cast")) {
      return flag_cast_target_declarator(expr, ctx);
   }

   if (!strcmp(expr->name, "sizeof")) {
      return NULL;
   }

   if (!strcmp(expr->name, "lvalue") && expr->count > 0) {
      LValueRef lv;
      if (resolve_lvalue(ctx, expr, &lv)) {
         return lv.declarator;
      }
   }

   if (expr->count == 1 && !strcmp(expr->name, "&")) {
      LValueRef lv;
      ASTNode *inner = (ASTNode *) unwrap_expr_node(expr->children[0]);
      if (inner && !strcmp(inner->name, "lvalue") && resolve_lvalue(ctx, inner, &lv) && lv.declarator) {
         const ASTNode *value_decl = declarator_value_declarator(lv.declarator);
         int start = declarator_suffix_start_index(value_decl ? value_decl : lv.declarator);
         return clone_declarator_variant(value_decl ? value_decl : lv.declarator,
               declarator_pointer_depth(lv.declarator) + 1, start);
      }
      {
         const char *ident = expr_bare_identifier_name(inner);
         const ASTNode *fn = ident ? resolve_function_designator_target(ident, NULL, NULL) : NULL;
         if (fn) {
            return function_pointer_declarator_from_callable(function_declarator_node(fn));
         }
      }
   }

   if (!strcmp(expr->name, "()")) {
      ASTNode *callee = expr->children[0];
      ASTNode *args = (expr->count > 1) ? expr->children[1] : NULL;
      const ASTNode *fn = NULL;
      {
         const char *callee_name = expr_bare_identifier_name(callee);
         if (callee_name) {
            fn = resolve_function_call_target(callee_name, expr, args, ctx);
         }
      }
      if (fn) {
         return function_return_declarator_from_callable(function_declarator_node(fn));
      }
      else {
         const ASTNode *callable_decl = expr_value_declarator(callee, ctx);
         if (callable_decl && declarator_has_parameter_list(callable_decl) && declarator_function_pointer_depth(callable_decl) > 0) {
            return function_return_declarator_from_callable(callable_decl);
         }
      }
   }

   if (!strcmp(expr->name, "comma_expr") && expr->count > 0) {
      return expr_value_declarator(expr->children[expr->count - 1], ctx);
   }

   if (expr_is_ternary_node(expr)) {
      return expr_value_declarator(expr_ternary_true(expr), ctx);
   }

   return NULL;
}
