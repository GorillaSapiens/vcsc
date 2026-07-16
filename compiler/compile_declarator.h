//! @file compiler/compile_declarator.h
//! @brief Declares declarator analysis for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_DECLARATOR_H_
#define _INCLUDE_COMPILE_DECLARATOR_H_

#include <stdbool.h>
#include "ast.h"
#include "compile_internal.h"

bool declarator_array_signature_matches_from(const ASTNode *actual, const ASTNode *formal, int start_child);
bool declarator_signature_matches(const ASTNode *actual, const ASTNode *formal);
bool declarator_is_plain_value(const ASTNode *declarator);
const ASTNode *call_adjusted_parameter_declarator(const ASTNode *declarator, bool is_ref);
void expr_match_signature(ASTNode *expr, Context *ctx, const ASTNode **type_out, const ASTNode **decl_out);
const char *missing_argname(int i);
ASTNode *make_named_pointer_declarator(const char *name);
const ASTNode *parameter_decl_specifiers(const ASTNode *parameter);
const ASTNode *parameter_type(const ASTNode *parameter);
const ASTNode *parameter_declarator(const ASTNode *parameter);
bool parameter_is_ref(const ASTNode *parameter);
bool parameter_has_symbol_storage(const ASTNode *parameter);
int parameter_storage_size(const ASTNode *parameter);
const char *parameter_name(const ASTNode *parameter, int i);
bool parameter_is_void(const ASTNode *parameter);
const ASTNode *unwrap_expr_node(const ASTNode *expr);
const ASTNode *declarator_value_declarator(const ASTNode *declarator);
const ASTNode *declarator_name_node(const ASTNode *declarator);
const char *declarator_name(const ASTNode *declarator);
const ASTNode *declarator_bitfield_node(const ASTNode *declarator);
int declarator_bitfield_width(const ASTNode *declarator);
int declarator_suffix_start_index(const ASTNode *declarator);
const ASTNode *declarator_parameter_list(const ASTNode *declarator);
bool declarator_has_parameter_list(const ASTNode *declarator);
int declarator_pointer_depth(const ASTNode *declarator);
int declarator_pointer_node_count(const ASTNode *declarator);
int declarator_function_pointer_depth(const ASTNode *declarator);
int declarator_array_multiplier_from(const ASTNode *declarator, int start_child);
int declarator_array_count(const ASTNode *declarator);
int declarator_first_element_size(const ASTNode *type, const ASTNode *declarator);
const ASTNode *clone_declarator_variant(const ASTNode *declarator, int new_ptr_depth, int first_array_child);
const ASTNode *function_pointer_declarator_from_callable(const ASTNode *declarator);
const ASTNode *function_return_declarator_from_callable(const ASTNode *declarator);
const ASTNode *declarator_after_subscript(const ASTNode *declarator);
const ASTNode *declarator_after_deref(const ASTNode *declarator);
const ASTNode *function_return_type(const ASTNode *fn);
const ASTNode *function_declarator_node(const ASTNode *fn);
bool declarator_is_function(const ASTNode *declarator);
int declarator_array_multiplier(const ASTNode *declarator);
int declarator_storage_size(const ASTNode *type, const ASTNode *declarator);

#endif
