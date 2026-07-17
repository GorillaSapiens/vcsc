//! @file compiler/compile_call.c
//! @brief Implements function call lowering for the n65 compiler.
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
#include "compile_overload.h"
#include "compile_support.h"
#include "compile_type.h"
#include "integer.h"
#include "messages.h"

//! @brief Restore the caller frame pointer while preserving an A:X return value.
static void emit_restore_fp_after_call(bool preserve_ax) {
   if (preserve_ax) {
      emit(&es_code, "    tay\n");
   }
   emit(&es_code, "    pla\n");
   emit(&es_code, "    sta fp\n");
   emit(&es_code, "    pla\n");
   emit(&es_code, "    sta fp+1\n");
   if (preserve_ax) {
      emit(&es_code, "    tya\n");
   }
}

//! @brief Store a one- or two-byte A:X return value in caller frame scratch.
static void emit_store_ax_to_fp(int offset, int size) {
   emit(&es_code, "    ldy #$%02x\n", offset & 0xff);
   emit(&es_code, "    sta (fp),y\n");
   if (size == 2) {
      emit(&es_code, "    txa\n");
      emit(&es_code, "    iny\n");
      emit(&es_code, "    sta (fp),y\n");
   }
}

//! @brief Save the current frame pointer on the 6502 hardware stack.
static void emit_save_fp(void) {
   emit(&es_code, "    lda fp+1\n");
   emit(&es_code, "    pha\n");
   emit(&es_code, "    lda fp\n");
   emit(&es_code, "    pha\n");
}

//! @brief Point fp at fixed compiler-generated scratch storage.
static void emit_set_fp_to_symbol(const char *symbol) {
   emit(&es_code, "    lda #<%s\n", symbol);
   emit(&es_code, "    sta fp\n");
   emit(&es_code, "    lda #>%s\n", symbol);
   emit(&es_code, "    sta fp+1\n");
}

//! @brief Restore fp from the 6502 hardware stack.
static void emit_restore_fp(void) {
   emit(&es_code, "    pla\n");
   emit(&es_code, "    sta fp\n");
   emit(&es_code, "    pla\n");
   emit(&es_code, "    sta fp+1\n");
}

//! @brief Store a one- or two-byte A:X value in fixed storage.
static void emit_store_ax_to_symbol(const char *symbol, int size) {
   emit(&es_code, "    ldy #0\n");
   emit(&es_code, "    sta %s,y\n", symbol);
   if (size == 2) {
      emit(&es_code, "    txa\n");
      emit(&es_code, "    iny\n");
      emit(&es_code, "    sta %s,y\n", symbol);
   }
}

//! @brief Lower an ordinary direct call using fixed call-site scratch rather than the N software stack.
static bool compile_direct_symbol_call(Context *ctx, ContextEntry *dst,
                                       ASTNode *callee, ASTNode *args,
                                       const ASTNode *fn, const ASTNode *declarator,
                                       const ASTNode *ret_type, int ret_size, bool ax_return) {
   const ASTNode *params = declarator_parameter_list(declarator);
   int arg_count = (args && !is_empty(args)) ? args->count : 0;
   int actual_index = 0;
   int scratch_size = (dst && ret_size > 0) ? ret_size : 0;
   char scratch_sym[96];
   char callee_sym[256];

   snprintf(scratch_sym, sizeof(scratch_sym), "__n65_calltmp_%d", label_counter++);
   if (!function_symbol_name(fn, callee->strval, callee_sym, sizeof(callee_sym))) {
      return false;
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
         int saved_locals;
         int saved_high_water;
         int used;
         bool ok;

         if (!ptype || parameter_is_void(parameter)) {
            continue;
         }
         psz = parameter_storage_size(parameter);
         if (!function_parameter_symbol_name(fn, parameter, i, param_sym, sizeof(param_sym), &is_zeropage)) {
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

         saved_locals = ctx ? ctx->locals : 0;
         saved_high_water = ctx ? ctx->locals_high_water : 0;
         if (ctx) {
            ctx->locals = psz;
            ctx->locals_high_water = psz;
         }

         emit_save_fp();
         emit_set_fp_to_symbol(scratch_sym);
         if (parameter_is_ref(parameter)) {
            ok = compile_ref_argument_to_slot(args->children[actual_index], ctx, 0, psz);
         }
         else {
            ok = compile_expr_to_slot(args->children[actual_index], ctx, &tmp);
         }
         used = ctx ? ctx->locals_high_water : psz;
         if (used > scratch_size) {
            scratch_size = used;
         }
         if (ok) {
            emit_copy_fp_to_symbol(param_sym, 0, psz);
         }
         emit_restore_fp();
         if (ctx) {
            ctx->locals = saved_locals;
            ctx->locals_high_water = saved_high_water;
         }
         if (!ok) {
            return false;
         }
         actual_index++;
      }
   }

   if (scratch_size > 0) {
      emit(&es_bss, ".segment \"BSS\"\n");
      emit(&es_bss, "%s:\n", scratch_sym);
      emit(&es_bss, "\t.res %d\n", scratch_size);
   }

   record_call_graph_edge(current_call_graph_function, fn);
   remember_symbol_import(callee_sym);
   emit_save_fp();
   emit(&es_code, "    jsr %s\n", callee_sym);
   emit_restore_fp_after_call(ax_return);

   if (dst && ret_size > 0) {
      emit_store_ax_to_symbol(scratch_sym, ret_size);
      emit_copy_symbol_to_fp_convert(dst->offset, dst->size, dst->type,
                                     scratch_sym, ret_size, ret_type);
   }

   return true;
}

