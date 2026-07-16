//! @file compiler/compile_internal.h
//! @brief Declares internal compiler interfaces for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_INTERNAL_H_
#define _INCLUDE_COMPILE_INTERNAL_H_

#include <stdbool.h>
#include <stddef.h>
#include "ast.h"
#include "pair.h"
#include "set.h"

#include "emit.h"
#include "compile_literal.h"

typedef enum InitConstKind {
   INIT_CONST_NONE = 0,
   INIT_CONST_INT,
   INIT_CONST_FLOAT,
   INIT_CONST_ADDRESS
} InitConstKind;

typedef struct InitConstValue {
   InitConstKind kind;
   long long i;
   double f;
   const char *symbol;
   long long addend;
   const char *int_text;
} InitConstValue;

typedef struct ContextEntry {
   const char *name;
   const ASTNode *type;
   const ASTNode *declarator;
   bool is_static;
   bool is_zeropage;
   bool is_global;
   bool is_ref;
   bool is_absolute_ref;
   const char *read_expr;
   const char *write_expr;
   bool target_typed;
   int offset;
   int size;
} ContextEntry;

typedef struct Context {
   const char *name;
   int locals;
   int params;
   Set *vars;
   const char *break_label;
   const char *continue_label;
} Context;

typedef struct LValueRef {
   const char *name;
   const ASTNode *type;
   const ASTNode *declarator;
   const ASTNode *base_type;
   const ASTNode *base_declarator;
   const ASTNode *suffixes;
   bool is_static;
   bool is_zeropage;
   bool is_global;
   bool is_ref;
   bool is_absolute_ref;
   const char *read_expr;
   const char *write_expr;
   bool indirect;
   int deref_depth;
   bool needs_runtime_address;
   int base_offset;
   int offset;
   int size;
   int ptr_adjust;
   bool is_bitfield;
   int bit_offset;
   int bit_width;
   int bit_storage_size;
} LValueRef;

typedef struct AggregateMemberInfo {
   const ASTNode *type;
   const ASTNode *declarator;
   int byte_offset;
   int bit_offset;
   int bit_width;
   int storage_size;
   bool is_bitfield;
} AggregateMemberInfo;

extern EmitSink es_header;
extern EmitSink es_import;
extern EmitSink es_export;
extern EmitSink es_code;
extern EmitSink es_rodata;
extern EmitSink es_data;
extern EmitSink es_bss;
extern EmitSink es_zp;
extern EmitSink es_zpdata;
extern Pair *typesizes;
extern Pair *enumbackings;
extern Set *globals;
extern Set *functions;
extern Set *runtime_imports;
extern Set *imported_symbols;
extern Set *abi_metadata_symbols;
extern Set *string_literals;
extern int label_counter;
extern int current_call_graph_node;
extern const ASTNode *current_call_graph_function;

const ASTNode *global_decl_lookup(const char *name);
ContextEntry *ctx_lookup(Context *ctx, const char *name);
void ctx_push(Context *ctx, const ASTNode *type, const char *name);
void ctx_resize_last_push(Context *ctx, const ASTNode *type, const ASTNode *declarator, const char *name);
void ctx_static(Context *ctx, const ASTNode *type, const char *name);
void ctx_zeropage(Context *ctx, const ASTNode *type, const char *name);
const char *next_label(const char *prefix);
void emit_copy_fp_to_fp(int dst_offset, int src_offset, int size);
void emit_prepare_fp_ptr(int ptrno, int offset);
void emit_add_fp_to_ptr(int ptrno, int src_offset, int src_size);
void emit_load_address_to_ptr(int ptrno, const char *symbol, int addend);
const char *assembler_address_expr(const char *expr, char *buf, size_t buf_size);
void emit_load_expr_address_to_ptr(int ptrno, const char *expr, int addend);
void emit_load_ptr_from_symbol(int ptrno, const char *symbol, int addend);
void emit_deref_ptr(int ptrno);
void emit_load_a_from_expr_address(const char *expr, int addend);
void emit_store_a_to_expr_address(const char *expr, int addend);
void emit_runtime_fill_ptr1(int count, unsigned char value);
const char *runtime_copy_convert_helper_name(int dst_size, const ASTNode *dst_type, int src_size, const ASTNode *src_type);
void emit_runtime_copy_ptr0_to_ptr1(const char *helper, int src_size, int dst_size);
void emit_copy_fp_to_fp_convert(int dst_offset, int dst_size, const ASTNode *dst_type, int src_offset, int src_size, const ASTNode *src_type);
void emit_runtime_binary_fp_fp(const char *helper, int dst_offset, int lhs_offset, int rhs_offset, int size);
void emit_runtime_fixed_binary_fp_fp(const char *helper, int dst_offset, int lhs_offset, int rhs_offset);
const char *int_addsub_helper_name(const ASTNode *type, int size, bool subtract, bool *is_generic_out);
const char *int_mul_helper_name(const ASTNode *type);
int int_mul_result_offset(const ASTNode *type, int dst_offset, int size);
const char *int_div_helper_name(const ASTNode *type);
const char *int_shift_helper_name(const ASTNode *type, bool left);
const char *int_comp2_helper_name(const ASTNode *type);
const char *int_compare_helper_name(const ASTNode *type, const char *op);
void emit_runtime_float_binary_fp_fp(const char *helper, int dst_offset, int lhs_offset, int rhs_offset, int size, int expbits, bool big_endian);
void emit_runtime_float_compare(int lhs_offset, int rhs_offset, int size, int expbits);
void emit_runtime_shift_fp(const char *helper, int dst_offset, int lhs_offset, int rhs_offset, const ASTNode *rhs_type, int rhs_size, int value_size);
bool compile_constant_expr_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst);
ASTNode *make_synthetic_call_expr(ASTNode *origin, const char *callee_name, ASTNode *args[], int argc);
bool expr_eligible_for_weak_builtin_operator(ASTNode *expr, Context *ctx,
                                             const char **opname_out,
                                             const ASTNode **ret_type_out,
                                             const ASTNode **ret_decl_out,
                                             int *ret_size_out,
                                             int *arg_count_out,
                                             ASTNode **arg_exprs_out,
                                             const ASTNode **arg_types_out,
                                             const ASTNode **arg_decls_out);
