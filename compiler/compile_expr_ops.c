//! @file compiler/compile_expr_ops.c
//! @brief Implements operator lowering helpers for the VCSC compiler.
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
#include "compile_function_registry.h"
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


typedef enum CommonLValuePairResult {
   COMMON_LVALUE_PAIR_NOT_APPLICABLE = 0,
   COMMON_LVALUE_PAIR_OK = 1,
   COMMON_LVALUE_PAIR_ERROR = -1
} CommonLValuePairResult;

//! @brief Compare expression structure while ignoring source positions and pass flags.
static bool expression_tree_equal(const ASTNode *lhs, const ASTNode *rhs) {
   if (lhs == rhs) {
      return true;
   }
   if (!lhs || !rhs || lhs->kind != rhs->kind || lhs->count != rhs->count ||
       strcmp(lhs->name ? lhs->name : "", rhs->name ? rhs->name : "")) {
      return false;
   }
   if (lhs->kind == AST_IDENTIFIER || lhs->kind == AST_TYPENAME ||
       lhs->kind == AST_INTEGER || lhs->kind == AST_STRING || lhs->kind == AST_ASM) {
      if (strcmp(lhs->strval ? lhs->strval : "", rhs->strval ? rhs->strval : "")) {
         return false;
      }
   }
   for (int i = 0; i < lhs->count; i++) {
      if (!expression_tree_equal(lhs->children[i], rhs->children[i])) {
         return false;
      }
   }
   return true;
}

//! @brief Return whether an exact lvalue load can be written to a binary work slot.
static bool common_lvalue_slot_compatible(const LValueRef *lv, const ContextEntry *slot) {
   if (!lv || !slot || lv->size != slot->size || lv->size <= 0) {
      return false;
   }
   return same_named_value_type(lv->type, lv->declarator, slot->type, slot->declarator);
}

//! @brief Copy one ptr0-relative object into an scratch-relative work slot.
static void emit_copy_ptr0_relative_to_slot(int ptr_offset, const ContextEntry *slot) {
   for (int i = 0; i < slot->size; i++) {
      emit(&es_code, "    ldy #%d\n", ptr_offset + i);
      emit(&es_code, "    lda (ptr0),y\n");
      emit(&es_code, "    ldy #%d\n", slot->offset + i);
      emit(&es_code, "    sta %s,y\n", compiler_scratch_active_symbol());
   }
}

