//! @file compiler/compile_function.h
//! @brief Declares function and variadic ABI lowering for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_FUNCTION_H_
#define _INCLUDE_COMPILE_FUNCTION_H_

#include <stdbool.h>
#include <stddef.h>
#include "ast.h"
#include "compile_internal.h"

#define SYMBOL_BACKED_META_PREFIX "__sbpmeta$"
#define VARIADIC_HIDDEN_ARGS_NAME "__va_args"
#define VARIADIC_HIDDEN_BYTES_NAME "__va_arg_bytes"
#define BUILTIN_VA_START_NAME "va_start"
#define BUILTIN_VA_ARG_NAME "va_arg"
#define BUILTIN_VA_END_NAME "va_end"
#define BUILTIN_VA_LIST_TYPE_NAME "va_list"
#define BUILTIN_VA_LIST_ARGS_FIELD "args"
#define BUILTIN_VA_LIST_BYTES_FIELD "bytes"
#define BUILTIN_VA_LIST_OFFSET_FIELD "offset"

bool function_parameter_symbol_name(const ASTNode *fn, const ASTNode *parameter, int index,
                                    char *buf, size_t bufsize, bool *is_zeropage_out);
bool builtin_variadic_call_name(const char *name);
bool compile_builtin_va_start_expr(ASTNode *expr, Context *ctx);
bool compile_builtin_va_arg_expr(ASTNode *expr, Context *ctx);
bool compile_builtin_va_end_expr(ASTNode *expr, Context *ctx);
void record_call_graph_edge(const ASTNode *caller, const ASTNode *callee);
void analyze_static_parameter_call_graph(void);
void emit_symbol_backed_call_graph_metadata(void);

#endif
