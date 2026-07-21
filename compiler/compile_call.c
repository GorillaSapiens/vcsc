//! @file compiler/compile_call.c
//! @brief Implements function call lowering for the VCSC compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#include "ast.h"
#include "compile_call.h"
#include "compile_expr.h"
#include "compile_expr_info.h"
#include "compile_function.h"
#include "compile_internal.h"
#include "compile_lvalue.h"
#include "compile_function_registry.h"
#include "compile_support.h"
#include "compile_stmt.h"
#include "compile_type.h"
#include "integer.h"
#include "messages.h"

#define INLINE_EXPANSION_MAX_DEPTH 128

static const ASTNode *inline_expansion_stack[INLINE_EXPANSION_MAX_DEPTH];
static int inline_expansion_depth = 0;
static int inline_expansion_counter = 0;

static void inline_expansion_push(const ASTNode *fn, const ASTNode *call_expr) {
   const char *name = declarator_name(function_declarator_node(fn));

   for (int i = 0; i < inline_expansion_depth; i++) {
      if (inline_expansion_stack[i] == fn) {
         error_user("[%s:%d.%d] recursive inline-expansion cycle reaches function '%s'",
                    call_expr->file, call_expr->line, call_expr->column,
                    name ? name : "<unnamed>");
      }
   }
   if (inline_expansion_depth >= INLINE_EXPANSION_MAX_DEPTH) {
      error_user("[%s:%d.%d] inline expansion nesting exceeds %d levels",
                 call_expr->file, call_expr->line, call_expr->column,
                 INLINE_EXPANSION_MAX_DEPTH);
   }
   inline_expansion_stack[inline_expansion_depth++] = fn;
}

static void inline_expansion_pop(const ASTNode *fn) {
   if (inline_expansion_depth <= 0 || inline_expansion_stack[inline_expansion_depth - 1] != fn) {
      error_unreachable("unbalanced inline expansion stack");
   }
   inline_expansion_depth--;
}