//! @brief Load two fields sharing one runtime-indexed aggregate address with one ptr0 calculation.
//!
//! This is deliberately narrow: both operands must be direct fields of the same
//! dynamic array element, with structurally identical index expressions and no
//! pointer dereference, bitfield, conversion, or absolute-ref semantics.  Those
//! restrictions make reusing ptr0 side-effect-free and mechanically safe.
static CommonLValuePairResult compile_common_indexed_lvalue_pair(Context *ctx,
                                                                 ASTNode *lhs_expr,
                                                                 ASTNode *rhs_expr,
                                                                 ContextEntry *lhs_slot,
                                                                 ContextEntry *rhs_slot) {
   LValueRef lhs;
   LValueRef rhs;
   const ASTNode *lhs_prefix;
   const ASTNode *rhs_prefix;
   const LValueRef *anchor;
   int lhs_relative;
   int rhs_relative;

   lhs_expr = (ASTNode *) unwrap_expr_node(lhs_expr);
   rhs_expr = (ASTNode *) unwrap_expr_node(rhs_expr);
   if (!lhs_expr || !rhs_expr || strcmp(lhs_expr->name, "lvalue") ||
       strcmp(rhs_expr->name, "lvalue") ||
       !resolve_lvalue(ctx, lhs_expr, &lhs) || !resolve_lvalue(ctx, rhs_expr, &rhs)) {
      return COMMON_LVALUE_PAIR_NOT_APPLICABLE;
   }
   if (!lhs.needs_runtime_address || !rhs.needs_runtime_address ||
       lhs.indirect || rhs.indirect || lhs.is_ref || rhs.is_ref ||
       lhs.is_absolute_ref || rhs.is_absolute_ref || lhs.is_bitfield || rhs.is_bitfield ||
       !lhs.name || !rhs.name || strcmp(lhs.name, rhs.name) ||
       lhs.base_offset != rhs.base_offset || lhs.ptr_adjust != rhs.ptr_adjust ||
       lhs.deref_depth != rhs.deref_depth ||
       lhs.is_static != rhs.is_static || lhs.is_zeropage != rhs.is_zeropage ||
       lhs.is_global != rhs.is_global ||
       !same_named_value_type(lhs.base_type, lhs.base_declarator,
                              rhs.base_type, rhs.base_declarator) ||
       !common_lvalue_slot_compatible(&lhs, lhs_slot) ||
       !common_lvalue_slot_compatible(&rhs, rhs_slot)) {
      return COMMON_LVALUE_PAIR_NOT_APPLICABLE;
   }
   if (!lhs.suffixes || !rhs.suffixes || strcmp(lhs.suffixes->name, ".") ||
       strcmp(rhs.suffixes->name, ".") || lhs.suffixes->count < 2 ||
       rhs.suffixes->count < 2) {
      return COMMON_LVALUE_PAIR_NOT_APPLICABLE;
   }
   lhs_prefix = lhs.suffixes->children[0];
   rhs_prefix = rhs.suffixes->children[0];
   if (!lhs_prefix || !rhs_prefix || is_empty(lhs_prefix) || is_empty(rhs_prefix) ||
       !expression_tree_equal(lhs_prefix, rhs_prefix)) {
      return COMMON_LVALUE_PAIR_NOT_APPLICABLE;
   }

   if (lhs.offset <= rhs.offset) {
      anchor = &lhs;
      lhs_relative = 0;
      rhs_relative = rhs.offset - lhs.offset;
   }
   else {
      anchor = &rhs;
      rhs_relative = 0;
      lhs_relative = lhs.offset - rhs.offset;
   }
   if (lhs_relative < 0 || rhs_relative < 0 ||
       lhs_relative + lhs.size > 256 || rhs_relative + rhs.size > 256) {
      return COMMON_LVALUE_PAIR_NOT_APPLICABLE;
   }
   if (!emit_prepare_lvalue_ptr(ctx, anchor, LVALUE_ACCESS_READ)) {
      return COMMON_LVALUE_PAIR_ERROR;
   }
   emit_copy_ptr0_relative_to_slot(lhs_relative, lhs_slot);
   emit_copy_ptr0_relative_to_slot(rhs_relative, rhs_slot);
   return COMMON_LVALUE_PAIR_OK;
}

typedef CompilerScratchLease ExprFixedScratch;

//! @brief Prepare one fixed-address expression working area without activating it.
static void expr_fixed_scratch_prepare(Context *ctx, int reserved,
                                       ExprFixedScratch *scratch) {
   compiler_scratch_acquire(ctx, reserved, scratch);
}

//! @brief Activate a prepared fixed-address expression working area.
static void expr_fixed_scratch_activate(Context *ctx, ExprFixedScratch *scratch) {
   compiler_scratch_activate(ctx, scratch);
}

//! @brief Begin and activate one fixed-address expression working area.
static void expr_fixed_scratch_begin(Context *ctx, int reserved,
                                     ExprFixedScratch *scratch) {
   expr_fixed_scratch_prepare(ctx, reserved, scratch);
   expr_fixed_scratch_activate(ctx, scratch);
}

//! @brief Deactivate the scratch lease live for result copy-out.
static void expr_fixed_scratch_deactivate(Context *ctx, ExprFixedScratch *scratch) {
   compiler_scratch_deactivate(ctx, scratch);
}

//! @brief Release one inactive expression scratch lease.
static void expr_fixed_scratch_finish(ExprFixedScratch *scratch) {
   compiler_scratch_release(scratch);
}

//! @brief Deactivate and release an expression scratch lease on an error path.
static void expr_fixed_scratch_abort(Context *ctx, ExprFixedScratch *scratch) {
   compiler_scratch_deactivate(ctx, scratch);
   compiler_scratch_release(scratch);
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
      emit_copy_symbol_to_scratch_convert_offset(dst->offset, dst->size, dst->type,
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

//! @brief Emit copy scratch to scratch for compiler operator lowering diagnostics or output files.
void emit_copy_scratch_to_scratch(int dst_offset, int src_offset, int size) {
   bool dst_direct;
   bool src_direct;

   if (size <= 0 || dst_offset == src_offset) {
      return;
   }

   dst_direct = dst_offset >= 0 && dst_offset + size <= 256;
   src_direct = src_offset >= 0 && src_offset + size <= 256;

   if (!src_direct) {
      emit_prepare_scratch_ptr(0, src_offset);
   }
   if (!dst_direct) {
      emit_prepare_scratch_ptr(1, dst_offset);
   }

   for (int i = 0; i < size; i++) {
      emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + i) : i);
      emit(&es_code, "    lda %s,y\n", src_direct ? compiler_scratch_active_symbol() : "(ptr0)");
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + i) : i);
      emit(&es_code, "    sta %s,y\n", dst_direct ? compiler_scratch_active_symbol() : "(ptr1)");
   }
}

