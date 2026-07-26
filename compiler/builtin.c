//! @file compiler/builtin.c
//! @brief Implements extensible compiler builtin lookup and evaluation.
//! @ingroup compiler

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#include "ast.h"
#include "builtin.h"
#include "builtin_rgb.h"
#include "compile_expr_info.h"
#include "compile_init.h"
#include "messages.h"

typedef bool (*BuiltinEvaluator)(const long long *args, int argc,
                                 long long *value_out);

typedef struct BuiltinSpec {
   const char *name;
   const char *result_type_name;
   int arity;
   bool has_uniform_integer_range;
   long long argument_minimum;
   long long argument_maximum;
   const char *argument_kind;
   BuiltinEvaluator evaluator;
} BuiltinSpec;

static bool eval_ntsc_rgb(const long long *args, int argc,
                          long long *value_out) {
   (void)argc;
   return builtin_ntsc_rgb_eval(args[0], args[1], args[2], value_out);
}

/* Adding another compile-time builtin requires one evaluator and one registry
 * row. Palette matchers such as PAL and SECAM can reuse builtin_rgb_nearest(). */
static const BuiltinSpec builtin_specs[] = {
   {
      "__builtin_ntsc_rgb",
      "uint8_t",
      3,
      true,
      0,
      255,
      "RGB",
      eval_ntsc_rgb
   }
};

static const BuiltinSpec *builtin_lookup_name(const char *name) {
   if (!name) {
      return NULL;
   }
   for (size_t i = 0; i < sizeof(builtin_specs) / sizeof(builtin_specs[0]); i++) {
      if (!strcmp(name, builtin_specs[i].name)) {
         return &builtin_specs[i];
      }
   }
   return NULL;
}

static const char *builtin_call_name(const ASTNode *call) {
   if (!call || strcmp(call->name, "()") || call->count < 1) {
      return NULL;
   }
   return expr_bare_identifier_name(call->children[0]);
}

static const BuiltinSpec *builtin_lookup_call(const ASTNode *call) {
   return builtin_lookup_name(builtin_call_name(call));
}

static BuiltinIntegerEvalStatus builtin_eval_spec_integer(
   const BuiltinSpec *spec, const long long *arguments, int argument_count,
   long long *value_out, BuiltinIntegerEvalDiagnostic *diagnostic_out) {
   BuiltinIntegerEvalDiagnostic diagnostic = {0};

   if (!spec) {
      return BUILTIN_INTEGER_EVAL_UNKNOWN;
   }
   diagnostic.expected_arity = spec->arity;
   if (argument_count != spec->arity) {
      if (diagnostic_out) *diagnostic_out = diagnostic;
      return BUILTIN_INTEGER_EVAL_WRONG_ARITY;
   }
   if (!arguments || !value_out) {
      return BUILTIN_INTEGER_EVAL_FAILED;
   }
   if (spec->has_uniform_integer_range) {
      for (int i = 0; i < argument_count; i++) {
         if (arguments[i] < spec->argument_minimum ||
             arguments[i] > spec->argument_maximum) {
            diagnostic.argument_index = i + 1;
            diagnostic.argument_minimum = spec->argument_minimum;
            diagnostic.argument_maximum = spec->argument_maximum;
            diagnostic.argument_kind = spec->argument_kind;
            if (diagnostic_out) *diagnostic_out = diagnostic;
            return BUILTIN_INTEGER_EVAL_ARGUMENT_RANGE;
         }
      }
   }
   if (!spec->evaluator(arguments, argument_count, value_out)) {
      return BUILTIN_INTEGER_EVAL_FAILED;
   }
   if (diagnostic_out) *diagnostic_out = diagnostic;
   return BUILTIN_INTEGER_EVAL_OK;
}

BuiltinIntegerEvalStatus builtin_eval_integer_arguments(
   const char *name, const long long *arguments, int argument_count,
   long long *value_out, BuiltinIntegerEvalDiagnostic *diagnostic_out) {
   return builtin_eval_spec_integer(builtin_lookup_name(name), arguments,
                                    argument_count, value_out, diagnostic_out);
}

bool builtin_name_is_registered(const char *name) {
   return builtin_lookup_name(name) != NULL;
}

const char *builtin_call_result_type_name(const ASTNode *call) {
   const BuiltinSpec *spec = builtin_lookup_call(call);
   return spec ? spec->result_type_name : NULL;
}

bool builtin_eval_constant_call(ASTNode *call, InitConstValue *out) {
   const BuiltinSpec *spec = builtin_lookup_call(call);
   ASTNode *args;
   int argc;
   long long argv[16];
   long long value = 0;
   BuiltinIntegerEvalDiagnostic diagnostic = {0};
   BuiltinIntegerEvalStatus status;

   if (!spec || !out) {
      return false;
   }

   args = call->count > 1 ? call->children[1] : NULL;
   argc = (args && !is_empty(args)) ? args->count : 0;
   if (argc > (int)(sizeof(argv) / sizeof(argv[0]))) {
      error_unreachable("compiler builtin argument buffer is too small");
   }
   if (argc != spec->arity) {
      error_user("[%s:%d.%d] compiler builtin '%s' expects %d arguments, got %d",
                 call->file ? call->file : "<unknown>", call->line, call->column,
                 spec->name, spec->arity, argc);
   }

   for (int i = 0; i < argc; i++) {
      InitConstValue arg = {0};
      ASTNode *arg_expr = args->children[i];

      if (!eval_constant_initializer_expr(arg_expr, &arg) ||
          arg.kind != INIT_CONST_INT) {
         error_user("[%s:%d.%d] argument %d to compiler builtin '%s' must be a compile-time integer constant",
                    arg_expr && arg_expr->file ? arg_expr->file : (call->file ? call->file : "<unknown>"),
                    arg_expr ? arg_expr->line : call->line,
                    arg_expr ? arg_expr->column : call->column,
                    i + 1, spec->name);
      }
      argv[i] = arg.i;
   }

   status = builtin_eval_spec_integer(spec, argv, argc, &value, &diagnostic);
   if (status == BUILTIN_INTEGER_EVAL_ARGUMENT_RANGE) {
      ASTNode *arg_expr = args->children[diagnostic.argument_index - 1];
      error_user("[%s:%d.%d] %s argument %d to compiler builtin '%s' is outside %lld..%lld: %lld",
                 arg_expr && arg_expr->file ? arg_expr->file : (call->file ? call->file : "<unknown>"),
                 arg_expr ? arg_expr->line : call->line,
                 arg_expr ? arg_expr->column : call->column,
                 diagnostic.argument_kind ? diagnostic.argument_kind : "integer",
                 diagnostic.argument_index, spec->name,
                 diagnostic.argument_minimum, diagnostic.argument_maximum,
                 argv[diagnostic.argument_index - 1]);
   }
   if (status != BUILTIN_INTEGER_EVAL_OK) {
      error_unreachable("compiler builtin '%s' evaluator failed", spec->name);
   }

   memset(out, 0, sizeof(*out));
   out->kind = INIT_CONST_INT;
   out->i = value;
   return true;
}