//! @brief Lower one direct source-level inline expansion at the current call site.
static bool compile_inline_symbol_call(Context *caller_ctx, ContextEntry *dst,
                                       ASTNode *callee, ASTNode *args,
                                       const ASTNode *fn, const ASTNode *declarator,
                                       const ASTNode *ret_type, int ret_size,
                                       ASTNode *call_expr) {
   const ASTNode *params = declarator_parameter_list(declarator);
   ASTNode *body;
   Context inline_ctx;
   ContextEntry *return_entry;
   StatementCompileState stmt_state;
   CompilerScratchLease arg_scratch;
   bool have_arg_scratch;
   int arg_count = (args && !is_empty(args)) ? args->count : 0;
   int actual_index = 0;
   int expansion_id = inline_expansion_counter++;
   char callee_sym[256];
   char context_name[768];
   char label_prefix[64];
   char return_label[96];
   char return_sym[1024];

   if (!function_has_body(fn)) {
      const char *inline_name = declarator_name(function_declarator_node(fn));
      error_user("[%s:%d.%d] inline function '%s' is called without a visible definition",
                 call_expr->file, call_expr->line, call_expr->column,
                 inline_name ? inline_name : "<unnamed>");
   }
   body = fn->children[2];
   if (!function_symbol_name(fn, callee->strval, callee_sym, sizeof(callee_sym))) {
      return false;
   }

   snprintf(label_prefix, sizeof(label_prefix), "inline_%d", expansion_id);
   snprintf(return_label, sizeof(return_label), "@%s_return", label_prefix);
   /* The expansion id is translation-unit unique, so storage does not need to
      inherit the caller's context name. Keeping this name flat prevents deeply
      nested inline helpers from growing assembler symbols at every level. */
   snprintf(context_name, sizeof(context_name), "__inline$%d$%s",
            expansion_id, callee_sym);

   memset(&inline_ctx, 0, sizeof(inline_ctx));
   inline_ctx.name = strdup(context_name);
   inline_ctx.activation_owner =
      (caller_ctx && caller_ctx->activation_owner && *caller_ctx->activation_owner)
         ? caller_ctx->activation_owner : (caller_ctx ? caller_ctx->name : NULL);
   if (!inline_ctx.name) {
      error_unreachable("out of memory naming inline expansion");
   }
   inline_ctx.vars = new_set();
   inline_ctx.return_label = strdup(return_label);
   inline_ctx.inline_label_prefix = strdup(label_prefix);
   if (!inline_ctx.return_label || !inline_ctx.inline_label_prefix) {
      error_unreachable("out of memory naming inline labels");
   }

   build_function_context(fn, &inline_ctx);
   return_entry = (ContextEntry *)set_get(inline_ctx.vars, "$$");
   if (!is_empty(body) && !strcmp(body->name, "statement_list")) {
      predeclare_statement_list(body, &inline_ctx);
   }

   emit_function_parameter_storage(fn, &inline_ctx);
   if (function_has_return_object(fn)) {
      if (!return_entry || !entry_symbol_name(&inline_ctx, return_entry,
                                              return_sym, sizeof(return_sym))) {
         error_unreachable("[%s:%d.%d] invalid inline return object",
                           call_expr->file, call_expr->line, call_expr->column);
      }
      {
         char segbuf[512];
         build_activation_storage_segment(segbuf, sizeof(segbuf), &inline_ctx, NULL, "ZEROPAGE");
         emit(&es_zp, ".segment \"%s\"\n", segbuf);
      }
      emit(&es_zp, "%s:\n", return_sym);
      emit(&es_zp, "\t.res %d\n", return_entry->size);
   }

   have_arg_scratch = arg_count > 0;
   if (have_arg_scratch) {
      compiler_scratch_acquire(caller_ctx, 1, &arg_scratch);
   }

   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count && actual_index < arg_count; i++) {
         const ASTNode *parameter = params->children[i];
         const ASTNode *ptype = parameter_type(parameter);
         const ASTNode *pdecl = parameter_declarator(parameter);
         const char *pname;
         ContextEntry *pentry;
         ContextEntry tmp;
         char param_sym[1024];
         int psz;
         bool ok;

         if (!ptype || parameter_is_void(parameter)) {
            continue;
         }
         pname = parameter_name(parameter, i);
         pentry = ctx_lookup(&inline_ctx, pname);
         if (!pentry || !entry_symbol_name(&inline_ctx, pentry,
                                           param_sym, sizeof(param_sym))) {
            if (have_arg_scratch) compiler_scratch_release(&arg_scratch);
            error_unreachable("[%s:%d.%d] missing inline parameter storage for '%s'",
                              call_expr->file, call_expr->line, call_expr->column,
                              pname ? pname : "?");
         }
         psz = parameter_storage_size(parameter);
         memset(&tmp, 0, sizeof(tmp));
         tmp.name = "$inline_arg";
         tmp.type = parameter_is_ref(parameter) ? required_typename_node("*") : ptype;
         tmp.declarator = parameter_is_ref(parameter)
            ? NULL : call_adjusted_parameter_declarator(pdecl, false);
         tmp.target_typed = true;
         tmp.size = psz;

         if (psz > arg_scratch.reserved) {
            arg_scratch.reserved = psz;
         }
         compiler_scratch_activate(caller_ctx, &arg_scratch);
         if (parameter_is_ref(parameter)) {
            ok = compile_ref_argument_to_slot(args->children[actual_index], caller_ctx, 0, psz);
         }
         else {
            ok = compile_expr_to_slot(args->children[actual_index], caller_ctx, &tmp);
         }
         if (ok) {
            emit_copy_scratch_to_symbol(param_sym, 0, psz);
         }
         compiler_scratch_deactivate(caller_ctx, &arg_scratch);
         if (!ok) {
            if (have_arg_scratch) compiler_scratch_release(&arg_scratch);
            return false;
         }
         actual_index++;
      }
   }
   if (have_arg_scratch) {
      compiler_scratch_release(&arg_scratch);
   }

   inline_expansion_push(fn, call_expr);
   statement_compile_state_push(&stmt_state);
   emit(&es_code, "; begin inline expansion %s #%d\n", callee_sym, expansion_id);
   if (!is_empty(body)) {
      if (strcmp(body->name, "statement_list")) {
         error_unreachable("[%s:%d.%d] unexpected inline function body node '%s'",
                           body->file, body->line, body->column, body->name);
      }
      compile_statement_list(body, &inline_ctx);
   }
   emit(&es_code, "%s:\n", inline_ctx.return_label);
   emit(&es_code, "; end inline expansion %s #%d\n", callee_sym, expansion_id);
   statement_compile_state_pop(&stmt_state);
   inline_expansion_pop(fn);

   if (dst && ret_size > 0) {
      if (!return_entry || !entry_symbol_name(&inline_ctx, return_entry,
                                              return_sym, sizeof(return_sym))) {
         return false;
      }
      emit_copy_symbol_to_scratch_convert(dst->offset, dst->size, dst->type,
                                          return_sym, ret_size, ret_type);
   }
   return true;
}

