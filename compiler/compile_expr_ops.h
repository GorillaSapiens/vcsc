//! @file compiler/compile_expr_ops.h
//! @brief Declares operator lowering helpers for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_EXPR_OPS_H_
#define _INCLUDE_COMPILE_EXPR_OPS_H_

#include "ast.h"
#include "compile_internal.h"

bool compile_expr_operator_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst);

#endif