//! @brief Store one scratch byte or zero into another scratch byte.
static void emit_bcd_copy_or_zero_byte(int dst_offset, int src_offset, bool have_source) {
   if (have_source) {
      emit(&es_code, "    ldy #%d\n", src_offset);
      emit(&es_code, "    lda %s,y\n", compiler_scratch_active_symbol());
   }
   else {
      emit(&es_code, "    lda #0\n");
   }
   emit(&es_code, "    ldy #%d\n", dst_offset);
   emit(&es_code, "    sta %s,y\n", compiler_scratch_active_symbol());
}

//! @brief Shift packed BCD by a constant decimal power using only loads, shifts, and masks.
void emit_bcd_power_of_ten_scratch(const char *op, int dst_offset, int src_offset,
                                   int size, int decimal_digits) {
   int byte_digits;
   bool odd;
   char opcode;

   if (!op || size <= 0 || decimal_digits < 0) {
      return;
   }
   opcode = op[0];
   if (opcode != '*' && opcode != '/' && opcode != '%') {
      return;
   }

   byte_digits = decimal_digits / 2;
   odd = (decimal_digits & 1) != 0;

   if (opcode == '%') {
      for (int i = 0; i < size; i++) {
         if (i < byte_digits) {
            emit_bcd_copy_or_zero_byte(dst_offset + i, src_offset + i, true);
         }
         else if (odd && i == byte_digits && i < size) {
            emit(&es_code, "    ldy #%d\n", src_offset + i);
            emit(&es_code, "    lda %s,y\n", compiler_scratch_active_symbol());
            emit(&es_code, "    and #$0f\n");
            emit(&es_code, "    ldy #%d\n", dst_offset + i);
            emit(&es_code, "    sta %s,y\n", compiler_scratch_active_symbol());
         }
         else {
            emit_bcd_copy_or_zero_byte(dst_offset + i, 0, false);
         }
      }
      return;
   }

   if (!odd) {
      for (int i = 0; i < size; i++) {
         int source_index = opcode == '*' ? i - byte_digits : i + byte_digits;
         bool have_source = source_index >= 0 && source_index < size;
         emit_bcd_copy_or_zero_byte(dst_offset + i,
                                    src_offset + (have_source ? source_index : 0),
                                    have_source);
      }
      return;
   }

   for (int i = 0; i < size; i++) {
      int low_source;
      int high_source;
      bool have_low;
      bool have_high;

      if (opcode == '*') {
         low_source = i - byte_digits - 1;
         high_source = i - byte_digits;
      }
      else {
         low_source = i + byte_digits;
         high_source = i + byte_digits + 1;
      }
      have_low = low_source >= 0 && low_source < size;
      have_high = high_source >= 0 && high_source < size;

      if (have_low) {
         emit(&es_code, "    ldy #%d\n", src_offset + low_source);
         emit(&es_code, "    lda %s,y\n", compiler_scratch_active_symbol());
         emit(&es_code, "    lsr\n");
         emit(&es_code, "    lsr\n");
         emit(&es_code, "    lsr\n");
         emit(&es_code, "    lsr\n");
      }
      else {
         emit(&es_code, "    lda #0\n");
      }
      emit(&es_code, "    ldy #%d\n", dst_offset + i);
      emit(&es_code, "    sta %s,y\n", compiler_scratch_active_symbol());

      if (have_high) {
         emit(&es_code, "    ldy #%d\n", src_offset + high_source);
         emit(&es_code, "    lda %s,y\n", compiler_scratch_active_symbol());
         emit(&es_code, "    and #$0f\n");
         emit(&es_code, "    asl\n");
         emit(&es_code, "    asl\n");
         emit(&es_code, "    asl\n");
         emit(&es_code, "    asl\n");
         emit(&es_code, "    ldy #%d\n", dst_offset + i);
         emit(&es_code, "    ora %s,y\n", compiler_scratch_active_symbol());
         emit(&es_code, "    sta %s,y\n", compiler_scratch_active_symbol());
      }
   }
}

