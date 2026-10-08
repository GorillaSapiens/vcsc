//! @file compiler/compile_init.h
//! @brief Declares initializer lowering for the VCSC compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_INIT_H_
#define _INCLUDE_COMPILE_INIT_H_

#include <stdbool.h>
#include "ast.h"
#include "compile_internal.h"
#include "emit.h"

bool type_is_aggregate(const ASTNode *type);
bool initializer_is_list(const ASTNode *init);
void diagnose_constant_shift_count(ASTNode *count_expr, int lhs_bits);
typedef bool (*InitConstIdentifierResolver)(const char *name, InitConstValue *out, void *opaque);
bool eval_constant_initializer_expr_resolved(ASTNode *expr, InitConstValue *out,
                                             InitConstIdentifierResolver resolver,
                                             void *opaque);
bool eval_constant_initializer_expr(ASTNode *expr, InitConstValue *out);

// Record a file-scope `const` scalar's folded bytes as a compile-time value, so an
// expression that uses it folds instead of being computed at runtime.  Only plain ROM
// data may be recorded: elsewhere -- a named memory region, zeropage, an absolute
// binding, swapram -- the byte's ADDRESSABILITY is the contract rather than its value,
// and folding a read would erase the very reference the linker diagnoses.
void const_scalar_value_record(const char *name, const unsigned char *bytes, int size);
bool const_scalar_value_lookup(const char *name, long long *out);

// eval_constant_initializer_expr with const scalars resolvable by name.  Separate from
// the plain entry point because a constant expression is also evaluated while PARSING,
// to fold an array extent, where no scope exists and nothing has been recorded yet.
bool eval_constant_initializer_expr_in_scope(ASTNode *expr, Context *ctx, InitConstValue *out);
bool encode_integer_initializer_value(long long value, unsigned char *buf, int size, const ASTNode *type);
bool encode_integer_literal_text(const char *text, unsigned char *buf, int size, const ASTNode *type);
bool encode_init_const_int_value(const InitConstValue *value, unsigned char *buf, int size, const ASTNode *type);
void emit_initializer_bytes_line(EmitSink *sink, const unsigned char *bytes, int size);
bool global_initializer_is_all_zero(const ASTNode *type, const ASTNode *declarator, ASTNode *expression, int size);
bool emit_global_initializer(EmitSink *sink, const ASTNode *type, const ASTNode *declarator, ASTNode *expression, int size, unsigned char **link_time_bytes);
void const_link_time_table_record(const char *name, const unsigned char *bytes, int size, int elem_size);
bool const_link_time_table_byte(const ASTNode *at, const char *name, long long index, long long *out);
void emit_sink_append(EmitSink *dst, const EmitSink *src);
void remember_pending_global_init(const char *name, const char *symbol, const ASTNode *type, const ASTNode *declarator,
                                  ASTNode *expression, int size, bool is_zeropage, bool is_absolute_ref,
                                  bool is_swapram, const char *read_expr, const char *write_expr);
void emit_runtime_global_init_function(void);
bool compile_initializer_to_scratch(const ASTNode *init, Context *ctx, const ASTNode *type, const ASTNode *declarator,
                               int base_offset, int total_size);

#endif