//! @brief Lower indirect call expression to slot from AST/semantic state into generated assembly or linker-visible metadata.
static bool compile_indirect_call_expr_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst,
                                               ASTNode *callee, ASTNode *args,
                                               const ASTNode *ret_type,
                                               const ASTNode *callable_decl) {
   const ASTNode *params = declarator_parameter_list(callable_decl);
   const ASTNode *ret_decl = function_return_declarator_from_callable(callable_decl);
   int arg_count = (args && !is_empty(args)) ? args->count : 0;
   int ret_size = dst ? dst->size : 0;
   int arg_total = 0;
   int ptr_size = get_size("*");
   int base_locals = ctx ? ctx->locals : 0;
   int callee_tmp_offset;
   int call_size;
   int fixed_params = 0;
   int fixed_stack_total = 0;
   bool ax_return;
   int caller_result_size;
   int call_prefix_size;
   int result_scratch_offset;
   ContextEntry callee_tmp;


   if (ret_type && dst) {
      ret_size = declarator_value_size(ret_type, ret_decl);
   }
   if (ret_size < 0) {
      ret_size = 0;
   }
   if (!return_type_is_supported(ret_type, ret_decl)) {
      error_user("[%s:%d.%d] indirect call has an unsupported return type; functions may return only void, an 8- or 16-bit little-endian integer, or a 16-bit pointer",
                 expr->file, expr->line, expr->column);
   }
   ax_return = return_type_uses_ax(ret_type, ret_decl);
   caller_result_size = (ax_return && dst) ? ret_size : 0;
   call_prefix_size = caller_result_size;

   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count; i++) {
         const ASTNode *parameter = params->children[i];
         const ASTNode *ptype = parameter_type(parameter);
         if (!ptype || parameter_is_void(parameter)) {
            continue;
         }
         if (parameter_has_symbol_storage(parameter)) {
            error_user("[%s:%d.%d] indirect call target type cannot use symbol-backed parameters", expr->file, expr->line, expr->column);
         }
         fixed_params++;
         fixed_stack_total += parameter_storage_size(parameter);
      }
      if (fixed_params != arg_count) {
         warning("[%s:%d.%d] indirect call argument count mismatch (%d vs %d)", expr->file, expr->line, expr->column, arg_count, fixed_params);
      }
   }

   arg_total = fixed_stack_total;
   callee_tmp_offset = 0;
   result_scratch_offset = base_locals + ptr_size;
   call_size = ptr_size + call_prefix_size + arg_total;

   if (call_size > 0) {
      remember_runtime_import("pushN");
      emit(&es_code, "    lda #$%02x\n", call_size & 0xff);
      emit(&es_code, "    sta arg0\n");
      emit(&es_code, "    jsr _pushN\n");
   }
   if (ctx) {
      ctx_set_locals(ctx, base_locals + call_size);
   }

   if (params && !is_empty(params)) {
      int arg_offset = ptr_size + call_prefix_size + fixed_stack_total;
      int actual_index = 0;

      for (int i = 0; i < params->count && actual_index < arg_count; i++) {
         const ASTNode *parameter = params->children[i];
         const ASTNode *ptype = parameter_type(parameter);
         const ASTNode *pdecl = parameter_declarator(parameter);
         ContextEntry tmp;
         int psz;

         if (!ptype || parameter_is_void(parameter)) {
            continue;
         }

         psz = parameter_storage_size(parameter);
         tmp.type = parameter_is_ref(parameter) ? required_typename_node("*") : ptype;
         tmp.declarator = parameter_is_ref(parameter) ? NULL : call_adjusted_parameter_declarator(pdecl, false);
         tmp.is_static = false;
         tmp.is_zeropage = false;
         tmp.is_global = false;
         tmp.target_typed = true;
         tmp.is_ref = false;
         tmp.is_absolute_ref = false;
         tmp.read_expr = NULL;
         tmp.write_expr = NULL;
         arg_offset -= psz;
         tmp.offset = base_locals + arg_offset;
         tmp.size = psz;

         if (parameter_is_ref(parameter)) {
            if (!compile_ref_argument_to_slot(args->children[actual_index], ctx, tmp.offset, tmp.size)) {
               goto fail;
            }
         }
         else if (!compile_expr_to_slot(args->children[actual_index], ctx, &tmp)) {
            goto fail;
         }

         actual_index++;
      }
   }

   callee_tmp.name = "$callee";
   callee_tmp.type = required_typename_node("*");
   callee_tmp.declarator = NULL;
   callee_tmp.is_static = false;
   callee_tmp.is_zeropage = false;
   callee_tmp.is_global = false;
   callee_tmp.is_ref = false;
   callee_tmp.is_absolute_ref = false;
   callee_tmp.read_expr = NULL;
   callee_tmp.write_expr = NULL;
   callee_tmp.offset = base_locals + callee_tmp_offset;
   callee_tmp.size = ptr_size;

   if (!compile_expr_to_slot(callee, ctx, &callee_tmp)) {
      goto fail;
   }

   emit_load_ptr_from_fpvar(0, callee_tmp.offset);
   remember_runtime_import("callptr0");
   emit(&es_code, "    lda fp+1\n");
   emit(&es_code, "    pha\n");
   emit(&es_code, "    lda fp\n");
   emit(&es_code, "    pha\n");
   emit(&es_code, "    jsr _callptr0\n");
   emit_restore_fp_after_call(ax_return);

   if (ctx) {
      ctx_set_locals(ctx, base_locals);
   }

   if (dst && ret_size > 0) {
      int source_offset = result_scratch_offset;
      emit_store_ax_to_fp(result_scratch_offset, ret_size);
      emit_copy_fp_to_fp_convert(dst->offset, dst->size, dst->type,
                                 source_offset, ret_size, ret_type);
   }

   if (call_size > 0) {
      remember_runtime_import("popN");
      emit(&es_code, "    lda #$%02x\n", call_size & 0xff);
      emit(&es_code, "    sta arg0\n");
      emit(&es_code, "    jsr _popN\n");
   }

   return true;

fail:
   if (ctx) {
      ctx_set_locals(ctx, base_locals);
   }
   if (call_size > 0) {
      remember_runtime_import("popN");
      emit(&es_code, "    lda #$%02x\n", call_size & 0xff);
      emit(&es_code, "    sta arg0\n");
      emit(&es_code, "    jsr _popN\n");
   }
   return false;
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
   bool ax_return = false;

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
      const ASTNode *callable_type = expr_value_type(callee, ctx);
      if (callable_decl && declarator_has_parameter_list(callable_decl) && declarator_function_pointer_depth(callable_decl) > 0) {
         return compile_indirect_call_expr_to_slot(expr, ctx, dst, callee, args, callable_type, callable_decl);
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
      ax_return = function_uses_ax_return(fn);
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
                                     ret_type, ret_size, ax_return);
}