//! @brief Handle expr byte index logic for compiler operator lowering.
static int expr_byte_index(const ASTNode *type, int size, int i) {
   (void) type;
   (void) size;
   return i;
}

//! @brief Emit add immediate to scratch for compiler operator lowering diagnostics or output files.
void emit_add_immediate_to_scratch(const ASTNode *type, int offset, const unsigned char *bytes, int size) {
   bool direct = offset >= 0 && offset + size <= 256;
   bool bcd = type_is_bcd_integer(type);

   if (!direct) {
      emit_prepare_scratch_ptr(0, offset);
   }

   if (bcd) {
      emit(&es_code, "    sed\n");
   }
   emit(&es_code, "    clc\n");
   for (int i = 0; i < size; i++) {
      int j = expr_byte_index(type, size, i);
      emit(&es_code, "    ldy #%d\n", direct ? (offset + j) : j);
      emit(&es_code, "    lda %s,y\n", direct ? compiler_scratch_active_symbol() : "(ptr0)");
      emit(&es_code, "    adc #$%02x\n", bytes[j]);
      emit(&es_code, "    sta %s,y\n", direct ? compiler_scratch_active_symbol() : "(ptr0)");
   }
   if (bcd) {
      emit(&es_code, "    cld\n");
   }
}

//! @brief Extract emit sub immediate from scratch for compiler operator lowering.
static void emit_sub_immediate_from_scratch(const ASTNode *type, int offset, const unsigned char *bytes, int size) {
   bool direct = offset >= 0 && offset + size <= 256;
   bool bcd = type_is_bcd_integer(type);

   if (!direct) {
      emit_prepare_scratch_ptr(0, offset);
   }

   if (bcd) {
      emit(&es_code, "    sed\n");
   }
   emit(&es_code, "    sec\n");
   for (int i = 0; i < size; i++) {
      int j = expr_byte_index(type, size, i);
      emit(&es_code, "    ldy #%d\n", direct ? (offset + j) : j);
      emit(&es_code, "    lda %s,y\n", direct ? compiler_scratch_active_symbol() : "(ptr0)");
      emit(&es_code, "    sbc #$%02x\n", bytes[j]);
      emit(&es_code, "    sta %s,y\n", direct ? compiler_scratch_active_symbol() : "(ptr0)");
   }
   if (bcd) {
      emit(&es_code, "    cld\n");
   }
}

//! @brief Emit add scratch to scratch for compiler operator lowering diagnostics or output files.
void emit_add_scratch_to_scratch(const ASTNode *type, int dst_offset, int src_offset, int size) {
   bool dst_direct = dst_offset >= 0 && dst_offset + size <= 256;
   bool src_direct = src_offset >= 0 && src_offset + size <= 256;
   bool bcd = type_is_bcd_integer(type);


   if (!dst_direct) {
      emit_prepare_scratch_ptr(0, dst_offset);
   }
   if (!src_direct) {
      emit_prepare_scratch_ptr(1, src_offset);
   }

   if (bcd) {
      emit(&es_code, "    sed\n");
   }
   emit(&es_code, "    clc\n");
   for (int i = 0; i < size; i++) {
      int j = expr_byte_index(type, size, i);
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + j) : j);
      emit(&es_code, "    lda %s,y\n", dst_direct ? compiler_scratch_active_symbol() : "(ptr0)");
      emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + j) : j);
      emit(&es_code, "    adc %s,y\n", src_direct ? compiler_scratch_active_symbol() : "(ptr1)");
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + j) : j);
      emit(&es_code, "    sta %s,y\n", dst_direct ? compiler_scratch_active_symbol() : "(ptr0)");
   }
   if (bcd) {
      emit(&es_code, "    cld\n");
   }
}

