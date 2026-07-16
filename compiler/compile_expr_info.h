//! @file compiler/compile_expr_info.h
//! @brief Declares expression type and value-size queries for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_EXPR_INFO_H_
#define _INCLUDE_COMPILE_EXPR_INFO_H_

#include "ast.h"
#include "compile_internal.h"

bool expr_is_ternary_node(const ASTNode *expr);
ASTNode *expr_ternary_test(ASTNode *expr);
ASTNode *expr_ternary_true(ASTNode *expr);
ASTNode *expr_ternary_false(ASTNode *expr);
const ASTNode *cast_expr_target_type(const ASTNode *expr);
const ASTNode *cast_expr_target_declarator(const ASTNode *expr);
bool is_identifier_spelling(const char *s);
const ASTNode *expr_value_type(ASTNode *expr, Context *ctx);
const ASTNode *expr_value_declarator(ASTNode *expr, Context *ctx);
const char *expr_bare_identifier_name(ASTNode *expr);

#endif
