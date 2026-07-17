//! @file compiler/compile_expr_slot.c
//! @brief Implements expression-to-storage-slot lowering for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>
#include <limits.h>

#include "ast.h"
#include "compile.h"
#include "compile_call.h"
#include "compile_expr.h"
#include "compile_expr_flow.h"
#include "compile_expr_info.h"
#include "compile_function.h"
#include "compile_init.h"
#include "compile_internal.h"
#include "compile_lvalue.h"
#include "compile_overload.h"
#include "compile_support.h"
#include "compile_type.h"
#include "emit.h"
#include "integer.h"
#include "memname.h"
#include "messages.h"
#include "pair.h"
#include "set.h"
#include "typename.h"
#include "xray.h"
#include "lextern.h"

#include "compile_expr_ops.h"
#include "compile_expr_slot.h"
static int cast_expr_target_size(const ASTNode *expr);

static const ASTNode *expr_lvalue_base_identifier_node(ASTNode *expr);

typedef struct SlotFixedScratch {
   int saved_locals;
   int saved_high_water;
   int reserved;
   char symbol[96];
} SlotFixedScratch;

//! @brief Begin fixed-address slot scratch and redirect fp to it.
static void slot_fixed_scratch_begin(Context *ctx, const char *prefix, int reserved,
                                     SlotFixedScratch *scratch) {
   memset(scratch, 0, sizeof(*scratch));
   scratch->saved_locals = ctx ? ctx->locals : 0;
   scratch->saved_high_water = ctx ? ctx->locals_high_water : 0;
   scratch->reserved = reserved > 0 ? reserved : 1;
   snprintf(scratch->symbol, sizeof(scratch->symbol), "__n65_%s_%d", prefix, label_counter++);

   if (ctx) {
      ctx->locals = scratch->reserved;
      ctx->locals_high_water = scratch->reserved;
   }
   emit(&es_code, "    lda fp+1\n");
   emit(&es_code, "    pha\n");
   emit(&es_code, "    lda fp\n");
   emit(&es_code, "    pha\n");
   emit(&es_code, "    lda #<%s\n", scratch->symbol);
   emit(&es_code, "    sta fp\n");
   emit(&es_code, "    lda #>%s\n", scratch->symbol);
   emit(&es_code, "    sta fp+1\n");
}

//! @brief Restore fp and declare fixed-address slot scratch.
static void slot_fixed_scratch_end(Context *ctx, SlotFixedScratch *scratch) {
   int used = scratch->reserved;
   if (ctx && ctx->locals_high_water > used) {
      used = ctx->locals_high_water;
   }
   emit(&es_code, "    pla\n");
   emit(&es_code, "    sta fp\n");
   emit(&es_code, "    pla\n");
   emit(&es_code, "    sta fp+1\n");
   if (ctx) {
      ctx->locals = scratch->saved_locals;
      ctx->locals_high_water = scratch->saved_high_water;
   }
   emit(&es_bss, ".segment \"BSS\"\n");
   emit(&es_bss, "%s:\n", scratch->symbol);
   emit(&es_bss, "\t.res %d\n", used > 0 ? used : 1);
}

//! @brief Copy a converted slot-scratch result into the caller destination.
static void emit_slot_fixed_scratch_result(Context *ctx, const SlotFixedScratch *scratch,
                                           int src_offset, int src_size, const ASTNode *src_type,
                                           ContextEntry *dst) {
   char dst_symbol[256];
   if (!dst || dst->size <= 0) {
      return;
   }
   if ((dst->is_static || dst->is_zeropage || dst->is_global) &&
       entry_symbol_name(ctx, dst, dst_symbol, sizeof(dst_symbol))) {
      emit_copy_symbol_to_symbol_convert_offset(dst_symbol, 0, dst->size, dst->type,
                                                scratch->symbol, src_offset, src_size, src_type);
   }
   else {
      emit_copy_symbol_to_fp_convert_offset(dst->offset, dst->size, dst->type,
                                            scratch->symbol, src_offset, src_size, src_type);
   }
}

