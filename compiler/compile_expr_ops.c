//! @file compiler/compile_expr_ops.c
//! @brief Implements operator lowering helpers for the n65 compiler.
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

static int expr_byte_index(const ASTNode *type, int size, int i);

typedef struct ExprFixedScratch {
   int saved_locals;
   int saved_high_water;
   int reserved;
   char symbol[96];
} ExprFixedScratch;

//! @brief Prepare one fixed-address expression working area without changing fp.
static void expr_fixed_scratch_prepare(Context *ctx, const char *prefix, int reserved,
                                       ExprFixedScratch *scratch) {
   memset(scratch, 0, sizeof(*scratch));
   scratch->saved_locals = ctx ? ctx->locals : 0;
   scratch->saved_high_water = ctx ? ctx->locals_high_water : 0;
   scratch->reserved = reserved > 0 ? reserved : 1;
   snprintf(scratch->symbol, sizeof(scratch->symbol), "__n65_%s_%d", prefix, label_counter++);
}

//! @brief Redirect fp to a prepared fixed-address expression working area.
static void expr_fixed_scratch_activate(Context *ctx, ExprFixedScratch *scratch) {
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

//! @brief Begin one fixed-address expression working area and redirect fp to it.
static void expr_fixed_scratch_begin(Context *ctx, const char *prefix, int reserved,
                                     ExprFixedScratch *scratch) {
   expr_fixed_scratch_prepare(ctx, prefix, reserved, scratch);
   expr_fixed_scratch_activate(ctx, scratch);
}

//! @brief Restore fp, restore compiler frame accounting, and declare fixed scratch.
static void expr_fixed_scratch_end(Context *ctx, ExprFixedScratch *scratch) {
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

//! @brief Copy a converted fixed-scratch result into the caller destination.
static void emit_fixed_scratch_result(Context *ctx, const ExprFixedScratch *scratch,
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


//! @brief Parse incdec lvalue expr into the normalized representation used by compiler operator lowering.
bool classify_incdec_lvalue_expr(ASTNode *expr, bool *inc, bool *pre) {
   const char *op;

   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || strcmp(expr->name, "lvalue") || expr->count < 3 || !expr->children[2] || expr->children[2]->kind != AST_IDENTIFIER) {
      return false;
   }

   op = expr->children[2]->strval;
   if (!op) {
      return false;
   }

   if (!strcmp(op, "pre++")) {
      if (inc) *inc = true;
      if (pre) *pre = true;
      return true;
   }
   if (!strcmp(op, "post++")) {
      if (inc) *inc = true;
      if (pre) *pre = false;
      return true;
   }
   if (!strcmp(op, "pre--")) {
      if (inc) *inc = false;
      if (pre) *pre = true;
      return true;
   }
   if (!strcmp(op, "post--")) {
      if (inc) *inc = false;
      if (pre) *pre = false;
      return true;
   }
   return false;
}

//! @brief Create incdec delta bytes for compiler operator lowering.
static bool make_incdec_delta_bytes(const ASTNode *type, const ASTNode *declarator, int size, unsigned char *bytes) {
   int step = 1;
   char step_buf[64];

   if (!bytes || size <= 0) {
      return false;
   }

   memset(bytes, 0, (size_t) size);
   if (declarator && declarator_pointer_depth(declarator) > 0) {
      step = declarator_first_element_size(type, declarator);
      if (step <= 0) {
         step = 1;
      }
   }

   snprintf(step_buf, sizeof(step_buf), "%d", step);
   make_le_int(step_buf, bytes, size);
   return true;
}

//! @brief Emit copy frame pointer to frame pointer for compiler operator lowering diagnostics or output files.
void emit_copy_fp_to_fp(int dst_offset, int src_offset, int size) {
   bool dst_direct;
   bool src_direct;

   if (size <= 0 || dst_offset == src_offset) {
      return;
   }

   dst_direct = dst_offset >= 0 && dst_offset + size <= 256;
   src_direct = src_offset >= 0 && src_offset + size <= 256;

   if (!src_direct) {
      emit_prepare_fp_ptr(0, src_offset);
   }
   if (!dst_direct) {
      emit_prepare_fp_ptr(1, dst_offset);
   }

   for (int i = 0; i < size; i++) {
      emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + i) : i);
      emit(&es_code, "    lda %s,y\n", src_direct ? "(fp)" : "(ptr0)");
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + i) : i);
      emit(&es_code, "    sta %s,y\n", dst_direct ? "(fp)" : "(ptr1)");
   }
}

