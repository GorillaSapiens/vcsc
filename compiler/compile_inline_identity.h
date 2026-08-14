//! @file compiler/compile_inline_identity.h
//! @brief ABI/assembly identity and reachability gates for item-31 optimization.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_INLINE_IDENTITY_H_
#define _INCLUDE_COMPILE_INLINE_IDENTITY_H_

#include <stdbool.h>

#include "ast.h"

void analyze_optimizer_inline_identity(ASTNode *program);
void recompute_optimizer_inline_reachability(ASTNode *program);
const char *optimizer_inline_identity_rejection(const ASTNode *fn);
bool optimizer_inline_identity_legal(const ASTNode *fn);
bool optimizer_inline_function_reachable(const ASTNode *fn);
bool optimizer_inline_function_dead(const ASTNode *fn);
void optimizer_inline_set_dead_pruning(bool enabled);

#endif