//! @brief Return lvalue base identifier node data used by compile expr slot; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *lvalue_base_identifier_node(ASTNode *base) {
   if (!base) {
      return NULL;
   }
   if (!strcmp(base->name, "lvalue_base")) {
      if (base->count <= 0 || !base->children[0] || base->children[0]->kind != AST_IDENTIFIER) {
         return NULL;
      }
      return base->children[0];
   }
   if (!strcmp(base->name, "*") && base->count > 0) {
      return expr_lvalue_base_identifier_node(base->children[0]);
   }
   return NULL;
}

//! @brief Return expr lvalue base identifier node data used by compile expr slot; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *expr_lvalue_base_identifier_node(ASTNode *expr) {
   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || is_empty(expr)) {
      return NULL;
   }
   if (expr->kind == AST_IDENTIFIER) {
      return expr;
   }
   if (strcmp(expr->name, "lvalue") || expr->count < 1) {
      return NULL;
   }
   return lvalue_base_identifier_node(expr->children[0]);
}

//! @brief Return expr bare identifier node data used by compile expr slot; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *expr_bare_identifier_node(ASTNode *expr) {
   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || is_empty(expr)) {
      return NULL;
   }
   if (expr->kind == AST_IDENTIFIER) {
      return expr;
   }
   if (strcmp(expr->name, "lvalue") || expr->count != 2) {
      return NULL;
   }
   if (!expr->children[1] || !is_empty(expr->children[1])) {
      return NULL;
   }
   return lvalue_base_identifier_node(expr->children[0]);
}


//! @brief Lower constant expression to slot from AST/semantic state into generated assembly or linker-visible metadata.
bool compile_constant_expr_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst) {
   InitConstValue value = {0};
   unsigned char *bytes;
   (void) ctx;

   if (!dst || !eval_constant_initializer_expr(expr, &value)) {
      return false;
   }

   if (value.kind != INIT_CONST_INT) {
      return false;
   }

   bytes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
   if (!bytes) {
      error_unreachable("out of memory");
   }
   if (!encode_init_const_int_value(&value, bytes, dst->size, dst->type)) {
      free(bytes);
      return false;
   }
   emit_store_immediate_to_fp(dst->offset, bytes, dst->size);
   free(bytes);
   return true;
}




//! @brief Return whether declarator is not pointer in compile expr slot.
static bool declarator_is_not_pointer(const ASTNode *declarator) {
   return declarator_pointer_depth(declarator) == 0;
}

//! @brief Return whether type node is plain void in compile expr slot.
static bool type_node_is_plain_void(const ASTNode *type, const ASTNode *declarator) {
   const char *name = type_name_from_node(type);
   return name && !strcmp(name, "void") && declarator_is_not_pointer(declarator);
}

//! @brief Return whether expr is plain void cast in compile expr slot.
static bool expr_is_plain_void_cast(ASTNode *expr) {
   const ASTNode *target_type;
   const ASTNode *target_decl;

   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || strcmp(expr->name, "cast")) {
      return false;
   }
   target_type = cast_expr_target_type(expr);
   target_decl = cast_expr_target_declarator(expr);
   return type_node_is_plain_void(target_type, target_decl);
}

//! @brief Handle cast expression target size logic for compile expr slot.
static int cast_expr_target_size(const ASTNode *expr) {
   const ASTNode *type = cast_expr_target_type(expr);
   const ASTNode *declarator = cast_expr_target_declarator(expr);
   int size;

   if (!type) {
      return 0;
   }

   size = declarator_storage_size(type, declarator);
   if (size <= 0) {
      size = type_size_from_node(type);
   }
   return size;
}

//! @brief Report unknown identifier node diagnostics with the location/context expected by compile expr slot callers.
static void error_unknown_identifier_node(const ASTNode *idnode, const ASTNode *fallback, const char *ident) {
   const char *file = idnode && idnode->file ? idnode->file : (fallback && fallback->file ? fallback->file : "<unknown>");
   int line = idnode ? idnode->line : (fallback ? fallback->line : 0);
   int column = idnode ? idnode->column : (fallback ? fallback->column : 0);

   if (ident && !strcmp(ident, "$$")) {
      error_user("[%s:%d.%d] '$$' is the current function's return object, so it is only valid inside a function that returns a value. "
                 "Use it in a non-void function body, for example '$$.field := value; return;', or use 'return <expr>;' to have the compiler write the return object for you.",
                 file, line, column);
   }

   error_user("[%s:%d.%d] unknown identifier '%s'", file, line, column, ident ? ident : "<unknown>");
}

