//! @file compiler/compile_function_registry.h
//! @brief Declares direct named-function registration and call validation.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_FUNCTION_REGISTRY_H_
#define _INCLUDE_COMPILE_FUNCTION_REGISTRY_H_

#include <stdbool.h>
#include <stddef.h>
#include "ast.h"
#include "compile_internal.h"

bool function_has_body(const ASTNode *fn);
int function_fixed_param_count(const ASTNode *fn);
void remember_function(const ASTNode *node, const char *name);
bool function_symbol_name(const ASTNode *fn, const char *fallback_name, char *buf, size_t bufsize);
bool format_user_asm_symbol(const char *name, char *buf, size_t bufsize);
const ASTNode *resolve_function_designator_target(const char *name);
const ASTNode *resolve_function_call_target(const char *name, ASTNode *call_expr, ASTNode *args, Context *ctx);

#endif
