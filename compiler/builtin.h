//! @file compiler/builtin.h
//! @brief Declares compiler builtin lookup and compile-time evaluation.
//! @ingroup compiler

#ifndef _INCLUDE_BUILTIN_H_
#define _INCLUDE_BUILTIN_H_

#include <stdbool.h>

#include "ast.h"
#include "compile_internal.h"


typedef enum BuiltinIntegerEvalStatus {
   BUILTIN_INTEGER_EVAL_OK = 0,
   BUILTIN_INTEGER_EVAL_UNKNOWN,
   BUILTIN_INTEGER_EVAL_WRONG_ARITY,
   BUILTIN_INTEGER_EVAL_ARGUMENT_RANGE,
   BUILTIN_INTEGER_EVAL_FAILED
} BuiltinIntegerEvalStatus;

typedef struct BuiltinIntegerEvalDiagnostic {
   int expected_arity;
   int argument_index;
   long long argument_minimum;
   long long argument_maximum;
   const char *argument_kind;
} BuiltinIntegerEvalDiagnostic;

//! Evaluate a registered builtin from already-folded integer arguments.
BuiltinIntegerEvalStatus builtin_eval_integer_arguments(
   const char *name, const long long *arguments, int argument_count,
   long long *value_out, BuiltinIntegerEvalDiagnostic *diagnostic_out);

//! True when name is reserved by a registered compiler builtin.
bool builtin_name_is_registered(const char *name);

//! Return a registered builtin call's result type name, or NULL for a normal call.
const char *builtin_call_result_type_name(const ASTNode *call);

//! Evaluate a recognized builtin call as an integer constant.
bool builtin_eval_constant_call(ASTNode *call, InitConstValue *out);

#endif // _INCLUDE_BUILTIN_H_
