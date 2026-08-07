//! @file compiler/compile_type.h
//! @brief Declares type declaration and layout handling for the VCSC compiler.
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
const char *parse_integer_style_flag_text(const char *text);
bool type_has_integer_style(const ASTNode *type, const char *style);
bool type_is_signed_integer(const ASTNode *type);
bool type_is_unsigned_integer(const ASTNode *type);
bool type_is_bcd_integer(const ASTNode *type);
bool type_is_promotable_integer(const ASTNode *type);
unsigned long long bcd_max_value_for_size(int size);
bool integer_value_fits_type(long long value, const ASTNode *type);
bool bcd_implicit_conversion_allowed(const ASTNode *dst_type, const ASTNode *dst_decl,
                                     const ASTNode *src_type, const ASTNode *src_decl,
                                     const ASTNode *src_expr);
bool bcd_power_of_ten_constant_expr(const ASTNode *expr, int *decimal_digits_out);
bool classify_trivial_integer_binary_expr(const ASTNode *expr, Context *ctx,
                                          const ASTNode **value_expr_out,
                                          bool *copy_value_out);
bool classify_trivial_integer_compound(const char *op, const ASTNode *lhs_type,
                                       const ASTNode *lhs_decl,
                                       const ASTNode *rhs_expr,
                                       bool *copy_value_out);
bool bcd_small_remainder_constant_expr(const ASTNode *expr, int *divisor_out);
bool classify_bcd_small_remainder_binary_expr(const ASTNode *expr, Context *ctx,
                                              const ASTNode **value_expr_out,
                                              int *divisor_out);
bool bcd_cheap_multiplier_constant_expr(const ASTNode *expr, int *power_a_out,
                                        int *power_b_out, bool *subtract_out);
bool classify_bcd_cheap_constant_multiply_binary_expr(const ASTNode *expr, Context *ctx,
                                                      const ASTNode **value_expr_out,
                                                      int *power_a_out,
                                                      int *power_b_out,
                                                      bool *subtract_out);
bool classify_bcd_power_of_ten_binary_expr(const ASTNode *expr, Context *ctx,
                                           const ASTNode **value_expr_out,
                                           int *decimal_digits_out);
void require_valid_bcd_operator_expr(ASTNode *expr, Context *ctx);
bool same_named_value_type(const ASTNode *lhs_type, const ASTNode *lhs_decl,
                           const ASTNode *rhs_type, const ASTNode *rhs_decl);
bool pointer_types_compatible(const ASTNode *lhs_type, const ASTNode *lhs_decl,
                              const ASTNode *rhs_type, const ASTNode *rhs_decl);
const ASTNode *pointer_difference_type(const ASTNode *origin);
const ASTNode *promoted_integer_type_for_binary(const ASTNode *lhs_type, const ASTNode *rhs_type, ASTNode *origin);
bool expr_is_literal_node(const ASTNode *expr);
const ASTNode *value_compare_integer_work_type(ASTNode *lhs_expr, ASTNode *rhs_expr, Context *ctx, ASTNode *origin);
const ASTNode *binary_integer_work_type(ASTNode *lhs_expr, ASTNode *rhs_expr, Context *ctx, ASTNode *origin);
const ASTNode *compound_integer_work_type(const ASTNode *lhs_type, const ASTNode *lhs_decl, ASTNode *rhs_expr, Context *ctx, ASTNode *origin);
void require_no_mixed_signed_integer_binary_expr(ASTNode *expr, Context *ctx);
const ASTNode *flag_cast_target_type(ASTNode *expr, Context *ctx);
const ASTNode *flag_cast_target_declarator(ASTNode *expr, Context *ctx);
int flag_cast_target_size(ASTNode *expr, Context *ctx);
const ASTNode *literal_annotation_type(const ASTNode *expr);
typedef struct MemRegionSet {
   const char **names;
   size_t count;
} MemRegionSet;