//! @brief One staged fixed argument awaiting its final callee-parameter copy.
typedef struct DirectCallArgStage {
   const ASTNode *parameter;
   const ASTNode *type;
   const ASTNode *declarator;
   int size;
   int offset;
   bool is_ref;
   bool is_zeropage;
   char symbol[256];
} DirectCallArgStage;

//! @brief Lower an ordinary direct call using caller-owned argument staging.
static bool compile_direct_symbol_call(Context *ctx, ContextEntry *dst,
                                       ASTNode *callee, ASTNode *args,
                                       const ASTNode *fn, const ASTNode *declarator,
                                       const ASTNode *ret_type, int ret_size) {
   const ASTNode *params = declarator_parameter_list(declarator);
   int arg_count = (args && !is_empty(args)) ? args->count : 0;
   int actual_index = 0;
   int staged_count = 0;
   int total_size = 0;
   DirectCallArgStage *staged = NULL;
   CompilerScratchLease scratch;
   char callee_sym[256];
   char return_sym[256];

   if (!function_symbol_name(fn, callee->strval, callee_sym, sizeof(callee_sym))) {
      return false;
   }

   if (arg_count > 0) {
      staged = (DirectCallArgStage *)calloc((size_t)arg_count, sizeof(*staged));
      if (!staged) {
         error_unreachable("out of memory staging direct-call arguments");
      }
   }

   /* Reserve one caller-owned block for all arguments.  Earlier argument
      values must survive calls made while evaluating later arguments; writing
      callee-owned parameter symbols eagerly would make sibling activations
      unsafe to overlay. */
   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count && actual_index < arg_count; i++) {
         const ASTNode *parameter = params->children[i];
         DirectCallArgStage *item;

         if (!parameter_type(parameter) || parameter_is_void(parameter)) {
            continue;
         }
         item = &staged[staged_count++];
         item->parameter = parameter;
         item->type = parameter_type(parameter);
         item->declarator = parameter_declarator(parameter);
         item->is_ref = parameter_is_ref(parameter);
         item->size = parameter_storage_size(parameter);
         item->offset = total_size;
         total_size += item->size;

         if (!function_parameter_symbol_name(fn, parameter, i,
                                             item->symbol, sizeof(item->symbol),
                                             &item->is_zeropage)) {
            free(staged);
            return false;
         }
         if (!function_has_body(fn)) {
            remember_symbol_import_mode(item->symbol, item->is_zeropage);
         }
         actual_index++;
      }
   }

   if (staged_count > 0) {
      bool ok = true;
      compiler_scratch_acquire(ctx, total_size, &scratch);
      compiler_scratch_activate(ctx, &scratch);

      for (int i = 0; i < staged_count; i++) {
         DirectCallArgStage *item = &staged[i];
         ContextEntry tmp;

         memset(&tmp, 0, sizeof(tmp));
         tmp.name = "$callarg";
         tmp.type = item->is_ref ? required_typename_node("*") : item->type;
         tmp.declarator = item->is_ref ? NULL
            : call_adjusted_parameter_declarator(item->declarator, false);
         tmp.target_typed = true;
         tmp.offset = item->offset;
         tmp.size = item->size;

         if (item->is_ref) {
            ok = compile_ref_argument_to_slot(args->children[i], ctx,
                                              item->offset, item->size);
         }
         else {
            ok = compile_expr_to_slot(args->children[i], ctx, &tmp);
         }
         if (!ok) {
            break;
         }
      }

      if (ok) {
         for (int i = 0; i < staged_count; i++) {
            emit_copy_scratch_to_symbol_offset(staged[i].symbol, 0,
                                               staged[i].offset,
                                               staged[i].size);
         }
      }

      compiler_scratch_deactivate(ctx, &scratch);
      compiler_scratch_release(&scratch);
      if (!ok) {
         free(staged);
         return false;
      }
   }
   free(staged);

   if (dst && ret_size > 0) {
      if (!function_return_symbol_name(fn, return_sym, sizeof(return_sym))) {
         return false;
      }
      if (!function_has_body(fn)) {
         remember_symbol_import_mode(return_sym, true);
      }
   }

   record_call_graph_edge(current_call_graph_function, fn);
   remember_symbol_import(callee_sym);
   emit(&es_code, "    jsr %s\n", callee_sym);

   if (dst && ret_size > 0) {
      emit_copy_symbol_to_scratch_convert(dst->offset, dst->size, dst->type,
                                          return_sym, ret_size, ret_type);
   }
   return true;
}

