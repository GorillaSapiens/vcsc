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
#include "compile_type.h"
#include "integer.h"
#include "messages.h"

//! @brief Lower an ordinary direct call using callee-owned symbols and fixed call-site scratch.
static bool compile_direct_symbol_call(Context *ctx, ContextEntry *dst,
                                       ASTNode *callee, ASTNode *args,
                                       const ASTNode *fn, const ASTNode *declarator,
                                       const ASTNode *ret_type, int ret_size) {
   const ASTNode *params = declarator_parameter_list(declarator);
   int arg_count = (args && !is_empty(args)) ? args->count : 0;
   int actual_index = 0;
   bool have_scratch = arg_count > 0;
   CompilerScratchLease scratch;
   char callee_sym[256];
   char return_sym[256];

   if (!function_symbol_name(fn, callee->strval, callee_sym, sizeof(callee_sym))) {
      return false;
   }
   if (have_scratch) {
      compiler_scratch_acquire(ctx, 1, &scratch);
   }

   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count && actual_index < arg_count; i++) {
         const ASTNode *parameter = params->children[i];
         const ASTNode *ptype = parameter_type(parameter);
         const ASTNode *pdecl = parameter_declarator(parameter);
         ContextEntry tmp;
         char param_sym[256];
         bool is_zeropage = false;
         int psz;
         bool ok;

         if (!ptype || parameter_is_void(parameter)) {
            continue;
         }
         psz = parameter_storage_size(parameter);
         if (!function_parameter_symbol_name(fn, parameter, i, param_sym, sizeof(param_sym), &is_zeropage)) {
            if (have_scratch) compiler_scratch_release(&scratch);
            return false;
         }
         if (!function_has_body(fn)) {
            remember_symbol_import_mode(param_sym, is_zeropage);
         }

         memset(&tmp, 0, sizeof(tmp));
         tmp.name = "$callarg";
         tmp.type = parameter_is_ref(parameter) ? required_typename_node("*") : ptype;
         tmp.declarator = parameter_is_ref(parameter) ? NULL : call_adjusted_parameter_declarator(pdecl, false);
         tmp.target_typed = true;
         tmp.offset = 0;
         tmp.size = psz;

         if (!have_scratch) {
            error_unreachable("direct call argument missing compiler scratch");
         }
         if (psz > scratch.reserved) {
            scratch.reserved = psz;
         }
         compiler_scratch_activate(ctx, &scratch);
         if (parameter_is_ref(parameter)) {
            ok = compile_ref_argument_to_slot(args->children[actual_index], ctx, 0, psz);
         }
         else {
            ok = compile_expr_to_slot(args->children[actual_index], ctx, &tmp);
         }
         if (ok) {
            emit_copy_scratch_to_symbol(param_sym, 0, psz);
         }
         compiler_scratch_deactivate(ctx, &scratch);
         if (!ok) {
            compiler_scratch_release(&scratch);
            return false;
         }
         actual_index++;
      }
   }

   if (dst && ret_size > 0) {
      if (!function_return_symbol_name(fn, return_sym, sizeof(return_sym))) {
         if (have_scratch) compiler_scratch_release(&scratch);
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

   if (have_scratch) {
      compiler_scratch_release(&scratch);
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
   return compile_direct_symbol_call(ctx, dst, callee, args, fn, declarator,
                                     ret_type, ret_size);
}