void mem_region_set_collect(const ASTNode *modifiers, MemRegionSet *set);
void mem_region_set_sort(MemRegionSet *set);
void mem_region_set_release(MemRegionSet *set);
bool mem_region_sets_equal(const ASTNode *a, const ASTNode *b);
const char *mem_region_set_first_sorted(const ASTNode *modifiers);

const char *find_mem_modifier_name(const ASTNode *modifiers);
const ASTNode *find_mem_modifier_node(const ASTNode *modifiers);
bool mem_decl_is_zeropage(const ASTNode *mem_decl);
bool mem_decl_is_readonly(const ASTNode *mem_decl);
bool mem_decl_is_writable(const ASTNode *mem_decl);
bool mem_decl_split_addresses(const ASTNode *mem_decl, unsigned int *read_start, unsigned int *write_start);
bool modifiers_imply_split_address(const ASTNode *modifiers);
bool modifiers_split_address_delta(const ASTNode *modifiers, int *delta);
bool modifiers_imply_zeropage(const ASTNode *modifiers);
bool modifiers_imply_readonly_mem(const ASTNode *modifiers);
bool modifiers_imply_mem_storage(const ASTNode *modifiers);
bool modifiers_imply_named_nonzeropage(const ASTNode *modifiers);
void build_named_storage_segment(char *buf, size_t bufsize, const ASTNode *modifiers, const char *base_segment);
int integer_literal_min_size(const ASTNode *expr);
bool has_flag(const char *type, const char *flag);
bool has_flag_prefix(const char *type, const char *prefix);
const char *enum_backing_type_name(const char *type);
bool has_modifier(ASTNode *node, const char *modifier);
bool declaration_alignment(const ASTNode *modifiers, unsigned int *alignment_out);
typedef enum DeclarationUseContract {
   DECL_USE_CONTRACT_NONE = 0,
   DECL_USE_CONTRACT_RECOMMEND = 1,
   DECL_USE_CONTRACT_REQUIRE = 2
} DeclarationUseContract;

typedef enum DeclarationContractSymbolKind {
   DECL_CONTRACT_OBJECT = 0,
   DECL_CONTRACT_FUNCTION = 1
} DeclarationContractSymbolKind;

DeclarationUseContract declaration_use_contract(const ASTNode *modifiers);
bool declaration_has_use_contract(const ASTNode *modifiers);
const ASTNode *declaration_use_contract_origin(const ASTNode *modifiers);
void remember_declaration_use_contract(DeclarationContractSymbolKind kind,
                                       const char *name,
                                       const ASTNode *modifiers);
DeclarationUseContract declaration_symbol_use_contract(DeclarationContractSymbolKind kind,
                                                        const char *name,
                                                        const ASTNode **origin_out);
bool declaration_const_applies_to_object(const ASTNode *modifiers, const ASTNode *declarator);
PointerAccessQualifier declaration_pointer_access(const ASTNode *modifiers,
                                                  const ASTNode *declarator);
const char *pointer_access_qualifier_name(PointerAccessQualifier qualifier);
bool pointer_access_implicit_conversion_allowed(PointerAccessQualifier dst,
                                                PointerAccessQualifier src);
void validate_pointer_access_conversion(const ASTNode *origin,
                                       PointerAccessQualifier dst,
                                       PointerAccessQualifier src,
                                       const char *what);
void validate_declaration_access_qualifiers(const ASTNode *origin,
                                            const ASTNode *modifiers,
                                            const ASTNode *declarator,
                                            const char *what);
int get_size(const char *type);
int type_size_from_node(const ASTNode *type);
int declarator_value_size(const ASTNode *type, const ASTNode *declarator);
int expr_value_size(ASTNode *expr, Context *ctx);
bool expr_is_integer_constant_expr(const ASTNode *expr, long long *value_out);
bool expr_is_untyped_integer_literal(const ASTNode *expr);
bool integer_literal_is_zero_expr(const ASTNode *expr);
bool integer_literal_fits_plain_integer_type(const ASTNode *expr, const ASTNode *formal_type, const ASTNode *formal_decl);

#endif