//! @brief Handle expr byte index logic for compiler operator lowering.
static int expr_byte_index(const ASTNode *type, int size, int i) {
   (void) type;
   (void) size;
   return i;
}

//! @brief Emit add immediate to frame pointer for compiler operator lowering diagnostics or output files.
void emit_add_immediate_to_fp(const ASTNode *type, int offset, const unsigned char *bytes, int size) {
   bool direct = offset >= 0 && offset + size <= 256;

   if (!direct) {
      emit_prepare_fp_ptr(0, offset);
   }

   emit(&es_code, "    clc\n");
   for (int i = 0; i < size; i++) {
      int j = expr_byte_index(type, size, i);
      emit(&es_code, "    ldy #%d\n", direct ? (offset + j) : j);
      emit(&es_code, "    lda %s,y\n", direct ? "(fp)" : "(ptr0)");
      emit(&es_code, "    adc #$%02x\n", bytes[j]);
      emit(&es_code, "    sta %s,y\n", direct ? "(fp)" : "(ptr0)");
   }
}

//! @brief Extract emit sub immediate from frame pointer for compiler operator lowering.
static void emit_sub_immediate_from_fp(const ASTNode *type, int offset, const unsigned char *bytes, int size) {
   bool direct = offset >= 0 && offset + size <= 256;

   if (!direct) {
      emit_prepare_fp_ptr(0, offset);
   }

   emit(&es_code, "    sec\n");
   for (int i = 0; i < size; i++) {
      int j = expr_byte_index(type, size, i);
      emit(&es_code, "    ldy #%d\n", direct ? (offset + j) : j);
      emit(&es_code, "    lda %s,y\n", direct ? "(fp)" : "(ptr0)");
      emit(&es_code, "    sbc #$%02x\n", bytes[j]);
      emit(&es_code, "    sta %s,y\n", direct ? "(fp)" : "(ptr0)");
   }
}

//! @brief Emit add frame pointer to frame pointer for compiler operator lowering diagnostics or output files.
void emit_add_fp_to_fp(const ASTNode *type, int dst_offset, int src_offset, int size) {
   bool helper_is_generic = false;
   const char *helper = int_addsub_helper_name(type, size, false, &helper_is_generic);
   bool dst_direct = dst_offset >= 0 && dst_offset + size <= 256;
   bool src_direct = src_offset >= 0 && src_offset + size <= 256;

   if (helper) {
      if (helper_is_generic) {
         emit_runtime_binary_fp_fp(helper, dst_offset, dst_offset, src_offset, size);
      }
      else {
         emit_runtime_fixed_binary_fp_fp(helper, dst_offset, dst_offset, src_offset);
      }
      return;
   }

   if (!dst_direct) {
      emit_prepare_fp_ptr(0, dst_offset);
   }
   if (!src_direct) {
      emit_prepare_fp_ptr(1, src_offset);
   }

   emit(&es_code, "    clc\n");
   for (int i = 0; i < size; i++) {
      int j = expr_byte_index(type, size, i);
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + j) : j);
      emit(&es_code, "    lda %s,y\n", dst_direct ? "(fp)" : "(ptr0)");
      emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + j) : j);
      emit(&es_code, "    adc %s,y\n", src_direct ? "(fp)" : "(ptr1)");
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + j) : j);
      emit(&es_code, "    sta %s,y\n", dst_direct ? "(fp)" : "(ptr0)");
   }
}

