//! @file compiler/compile_expr_info.h
//! @brief Declares expression type and value-size queries for the VCSC compiler.
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
const ASTNode *cast_expr_target_modifiers(const ASTNode *expr);
bool is_identifier_spelling(const char *s);
const ASTNode *expr_value_type(ASTNode *expr, Context *ctx);
const ASTNode *expr_value_declarator(ASTNode *expr, Context *ctx);
PointerAccessQualifier expr_pointer_access(ASTNode *expr, Context *ctx);
const char *expr_bare_identifier_name(ASTNode *expr);

// Context-free half of sizeof: the operand's size when the operand is a TYPE, or 0
// when it is not one.  `sizeof(type)` needs no scope, so a constant expression can
// fold it -- which is what lets it appear in an array extent, where no scope has
// been built yet.  `sizeof(expression)` needs the expression's type, which is a
// function of scope; that form stays with the emitter, which resolves it against a
// Context when it reaches it, and is reported as not-constant where a constant is
// required.
int expr_sizeof_type_size(const ASTNode *operand);

// Size of a named type read from its own declaration -- a `type X { $size:N }`,
// a pointer, or a typedef alias resolved to one of those -- or -1 when the
// declaration carries no size.  Never diagnoses.
int declared_type_size(const char *name);

#endif
