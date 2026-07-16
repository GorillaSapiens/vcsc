//! @file compiler/compile_call.h
//! @brief Declares function call lowering for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_CALL_H_
#define _INCLUDE_COMPILE_CALL_H_

#include "ast.h"
#include "compile_internal.h"

bool compile_call_expr_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst);

#endif