//! @brief Extract emit sub frame pointer from frame pointer for compiler operator lowering.
void emit_sub_fp_from_fp(const ASTNode *type, int dst_offset, int src_offset, int size) {
   bool helper_is_generic = false;
   const char *helper = int_addsub_helper_name(type, size, true, &helper_is_generic);
   bool dst_direct = dst_offset >= 0 && dst_offset + size <= 256;
   bool src_direct = src_offset >= 0 && src_offset + size <= 256;

   if (helper) {
      if (helper_is_generic) {
         emit_runtime_binary_fp_fp(helper, dst_offset, dst_offset, src_offset, size);
      }
      else {
         emit_runtime_fixed_binary_fp_fp(helper, dst_offset, dst_offset, src_offset);
      }
      return;
   }

   if (!dst_direct) {
      emit_prepare_fp_ptr(0, dst_offset);
   }
   if (!src_direct) {
      emit_prepare_fp_ptr(1, src_offset);
   }

   emit(&es_code, "    sec\n");
   for (int i = 0; i < size; i++) {
      int j = expr_byte_index(type, size, i);
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + j) : j);
      emit(&es_code, "    lda %s,y\n", dst_direct ? "(fp)" : "(ptr0)");
      emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + j) : j);
      emit(&es_code, "    sbc %s,y\n", src_direct ? "(fp)" : "(ptr1)");
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + j) : j);
      emit(&es_code, "    sta %s,y\n", dst_direct ? "(fp)" : "(ptr0)");
   }
}

