//! @file compiler/compile_init.h
//! @brief Declares initializer lowering for the n65 compiler.
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
bool eval_constant_initializer_expr(ASTNode *expr, InitConstValue *out);
bool encode_integer_initializer_value(long long value, unsigned char *buf, int size, const ASTNode *type);
bool encode_init_const_int_value(const InitConstValue *value, unsigned char *buf, int size, const ASTNode *type);
bool encode_float_initializer_value(double value, unsigned char *buf, int size, const ASTNode *type);
void emit_initializer_bytes_line(EmitSink *sink, const unsigned char *bytes, int size);
bool emit_global_initializer(EmitSink *sink, const ASTNode *type, const ASTNode *declarator, ASTNode *expression, int size);
void emit_sink_append(EmitSink *dst, const EmitSink *src);
void remember_pending_global_init(const char *name, const char *symbol, const ASTNode *type, const ASTNode *declarator,
                                  ASTNode *expression, int size, bool is_zeropage, bool is_absolute_ref,
                                  const char *read_expr, const char *write_expr);
void emit_runtime_global_init_function(void);
bool compile_initializer_to_fp(const ASTNode *init, Context *ctx, const ASTNode *type, const ASTNode *declarator,
                               int base_offset, int total_size);

#endif