//! @brief Lower call expression to slot from AST/semantic state into generated assembly or linker-visible metadata.
bool compile_call_expr_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst) {
   if (!expr || strcmp(expr->name, "()") || expr->count < 1) {
      return false;
   }

   ASTNode *callee = expr->children[0];
   ASTNode *args = (expr->count > 1) ? expr->children[1] : NULL;
   const ASTNode *fn = NULL;
   const ASTNode *ret_type = dst ? dst->type : NULL;
   const ASTNode *declarator = NULL;
   const ASTNode *ret_decl = NULL;
   int ret_size = dst ? dst->size : 0;
   int arg_count = (args && !is_empty(args)) ? args->count : 0;
   int fixed_params = 0;

   {
      const char *callee_name = expr_bare_identifier_name(callee);
      if (callee_name) {
         fn = resolve_function_call_target(callee_name, expr, args, ctx);
         if (!fn && is_identifier_spelling(callee_name) && !ctx_lookup(ctx, callee_name) && !global_decl_lookup(callee_name)) {
            error_user("[%s:%d.%d] call target '%s' has no visible signature; declare it in this translation unit or with extern",
                  expr->file, expr->line, expr->column, callee_name);
         }
      }
   }

   if (!fn) {
      const ASTNode *callable_decl = expr_value_declarator(callee, ctx);
      if (callable_decl && declarator_has_parameter_list(callable_decl) && declarator_function_pointer_depth(callable_decl) > 0) {
         error_user("[%s:%d.%d] indirect calls through function pointers are not supported",
                    expr->file, expr->line, expr->column);
      }
      if (expr_bare_identifier_name(callee)) {
         error_user("[%s:%d.%d] call target '%s' has no visible signature; declare it in this translation unit or with extern",
               expr->file, expr->line, expr->column, expr_bare_identifier_name(callee));
      }
      error_user("[%s:%d.%d] call target has no visible signature", expr->file, expr->line, expr->column);
      return false;
   }

   {
      const ASTNode *known_ret = function_return_type(fn);
      const ASTNode *params;
      declarator = function_declarator_node(fn);
      ret_decl = function_return_declarator_from_callable(declarator);
      if (known_ret) {
         ret_type = known_ret;
         ret_size = declarator_value_size(ret_type, ret_decl);
      }
      if (!return_type_is_supported(ret_type, ret_decl)) {
         error_unreachable("[%s:%d.%d] call target '%s' escaped function return-type validation",
                           expr->file, expr->line, expr->column,
                           callee->strval ? callee->strval : "<unknown>");
      }
      params = declarator_parameter_list(declarator);
      if (params && !is_empty(params)) {
         for (int i = 0; i < params->count; i++) {
            const ASTNode *parameter = params->children[i];
            const ASTNode *ptype = parameter_type(parameter);
            if (!ptype || parameter_is_void(parameter)) {
               continue;
            }
            fixed_params++;
         }
         if (fixed_params != arg_count) {
            warning("[%s:%d.%d] call to '%s' argument count mismatch (%d vs %d)",
                    expr->file, expr->line, expr->column,
                    callee->strval, arg_count, fixed_params);
         }
      }
   }

   if (ret_size < 0) {
      ret_size = 0;
   }
   if (function_is_inline(fn)) {
      return compile_inline_symbol_call(ctx, dst, callee, args, fn, declarator,
                                        ret_type, ret_size, expr);
   }
   return compile_direct_symbol_call(ctx, dst, callee, args, fn, declarator,
                                     ret_type, ret_size);
}


