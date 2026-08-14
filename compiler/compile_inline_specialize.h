//! @file compiler/compile_inline_specialize.h
//! @brief Plans and applies single-callsite parameter specialization.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_INLINE_SPECIALIZE_H_
#define _INCLUDE_COMPILE_INLINE_SPECIALIZE_H_

#include <stdbool.h>
#include "ast.h"
#include "compile_internal.h"

typedef struct InlineRefSpecialization {
   const char *read_expr;
   const char *write_expr;
   int offset;
   bool is_zeropage;
   bool has_split_alias_delta;
   int split_alias_delta;
} InlineRefSpecialization;

typedef enum InlineValueSpecializationKind {
   INLINE_VALUE_NONE = 0,
   INLINE_VALUE_ADDRESS,
   INLINE_VALUE_INTEGER_CONSTANT
} InlineValueSpecializationKind;

typedef struct InlineValueSpecialization {
   InlineValueSpecializationKind kind;
   const char *read_expr;
   int offset;
   bool is_zeropage;
   long long constant_value;
} InlineValueSpecialization;

void analyze_optimizer_ref_specializations(ASTNode *program);
bool optimizer_ref_parameter_specialization(const ASTNode *fn, int parameter_index,
                                            InlineRefSpecialization *out);
void apply_optimizer_ref_specializations(const ASTNode *fn, Context *ctx);

void analyze_optimizer_value_specializations(ASTNode *program);
bool optimizer_value_parameter_specialization(const ASTNode *fn, int parameter_index,
                                              InlineValueSpecialization *out);
void apply_optimizer_value_specializations(const ASTNode *fn, Context *ctx);

/* Evaluate expressions after readonly single-callsite bindings have been
   planned/applied.  The context form is used while lowering a function; the
   function form is used by pre-lowering reachability/DCE. */
bool optimizer_eval_context_constant_expr(ASTNode *expr, Context *ctx, InitConstValue *out);
bool optimizer_eval_function_constant_expr(const ASTNode *fn, ASTNode *expr, InitConstValue *out);

#endif