//! @brief Handle sizeof operand size logic for compile expr slot.
static int sizeof_operand_size(const ASTNode *operand, Context *ctx) {
   operand = unwrap_expr_node(operand);
   if (!operand || is_empty(operand)) {
      return 0;
   }
   if (!strcmp(operand->name, "sizeof_expr") && operand->count > 0) {
      ASTNode *value = (ASTNode *) operand->children[0];
      const char *ident = expr_bare_identifier_name(value);
      int size;
      if (ident && !ctx_lookup(ctx, ident) && !global_decl_lookup(ident) && !resolve_function_designator_target(ident)) {
         error_unknown_identifier_node(expr_bare_identifier_node(value), value, ident);
      }
      size = expr_value_size(value, ctx);
      if (size <= 0) {
         error_user("[%s:%d.%d] invalid operand to sizeof",
               value && value->file ? value->file : (operand->file ? operand->file : "<unknown>"),
               value ? value->line : operand->line,
               value ? value->column : operand->column);
      }
      return size;
   }
   if (!strcmp(operand->name, "sizeof_type") && operand->count > 0) {
      const ASTNode *cast_type = operand->children[0];
      const ASTNode *specifiers;
      const ASTNode *type;
      const ASTNode *declarator;
      const char *type_name;
      int size;
      if (!cast_type || strcmp(cast_type->name, "cast_type") || cast_type->count < 2) {
         return 0;
      }
      specifiers = cast_type->children[0];
      if (!specifiers || specifiers->count < 2) {
         return 0;
      }
      type = specifiers->children[1];
      declarator = cast_type->children[1];
      type_name = type_name_from_node(type);
      if (type_name && !strcmp(type_name, "void") && declarator_pointer_depth(declarator) == 0) {
         error_user("[%s:%d.%d] invalid application of sizeof to void type",
               type && type->file ? type->file : (operand->file ? operand->file : "<unknown>"),
               type ? type->line : operand->line,
               type ? type->column : operand->column);
      }
      size = declarator_storage_size(type, declarator);
      if (size <= 0) {
         size = type_size_from_node(type);
      }
      if (size <= 0) {
         error_user("[%s:%d.%d] invalid application of sizeof to incomplete type '%s'",
               type && type->file ? type->file : (operand->file ? operand->file : "<unknown>"),
               type ? type->line : operand->line,
               type ? type->column : operand->column,
               type_name ? type_name : "<unknown>");
      }
      return size;
   }
   return 0;
}






