//! @file compiler/compile_function.h
//! @brief Declares function ABI lowering for the VCSC compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_FUNCTION_H_
#define _INCLUDE_COMPILE_FUNCTION_H_

#include <stdbool.h>
#include <stddef.h>
#include "ast.h"
#include "compile_internal.h"

#define SYMBOL_BACKED_META_PREFIX "__sbpmeta$"

bool function_parameter_uses_symbol_storage(const ASTNode *fn, const ASTNode *parameter);
bool function_parameter_symbol_name(const ASTNode *fn, const ASTNode *parameter, int index,
                                    char *buf, size_t bufsize, bool *is_zeropage_out);
bool return_type_is_void(const ASTNode *type, const ASTNode *declarator);
bool return_type_is_supported(const ASTNode *type, const ASTNode *declarator);
bool return_type_has_value(const ASTNode *type, const ASTNode *declarator);
bool function_has_return_object(const ASTNode *fn);
bool function_return_symbol_name(const ASTNode *fn, char *buf, size_t bufsize);
void validate_function_return_type(const ASTNode *fn);
void record_call_graph_edge(const ASTNode *caller, const ASTNode *callee);
void analyze_static_parameter_call_graph(void);
void emit_symbol_backed_call_graph_metadata(void);

#endif
