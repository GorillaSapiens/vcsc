//! @file compiler/compile_expr_slot.h
//! @brief Declares expression-to-storage-slot lowering for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_EXPR_SLOT_H_
#define _INCLUDE_COMPILE_EXPR_SLOT_H_

#include "ast.h"
#include "compile_internal.h"

bool compile_constant_expr_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst);
bool compile_expr_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst);

#endif
