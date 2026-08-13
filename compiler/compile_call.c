//! @file compiler/compile_call.c
//! @brief Implements function call lowering for the VCSC compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#include "ast.h"
#include "builtin.h"
#include "abi_meta.h"
#include "compile_call.h"
#include "compile_expr.h"
#include "compile_expr_info.h"
#include "compile_function.h"
#include "compile_internal.h"
#include "compile_inline_specialize.h"
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
   inline_ctx.phase_mask = function_phase_mask_for_function(fn, callee_sym);
   if (inline_ctx.phase_mask == 0 && caller_ctx)
      inline_ctx.phase_mask = caller_ctx->phase_mask;
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
         if (!pentry) {
            if (have_arg_scratch) compiler_scratch_release(&arg_scratch);
            error_unreachable("[%s:%d.%d] missing inline parameter storage for '%s'",
                              call_expr->file, call_expr->line, call_expr->column,
                              pname ? pname : "?");
         }
         if (pentry->is_absolute_ref && pentry->read_expr && *pentry->read_expr) {
            snprintf(param_sym, sizeof(param_sym), "%s", pentry->read_expr);
         }
         else if (!entry_symbol_name(&inline_ctx, pentry,
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
         {
            const ASTNode *specs = parameter_decl_specifiers(parameter);
            const ASTNode *mods = (specs && specs->count > 0) ? specs->children[0] : NULL;
            tmp.pointer_access = declaration_pointer_access(mods, tmp.declarator);
         }
         tmp.target_typed = true;
         tmp.size = psz;

         if (psz > arg_scratch.reserved) {
            arg_scratch.reserved = psz;
         }
         compiler_scratch_activate(caller_ctx, &arg_scratch);
         if (parameter_is_ref(parameter)) {
            ok = compile_ref_argument_to_slot(args->children[actual_index], caller_ctx,
                                              0, psz,
                                              parameter_access_qualifier(parameter),
                                              parameter_name(parameter, i));
         }
         else {
            ok = compile_expr_to_slot(args->children[actual_index], caller_ctx, &tmp);
         }
         if (ok) {
            if (pentry->is_absolute_ref && pentry->write_expr && *pentry->write_expr) {
               emit_copy_scratch_to_address_expr(pentry->write_expr, 0, psz);
            }
            else {
               emit_copy_scratch_to_symbol(param_sym, 0, psz);
            }
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
   int actual_index;
   int parameter_index;
   bool must_stage;
   bool is_ref;
   bool is_zeropage;
   bool is_split;
   char symbol[256];
   char write_expr[320];
} DirectCallArgStage;

//! @brief Return whether evaluating an expression may execute an ordinary call.
//!
//! `sizeof` operands and registered compiler builtins are compile-time-only and
//! therefore cannot clobber a pending callee activation.  Other call nodes are
//! conservatively treated as runtime calls, including inline calls: an inline
//! body may itself contain an ordinary call even when that fact is not visible
//! from the call-site expression tree.
static bool expr_may_execute_runtime_call(const ASTNode *expr) {
   if (!expr || is_empty(expr)) {
      return false;
   }
   expr = unwrap_expr_node(expr);
   if (!expr || is_empty(expr)) {
      return false;
   }
   if (!strcmp(expr->name, "sizeof")) {
      return false;
   }
   if (!strcmp(expr->name, "()")) {
      if (builtin_call_result_type_name(expr)) {
         return false;
      }
      return true;
   }
   for (int i = 0; i < expr->count; i++) {
      if (expr_may_execute_runtime_call(expr->children[i])) {
         return true;
      }
   }
   return false;
}

//! @brief Copy one converted argument from active scratch to its callee object.
static void emit_direct_argument_copy(const DirectCallArgStage *item,
                                      int scratch_offset) {
   if (item->is_split) {
      emit_copy_scratch_to_address_expr(item->write_expr,
                                        scratch_offset,
                                        item->size);
   }
   else {
      emit_copy_scratch_to_symbol_offset(item->symbol, 0,
                                         scratch_offset,
                                         item->size);
   }
}

//! @brief Validate a specialized ref actual without materializing its address slot.
static bool validate_specialized_ref_argument(ASTNode *expr, Context *ctx,
                                              const ASTNode *parameter,
                                              int parameter_index) {
   LValueRef lv;
   PointerAccessQualifier access = parameter_access_qualifier(parameter);
   if (!validate_ref_argument_binding(expr, ctx, access,
                                      parameter_name(parameter, parameter_index),
                                      true, &lv)) {
      return false;
   }
   emit_lvalue_semantic_use(ctx, &lv,
      access == POINTER_ACCESS_READWRITE ? "ref" : "address");
   return true;
}

//! @brief Lower an ordinary direct call using selective caller-owned staging.
static bool compile_direct_symbol_call(Context *ctx, ContextEntry *dst,
                                       ASTNode *callee, ASTNode *args,
                                       const ASTNode *fn, const ASTNode *declarator,
                                       const ASTNode *ret_type, int ret_size) {
   const ASTNode *params = declarator_parameter_list(declarator);
   int arg_count = (args && !is_empty(args)) ? args->count : 0;
   int actual_index = 0;
   int staged_count = 0;
   int staged_size = 0;
   int direct_temp_size = 0;
   int direct_temp_offset = 0;
   int total_size = 0;
   DirectCallArgStage *staged = NULL;
   CompilerScratchLease scratch;
   char callee_sym[256];
   char return_sym[256];
   char return_write_expr[320];
   bool return_is_zeropage = true;
   bool return_is_split = false;

   if (!function_symbol_name(fn, callee->strval, callee_sym, sizeof(callee_sym))) {
      return false;
   }

   if (arg_count > 0) {
      staged = (DirectCallArgStage *)calloc((size_t)arg_count, sizeof(*staged));
      if (!staged) {
         error_unreachable("out of memory staging direct-call arguments");
      }
   }

   /* Collect the fixed-parameter ABI objects before deciding which values must
      remain in caller storage. */
   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count && actual_index < arg_count; i++) {
         const ASTNode *parameter = params->children[i];
         DirectCallArgStage *item;

         if (!parameter_type(parameter) || parameter_is_void(parameter)) {
            continue;
         }
         if (parameter_is_ref(parameter) &&
             optimizer_ref_parameter_specialization(fn, i, NULL)) {
            if (!validate_specialized_ref_argument(args->children[actual_index], ctx,
                                                   parameter, i)) {
               free(staged);
               return false;
            }
            actual_index++;
            continue;
         }
         if (!parameter_is_ref(parameter) &&
             optimizer_value_parameter_specialization(fn, i, NULL)) {
            InlineValueSpecialization value_spec;
            if (!optimizer_value_parameter_specialization(fn, i, &value_spec)) {
               free(staged);
               return false;
            }
            if (value_spec.kind == INLINE_VALUE_ADDRESS) {
               LValueRef lv;
               if (!resolve_ref_argument_lvalue(ctx, args->children[actual_index], &lv)) {
                  free(staged);
                  return false;
               }
               emit_lvalue_semantic_use(ctx, &lv, "read");
            }
            actual_index++;
            continue;
         }

         item = &staged[staged_count++];
         item->parameter = parameter;
         item->type = parameter_type(parameter);
         item->declarator = parameter_declarator(parameter);
         item->is_ref = parameter_is_ref(parameter);
         item->size = parameter_storage_size(parameter);
         item->actual_index = actual_index;
         item->parameter_index = i;

         if (!function_parameter_storage_addresses(fn, parameter, i,
                                                   item->symbol, sizeof(item->symbol),
                                                   item->write_expr, sizeof(item->write_expr),
                                                   &item->is_zeropage, &item->is_split)) {
            free(staged);
            return false;
         }
         {
            const ASTNode *decl_specs = parameter_decl_specifiers(parameter);
            const ASTNode *modifiers = (decl_specs && decl_specs->count > 0)
               ? decl_specs->children[0] : NULL;
            emit_mem_region_metadata_for_modifiers(parameter, modifiers);
         }
         if (!function_has_body(fn)) {
            remember_symbol_import_mode(item->symbol, item->is_zeropage);
         }
         actual_index++;
      }
   }

   /* Preserve only arguments whose converted values must survive a runtime
      call in a later argument.  Everything else can be copied to its callee-
      owned parameter object immediately after evaluation.  This keeps the
      language's left-to-right evaluation order while avoiding a whole-list
      staging block for call-free suffixes. */
   {
      bool later_argument_may_call = false;
      for (int i = staged_count - 1; i >= 0; i--) {
         DirectCallArgStage *item = &staged[i];
         item->must_stage = later_argument_may_call;
         if (item->must_stage) {
            item->offset = staged_size;
            staged_size += item->size;
         }
         else if (item->size > direct_temp_size) {
            direct_temp_size = item->size;
         }
         if (expr_may_execute_runtime_call(args->children[item->actual_index])) {
            later_argument_may_call = true;
         }
      }
   }
   direct_temp_offset = staged_size;
   total_size = staged_size + direct_temp_size;

   if (staged_count > 0) {
      bool ok = true;
      compiler_scratch_acquire(ctx, total_size, &scratch);
      compiler_scratch_activate(ctx, &scratch);

      for (int i = 0; i < staged_count; i++) {
         DirectCallArgStage *item = &staged[i];
         ContextEntry tmp;
         int eval_offset = item->must_stage ? item->offset : direct_temp_offset;

         memset(&tmp, 0, sizeof(tmp));
         tmp.name = "$callarg";
         tmp.type = item->is_ref ? required_typename_node("*") : item->type;
         tmp.declarator = item->is_ref ? NULL
            : call_adjusted_parameter_declarator(item->declarator, false);
         if (!item->is_ref) {
            const ASTNode *specs = parameter_decl_specifiers(item->parameter);
            const ASTNode *mods = (specs && specs->count > 0) ? specs->children[0] : NULL;
            tmp.pointer_access = declaration_pointer_access(mods, tmp.declarator);
         }
         tmp.target_typed = true;
         tmp.offset = eval_offset;
         tmp.size = item->size;

         if (item->is_ref) {
            ok = compile_ref_argument_to_slot(args->children[item->actual_index], ctx,
                                              eval_offset, item->size,
                                              parameter_access_qualifier(item->parameter),
                                              parameter_name(item->parameter, item->parameter_index));
         }
         else {
            ok = compile_expr_to_slot(args->children[item->actual_index], ctx, &tmp);
         }
         if (!ok) {
            break;
         }
         if (!item->must_stage) {
            emit_direct_argument_copy(item, eval_offset);
         }
      }

      if (ok) {
         for (int i = 0; i < staged_count; i++) {
            if (staged[i].must_stage) {
               emit_direct_argument_copy(&staged[i], staged[i].offset);
            }
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
      if (!function_return_storage_addresses(fn,
                                             return_sym, sizeof(return_sym),
                                             return_write_expr, sizeof(return_write_expr),
                                             &return_is_zeropage, &return_is_split)) {
         return false;
      }
      {
         const char *result_region = function_result_region_name(fn);
         if (result_region) {
            emit_mem_region_metadata_for_name(fn, result_region);
         }
      }
      if (!function_has_body(fn)) {
         remember_symbol_import_mode(return_sym, return_is_zeropage);
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

   {
      const char *builtin_type = builtin_call_result_type_name(expr);
      if (builtin_type) {
         if (!dst) {
            InitConstValue value = {0};
            if (!builtin_eval_constant_call(expr, &value)) {
               error_unreachable("registered compiler builtin did not evaluate");
            }
            return true;
         }
         return compile_constant_expr_to_slot(expr, ctx, dst);
      }
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
         if (!fn && !strncmp(callee_name, "__builtin_", 10)) {
            error_user("[%s:%d.%d] unknown compiler builtin '%s'",
                       expr->file, expr->line, expr->column, callee_name);
         }
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
   {
      char callee_sym[256];
      if (!function_symbol_name(fn, callee->strval, callee_sym, sizeof(callee_sym)))
         return false;
      emit_semantic_use_metadata("call", callee_sym,
                                 ctx ? ctx->activation_owner : NULL, expr);
   }
   if (function_is_inline(fn)) {
      return compile_inline_symbol_call(ctx, dst, callee, args, fn, declarator,
                                        ret_type, ret_size, expr);
   }
   return compile_direct_symbol_call(ctx, dst, callee, args, fn, declarator,
                                     ret_type, ret_size);
}