//! @brief Lower expr operator to slot from AST/semantic state into generated assembly or linker-visible metadata.
bool compile_expr_operator_to_slot(ASTNode *expr, Context *ctx, ContextEntry *dst) {
   if (!strcmp(expr->name, "lvalue") && expr->count > 0 && expr->count >= 3 && expr->children[2] &&
       expr->children[2]->kind == AST_IDENTIFIER &&
       (!strcmp(expr->children[2]->strval, "pre++") || !strcmp(expr->children[2]->strval, "post++") ||
        !strcmp(expr->children[2]->strval, "pre--") || !strcmp(expr->children[2]->strval, "post--"))) {
      LValueRef lv;
      bool inc;
      bool pre;
      if (!resolve_lvalue(ctx, expr, &lv)) {
         return false;
      }
      if (lv.is_absolute_ref) {
         if (!lv.read_expr) {
            error_user("[%s:%d.%d] absolute ref '%s' is write-only", expr->file, expr->line, expr->column, lv.name ? lv.name : "<unnamed>");
         }
         if (!lv.write_expr) {
            error_user("[%s:%d.%d] absolute ref '%s' is read-only", expr->file, expr->line, expr->column, lv.name ? lv.name : "<unnamed>");
         }
      }
      classify_incdec_lvalue_expr(expr, &inc, &pre);
      {
         int tmp_size;
         unsigned char *one;
         ExprFixedScratch scratch;
         tmp_size = lv.size > 0 ? lv.size : dst->size;
         expr_fixed_scratch_prepare(ctx, "incdectmp", tmp_size, &scratch);
         if (!emit_copy_lvalue_to_symbol(ctx, scratch.symbol, 0, &lv, tmp_size)) {
            return false;
         }
         if (!pre) {
            emit_fixed_scratch_result(ctx, &scratch, 0, tmp_size, lv.type, dst);
         }
         one = (unsigned char *) calloc(tmp_size ? tmp_size : 1, sizeof(unsigned char));
         if (!one) {
            return false;
         }
         if (!make_incdec_delta_bytes(lv.type, lv.declarator, tmp_size, one)) {
            free(one);
            return false;
         }
         expr_fixed_scratch_activate(ctx, &scratch);
         if (inc) {
            emit_add_immediate_to_fp(lv.type, 0, one, tmp_size);
         }
         else {
            emit_sub_immediate_from_fp(lv.type, 0, one, tmp_size);
         }
         free(one);
         expr_fixed_scratch_end(ctx, &scratch);
         if (!emit_copy_symbol_to_lvalue(ctx, &lv, scratch.symbol, 0, tmp_size)) {
            return false;
         }
         if (pre) {
            emit_fixed_scratch_result(ctx, &scratch, 0, tmp_size, lv.type, dst);
         }
         return true;
      }
   }

   require_no_mixed_signed_integer_binary_expr(expr, ctx);

   if (expr->count == 1 && !strcmp(expr->name, "+")) {
      return compile_expr_to_slot(expr->children[0], ctx, dst);
   }

   if (expr->count == 1 && !strcmp(expr->name, "!")) {
      const char *false_label = next_label("not_false");
      const char *end_label = next_label("not_end");
      unsigned char *zeroes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
      unsigned char *ones = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
      bool ok = false;
      if (!false_label || !end_label || !zeroes || !ones) {
         free(zeroes);
         free(ones);
         free((void *) false_label);
         free((void *) end_label);
         return false;
      }
      ones[0] = 1;
      if (!compile_condition_branch_false(expr->children[0], ctx, false_label)) {
         goto unary_not_done;
      }
      emit_store_immediate_to_fp(dst->offset, zeroes, dst->size);
      emit(&es_code, "    jmp %s\n", end_label);
      emit(&es_code, "%s:\n", false_label);
      emit_store_immediate_to_fp(dst->offset, ones, dst->size);
      emit(&es_code, "%s:\n", end_label);
      ok = true;
unary_not_done:
      free(zeroes);
      free(ones);
      free((void *) false_label);
      free((void *) end_label);
      return ok;
   }

   if (expr->count == 1 && !strcmp(expr->name, "~")) {
      if (!compile_expr_to_slot(expr->children[0], ctx, dst)) {
         return false;
      }
      for (int i = 0; i < dst->size; i++) {
         emit(&es_code, "    ldy #%d\n", dst->offset + i);
         emit(&es_code, "    lda (fp),y\n");
         emit(&es_code, "    eor #$ff\n");
         emit(&es_code, "    sta (fp),y\n");
      }
      return true;
   }

   if (expr->count == 1 && !strcmp(expr->name, "-")) {
      const ASTNode *neg_type = expr_value_type(expr, ctx);
      if (!compile_expr_to_slot(expr->children[0], ctx, dst)) {
         return false;
      }
      if (!neg_type) {
         neg_type = dst->type;
      }
      emit_prepare_fp_ptr(0, dst->offset);
      emit_prepare_fp_ptr(1, dst->offset);
      emit(&es_code, "    lda #$%02x\n", dst->size & 0xff);
      emit(&es_code, "    sta arg0\n");
      remember_runtime_import(int_comp2_helper_name(neg_type));
      emit(&es_code, "    jsr _%s\n", int_comp2_helper_name(neg_type));
      return true;
   }

   if (expr->count == 2 && (!strcmp(expr->name, "&&") || !strcmp(expr->name, "||"))) {
      const char *false_label = next_label(!strcmp(expr->name, "&&") ? "and_false" : "or_false");
      const char *end_label = next_label(!strcmp(expr->name, "&&") ? "and_end" : "or_end");
      unsigned char *zeroes;
      unsigned char *ones;

      if (!false_label || !end_label) {
         free((void *) false_label);
         free((void *) end_label);
         return false;
      }

      zeroes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
      ones = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
      if (!zeroes || !ones) {
         free(zeroes);
         free(ones);
         free((void *) false_label);
         free((void *) end_label);
         return false;
      }
      ones[0] = 1;

      if (!strcmp(expr->name, "&&")) {
         if (!compile_condition_branch_false(expr->children[0], ctx, false_label) ||
             !compile_condition_branch_false(expr->children[1], ctx, false_label)) {
            free(zeroes);
            free(ones);
            free((void *) false_label);
            free((void *) end_label);
            return false;
         }
      }
      else {
         const char *rhs_label = next_label("or_rhs");
         if (!rhs_label) {
            free(zeroes);
            free(ones);
            free((void *) false_label);
            free((void *) end_label);
            return false;
         }
         if (!compile_condition_branch_false(expr->children[0], ctx, rhs_label)) {
            free(zeroes);
            free(ones);
            free((void *) rhs_label);
            free((void *) false_label);
            free((void *) end_label);
            return false;
         }
         emit_store_immediate_to_fp(dst->offset, ones, dst->size);
         emit(&es_code, "    jmp %s\n", end_label);
         emit(&es_code, "%s:\n", rhs_label);
         if (!compile_condition_branch_false(expr->children[1], ctx, false_label)) {
            free(zeroes);
            free(ones);
            free((void *) rhs_label);
            free((void *) false_label);
            free((void *) end_label);
            return false;
         }
         free((void *) rhs_label);
         emit_store_immediate_to_fp(dst->offset, ones, dst->size);
         emit(&es_code, "    jmp %s\n", end_label);
         emit(&es_code, "%s:\n", false_label);
         emit_store_immediate_to_fp(dst->offset, zeroes, dst->size);
         emit(&es_code, "%s:\n", end_label);
         free(zeroes);
         free(ones);
         free((void *) false_label);
         free((void *) end_label);
         return true;
      }

      emit_store_immediate_to_fp(dst->offset, ones, dst->size);
      emit(&es_code, "    jmp %s\n", end_label);
      emit(&es_code, "%s:\n", false_label);
      emit_store_immediate_to_fp(dst->offset, zeroes, dst->size);
      emit(&es_code, "%s:\n", end_label);
      free(zeroes);
      free(ones);
      free((void *) false_label);
      free((void *) end_label);
      return true;
   }

   if (expr->count == 2 && (!strcmp(expr->name, "==") || !strcmp(expr->name, "!=") ||
                            !strcmp(expr->name, "<") || !strcmp(expr->name, ">") ||
                            !strcmp(expr->name, "<=") || !strcmp(expr->name, ">="))) {
      const char *false_label = next_label("cmp_false");
      const char *end_label = next_label("cmp_end");
      unsigned char *zeroes = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
      unsigned char *ones = (unsigned char *) calloc(dst->size ? dst->size : 1, sizeof(unsigned char));
      if (!false_label || !end_label || !zeroes || !ones) {
         free(zeroes);
         free(ones);
         free((void *) false_label);
         free((void *) end_label);
         return false;
      }
      ones[0] = 1;
      if (!compile_condition_branch_false(expr, ctx, false_label)) {
         free(zeroes);
         free(ones);
         free((void *) false_label);
         free((void *) end_label);
         return false;
      }
      emit_store_immediate_to_fp(dst->offset, ones, dst->size);
      emit(&es_code, "    jmp %s\n", end_label);
      emit(&es_code, "%s:\n", false_label);
      emit_store_immediate_to_fp(dst->offset, zeroes, dst->size);
      emit(&es_code, "%s:\n", end_label);
      free(zeroes);
      free(ones);
      free((void *) false_label);
      free((void *) end_label);
      return true;
   }

   if (expr->count == 2 && (!strcmp(expr->name, "+") || !strcmp(expr->name, "-"))) {
      const ASTNode *rhs = unwrap_expr_node(expr->children[1]);
      const ASTNode *lhs_type = NULL;
      const ASTNode *lhs_decl = NULL;
      const ASTNode *rhs_type = NULL;
      const ASTNode *rhs_decl = NULL;
      const ASTNode *work_type = NULL;
      int work_size = expr_value_size(expr, ctx);
      int pointer_scale = 1;

      if (!dst || dst->size <= 0) {
         return false;
      }
      expr_match_signature(expr->children[0], ctx, &lhs_type, &lhs_decl);
      expr_match_signature(expr->children[1], ctx, &rhs_type, &rhs_decl);

      bool scaled_pointer_arith = lhs_decl && declarator_pointer_depth(lhs_decl) > 0;
      work_type = expr_value_type(expr, ctx);

      if (scaled_pointer_arith) {
         work_size = declarator_storage_size(lhs_type, lhs_decl);
         if (work_size <= 0) {
            work_size = dst->size;
         }
      }
      else if (!strcmp(expr->name, "+") && rhs_decl && declarator_pointer_depth(rhs_decl) > 0) {
      }
      if (work_size <= 0) {
         work_size = dst->size;
      }
      if (work_size <= 0) {
         work_size = 1;
      }
      if (!work_type) {
         work_type = scaled_pointer_arith ? lhs_type : dst->type;
      }
      if (scaled_pointer_arith) {
         pointer_scale = declarator_first_element_size(lhs_type, lhs_decl);
         if (pointer_scale <= 0) {
            pointer_scale = 1;
         }
      }

      if (!strcmp(expr->name, "-") && lhs_decl && declarator_pointer_depth(lhs_decl) > 0 && rhs_decl && declarator_pointer_depth(rhs_decl) > 0) {
         int ptr_size = declarator_storage_size(lhs_type, lhs_decl);
         int elem_size = pointer_scale > 0 ? pointer_scale : 1;
         int work_total = ptr_size * 3;
         int out_offset = work_total;
         ExprFixedScratch scratch;
         ContextEntry lhs_tmp = { .name = "$lhs", .type = lhs_type, .declarator = lhs_decl, .is_static = false, .is_zeropage = false, .is_global = false, .offset = 0, .size = ptr_size };
         ContextEntry rhs_tmp = { .name = "$rhs", .type = lhs_type, .declarator = lhs_decl, .is_static = false, .is_zeropage = false, .is_global = false, .offset = ptr_size, .size = ptr_size };
         unsigned char *factor_bytes;
         char factor_buf[64];

         expr_fixed_scratch_begin(ctx, "ptrdifftmp", work_total + dst->size, &scratch);
         if (!compile_expr_to_slot(expr->children[0], ctx, &lhs_tmp) ||
             !compile_expr_to_slot((ASTNode *) rhs, ctx, &rhs_tmp)) {
            expr_fixed_scratch_end(ctx, &scratch);
            return false;
         }
         emit_sub_fp_from_fp(lhs_type, 0, ptr_size, ptr_size);
         factor_bytes = (unsigned char *) calloc(ptr_size ? ptr_size : 1, sizeof(unsigned char));
         if (!factor_bytes) {
            expr_fixed_scratch_end(ctx, &scratch);
            return false;
         }
         snprintf(factor_buf, sizeof(factor_buf), "%d", elem_size);
         make_le_int(factor_buf, factor_bytes, ptr_size);
         emit_store_immediate_to_fp(ptr_size, factor_bytes, ptr_size);
         free(factor_bytes);
         emit_prepare_fp_ptr(0, 0);
         emit_prepare_fp_ptr(1, ptr_size);
         emit_prepare_fp_ptr(2, ptr_size * 2);
         emit_prepare_fp_ptr(3, ptr_size);
         emit(&es_code, "    lda #$%02x\n", ptr_size & 0xff);
         emit(&es_code, "    sta arg0\n");
         remember_runtime_import(int_div_helper_name(lhs_type));
         emit(&es_code, "    jsr _%s\n", int_div_helper_name(lhs_type));
         emit_copy_fp_to_fp_convert(out_offset, dst->size, dst->type, ptr_size * 2, ptr_size,
                                    dst->type ? dst->type : lhs_type);
         expr_fixed_scratch_end(ctx, &scratch);
         emit_fixed_scratch_result(ctx, &scratch, out_offset, dst->size, dst->type, dst);
         return true;
      }

      {
         int lhs_offset = 0;
         int rhs_offset = work_size;
         int factor_offset = 0;
         int scaled_offset = 0;
         int value_offset = rhs_offset;
         int work_total = work_size * 2;
         int out_offset;
         const ASTNode *rhs_slot_type = scaled_pointer_arith ? (expr_is_literal_node(rhs) ? work_type : rhs_type) : work_type;
         ContextEntry lhs_tmp = { .name = "$lhs", .type = work_type, .declarator = lhs_decl, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = dst->target_typed, .offset = lhs_offset, .size = work_size };
         ContextEntry rhs_tmp = { .name = "$rhs", .type = rhs_slot_type ? rhs_slot_type : work_type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = dst->target_typed, .offset = rhs_offset, .size = work_size };
         ExprFixedScratch scratch;

         if (scaled_pointer_arith && pointer_scale != 1) {
            work_total += work_size * 2;
            factor_offset = rhs_offset + work_size;
            scaled_offset = factor_offset + work_size;
            value_offset = scaled_offset;
         }
         out_offset = work_total;
         expr_fixed_scratch_begin(ctx, "addtmp", work_total + dst->size, &scratch);

         if (!compile_expr_to_slot(expr->children[0], ctx, &lhs_tmp) ||
             !compile_expr_to_slot((ASTNode *) rhs, ctx, &rhs_tmp)) {
            expr_fixed_scratch_end(ctx, &scratch);
            return false;
         }

         if (scaled_pointer_arith && pointer_scale != 1) {
            unsigned char *factor_bytes = (unsigned char *) calloc(work_size ? work_size : 1, sizeof(unsigned char));
            char scaled_buf[64];
            const ASTNode *factor_type = rhs_slot_type ? rhs_slot_type : work_type;
            if (!factor_bytes) {
               expr_fixed_scratch_end(ctx, &scratch);
               return false;
            }
            snprintf(scaled_buf, sizeof(scaled_buf), "%d", pointer_scale);
            make_le_int(scaled_buf, factor_bytes, work_size);
            emit_store_immediate_to_fp(factor_offset, factor_bytes, work_size);
            free(factor_bytes);
            emit_runtime_binary_fp_fp(int_mul_helper_name(factor_type ? factor_type : work_type), scaled_offset, rhs_offset, factor_offset, work_size);
            value_offset = int_mul_result_offset(factor_type ? factor_type : work_type, scaled_offset, work_size);
         }

         if (!strcmp(expr->name, "+")) {
            emit_add_fp_to_fp(work_type, lhs_offset, value_offset, work_size);
         }
         else {
            emit_sub_fp_from_fp(work_type, lhs_offset, value_offset, work_size);
         }

         emit_copy_fp_to_fp_convert(out_offset, dst->size, dst->type, lhs_offset, work_size, work_type);
         expr_fixed_scratch_end(ctx, &scratch);
         emit_fixed_scratch_result(ctx, &scratch, out_offset, dst->size, dst->type, dst);
         return true;
      }
   }



   if (expr->count == 2 && (!strcmp(expr->name, "<<") || !strcmp(expr->name, ">>"))) {
      const char *op = expr->name;
      const ASTNode *rhs_type = expr_value_type(expr->children[1], ctx);
      const ASTNode *op_type = NULL;
      if (!dst || dst->size <= 0) {
         return false;
      }
      op_type = expr_value_type(expr, ctx);
      const ASTNode *rhs_slot_type = expr_is_literal_node(expr->children[1]) ? op_type : (rhs_type ? rhs_type : op_type);
      int lhs_size = op_type ? type_size_from_node(op_type) : 0;
      int rhs_size = rhs_slot_type ? type_size_from_node(rhs_slot_type) : 0;
      int work_total;
      int lhs_offset = 0;
      int rhs_offset;
      int aux_offset;
      int out_offset;
      ContextEntry lhs_tmp;
      ContextEntry rhs_tmp;
      const char *helper;
      ExprFixedScratch scratch;

      if (lhs_size <= 0) {
         lhs_size = expr_value_size(expr->children[0], ctx);
      }
      if (lhs_size <= 0) {
         lhs_size = expr_value_size(expr, ctx);
      }
      if (lhs_size <= 0) {
         lhs_size = dst->size > 0 ? dst->size : 1;
      }
      if (rhs_size <= 0) {
         rhs_size = expr_value_size(expr->children[1], ctx);
      }
      if (rhs_size <= 0) {
         rhs_size = 1;
      }

      diagnose_constant_shift_count(expr->children[1], lhs_size * 8);

      rhs_offset = lhs_size;
      aux_offset = rhs_offset + rhs_size;
      work_total = lhs_size + rhs_size + lhs_size;
      out_offset = work_total;
      lhs_tmp = (ContextEntry){ .name = "$lhs", .type = op_type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = dst->target_typed, .offset = lhs_offset, .size = lhs_size };
      rhs_tmp = (ContextEntry){ .name = "$rhs", .type = rhs_slot_type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = dst->target_typed, .offset = rhs_offset, .size = rhs_size };

      expr_fixed_scratch_begin(ctx, "shifttmp", work_total + dst->size, &scratch);
      if (!compile_expr_to_slot(expr->children[0], ctx, &lhs_tmp) ||
          !compile_expr_to_slot(expr->children[1], ctx, &rhs_tmp)) {
         expr_fixed_scratch_end(ctx, &scratch);
         return false;
      }

      helper = int_shift_helper_name(op_type, !strcmp(op, "<<"));
      emit_runtime_shift_fp(helper, lhs_offset, aux_offset, rhs_offset, rhs_type, rhs_size, lhs_size);
      emit_copy_fp_to_fp_convert(out_offset, dst->size, dst->type, aux_offset, lhs_size, op_type);
      expr_fixed_scratch_end(ctx, &scratch);
      emit_fixed_scratch_result(ctx, &scratch, out_offset, dst->size, dst->type, dst);
      return true;
   }


   if (expr->count == 2 && (!strcmp(expr->name, "&") || !strcmp(expr->name, "|") || !strcmp(expr->name, "^") ||
                            !strcmp(expr->name, "*") || !strcmp(expr->name, "/") || !strcmp(expr->name, "%"))) {
      const char *op = expr->name;
      const ASTNode *op_type = NULL;
      int op_size = expr_value_size(expr, ctx);
      int work_total;
      int lhs_offset = 0;
      int rhs_offset;
      int aux_offset;
      int out_offset;
      ContextEntry lhs_tmp;
      ContextEntry rhs_tmp;
      const char *helper = NULL;
      ExprFixedScratch scratch;

      if (!dst || dst->size <= 0) {
         return false;
      }
      op_type = expr_value_type(expr, ctx);
      if (op_size <= 0) {
         op_size = expr_value_size(expr->children[0], ctx);
      }
      if (op_size <= 0 && expr->count > 1) {
         op_size = expr_value_size(expr->children[1], ctx);
      }
      if (op_size <= 0) {
         op_size = dst->size > 0 ? dst->size : 1;
      }
      if (!op_type) {
         op_type = dst->type;
      }

      work_total = op_size * 2;
      if (!strcmp(op, "*") || !strcmp(op, "/") || !strcmp(op, "%")) {
         work_total += op_size * 2;
      }
      rhs_offset = op_size;
      aux_offset = rhs_offset + op_size;
      out_offset = work_total;
      lhs_tmp = (ContextEntry){ .name = "$lhs", .type = op_type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = dst->target_typed, .offset = lhs_offset, .size = op_size };
      rhs_tmp = (ContextEntry){ .name = "$rhs", .type = op_type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = dst->target_typed, .offset = rhs_offset, .size = op_size };

      expr_fixed_scratch_begin(ctx, "binarytmp", work_total + dst->size, &scratch);
      if (!compile_expr_to_slot(expr->children[0], ctx, &lhs_tmp) ||
          !compile_expr_to_slot(expr->children[1], ctx, &rhs_tmp)) {
         expr_fixed_scratch_end(ctx, &scratch);
         return false;
      }

      if (!strcmp(op, "&")) helper = "bit_andN";
      else if (!strcmp(op, "|")) helper = "bit_orN";
      else if (!strcmp(op, "^")) helper = "bit_xorN";

      if (helper) {
         emit_runtime_binary_fp_fp(helper, lhs_offset, lhs_offset, rhs_offset, op_size);
      }
      else if (!strcmp(op, "*")) {
         emit_runtime_binary_fp_fp(int_mul_helper_name(op_type), aux_offset, lhs_offset, rhs_offset, op_size);
         emit_copy_fp_to_fp(lhs_offset, int_mul_result_offset(op_type, aux_offset, op_size), op_size);
      }
      else if (!strcmp(op, "/") || !strcmp(op, "%")) {
         int rem_offset = aux_offset + op_size;
         emit_prepare_fp_ptr(0, lhs_offset);
         emit_prepare_fp_ptr(1, rhs_offset);
         emit_prepare_fp_ptr(2, aux_offset);
         emit_prepare_fp_ptr(3, rem_offset);
         emit(&es_code, "    lda #$%02x\n", op_size & 0xff);
         emit(&es_code, "    sta arg0\n");
         remember_runtime_import(int_div_helper_name(op_type));
         emit(&es_code, "    jsr _%s\n", int_div_helper_name(op_type));
         emit_copy_fp_to_fp(lhs_offset, !strcmp(op, "/") ? aux_offset : rem_offset, op_size);
      }

      emit_copy_fp_to_fp_convert(out_offset, dst->size, dst->type, lhs_offset, op_size, op_type);
      expr_fixed_scratch_end(ctx, &scratch);
      emit_fixed_scratch_result(ctx, &scratch, out_offset, dst->size, dst->type, dst);
      return true;
   }

   return false;
}
