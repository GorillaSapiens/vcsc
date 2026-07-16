//! @file compiler/compile_overload.h
//! @brief Declares operator overload resolution for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_OVERLOAD_H_
#define _INCLUDE_COMPILE_OVERLOAD_H_

#include <stdbool.h>
#include <stddef.h>
#include "ast.h"
#include "compile_internal.h"

bool is_operator_function_name(const char *name);
const char *operator_mangle_code(const char *name, int arg_count);
bool function_has_body(const ASTNode *fn);
bool parameter_is_ellipsis(const ASTNode *parameter);
bool parameter_list_is_variadic(const ASTNode *params);
bool function_is_variadic(const ASTNode *fn);
int function_fixed_parameter_stack_bytes(const ASTNode *fn);
int function_fixed_param_count(const ASTNode *fn);
const ASTNode *lookup_operator_overload(const char *name, int arg_count, const ASTNode **arg_types, const ASTNode **arg_decls, const bool *arg_lvalues, const ASTNode **arg_exprs, Context *ctx);
void remember_function(const ASTNode *node, const char *name);
bool ordinary_function_name_is_overloaded(const char *name);
bool function_symbol_name(const ASTNode *fn, const char *fallback_name, char *buf, size_t bufsize);
bool format_user_asm_symbol(const char *name, char *buf, size_t bufsize);
void append_mangled_text(char *buf, size_t bufsize, const char *text);
const ASTNode *resolve_function_designator_target(const char *name, const ASTNode *expected_type, const ASTNode *expected_decl);
const ASTNode *resolve_function_call_target(const char *name, ASTNode *call_expr, ASTNode *args, Context *ctx);
const ASTNode *resolve_operator_overload_expr(ASTNode *expr, Context *ctx);
const ASTNode *resolve_incdec_overload_expr(ASTNode *expr, Context *ctx);
const ASTNode *resolve_truthiness_overload(ASTNode *expr, Context *ctx);

#endif
