//! @file compiler/compile_inline_prepass.h
//! @brief Builds optimizer direct-callsite facts before ordinary function lowering.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_INLINE_PREPASS_H_
#define _INCLUDE_COMPILE_INLINE_PREPASS_H_

#include "ast.h"

void analyze_optimizer_direct_calls(ASTNode *program);

#endif
