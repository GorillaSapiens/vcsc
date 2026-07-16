//! @file compiler/compile_expr_flow.h
//! @brief Declares control-flow expression lowering for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_EXPR_FLOW_H_
#define _INCLUDE_COMPILE_EXPR_FLOW_H_

#include "ast.h"
#include "compile_internal.h"

bool compile_condition_branch_false(ASTNode *expr, Context *ctx, const char *false_label);
void compile_expr(ASTNode *node, Context *ctx);

#endif