//! @brief Extract emit sub scratch from scratch for compiler operator lowering.
void emit_sub_scratch_from_scratch(const ASTNode *type, int dst_offset, int src_offset, int size) {
   bool dst_direct = dst_offset >= 0 && dst_offset + size <= 256;
   bool src_direct = src_offset >= 0 && src_offset + size <= 256;
   bool bcd = type_is_bcd_integer(type);


   if (!dst_direct) {
      emit_prepare_scratch_ptr(0, dst_offset);
   }
   if (!src_direct) {
      emit_prepare_scratch_ptr(1, src_offset);
   }

   if (bcd) {
      emit(&es_code, "    sed\n");
   }
   emit(&es_code, "    sec\n");
   for (int i = 0; i < size; i++) {
      int j = expr_byte_index(type, size, i);
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + j) : j);
      emit(&es_code, "    lda %s,y\n", dst_direct ? compiler_scratch_active_symbol() : "(ptr0)");
      emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + j) : j);
      emit(&es_code, "    sbc %s,y\n", src_direct ? compiler_scratch_active_symbol() : "(ptr1)");
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + j) : j);
      emit(&es_code, "    sta %s,y\n", dst_direct ? compiler_scratch_active_symbol() : "(ptr0)");
   }
   if (bcd) {
      emit(&es_code, "    cld\n");
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
      emit_lvalue_semantic_use(ctx, &lv, "read");
      emit_lvalue_semantic_use(ctx, &lv, "write");
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
         expr_fixed_scratch_prepare(ctx, tmp_size, &scratch);
         if (!emit_copy_lvalue_to_symbol(ctx, scratch.symbol, 0, &lv, tmp_size)) {
            expr_fixed_scratch_finish(&scratch);
            return false;
         }
         if (!pre) {
            emit_fixed_scratch_result(ctx, &scratch, 0, tmp_size, lv.type, dst);
         }
         one = (unsigned char *) calloc(tmp_size ? tmp_size : 1, sizeof(unsigned char));
         if (!one) {
            expr_fixed_scratch_finish(&scratch);
            return false;
         }
         if (!make_incdec_delta_bytes(lv.type, lv.declarator, tmp_size, one)) {
            free(one);
            expr_fixed_scratch_finish(&scratch);
            return false;
         }
         expr_fixed_scratch_activate(ctx, &scratch);
         if (inc) {
            emit_add_immediate_to_scratch(lv.type, 0, one, tmp_size);
         }
         else {
            emit_sub_immediate_from_scratch(lv.type, 0, one, tmp_size);
         }
         free(one);
         expr_fixed_scratch_deactivate(ctx, &scratch);
         if (!emit_copy_symbol_to_lvalue(ctx, &lv, scratch.symbol, 0, tmp_size)) {
            expr_fixed_scratch_finish(&scratch);
            return false;
         }
         if (pre) {
            emit_fixed_scratch_result(ctx, &scratch, 0, tmp_size, lv.type, dst);
         }
         expr_fixed_scratch_finish(&scratch);
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
      emit_store_immediate_to_scratch(dst->offset, zeroes, dst->size);
      emit(&es_code, "    jmp %s\n", end_label);
      emit(&es_code, "%s:\n", false_label);
      emit_store_immediate_to_scratch(dst->offset, ones, dst->size);
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
         emit(&es_code, "    lda %s,y\n", compiler_scratch_active_symbol());
         emit(&es_code, "    eor #$ff\n");
         emit(&es_code, "    sta %s,y\n", compiler_scratch_active_symbol());
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
      (void) neg_type;
      emit_fixed_twos_complement_scratch(dst->offset, dst->size);
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
         emit_store_immediate_to_scratch(dst->offset, ones, dst->size);
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
         emit_store_immediate_to_scratch(dst->offset, ones, dst->size);
         emit(&es_code, "    jmp %s\n", end_label);
         emit(&es_code, "%s:\n", false_label);
         emit_store_immediate_to_scratch(dst->offset, zeroes, dst->size);
         emit(&es_code, "%s:\n", end_label);
         free(zeroes);
         free(ones);
         free((void *) false_label);
         free((void *) end_label);
         return true;
      }

      emit_store_immediate_to_scratch(dst->offset, ones, dst->size);
      emit(&es_code, "    jmp %s\n", end_label);
      emit(&es_code, "%s:\n", false_label);
      emit_store_immediate_to_scratch(dst->offset, zeroes, dst->size);
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
      emit_store_immediate_to_scratch(dst->offset, ones, dst->size);
      emit(&es_code, "    jmp %s\n", end_label);
      emit(&es_code, "%s:\n", false_label);
      emit_store_immediate_to_scratch(dst->offset, zeroes, dst->size);
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
         const ASTNode *pointer_type = required_typename_node("*");
         const ASTNode *difference_type = pointer_difference_type(expr);
         int ptr_size = declarator_storage_size(lhs_type, lhs_decl);
         int elem_size = pointer_scale > 0 ? pointer_scale : 1;
         bool divide_by_element_size = elem_size != 1;
         int work_total = ptr_size * 4 + (divide_by_element_size ? 1 : 0);
         int remainder_offset = ptr_size * 3;
         int sign_offset = ptr_size * 4;
         int out_offset = work_total;
         int result_offset = 0;
         ExprFixedScratch scratch;
         ContextEntry lhs_tmp = { .name = "$lhs", .type = lhs_type, .declarator = lhs_decl, .is_static = false, .is_zeropage = false, .is_global = false, .offset = 0, .size = ptr_size };
         ContextEntry rhs_tmp = { .name = "$rhs", .type = rhs_type, .declarator = rhs_decl, .is_static = false, .is_zeropage = false, .is_global = false, .offset = ptr_size, .size = ptr_size };
         const char *absolute_done = NULL;
         const char *quotient_done = NULL;

         expr_fixed_scratch_begin(ctx, work_total + dst->size, &scratch);
         if (!compile_expr_to_slot(expr->children[0], ctx, &lhs_tmp) ||
             !compile_expr_to_slot((ASTNode *) rhs, ctx, &rhs_tmp)) {
            expr_fixed_scratch_abort(ctx, &scratch);
            return false;
         }
         emit_sub_scratch_from_scratch(pointer_type, 0, ptr_size, ptr_size);

         if (divide_by_element_size) {
            unsigned char *factor_bytes;
            char factor_buf[64];
            int sign_index = ptr_size - 1;

            absolute_done = next_label("ptrdiff_absolute_done");
            quotient_done = next_label("ptrdiff_quotient_done");
            if (!absolute_done || !quotient_done) {
               free((void *) absolute_done);
               free((void *) quotient_done);
               expr_fixed_scratch_abort(ctx, &scratch);
               return false;
            }

            emit(&es_code, "    ldy #%d\n", sign_offset);
            emit(&es_code, "    lda #0\n");
            emit(&es_code, "    sta %s,y\n", compiler_scratch_active_symbol());
            emit(&es_code, "    ldy #%d\n", sign_index);
            emit(&es_code, "    lda %s,y\n", compiler_scratch_active_symbol());
            emit(&es_code, "    bpl %s\n", absolute_done);
            emit(&es_code, "    ldy #%d\n", sign_offset);
            emit(&es_code, "    lda #1\n");
            emit(&es_code, "    sta %s,y\n", compiler_scratch_active_symbol());
            emit_fixed_twos_complement_scratch(0, ptr_size);
            emit(&es_code, "%s:\n", absolute_done);

            factor_bytes = (unsigned char *) calloc(ptr_size ? ptr_size : 1, sizeof(unsigned char));
            if (!factor_bytes) {
               free((void *) absolute_done);
               free((void *) quotient_done);
               expr_fixed_scratch_abort(ctx, &scratch);
               return false;
            }
            snprintf(factor_buf, sizeof(factor_buf), "%d", elem_size);
            make_le_int(factor_buf, factor_bytes, ptr_size);
            emit_store_immediate_to_scratch(ptr_size, factor_bytes, ptr_size);
            free(factor_bytes);
            emit_prepare_scratch_ptr(0, 0);
            emit_prepare_scratch_ptr(1, ptr_size);
            emit_prepare_scratch_ptr(2, ptr_size * 2);
            (void) remainder_offset;
            remember_runtime_import(int_div_helper_name(difference_type));
            emit(&es_code, "    jsr _%s\n", int_div_helper_name(difference_type));

            emit(&es_code, "    ldy #%d\n", sign_offset);
            emit(&es_code, "    lda %s,y\n", compiler_scratch_active_symbol());
            emit(&es_code, "    beq %s\n", quotient_done);
            emit_fixed_twos_complement_scratch(ptr_size * 2, ptr_size);
            emit(&es_code, "%s:\n", quotient_done);
            result_offset = ptr_size * 2;
         }

         emit_copy_scratch_to_scratch_convert(out_offset, dst->size, dst->type, result_offset, ptr_size, difference_type);
         expr_fixed_scratch_deactivate(ctx, &scratch);
         emit_fixed_scratch_result(ctx, &scratch, out_offset, dst->size, dst->type, dst);
         expr_fixed_scratch_finish(&scratch);
         free((void *) absolute_done);
         free((void *) quotient_done);
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
         expr_fixed_scratch_begin(ctx, work_total + dst->size, &scratch);

         {
            CommonLValuePairResult pair_result = compile_common_indexed_lvalue_pair(
               ctx, expr->children[0], (ASTNode *) rhs, &lhs_tmp, &rhs_tmp);
            if (pair_result == COMMON_LVALUE_PAIR_ERROR ||
                (pair_result == COMMON_LVALUE_PAIR_NOT_APPLICABLE &&
                 (!compile_expr_to_slot(expr->children[0], ctx, &lhs_tmp) ||
                  !compile_expr_to_slot((ASTNode *) rhs, ctx, &rhs_tmp)))) {
               expr_fixed_scratch_abort(ctx, &scratch);
               return false;
            }
         }

         if (scaled_pointer_arith && pointer_scale != 1) {
            unsigned char *factor_bytes = (unsigned char *) calloc(work_size ? work_size : 1, sizeof(unsigned char));
            char scaled_buf[64];
            const ASTNode *factor_type = rhs_slot_type ? rhs_slot_type : work_type;
            if (!factor_bytes) {
               expr_fixed_scratch_abort(ctx, &scratch);
               return false;
            }
            snprintf(scaled_buf, sizeof(scaled_buf), "%d", pointer_scale);
            make_le_int(scaled_buf, factor_bytes, work_size);
            emit_store_immediate_to_scratch(factor_offset, factor_bytes, work_size);
            free(factor_bytes);
            emit_runtime_binary_scratch(int_mul_helper_name(factor_type ? factor_type : work_type), scaled_offset, rhs_offset, factor_offset, work_size);
            value_offset = int_mul_result_offset(factor_type ? factor_type : work_type, scaled_offset, work_size);
         }

         if (!strcmp(expr->name, "+")) {
            emit_add_scratch_to_scratch(work_type, lhs_offset, value_offset, work_size);
         }
         else {
            emit_sub_scratch_from_scratch(work_type, lhs_offset, value_offset, work_size);
         }

         emit_copy_scratch_to_scratch_convert(out_offset, dst->size, dst->type, lhs_offset, work_size, work_type);
         expr_fixed_scratch_deactivate(ctx, &scratch);
         emit_fixed_scratch_result(ctx, &scratch, out_offset, dst->size, dst->type, dst);
         expr_fixed_scratch_finish(&scratch);
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

      expr_fixed_scratch_begin(ctx, work_total + dst->size, &scratch);
      {
         CommonLValuePairResult pair_result = compile_common_indexed_lvalue_pair(
            ctx, expr->children[0], expr->children[1], &lhs_tmp, &rhs_tmp);
         if (pair_result == COMMON_LVALUE_PAIR_ERROR ||
             (pair_result == COMMON_LVALUE_PAIR_NOT_APPLICABLE &&
              (!compile_expr_to_slot(expr->children[0], ctx, &lhs_tmp) ||
               !compile_expr_to_slot(expr->children[1], ctx, &rhs_tmp)))) {
            expr_fixed_scratch_abort(ctx, &scratch);
            return false;
         }
      }

      helper = int_shift_helper_name(op_type, !strcmp(op, "<<"));
      emit_fixed_shift_scratch(helper, lhs_offset, aux_offset, rhs_offset, rhs_type, rhs_size, lhs_size);
      emit_copy_scratch_to_scratch_convert(out_offset, dst->size, dst->type, aux_offset, lhs_size, op_type);
      expr_fixed_scratch_deactivate(ctx, &scratch);
      emit_fixed_scratch_result(ctx, &scratch, out_offset, dst->size, dst->type, dst);
      expr_fixed_scratch_finish(&scratch);
      return true;
   }


   {
      const ASTNode *bcd_value_expr = NULL;
      int decimal_digits = 0;

      if (classify_bcd_power_of_ten_binary_expr(expr, ctx, &bcd_value_expr,
                                                &decimal_digits)) {
         const ASTNode *op_type = expr_value_type((ASTNode *) bcd_value_expr, ctx);
         int op_size = op_type ? type_size_from_node(op_type) : 0;
         int value_offset = 0;
         int result_offset;
         int out_offset;
         ContextEntry value_tmp;
         ExprFixedScratch scratch;

         if (!dst || dst->size <= 0) {
            return false;
         }
         if (op_size <= 0) {
            op_size = expr_value_size((ASTNode *) bcd_value_expr, ctx);
         }
         if (op_size <= 0) {
            op_size = dst->size;
         }
         if (op_size <= 0 || !op_type || !type_is_bcd_integer(op_type)) {
            return false;
         }

         result_offset = op_size;
         out_offset = op_size * 2;
         value_tmp = (ContextEntry){
            .name = "$bcd_value",
            .type = op_type,
            .declarator = NULL,
            .is_static = false,
            .is_zeropage = false,
            .is_global = false,
            .target_typed = true,
            .offset = value_offset,
            .size = op_size
         };

         expr_fixed_scratch_begin(ctx, op_size * 2 + dst->size, &scratch);
         if (!compile_expr_to_slot((ASTNode *) bcd_value_expr, ctx, &value_tmp)) {
            expr_fixed_scratch_abort(ctx, &scratch);
            return false;
         }
         emit_bcd_power_of_ten_scratch(expr->name, result_offset, value_offset,
                                       op_size, decimal_digits);
         emit_copy_scratch_to_scratch_convert(out_offset, dst->size, dst->type,
                                              result_offset, op_size, op_type);
         expr_fixed_scratch_deactivate(ctx, &scratch);
         emit_fixed_scratch_result(ctx, &scratch, out_offset, dst->size, dst->type, dst);
         expr_fixed_scratch_finish(&scratch);
         return true;
      }
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
      if (!strcmp(op, "*")) {
         work_total += op_size;
      }
      else if (!strcmp(op, "/") || !strcmp(op, "%")) {
         work_total += op_size * 2;
      }
      rhs_offset = op_size;
      aux_offset = rhs_offset + op_size;
      out_offset = work_total;
      lhs_tmp = (ContextEntry){ .name = "$lhs", .type = op_type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = dst->target_typed, .offset = lhs_offset, .size = op_size };
      rhs_tmp = (ContextEntry){ .name = "$rhs", .type = op_type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = dst->target_typed, .offset = rhs_offset, .size = op_size };

      expr_fixed_scratch_begin(ctx, work_total + dst->size, &scratch);
      {
         CommonLValuePairResult pair_result = compile_common_indexed_lvalue_pair(
            ctx, expr->children[0], expr->children[1], &lhs_tmp, &rhs_tmp);
         if (pair_result == COMMON_LVALUE_PAIR_ERROR ||
             (pair_result == COMMON_LVALUE_PAIR_NOT_APPLICABLE &&
              (!compile_expr_to_slot(expr->children[0], ctx, &lhs_tmp) ||
               !compile_expr_to_slot(expr->children[1], ctx, &rhs_tmp)))) {
            expr_fixed_scratch_abort(ctx, &scratch);
            return false;
         }
      }

      if (!strcmp(op, "&")) helper = "and";
      else if (!strcmp(op, "|")) helper = "ora";
      else if (!strcmp(op, "^")) helper = "eor";

      if (helper) {
         emit_fixed_bitwise_scratch(helper, lhs_offset, lhs_offset, rhs_offset, op_size);
      }
      else if (!strcmp(op, "*")) {
         emit_runtime_binary_scratch(int_mul_helper_name(op_type), aux_offset, lhs_offset, rhs_offset, op_size);
         emit_copy_scratch_to_scratch(lhs_offset, int_mul_result_offset(op_type, aux_offset, op_size), op_size);
      }
      else if (!strcmp(op, "/") || !strcmp(op, "%")) {
         int rem_offset = aux_offset + op_size;
         diagnose_runtime_power_of_two_divisor(expr, expr->children[1], op);
         emit_prepare_scratch_ptr(0, lhs_offset);
         emit_prepare_scratch_ptr(1, rhs_offset);
         emit_prepare_scratch_ptr(2, aux_offset);
         (void) rem_offset;
         remember_runtime_import(int_div_helper_name(op_type));
         emit(&es_code, "    jsr _%s\n", int_div_helper_name(op_type));
         emit_copy_scratch_to_scratch(lhs_offset, !strcmp(op, "/") ? aux_offset : rem_offset, op_size);
      }

      emit_copy_scratch_to_scratch_convert(out_offset, dst->size, dst->type, lhs_offset, op_size, op_type);
      expr_fixed_scratch_deactivate(ctx, &scratch);
      emit_fixed_scratch_result(ctx, &scratch, out_offset, dst->size, dst->type, dst);
      expr_fixed_scratch_finish(&scratch);
      return true;
   }

   return false;
}