//! @brief Lower expr to slot from AST/semantic state into generated assembly or linker-visible metadata.
bool compile_expr_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst) {
   expr = (ASTNode *) unwrap_expr_node(expr);

   if (!expr || is_empty(expr)) {
      return true;
   }

   if (dst && dst->declarator && declarator_pointer_depth(dst->declarator) > 0) {
      LValueRef lv;
      if (resolve_ref_argument_lvalue(ctx, expr, &lv) && lv.declarator &&
          declarator_pointer_depth(lv.declarator) == 0 && declarator_array_count(lv.declarator) > 0) {
         if (!emit_prepare_lvalue_ptr(ctx, &lv, LVALUE_ACCESS_ADDRESS)) {
            return false;
         }
         emit_store_ptr_to_fp(dst->offset, 0, dst->size);
         return true;
      }
   }

   if (!strcmp(expr->name, "assign_expr") && expr->count == 3) {
      LValueRef lv;
      int load_size;

      compile_expr(expr, ctx);
      if (!resolve_lvalue(ctx, expr->children[1], &lv)) {
         return false;
      }

      load_size = lv.size < dst->size ? lv.size : dst->size;
      if (load_size <= 0) {
         load_size = dst->size > 0 ? dst->size : lv.size;
      }
      if (load_size <= 0) {
         return false;
      }

      if (!emit_copy_lvalue_to_fp(ctx, dst->offset, &lv, load_size)) {
         return false;
      }
      emit_copy_fp_to_fp_convert(dst->offset, dst->size, dst->type, dst->offset, load_size, lv.type);
      return true;
   }

   if (!strcmp(expr->name, "()")) {
      return compile_call_expr_to_slot(expr, ctx, dst);
   }

   if (!strcmp(expr->name, "cast") || !strcmp(expr->name, "flag_cast")) {
      const ASTNode *target_type = !strcmp(expr->name, "cast") ? cast_expr_target_type(expr) : flag_cast_target_type(expr, ctx);
      const ASTNode *target_decl = !strcmp(expr->name, "cast") ? cast_expr_target_declarator(expr) : flag_cast_target_declarator(expr, ctx);
      int target_size = !strcmp(expr->name, "cast") ? cast_expr_target_size(expr) : flag_cast_target_size(expr, ctx);
      SlotFixedScratch scratch;
      ContextEntry tmp;
      if (expr_is_plain_void_cast(expr)) {
         error_user("[%s:%d.%d] void expression has no value",
               expr->file ? expr->file : "<unknown>", expr->line, expr->column);
      }
      if (!target_type || target_size <= 0 || expr->count < 2) {
         error_user("[%s:%d.%d] invalid cast target type",
               expr->file ? expr->file : "<unknown>", expr->line, expr->column);
      }
      slot_fixed_scratch_begin(ctx, "casttmp", target_size, &scratch);
      tmp = (ContextEntry){ .name = "$cast", .type = target_type, .declarator = target_decl,
                            .is_static = false, .is_zeropage = false, .is_global = false,
                            .target_typed = true, .offset = 0, .size = target_size };
      if (!compile_expr_to_slot(expr->children[1], ctx, &tmp)) {
         slot_fixed_scratch_end(ctx, &scratch);
         return false;
      }
      slot_fixed_scratch_end(ctx, &scratch);
      emit_slot_fixed_scratch_result(ctx, &scratch, 0, tmp.size, tmp.type, dst);
      return true;
   }

   if (!strcmp(expr->name, "sizeof")) {
      int size_value = sizeof_operand_size(expr->children[0], ctx);
      unsigned char *bytes;
      if (size_value <= 0) {
         return false;
      }
      bytes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
      if (!bytes) {
         error_unreachable("out of memory");
      }
      if (!encode_integer_initializer_value(size_value, bytes, dst->size, dst->type)) {
         free(bytes);
         return false;
      }
      emit_store_immediate_to_fp(dst->offset, bytes, dst->size);
      free(bytes);
      return true;
   }

   if (expr->kind == AST_INTEGER) {
      unsigned char *bytes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
      make_le_int(expr->strval, bytes, dst->size);
      emit_store_immediate_to_fp(dst->offset, bytes, dst->size);
      free(bytes);
      return true;
   }

   if (expr->kind == AST_STRING) {
      long long ch_value = 0;

      if (decode_char_constant_value(expr->strval, &ch_value)) {
         unsigned char *bytes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
         char tmp[64];
         snprintf(tmp, sizeof(tmp), "%lld", ch_value);
         make_le_int(tmp, bytes, dst->size);
         emit_store_immediate_to_fp(dst->offset, bytes, dst->size);
         free(bytes);
      }
      else {
         const char *label = emit_pointer_initializer_backing_object(dst ? dst->type : NULL,
               dst ? dst->declarator : NULL, expr);
         if (!label) {
            label = remember_string_literal(expr->strval);
         }
         emit_store_label_address_to_fp(dst->offset, dst->size, label);
      }
      return true;
   }

   {
      const char *ident = expr_bare_identifier_name(expr);
      if (ident) {
         ContextEntry *entry = ctx_lookup(ctx, ident);
         if (entry && entry_is_absolute_ref(entry)) {
            LValueRef lv = { .name = entry->name, .type = entry->type, .declarator = entry->declarator, .base_type = entry->type, .base_declarator = entry->declarator, .is_static = entry->is_static, .is_zeropage = entry->is_zeropage, .is_global = entry->is_global, .is_ref = entry->is_ref, .is_absolute_ref = entry->is_absolute_ref, .read_expr = entry->read_expr, .write_expr = entry->write_expr, .offset = entry->offset, .size = entry->size };
            if (!entry_has_read_address(entry)) {
               error_user("[%s:%d.%d] absolute ref '%s' is write-only", expr->file, expr->line, expr->column, ident);
            }
            if (dst->size == lv.size && dst->type == lv.type) {
               return emit_copy_lvalue_to_fp(ctx, dst->offset, &lv, lv.size);
            }
            {
               SlotFixedScratch scratch;
               slot_fixed_scratch_begin(ctx, "abslocaltmp", lv.size, &scratch);
               if (!emit_copy_lvalue_to_fp(ctx, 0, &lv, lv.size)) {
                  slot_fixed_scratch_end(ctx, &scratch);
                  return false;
               }
               slot_fixed_scratch_end(ctx, &scratch);
               emit_slot_fixed_scratch_result(ctx, &scratch, 0, lv.size, lv.type, dst);
               return true;
            }
         }
         if (entry && !entry->is_static && !entry->is_zeropage) {
            emit_copy_fp_to_fp_convert(dst->offset, dst->size, dst->type, entry->offset, entry->size, entry->type);
            return true;
         }
         if (entry) {
            char sym[256];
            if (entry_symbol_name(ctx, entry, sym, sizeof(sym))) {
               emit_copy_symbol_to_fp_convert(dst->offset, dst->size, dst->type, sym, entry->size, entry->type);
               return true;
            }
         }
         {
            const ASTNode *g = global_decl_lookup(ident);
            if (g && g->count >= 3) {
               ContextEntry gentry;
               if (init_context_entry_from_global_decl(&gentry, ident, g) && entry_is_absolute_ref(&gentry)) {
                  LValueRef lv = { .name = gentry.name, .type = gentry.type, .declarator = gentry.declarator, .base_type = gentry.type, .base_declarator = gentry.declarator, .is_static = gentry.is_static, .is_zeropage = gentry.is_zeropage, .is_global = gentry.is_global, .is_ref = gentry.is_ref, .is_absolute_ref = gentry.is_absolute_ref, .read_expr = gentry.read_expr, .write_expr = gentry.write_expr, .offset = gentry.offset, .size = gentry.size };
                  if (!entry_has_read_address(&gentry)) {
                     error_user("[%s:%d.%d] absolute ref '%s' is write-only", expr->file, expr->line, expr->column, ident);
                  }
                  if (dst->size == lv.size && dst->type == lv.type) {
                     return emit_copy_lvalue_to_fp(ctx, dst->offset, &lv, lv.size);
                  }
                  {
                     SlotFixedScratch scratch;
                     slot_fixed_scratch_begin(ctx, "absglobaltmp", lv.size, &scratch);
                     if (!emit_copy_lvalue_to_fp(ctx, 0, &lv, lv.size)) {
                        slot_fixed_scratch_end(ctx, &scratch);
                        return false;
                     }
                     slot_fixed_scratch_end(ctx, &scratch);
                     emit_slot_fixed_scratch_result(ctx, &scratch, 0, lv.size, lv.type, dst);
                     return true;
                  }
               }
               else {
                  char sym[256];
                  int gsize = declarator_storage_size(g->children[1], decl_node_declarator(g));
                  format_user_asm_symbol(ident, sym, sizeof(sym));
                  emit_copy_symbol_to_fp_convert(dst->offset, dst->size, dst->type, sym, gsize, g->children[1]);
                  return true;
               }
            }
         }
         {
            const ASTNode *fn = resolve_function_designator_target(ident);
            if (fn) {
               error_user("[%s:%d.%d] function pointers are not supported; call '%s' directly",
                          expr->file, expr->line, expr->column, ident);
            }
         }
         error_unknown_identifier_node(expr_bare_identifier_node(expr), expr, ident);
      }
   }

   if (expr->count == 1 && !strcmp(expr->name, "&")) {
      LValueRef lv;
      ASTNode *inner = (ASTNode *) unwrap_expr_node(expr->children[0]);
      if (inner && !strcmp(inner->name, "lvalue") && resolve_lvalue(ctx, inner, &lv)) {
         if (!emit_prepare_lvalue_ptr(ctx, &lv, LVALUE_ACCESS_ADDRESS)) {
            if (lv.is_absolute_ref) {
               error_user("[%s:%d.%d] absolute ref '%s' does not have a single address", inner->file, inner->line, inner->column, lv.name ? lv.name : "<unnamed>");
            }
            return false;
         }
         emit_store_ptr_to_fp(dst->offset, 0, dst->size);
         return true;
      }
      {
         const char *ident = expr_bare_identifier_name(inner);
         if (ident) {
            const ASTNode *fn = resolve_function_designator_target(ident);
            if (fn) {
               error_user("[%s:%d.%d] function pointers are not supported; call '%s' directly",
                          inner->file, inner->line, inner->column, ident);
            }
            if (!ctx_lookup(ctx, ident) && !global_decl_lookup(ident)) {
               error_unknown_identifier_node(expr_bare_identifier_node(inner), inner, ident);
            }
         }
      }
      {
         const char *label = emit_pointer_initializer_backing_object(dst ? dst->type : NULL,
               dst ? dst->declarator : NULL, expr);
         InitConstValue value = {0};
         if (label) {
            emit_store_label_address_to_fp(dst->offset, dst->size, label);
            return true;
         }
         if (eval_constant_initializer_expr(inner, &value) && value.kind == INIT_CONST_INT) {
            unsigned char *bytes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
            char tmp[64];
            snprintf(tmp, sizeof(tmp), "%lld", value.i);
            make_le_int(tmp, bytes, dst->size);
            emit_store_immediate_to_fp(dst->offset, bytes, dst->size);
            free(bytes);
            return true;
         }
      }
   }



   if (compile_expr_operator_to_slot(expr, ctx, dst)) {
      return true;
   }

   if (!strcmp(expr->name, "lvalue") && expr->count > 0) {
      LValueRef lv;
      if (resolve_lvalue(ctx, expr, &lv)) {
         int load_size = lv.size < dst->size ? lv.size : dst->size;
         if (lv.size == dst->size && !strcmp(type_name_from_node(lv.type), type_name_from_node(dst->type)) &&
             declarator_pointer_depth(lv.declarator) == declarator_pointer_depth(dst->declarator) &&
             declarator_array_count(lv.declarator) == declarator_array_count(dst->declarator)) {
            return emit_copy_lvalue_to_fp(ctx, dst->offset, &lv, lv.size);
         }
         if (!emit_copy_lvalue_to_fp(ctx, dst->offset, &lv, load_size)) {
            return false;
         }
         emit_copy_fp_to_fp_convert(dst->offset, dst->size, dst->type, dst->offset, load_size, lv.type);
         return true;
      }
      {
         const ASTNode *idnode = expr_lvalue_base_identifier_node(expr);
         const char *ident = idnode ? idnode->strval : NULL;
         if (ident && !ctx_lookup(ctx, ident) && !global_decl_lookup(ident)) {
            error_unknown_identifier_node(idnode, expr, ident);
         }
      }
      error_user("[%s:%d.%d] invalid lvalue expression",
            expr->file ? expr->file : "<unknown>", expr->line, expr->column);
   }

   if (!strcmp(expr->name, "comma_expr") && expr->count > 0) {
      for (int i = 0; i < expr->count - 1; i++) {
         compile_expr(expr->children[i], ctx);
      }
      return compile_expr_to_slot(expr->children[expr->count - 1], ctx, dst);
   }

   if (expr_is_ternary_node(expr)) {
      ASTNode *test_expr = expr_ternary_test(expr);
      ASTNode *true_expr = expr_ternary_true(expr);
      ASTNode *false_expr = expr_ternary_false(expr);
      const char *false_label = next_label("ternary_false");
      const char *end_label = next_label("ternary_end");
      bool ok;
      if (!test_expr || !true_expr || !false_expr || !false_label || !end_label) {
         free((void *) false_label);
         free((void *) end_label);
         return false;
      }
      if (!compile_condition_branch_false(test_expr, ctx, false_label)) {
         free((void *) false_label);
         free((void *) end_label);
         return false;
      }
      ok = compile_expr_to_slot(true_expr, ctx, dst);
      emit(&es_code, "    jmp %s\n", end_label);
      emit(&es_code, "%s:\n", false_label);
      if (ok) {
         ok = compile_expr_to_slot(false_expr, ctx, dst);
      }
      emit(&es_code, "%s:\n", end_label);
      free((void *) false_label);
      free((void *) end_label);
      return ok;
   }



   return false;
}




