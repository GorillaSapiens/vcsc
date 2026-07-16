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
   int len_size = get_size("*");
   int base_locals = ctx ? ctx->locals : 0;
   int callee_tmp_offset;
   int call_size;
   int fixed_params = 0;
   int fixed_stack_total = 0;
   int variadic_total = 0;
   bool variadic = parameter_list_is_variadic(params);
   bool ax_return;
   int frame_ret_size;
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
   ax_return = return_type_uses_ax(ret_type, ret_decl);
   frame_ret_size = ax_return ? 0 : ret_size;
   caller_result_size = (ax_return && dst) ? ret_size : 0;
   call_prefix_size = frame_ret_size + caller_result_size;

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
      if ((!variadic && fixed_params != arg_count) || (variadic && arg_count < fixed_params)) {
         warning("[%s:%d.%d] indirect call argument count mismatch (%d vs %d)", expr->file, expr->line, expr->column, arg_count, fixed_params);
      }
   }

    if (variadic && args && !is_empty(args)) {
      for (int i = fixed_params; i < arg_count; i++) {
         int actual_size = expr_value_size(args->children[i], ctx);
         if (actual_size <= 0) {
            error_user("[%s:%d.%d] variadic argument %d has no runtime storage", args->children[i]->file, args->children[i]->line, args->children[i]->column, i - fixed_params + 1);
         }
         variadic_total += actual_size;
      }
    }

   arg_total = fixed_stack_total;
   if (variadic) {
      arg_total += variadic_total + ptr_size + len_size;
   }

   callee_tmp_offset = 0;
   result_scratch_offset = base_locals + ptr_size + (variadic ? variadic_total : 0);
   call_size = ptr_size + call_prefix_size + arg_total;

   if (call_size > 0) {
      remember_runtime_import("pushN");
      emit(&es_code, "    lda #$%02x\n", call_size & 0xff);
      emit(&es_code, "    sta arg0\n");
      emit(&es_code, "    jsr _pushN\n");
   }
   if (ctx) {
      ctx->locals = base_locals + call_size;
   }

   if (params && !is_empty(params)) {
      int arg_offset = ptr_size + call_prefix_size + (variadic ? variadic_total + ptr_size + len_size + fixed_stack_total : fixed_stack_total);
      int actual_index = 0;

      if (variadic) {
         int extra_offset = ptr_size;

         for (int i = fixed_params; i < arg_count; i++) {
            ContextEntry tmp;
            int actual_size = expr_value_size(args->children[i], ctx);
            const ASTNode *actual_type = expr_value_type(args->children[i], ctx);
            const ASTNode *actual_decl = expr_value_declarator(args->children[i], ctx);

            tmp.name = "$vararg";
            tmp.type = actual_type ? actual_type : required_typename_node("int");
            tmp.declarator = actual_decl;
            tmp.is_static = false;
            tmp.is_zeropage = false;
            tmp.is_global = false;
            tmp.is_ref = false;
            tmp.is_absolute_ref = false;
            tmp.read_expr = NULL;
            tmp.write_expr = NULL;
            tmp.offset = base_locals + extra_offset;
            tmp.size = actual_size;
            if (!compile_expr_to_slot(args->children[i], ctx, &tmp)) {
               goto fail;
            }
            extra_offset += actual_size;
         }

         emit_prepare_fp_ptr(0, base_locals + ptr_size);
         emit_store_ptr_to_fp(base_locals + ptr_size + variadic_total + call_prefix_size, 0, ptr_size);
         {
            unsigned char bytes[sizeof(long long)] = {0};
            char len_buf[32];
            snprintf(len_buf, sizeof(len_buf), "%d", variadic_total);
            if (type_is_big_endian(required_typename_node("*"))) make_be_int(len_buf, bytes, len_size);
            else make_le_int(len_buf, bytes, len_size);
            emit_store_immediate_to_fp(base_locals + ptr_size + variadic_total + call_prefix_size + ptr_size, bytes, len_size);
         }
      }

      for (int i = 0; i < params->count && actual_index < arg_count; i++) {
         const ASTNode *parameter = params->children[i];
         const ASTNode *ptype = parameter_type(parameter);
         const ASTNode *pdecl = parameter_declarator(parameter);
         ContextEntry tmp;
         int psz;

         if (!ptype || parameter_is_void(parameter) || parameter_is_ellipsis(parameter)) {
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
      ctx->locals = base_locals;
   }

   if (dst && ret_size > 0) {
      int source_offset = base_locals + ptr_size + variadic_total;
      if (ax_return) {
         emit_store_ax_to_fp(result_scratch_offset, ret_size);
         source_offset = result_scratch_offset;
      }
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
      ctx->locals = base_locals;
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
   {
      const char *builtin_name = expr_bare_identifier_name(callee);
      if (builtin_name && builtin_variadic_call_name(builtin_name)) {
         if (dst) {
            error_user("[%s:%d.%d] %s does not produce a value", expr->file, expr->line, expr->column, builtin_name);
         }
         if (!strcmp(builtin_name, BUILTIN_VA_START_NAME)) {
            return compile_builtin_va_start_expr(expr, ctx);
         }
         if (!strcmp(builtin_name, BUILTIN_VA_ARG_NAME)) {
            return compile_builtin_va_arg_expr(expr, ctx);
         }
         if (!strcmp(builtin_name, BUILTIN_VA_END_NAME)) {
            return compile_builtin_va_end_expr(expr, ctx);
         }
      }
   }
   ASTNode *args = (expr->count > 1) ? expr->children[1] : NULL;
   const ASTNode *fn = NULL;
   const ASTNode *ret_type = dst ? dst->type : NULL;
   const ASTNode *declarator = NULL;
   const ASTNode *ret_decl = NULL;
   int ret_size = dst ? dst->size : 0;
   int arg_total = 0;
   int arg_count = (args && !is_empty(args)) ? args->count : 0;
   int ptr_size = get_size("*");
   int len_size = get_size("*");
   int fixed_params = 0;
   int fixed_stack_total = 0;
   int symbol_scratch_size = 0;
   int symbol_scratch_offset = 0;
   int result_scratch_offset = 0;
   int variadic_total = 0;
   bool variadic = false;
   bool ax_return = false;
   int frame_ret_size = 0;
   int caller_result_size = 0;
   int call_prefix_size = 0;
   int base_locals = ctx ? ctx->locals : 0;

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
      const ASTNode *params = NULL;
      declarator = function_declarator_node(fn);
      ret_decl = function_return_declarator_from_callable(declarator);
      if (known_ret) {
         ret_type = known_ret;
         ret_size = declarator_value_size(ret_type, ret_decl);
      }
      ax_return = function_uses_ax_return(fn);
      params = declarator_parameter_list(declarator);
      variadic = parameter_list_is_variadic(params);
      if (params && !is_empty(params)) {
         for (int i = 0; i < params->count; i++) {
            const ASTNode *parameter = params->children[i];
            const ASTNode *ptype = parameter_type(parameter);
            int psz;
            if (!ptype || parameter_is_void(parameter) || parameter_is_ellipsis(parameter)) {
               continue;
            }
            fixed_params++;
            psz = parameter_storage_size(parameter);
            if (function_parameter_uses_symbol_storage(fn, parameter)) {
               if (psz > symbol_scratch_size) {
                  symbol_scratch_size = psz;
               }
            }
            else {
               fixed_stack_total += psz;
            }
         }
         if ((!variadic && fixed_params != arg_count) || (variadic && arg_count < fixed_params)) {
            warning("[%s:%d.%d] call to '%s' argument count mismatch (%d vs %d)",
                    expr->file, expr->line, expr->column,
                    callee->strval, arg_count, fixed_params);
         }
      }

      if (variadic && args && !is_empty(args)) {
         for (int i = fixed_params; i < arg_count; i++) {
            int actual_size = expr_value_size(args->children[i], ctx);
            if (actual_size <= 0) {
               error_user("[%s:%d.%d] variadic argument %d has no runtime storage", args->children[i]->file, args->children[i]->line, args->children[i]->column, i - fixed_params + 1);
            }
            variadic_total += actual_size;
         }
      }
   }

   arg_total = fixed_stack_total;
   if (variadic) {
      arg_total += variadic_total + ptr_size + len_size;
   }

   if (ret_size < 0) ret_size = 0;
   frame_ret_size = ax_return ? 0 : ret_size;
   caller_result_size = (ax_return && dst) ? ret_size : 0;
   call_prefix_size = frame_ret_size + caller_result_size;
   result_scratch_offset = base_locals + (variadic ? variadic_total : 0);
   symbol_scratch_offset = base_locals + call_prefix_size + arg_total;
   int call_size = call_prefix_size + arg_total + symbol_scratch_size;

   if (call_size > 0) {
      remember_runtime_import("pushN");
      emit(&es_code, "    lda #$%02x\n", call_size & 0xff);
      emit(&es_code, "    sta arg0\n");
      emit(&es_code, "    jsr _pushN\n");
   }
   if (ctx) {
      ctx->locals = base_locals + call_size;
   }

   if (fn && declarator) {
      const ASTNode *params = declarator_parameter_list(declarator);
      int arg_offset = call_prefix_size + (variadic ? variadic_total + ptr_size + len_size + fixed_stack_total : fixed_stack_total);
      int actual_index = 0;
      char callee_sym[256];
      if (!function_symbol_name(fn, callee->strval, callee_sym, sizeof(callee_sym))) {
         goto fail;
      }

      if (variadic) {
         int extra_offset = 0;

         for (int i = fixed_params; i < arg_count; i++) {
            ContextEntry tmp;
            int actual_size = expr_value_size(args->children[i], ctx);
            const ASTNode *actual_type = expr_value_type(args->children[i], ctx);
            const ASTNode *actual_decl = expr_value_declarator(args->children[i], ctx);

            tmp.name = "$vararg";
            tmp.type = actual_type ? actual_type : required_typename_node("int");
            tmp.declarator = actual_decl;
            tmp.is_static = false;
            tmp.is_zeropage = false;
            tmp.is_global = false;
            tmp.is_ref = false;
            tmp.is_absolute_ref = false;
            tmp.read_expr = NULL;
            tmp.write_expr = NULL;
            tmp.offset = base_locals + extra_offset;
            tmp.size = actual_size;
            if (!compile_expr_to_slot(args->children[i], ctx, &tmp)) {
               goto fail;
            }
            extra_offset += actual_size;
         }

         emit_prepare_fp_ptr(0, base_locals);
         emit_store_ptr_to_fp(base_locals + variadic_total + call_prefix_size, 0, ptr_size);
         {
            unsigned char bytes[sizeof(long long)] = {0};
            char len_buf[32];
            snprintf(len_buf, sizeof(len_buf), "%d", variadic_total);
            if (type_is_big_endian(required_typename_node("*"))) make_be_int(len_buf, bytes, len_size);
            else make_le_int(len_buf, bytes, len_size);
            emit_store_immediate_to_fp(base_locals + variadic_total + call_prefix_size + ptr_size, bytes, len_size);
         }
      }

      if (params && !is_empty(params)) {
         for (int i = 0; i < params->count && actual_index < arg_count; i++) {
            const ASTNode *parameter = params->children[i];
            const ASTNode *ptype = parameter_type(parameter);
            const ASTNode *pdecl = parameter_declarator(parameter);
            ContextEntry tmp;
            int psz;

            if (!ptype || parameter_is_void(parameter) || parameter_is_ellipsis(parameter)) {
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
            tmp.size = psz;

            if (function_parameter_uses_symbol_storage(fn, parameter)) {
               char sym[256];
               bool is_zeropage = false;

               if (!function_parameter_symbol_name(fn, parameter, i, sym, sizeof(sym), &is_zeropage)) {
                  goto fail;
               }

               tmp.offset = symbol_scratch_offset;
               if (parameter_is_ref(parameter)) {
                  if (!compile_ref_argument_to_slot(args->children[actual_index], ctx, tmp.offset, tmp.size)) {
                     goto fail;
                  }
               }
               else if (!compile_expr_to_slot(args->children[actual_index], ctx, &tmp)) {
                  goto fail;
               }
               if (!function_has_body(fn)) {
                  remember_symbol_import_mode(sym, is_zeropage);
               }
               emit_copy_fp_to_symbol(sym, tmp.offset, tmp.size);
            }
            else {
               arg_offset -= psz;
               tmp.offset = base_locals + arg_offset;
               if (parameter_is_ref(parameter)) {
                  if (!compile_ref_argument_to_slot(args->children[actual_index], ctx, tmp.offset, tmp.size)) {
                     goto fail;
                  }
               }
               else if (!compile_expr_to_slot(args->children[actual_index], ctx, &tmp)) {
                  goto fail;
               }
            }
            actual_index++;
         }
      }

      record_call_graph_edge(current_call_graph_function, fn);
      remember_symbol_import(callee_sym);
      emit(&es_code, "    lda fp+1\n");
      emit(&es_code, "    pha\n");
      emit(&es_code, "    lda fp\n");
      emit(&es_code, "    pha\n");
      emit(&es_code, "    jsr %s\n", callee_sym);
      emit_restore_fp_after_call(ax_return);
   }

   if (ctx) {
      ctx->locals = base_locals;
   }

   if (dst && ret_size > 0) {
      int source_offset = base_locals + (variadic ? variadic_total : 0);
      if (ax_return) {
         emit_store_ax_to_fp(result_scratch_offset, ret_size);
         source_offset = result_scratch_offset;
      }
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
      ctx->locals = base_locals;
   }
   if (call_size > 0) {
      remember_runtime_import("popN");
      emit(&es_code, "    lda #$%02x\n", call_size & 0xff);
      emit(&es_code, "    sta arg0\n");
      emit(&es_code, "    jsr _popN\n");
   }
   return false;
}