void emit_sub_fp_from_fp(const ASTNode *type, int dst_offset, int src_offset, int size);
bool compile_condition_branch_false(ASTNode *expr, Context *ctx, const char *false_label);
void compile_expr(ASTNode *node, Context *ctx);
void build_function_context(const ASTNode *node, Context *ctx);
void emit_function_parameter_storage(const ASTNode *fn, Context *ctx);
void emit_function_parameter_exports(const ASTNode *fn);
void emit_variadic_hidden_local_setup(const ASTNode *node, Context *ctx);
int call_graph_node_index_for_function(const ASTNode *fn);
void remember_symbol_import(const char *name);
bool init_context_entry_from_global_decl(ContextEntry *entry, const char *name, const ASTNode *g);
const ASTNode *cast_expr_target_type(const ASTNode *expr);
const ASTNode *cast_expr_target_declarator(const ASTNode *expr);
bool function_has_static_parameters(const ASTNode *fn);
bool entry_symbol_name(Context *ctx, const ContextEntry *entry, char *buf, size_t bufsize);
bool resolve_lvalue(Context *ctx, ASTNode *node, LValueRef *out);
void emit_fill_fp_bytes(int dst_offset, int start, int count, unsigned char value);
bool emit_copy_fp_to_lvalue(Context *ctx, const LValueRef *dst, int src_offset, int size);
void emit_copy_fp_to_symbol(const char *symbol, int src_offset, int size);
void emit_store_label_address_to_fp(int dst_offset, int dst_size, const char *label);
const ASTNode *expr_value_type(ASTNode *expr, Context *ctx);
bool eval_constant_initializer_expr(ASTNode *expr, InitConstValue *out);
const ASTNode *expr_value_declarator(ASTNode *expr, Context *ctx);
bool resolve_ref_argument_lvalue(Context *ctx, ASTNode *expr, LValueRef *out);
bool classify_incdec_lvalue_expr(ASTNode *expr, bool *inc, bool *pre);
const char *expr_bare_identifier_name(ASTNode *expr);
void validate_nonreserved_variadic_name(const char *name, const ASTNode *node);
void validate_function_nonreserved_variadic_names(const ASTNode *fn);
void validate_function_parameter_storage_modifiers(const ASTNode *fn);
void remember_runtime_import(const char *name);
void emit_store_immediate_to_fp(int dst_offset, const unsigned char *bytes, int size);
void emit_add_immediate_to_fp(const ASTNode *type, int offset, const unsigned char *bytes, int size);
void emit_add_fp_to_fp(const ASTNode *type, int dst_offset, int src_offset, int size);
bool compile_expr_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst);
bool find_aggregate_member(const ASTNode *type, const char *member, const ASTNode **member_type, const ASTNode **member_declarator, int *member_offset);
void calculate_struct_union_sizes(ASTNode *program);

#endif
