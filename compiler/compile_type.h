//! @file compiler/compile_type.h
//! @brief Declares type declaration and layout handling for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_TYPE_H_
#define _INCLUDE_COMPILE_TYPE_H_

#include <stdbool.h>
#include <stddef.h>
#include "ast.h"
#include "compile_internal.h"
#include "compile_declarator.h"

const ASTNode *type_name_node(const ASTNode *type);
const char *type_name_from_node(const ASTNode *type);
const ASTNode *required_typename_node(const char *name);
const ASTNode *bool_type_node(void);
bool type_is_bool(const ASTNode *type);
const char *parse_integer_style_flag_text(const char *text);
bool type_has_integer_style(const ASTNode *type, const char *style);
bool type_is_signed_integer(const ASTNode *type);
bool type_is_unsigned_integer(const ASTNode *type);
bool type_is_promotable_integer(const ASTNode *type);
bool same_named_value_type(const ASTNode *lhs_type, const ASTNode *lhs_decl,
                           const ASTNode *rhs_type, const ASTNode *rhs_decl);
const char *type_endian_name(const ASTNode *type);
bool type_is_big_endian(const ASTNode *type);
int endian_mem_index_for_significance(int size, bool big_endian, int significance_index);
const ASTNode *promoted_integer_type_for_binary(const ASTNode *lhs_type, const ASTNode *rhs_type, ASTNode *origin);
bool expr_is_literal_node(const ASTNode *expr);
bool ordinary_integer_endian_conflict(const ASTNode *lhs_type, const ASTNode *rhs_type);
bool expr_is_mixed_endian_integer_binary_expr(ASTNode *expr, Context *ctx);
const ASTNode *target_endian_integer_binary_work_type(ASTNode *lhs_expr, ASTNode *rhs_expr, Context *ctx, const ASTNode *target_type, ASTNode *origin);
const ASTNode *value_compare_integer_work_type(ASTNode *lhs_expr, ASTNode *rhs_expr, Context *ctx, ASTNode *origin);
const ASTNode *binary_integer_work_type(ASTNode *lhs_expr, ASTNode *rhs_expr, Context *ctx, ASTNode *origin);
const ASTNode *compound_integer_work_type(const ASTNode *lhs_type, const ASTNode *lhs_decl, ASTNode *rhs_expr, Context *ctx, ASTNode *origin);
void require_no_mixed_signed_integer_binary_expr(ASTNode *expr, Context *ctx);
void require_no_mixed_endian_integer_binary_expr(ASTNode *expr, Context *ctx);
void require_no_mixed_endian_pointer_index_expr(ASTNode *origin, ASTNode *idx_expr, Context *ctx, const char *op);
const ASTNode *select_endian_variant_type(const ASTNode *src_type, const char *target_endian);
const ASTNode *flag_cast_target_type(ASTNode *expr, Context *ctx);
const ASTNode *flag_cast_target_declarator(ASTNode *expr, Context *ctx);
int flag_cast_target_size(ASTNode *expr, Context *ctx);
const ASTNode *literal_annotation_type(const ASTNode *expr);
const char *find_mem_modifier_name(const ASTNode *modifiers);
const ASTNode *find_mem_modifier_node(const ASTNode *modifiers);
bool mem_decl_is_zeropage(const ASTNode *mem_decl);
bool modifiers_imply_zeropage(const ASTNode *modifiers);
bool modifiers_imply_mem_storage(const ASTNode *modifiers);
bool modifiers_imply_named_nonzeropage(const ASTNode *modifiers);
void build_named_storage_segment(char *buf, size_t bufsize, const ASTNode *modifiers, const char *base_segment);
int integer_literal_min_size(const ASTNode *expr);
bool has_flag(const char *type, const char *flag);
bool has_flag_prefix(const char *type, const char *prefix);
const char *enum_backing_type_name(const char *type);
bool has_modifier(ASTNode *node, const char *modifier);
bool declaration_const_applies_to_object(const ASTNode *modifiers, const ASTNode *declarator);
int get_size(const char *type);
int type_size_from_node(const ASTNode *type);
int declarator_value_size(const ASTNode *type, const ASTNode *declarator);
int expr_value_size(ASTNode *expr, Context *ctx);
bool expr_is_integer_constant_expr(const ASTNode *expr, long long *value_out);
bool expr_is_untyped_integer_literal(const ASTNode *expr);
bool integer_literal_is_zero_expr(const ASTNode *expr);
bool integer_literal_fits_plain_integer_type(const ASTNode *expr, const ASTNode *formal_type, const ASTNode *formal_decl);

#endif
