//! @file compiler/compile_lvalue.c
//! @brief Implements lvalue resolution and storage access for the VCSC compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

#include "ast.h"
#include "compile.h"
#include "compile_init.h"
#include "compile_internal.h"
#include "compile_support.h"
#include "compile_lvalue.h"
#include "compile_function_registry.h"
#include "compile_type.h"
#include "abi_meta.h"
#include "emit.h"
#include "integer.h"
#include "messages.h"
#include "typename.h"
#include "xray.h"
#include "lextern.h"

typedef CompilerScratchLease LValueFixedScratch;

//! @brief Begin and activate fixed-address lvalue scratch.
static void lvalue_fixed_scratch_begin(Context *ctx, int reserved,
                                       LValueFixedScratch *scratch) {
   compiler_scratch_acquire(ctx, reserved, scratch);
   compiler_scratch_activate(ctx, scratch);
}

//! @brief Deactivate and release fixed-address lvalue scratch.
static void lvalue_fixed_scratch_end(Context *ctx, LValueFixedScratch *scratch) {
   compiler_scratch_deactivate(ctx, scratch);
   compiler_scratch_release(scratch);
}

//! @brief Handle absolute ref supports direct access logic for compiler lvalue lowering.
static bool absolute_ref_supports_direct_access(const LValueRef *lv) {
   return lv && lv->is_absolute_ref && !lv->is_bitfield && !lv->indirect && !lv->needs_runtime_address;
}

//! @brief Load one directly addressable byte lvalue into A without scratch or pointer setup.
bool emit_load_direct_byte_lvalue_to_a(Context *ctx, const LValueRef *src) {
   ContextEntry entry;
   char symbol[256];
   char expr_buf[256];
   const char *formatted;

   if (!src || src->size != 1 || src->is_bitfield || src->indirect ||
       src->needs_runtime_address) {
      return false;
   }

   if (src->is_absolute_ref) {
      if (!src->read_expr || !*src->read_expr) {
         return false;
      }
      emit_load_a_from_expr_address(src->read_expr, src->offset);
      return true;
   }

   if (!(src->is_static || src->is_zeropage || src->is_global)) {
      return false;
   }

   entry = (ContextEntry){ .name = src->name, .type = src->type,
      .declarator = src->declarator, .is_static = src->is_static,
      .is_zeropage = src->is_zeropage, .is_global = src->is_global,
      .offset = src->offset, .size = src->size };
   if (!entry_symbol_name(ctx, &entry, symbol, sizeof(symbol))) {
      return false;
   }
   formatted = assembler_address_expr(symbol, expr_buf, sizeof(expr_buf));
   if (src->offset == 0) {
      emit(&es_code, src->is_zeropage ? "    lda.z %s\n" : "    lda.a %s\n", formatted);
   }
   else {
      emit(&es_code, src->is_zeropage ? "    lda.z %s + %d\n" : "    lda.a %s + %d\n",
           formatted, src->offset);
   }
   return true;
}

//! @brief Store A into one directly addressable byte lvalue without scratch or pointer setup.
bool emit_store_a_to_direct_byte_lvalue(Context *ctx, const LValueRef *dst) {
   ContextEntry entry;
   char symbol[256];
   char expr_buf[256];
   const char *formatted;

   if (!dst || dst->size != 1 || dst->is_bitfield || dst->indirect ||
       dst->needs_runtime_address) {
      return false;
   }

   if (dst->is_absolute_ref) {
      if (!dst->write_expr || !*dst->write_expr) {
         return false;
      }
      emit_store_a_to_expr_address(dst->write_expr, dst->offset);
      return true;
   }

   if (!(dst->is_static || dst->is_zeropage || dst->is_global)) {
      return false;
   }

   entry = (ContextEntry){ .name = dst->name, .type = dst->type,
      .declarator = dst->declarator, .is_static = dst->is_static,
      .is_zeropage = dst->is_zeropage, .is_global = dst->is_global,
      .offset = dst->offset, .size = dst->size };
   if (!entry_symbol_name(ctx, &entry, symbol, sizeof(symbol))) {
      return false;
   }
   formatted = assembler_address_expr(symbol, expr_buf, sizeof(expr_buf));
   if (dst->offset == 0) {
      emit(&es_code, dst->is_zeropage ? "    sta.z %s\n" : "    sta.a %s\n", formatted);
   }
   else {
      emit(&es_code, dst->is_zeropage ? "    sta.z %s + %d\n" : "    sta.a %s + %d\n",
           formatted, dst->offset);
   }
   return true;
}

//! @brief Copy an already converted fixed-symbol value to an lvalue without readback.
bool emit_copy_preserved_symbol_to_lvalue(Context *ctx, const LValueRef *dst,
                                          const char *symbol, int size) {
   ContextEntry entry;
   char dst_symbol[256];

   if (!dst || !symbol || size <= 0) {
      return false;
   }

   if (!dst->is_bitfield && dst->is_absolute_ref && !dst->indirect &&
       !dst->needs_runtime_address) {
      if (!dst->write_expr || !*dst->write_expr) {
         return false;
      }
      for (int i = 0; i < size; i++) {
         emit(&es_code, "    ldy #%d\n", i);
         emit(&es_code, "    lda %s,y\n", symbol);
         emit_store_a_to_expr_address(dst->write_expr, dst->offset + i);
      }
      return true;
   }

   if (!dst->is_bitfield && !dst->indirect && !dst->needs_runtime_address &&
       (dst->is_static || dst->is_zeropage || dst->is_global)) {
      entry = (ContextEntry){ .name = dst->name, .type = dst->type,
         .declarator = dst->declarator, .is_static = dst->is_static,
         .is_zeropage = dst->is_zeropage, .is_global = dst->is_global,
         .offset = dst->offset, .size = dst->size };
      if (!entry_symbol_name(ctx, &entry, dst_symbol, sizeof(dst_symbol))) {
         return false;
      }
      emit_copy_symbol_to_symbol_convert_offset(dst_symbol, dst->offset, size,
                                                dst->type, symbol, 0, size,
                                                dst->type);
      return true;
   }

   if (!dst->is_bitfield && !dst->indirect && !dst->needs_runtime_address &&
       !dst->is_static && !dst->is_zeropage && !dst->is_global) {
      emit_copy_symbol_to_scratch_convert_offset(dst->offset, size, dst->type,
                                                 symbol, 0, size, dst->type);
      return true;
   }

   return emit_copy_symbol_to_lvalue(ctx, dst, symbol, 0, size);
}

//! @brief Find aggregate member info in compiler lvalue lowering tables without transferring ownership.
bool find_aggregate_member_info(const ASTNode *type, const char *member, AggregateMemberInfo *out) {
   const ASTNode *agg;
   int bit_cursor = 0;
   bool is_union = false;

   if (!type || !type_name_from_node(type) || !member) {
      return false;
   }
   agg = get_typename_node(type_name_from_node(type));
   if (!agg || agg->count < 2) {
      return false;
   }
   is_union = !strcmp(agg->name, "union_decl_stmt");
   for (int i = 1; i < agg->count; i++) {
      const ASTNode *field = agg->children[i];
      const ASTNode *ftype;
      const ASTNode *fdecl;
      const char *fname;
      int fsize;
      int bit_width;
      int byte_offset;
      int bit_offset;
      int storage_size;
      if (!field || field->count < 3) {
         continue;
      }
      ftype = field->children[1];
      fdecl = field->children[2];
      fname = declarator_name(fdecl);
      if (!fname) {
         continue;
      }
      fsize = declarator_storage_size(ftype, fdecl);
      bit_width = declarator_bitfield_width(fdecl);
      if (is_union) {
         byte_offset = 0;
         bit_offset = 0;
      }
      else if (bit_width > 0) {
         byte_offset = bit_cursor / 8;
         bit_offset = bit_cursor % 8;
      }
      else {
         if (bit_cursor % 8) {
            bit_cursor = ((bit_cursor + 7) / 8) * 8;
         }
         byte_offset = bit_cursor / 8;
         bit_offset = 0;
      }
      storage_size = bit_width > 0 ? ((bit_offset + bit_width + 7) / 8) : fsize;
      if (!strcmp(fname, member)) {
         if (out) {
            out->type = ftype;
            out->declarator = fdecl;
            out->byte_offset = byte_offset;
            out->bit_offset = bit_offset;
            out->bit_width = bit_width;
            out->storage_size = storage_size;
            out->is_bitfield = bit_width > 0;
         }
         return true;
      }
      if (!is_union) {
         if (bit_width > 0) {
            bit_cursor += bit_width;
         }
         else {
            bit_cursor += fsize * 8;
         }
      }
   }
   return false;
}

//! @brief Find aggregate member in compiler lvalue lowering tables without transferring ownership.
bool find_aggregate_member(const ASTNode *type, const char *member, const ASTNode **member_type, const ASTNode **member_declarator, int *member_offset) {
   AggregateMemberInfo info = {0};
   if (!find_aggregate_member_info(type, member, &info)) {
      return false;
   }
   if (member_type) *member_type = info.type;
   if (member_declarator) *member_declarator = info.declarator;
   if (member_offset) *member_offset = info.byte_offset;
   return true;
}

//! @brief Extract emit load ptr from active scratch for compiler lvalue lowering.
void emit_load_ptr_from_scratch(int ptrno, int src_offset) {
   bool direct = src_offset >= 0 && src_offset + 2 <= 256;
   if (!direct) {
      emit_prepare_scratch_ptr(ptrno == 0 ? 1 : 0, src_offset);
   }
   for (int i = 0; i < 2; i++) {
      emit(&es_code, "    ldy #%d\n", direct ? (src_offset + i) : i);
      emit(&es_code, "    lda %s,y\n", direct ? compiler_scratch_active_symbol() : (ptrno == 0 ? "(ptr1)" : "(ptr0)"));
      emit(&es_code, "    sta ptr%d%s\n", ptrno, i == 0 ? "" : "+1");
   }
}

//! @brief Emit add immediate to ptr for compiler lvalue lowering diagnostics or output files.
static void emit_add_immediate_to_ptr(int ptrno, int adjust) {
   if (adjust == 0) {
      return;
   }
   emit(&es_code, "    clc\n");
   emit(&es_code, "    lda ptr%d\n", ptrno);
   emit(&es_code, "    adc #$%02x\n", adjust & 0xff);
   emit(&es_code, "    sta ptr%d\n", ptrno);
   emit(&es_code, "    lda ptr%d+1\n", ptrno);
   emit(&es_code, "    adc #$%02x\n", (adjust >> 8) & 0xff);
   emit(&es_code, "    sta ptr%d+1\n", ptrno);
}

//! @brief Emit store ptr to scratch for compiler lvalue lowering diagnostics or output files.
void emit_store_ptr_to_scratch(int dst_offset, int ptrno, int size) {
   bool direct = dst_offset >= 0 && dst_offset + size <= 256;

   if (size <= 0) {
      return;
   }

   if (!direct) {
      emit_prepare_scratch_ptr(ptrno == 0 ? 1 : 0, dst_offset);
   }

   for (int i = 0; i < size; i++) {
      if (i < get_size("*")) {
         emit(&es_code, "    lda ptr%d%s\n", ptrno, i == 0 ? "" : "+1");
      }
      else {
         emit(&es_code, "    lda #0\n");
      }
      emit(&es_code, "    ldy #%d\n", direct ? (dst_offset + i) : i);
      emit(&es_code, "    sta %s,y\n", direct ? compiler_scratch_active_symbol() : (ptrno == 0 ? "(ptr1)" : "(ptr0)"));
   }
}

//! @brief Compute ref argument lvalue and update compiler lvalue lowering state once prerequisite pass data is available.
bool resolve_ref_argument_lvalue(Context *ctx, ASTNode *expr, LValueRef *out) {
   ContextEntry *entry;
   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr) {
      return false;
   }
   /* Valued ++/-- expressions name an underlying object, but the expression
      itself is not an lvalue.  Treating it as one lets direct-copy/index/ref
      shortcuts silently erase the required side effect. */
   if (classify_incdec_lvalue_expr(expr, NULL, NULL)) {
      return false;
   }
   if (!strcmp(expr->name, "lvalue") && expr->count > 0) {
      if (!out) {
         LValueRef tmp;
         return resolve_lvalue(ctx, expr, &tmp);
      }
      return resolve_lvalue(ctx, expr, out);
   }
   if (expr->kind != AST_IDENTIFIER) {
      return false;
   }
   entry = ctx_lookup(ctx, expr->strval);
   if (!entry) {
      const ASTNode *g = global_decl_lookup(expr->strval);
      if (g && g->count >= 3) {
         static ContextEntry gtmp;
         if (init_context_entry_from_global_decl(&gtmp, expr->strval, g)) {
            entry = &gtmp;
         }
      }
   }
   if (!entry) {
      return false;
   }
   if (out) {
      memset(out, 0, sizeof(*out));
      out->name = entry->name ? entry->name : expr->strval;
      out->use_site = expr;
      out->type = entry->type;
      out->declarator = entry->declarator;
      out->base_type = entry->type;
      out->base_declarator = entry->declarator;
      out->suffixes = NULL;
      out->is_static = entry->is_static;
      out->is_zeropage = entry->is_zeropage;
      out->is_global = entry->is_global;
      out->is_ref = entry->is_ref;
      out->is_absolute_ref = entry->is_absolute_ref;
      out->read_expr = entry->read_expr;
      out->write_expr = entry->write_expr;
      out->base_offset = entry->offset;
      out->offset = entry->offset;
      out->size = entry->is_ref
         ? declarator_storage_size(entry->type, entry->declarator)
         : entry->size;
      if (entry->is_ref) {
         out->indirect = true;
      }
   }
   return true;
}

//! @brief Lower ref argument to slot from AST/semantic state into generated assembly or linker-visible metadata.
bool compile_ref_argument_to_slot(ASTNode *expr, Context *ctx, int dst_offset, int dst_size) {
   LValueRef lv;
   if (!resolve_ref_argument_lvalue(ctx, expr, &lv)) {
      error_user("[%s:%d.%d] ref argument must be an lvalue", expr->file, expr->line, expr->column);
   }
   if (!emit_prepare_lvalue_ptr(ctx, &lv, LVALUE_ACCESS_REF)) {
      return false;
   }
   emit_store_ptr_to_scratch(dst_offset, 0, dst_size);
   return true;
}

//! @brief Emit load count lowbyte scratch to arg1 for compiler lvalue lowering diagnostics or output files.
static void emit_load_count_lowbyte_scratch_to_arg1(int src_offset, const ASTNode *src_type, int src_size) {
   bool direct;
   int mem_index = 0;

   (void) src_type;
   if (src_size <= 0) {
      src_size = 1;
   }
   direct = src_offset >= 0 && src_offset + src_size <= 256;
   if (!direct) {
      emit_prepare_scratch_ptr(0, src_offset);
      emit(&es_code, "    ldy #%d\n", mem_index);
      emit(&es_code, "    lda (ptr0),y\n");
   }
   else {
      emit(&es_code, "    ldy #%d\n", src_offset + mem_index);
      emit(&es_code, "    lda %s,y\n", compiler_scratch_active_symbol());
   }
   emit(&es_code, "    sta arg1\n");
}

//! @brief Emit runtime binary scratch scratch for compiler lvalue lowering diagnostics or output files.
void emit_runtime_binary_scratch(const char *helper, int dst_offset, int lhs_offset, int rhs_offset, int size) {
   emit_prepare_scratch_ptr(0, lhs_offset);
   emit_prepare_scratch_ptr(1, rhs_offset);
   emit_prepare_scratch_ptr(2, dst_offset);
   (void) size;
   remember_runtime_import(helper);
   emit(&es_code, "    jsr _%s\n", helper);
}

//! @brief Emit a fixed-width bytewise operation directly on compiler scratch.
void emit_fixed_bitwise_scratch(const char *mnemonic, int dst_offset, int lhs_offset, int rhs_offset, int size) {
   const char *symbol = compiler_scratch_active_symbol();

   if (!mnemonic || size < 1 || size > 4) {
      error_unreachable("invalid fixed-width bitwise operation");
   }
   for (int i = 0; i < size; i++) {
      emit(&es_code, "    ldy #%d\n", lhs_offset + i);
      emit(&es_code, "    lda %s,y\n", symbol);
      emit(&es_code, "    ldy #%d\n", rhs_offset + i);
      emit(&es_code, "    %s %s,y\n", mnemonic, symbol);
      emit(&es_code, "    ldy #%d\n", dst_offset + i);
      emit(&es_code, "    sta %s,y\n", symbol);
   }
}

//! @brief Emit fixed-width two's-complement negation directly on compiler scratch.
void emit_fixed_twos_complement_scratch(int offset, int size) {
   const char *symbol = compiler_scratch_active_symbol();

   if (size < 1 || size > 4) {
      error_unreachable("unsupported integer width %d reached negation lowering", size);
   }
   emit(&es_code, "    sec\n");
   for (int i = 0; i < size; i++) {
      emit(&es_code, "    ldy #%d\n", offset + i);
      emit(&es_code, "    lda %s,y\n", symbol);
      emit(&es_code, "    eor #$ff\n");
      emit(&es_code, "    adc #$00\n");
      emit(&es_code, "    sta %s,y\n", symbol);
   }
}

//! @brief Compare two fixed-width little-endian scratch values and leave A as 0 or 1.
void emit_fixed_compare_scratch(const ASTNode *type, const char *op, int lhs_offset, int rhs_offset, int size) {
   const char *symbol = compiler_scratch_active_symbol();
   const char *true_label = next_label("cmp_true");
   const char *false_label = next_label("cmp_false");
   const char *done_label = next_label("cmp_done");
   const char *same_sign_label = NULL;
   bool is_equal;
   bool is_le;
   bool is_signed;

   if (!op || size < 1 || size > 4 || !true_label || !false_label || !done_label) {
      free((void *) true_label);
      free((void *) false_label);
      free((void *) done_label);
      error_unreachable("invalid fixed-width comparison lowering");
   }
   is_equal = !strcmp(op, "==");
   is_le = !strcmp(op, "<=");
   is_signed = type_is_signed_integer(type);
   if (!is_equal && strcmp(op, "<") && strcmp(op, "<=")) {
      free((void *) true_label);
      free((void *) false_label);
      free((void *) done_label);
      error_unreachable("unsupported fixed-width comparison '%s'", op);
   }

   if (is_equal) {
      for (int i = 0; i < size; i++) {
         emit(&es_code, "    ldy #%d\n", lhs_offset + i);
         emit(&es_code, "    lda %s,y\n", symbol);
         emit(&es_code, "    ldy #%d\n", rhs_offset + i);
         emit(&es_code, "    cmp %s,y\n", symbol);
         emit(&es_code, "    bne %s\n", false_label);
      }
      emit(&es_code, "    jmp %s\n", true_label);
   }
   else {
      if (is_signed) {
         same_sign_label = next_label("cmp_same_sign");
         if (!same_sign_label) {
            free((void *) true_label);
            free((void *) false_label);
            free((void *) done_label);
            error_unreachable("comparison label generation failed");
         }
         emit(&es_code, "    ldy #%d\n", lhs_offset + size - 1);
         emit(&es_code, "    lda %s,y\n", symbol);
         emit(&es_code, "    ldy #%d\n", rhs_offset + size - 1);
         emit(&es_code, "    eor %s,y\n", symbol);
         emit(&es_code, "    bpl %s\n", same_sign_label);
         emit(&es_code, "    ldy #%d\n", lhs_offset + size - 1);
         emit(&es_code, "    lda %s,y\n", symbol);
         emit(&es_code, "    bmi %s\n", true_label);
         emit(&es_code, "    jmp %s\n", false_label);
         emit(&es_code, "%s:\n", same_sign_label);
      }
      for (int i = size - 1; i >= 0; i--) {
         emit(&es_code, "    ldy #%d\n", lhs_offset + i);
         emit(&es_code, "    lda %s,y\n", symbol);
         emit(&es_code, "    ldy #%d\n", rhs_offset + i);
         emit(&es_code, "    cmp %s,y\n", symbol);
         emit(&es_code, "    bcc %s\n", true_label);
         emit(&es_code, "    bne %s\n", false_label);
      }
      emit(&es_code, "    jmp %s\n", is_le ? true_label : false_label);
   }

   emit(&es_code, "%s:\n", true_label);
   emit(&es_code, "    lda #1\n");
   emit(&es_code, "    bne %s\n", done_label);
   emit(&es_code, "%s:\n", false_label);
   emit(&es_code, "    lda #0\n");
   emit(&es_code, "%s:\n", done_label);

   free((void *) same_sign_label);
   free((void *) true_label);
   free((void *) false_label);
   free((void *) done_label);
}

//! @brief Return int mul helper name data used by compiler lvalue lowering.
const char *int_mul_helper_name(const ASTNode *type) {
   int size = type_size_from_node(type);

   switch (size) {
      case 1: return "mul8";
      case 2: return "mul16";
      case 3: return "mul24";
      case 4: return "mul32";
      default:
         error_unreachable("unsupported integer width %d reached multiply lowering", size);
   }
   return NULL;
}

//! @brief Handle int mul result offset logic for compiler lvalue lowering.
int int_mul_result_offset(const ASTNode *type, int product_offset, int size) {
   (void) type;
   (void) size;
   return product_offset;
}

//! @brief Return int div helper name data used by compiler lvalue lowering.
const char *int_div_helper_name(const ASTNode *type) {
   int size = type_size_from_node(type);

   switch (size) {
      case 1: return "div8";
      case 2: return "div16";
      case 3: return "div24";
      case 4: return "div32";
      default:
         error_unreachable("unsupported integer width %d reached division lowering", size);
   }
   return NULL;
}

//! @brief Return the fixed-width shift helper selected for a scalar type.
const char *int_shift_helper_name(const ASTNode *type, bool left_shift) {
   int size = type_size_from_node(type);
   bool is_signed = type_is_signed_integer(type);

   switch (size) {
      case 1: return left_shift ? "shl8"  : (is_signed ? "sar8"  : "shr8");
      case 2: return left_shift ? "shl16" : (is_signed ? "sar16" : "shr16");
      case 3: return left_shift ? "shl24" : (is_signed ? "sar24" : "shr24");
      case 4: return left_shift ? "shl32" : (is_signed ? "sar32" : "shr32");
      default:
         error_unreachable("unsupported integer width %d reached shift lowering", size);
   }
   return NULL;
}

//! @brief Emit a fixed-width runtime shift on compiler scratch.
void emit_fixed_shift_scratch(const char *helper, int value_offset, int scratch_offset, int count_offset,
                                  const ASTNode *count_type, int count_size, int size) {
   emit_prepare_scratch_ptr(0, value_offset);
   emit_prepare_scratch_ptr(1, scratch_offset);
   emit_load_count_lowbyte_scratch_to_arg1(count_offset, count_type, count_size);
   (void) size;
   remember_runtime_import(helper);
   emit(&es_code, "    jsr _%s\n", helper);
}

//! @brief Load a simple unsigned byte lvalue into A without disturbing ptr0.
//!
//! This is the common VCS array-index case.  It deliberately accepts only a
//! directly addressable one-byte unsigned object; complex expressions keep the
//! fully general fixed-scratch path below.
static bool emit_load_simple_u8_index_to_a(Context *ctx, ASTNode *idx) {
   LValueRef lv;
   ContextEntry entry;
   char symbol[256];

   idx = (ASTNode *) unwrap_expr_node(idx);
   if (!idx || !resolve_ref_argument_lvalue(ctx, idx, &lv) || lv.size != 1 ||
       type_is_signed_integer(lv.type) || lv.is_bitfield || lv.indirect ||
       lv.needs_runtime_address) {
      return false;
   }

   if (lv.is_absolute_ref) {
      if (!lv.read_expr || !*lv.read_expr) {
         return false;
      }
      emit_load_a_from_expr_address(lv.read_expr, lv.offset);
      return true;
   }

   if (lv.is_static || lv.is_zeropage || lv.is_global) {
      entry = (ContextEntry){ .name = lv.name, .type = lv.type,
         .declarator = lv.declarator, .is_static = lv.is_static,
         .is_zeropage = lv.is_zeropage, .is_global = lv.is_global,
         .offset = lv.offset, .size = lv.size };
      if (!entry_symbol_name(ctx, &entry, symbol, sizeof(symbol))) {
         return false;
      }
      {
         char expr_buf[256];
         const char *asm_expr = assembler_address_expr(symbol, expr_buf, sizeof(expr_buf));
         if (lv.offset == 0)
            emit(&es_code, lv.is_zeropage ? "    lda.z %s\n" : "    lda.a %s\n", asm_expr);
         else
            emit(&es_code, lv.is_zeropage ? "    lda.z %s + %d\n" : "    lda.a %s + %d\n", asm_expr, lv.offset);
      }
      return true;
   }

   if (lv.offset < 0 || lv.offset > 255) {
      return false;
   }
   emit(&es_code, "    ldy #%d\n", lv.offset);
   emit(&es_code, "    lda %s,y\n", compiler_scratch_active_symbol());
   return true;
}

//! @brief Return log2(value) for a positive power of two, otherwise -1.
static int exact_power_of_two_shift(int value) {
   int shift = 0;

   if (value <= 0 || (value & (value - 1)) != 0) {
      return -1;
   }
   while (value > 1) {
      value >>= 1;
      shift++;
   }
   return shift;
}

//! @brief Add an unsigned byte index times a power-of-two element size to ptr0.
//!
//! arg0:arg1 is compiler-owned zero-page scratch.  Using it here avoids a
//! per-expression BSS object and the generic runtime multiplication helper.
static bool emit_add_simple_u8_index_to_ptr0(Context *ctx, ASTNode *idx, int elem_size) {
   int shift = exact_power_of_two_shift(elem_size);

   if (shift < 0 || shift > 8 || !emit_load_simple_u8_index_to_a(ctx, idx)) {
      return false;
   }

   emit(&es_code, "    sta arg0\n");
   emit(&es_code, "    lda #0\n");
   emit(&es_code, "    sta arg1\n");
   for (int i = 0; i < shift; i++) {
      emit(&es_code, "    asl arg0\n");
      emit(&es_code, "    rol arg1\n");
   }
   emit(&es_code, "    clc\n");
   emit(&es_code, "    lda ptr0\n");
   emit(&es_code, "    adc arg0\n");
   emit(&es_code, "    sta ptr0\n");
   emit(&es_code, "    lda ptr0+1\n");
   emit(&es_code, "    adc arg1\n");
   emit(&es_code, "    sta ptr0+1\n");
   return true;
}

//! @brief Emit prepare lvalue ptr suffixes for compiler lvalue lowering diagnostics or output files.
static bool emit_prepare_lvalue_ptr_suffixes(Context *ctx, const ASTNode *suffixes, const ASTNode **type_io, const ASTNode **decl_io) {
   if (!suffixes || is_empty(suffixes)) {
      return true;
   }
   if (suffixes->count > 0 && !emit_prepare_lvalue_ptr_suffixes(ctx, suffixes->children[0], type_io, decl_io)) {
      return false;
   }
   if (!strcmp(suffixes->name, "[")) {
      const ASTNode *idx = unwrap_expr_node(suffixes->children[1]);
      int elem_size = declarator_first_element_size(*type_io, *decl_io);
      const ASTNode *next_decl;

      if (!idx || elem_size <= 0) {
         return false;
      }
      if (declarator_pointer_depth(*decl_io) > 0) {
         emit_deref_ptr(0);
      }
      else if (declarator_array_count(*decl_io) <= 0) {
         return false;
      }

      if (idx->kind == AST_INTEGER) {
         emit_add_immediate_to_ptr(0, atoi(idx->strval) * elem_size);
      }
      else if (emit_add_simple_u8_index_to_ptr0(ctx, (ASTNode *) idx, elem_size)) {
         /* Fully lowered without fixed BSS scratch. */
      }
      else {
         const ASTNode *idx_type = expr_value_type((ASTNode *) idx, ctx);
         int ptr_size = get_size("*");
         int idx_offset = 0;
         int factor_offset = idx_offset + ptr_size;
         int scaled_offset = factor_offset + ptr_size;
         int save_ptr0_offset = elem_size != 1 ? (scaled_offset + ptr_size) : (idx_offset + ptr_size);
         int total = (save_ptr0_offset - idx_offset) + ptr_size;
         ContextEntry idx_tmp = { .name = "$idx", .type = idx_type ? idx_type : required_typename_node("int16_t"), .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .offset = idx_offset, .size = ptr_size };
         LValueFixedScratch scratch;

         lvalue_fixed_scratch_begin(ctx, total, &scratch);
         emit_store_ptr_to_scratch(save_ptr0_offset, 0, ptr_size);
         if (!compile_expr_to_slot((ASTNode *) idx, ctx, &idx_tmp)) {
            lvalue_fixed_scratch_end(ctx, &scratch);
            return false;
         }
         emit_load_ptr_from_scratch(0, save_ptr0_offset);
         if (elem_size != 1) {
            unsigned char *factor_bytes = (unsigned char *) calloc(ptr_size ? ptr_size : 1, sizeof(unsigned char));
            char factor_buf[64];
            if (!factor_bytes) {
               lvalue_fixed_scratch_end(ctx, &scratch);
               return false;
            }
            snprintf(factor_buf, sizeof(factor_buf), "%d", elem_size);
            make_le_int(factor_buf, factor_bytes, ptr_size);
            emit_store_immediate_to_scratch(factor_offset, factor_bytes, ptr_size);
            free(factor_bytes);
            emit_runtime_binary_scratch(int_mul_helper_name(idx_type ? idx_type : required_typename_node("int16_t")), scaled_offset, idx_offset, factor_offset, ptr_size);
            emit_load_ptr_from_scratch(0, save_ptr0_offset);
            emit_add_scratch_to_ptr(0, int_mul_result_offset(idx_type ? idx_type : required_typename_node("int16_t"), scaled_offset, ptr_size), ptr_size);
         }
         else {
            emit_add_scratch_to_ptr(0, idx_offset, ptr_size);
         }
         lvalue_fixed_scratch_end(ctx, &scratch);
      }

      next_decl = declarator_after_subscript(*decl_io);
      *decl_io = next_decl;
      return true;
   }
   if (!strcmp(suffixes->name, ".") || !strcmp(suffixes->name, "->")) {
      AggregateMemberInfo info = {0};

      if (!strcmp(suffixes->name, "->")) {
         if (declarator_pointer_depth(*decl_io) <= 0) {
            return false;
         }
         emit_deref_ptr(0);
      }
      if (!find_aggregate_member_info(*type_io, suffixes->children[1]->strval, &info)) {
         return false;
      }
      emit_add_immediate_to_ptr(0, info.byte_offset);
      *type_io = info.type;
      *decl_io = info.declarator;
      return true;
   }
   return true;
}

//! @brief Emit semantic-use metadata for a contracted file-scope object lvalue.
void emit_lvalue_semantic_use(Context *ctx, const LValueRef *lv, const char *kind) {
   char symbol[256];
   const char *effective_kind = kind;

   if (!lv || !lv->is_global || !lv->name || !*lv->name || !lv->use_site ||
       !kind || !*kind ||
       declaration_symbol_use_contract(DECL_CONTRACT_OBJECT, lv->name, NULL) ==
          DECL_USE_CONTRACT_NONE) {
      return;
   }

   /* Accessing through a global pointer reads the pointer object itself; the
      pointee is not a statically named VCSC object. */
   if (lv->deref_depth > 0) {
      effective_kind = "read";
   }

   if (!format_user_asm_symbol(lv->name, symbol, sizeof(symbol))) {
      return;
   }
   emit_semantic_use_metadata(effective_kind, symbol,
                              ctx ? ctx->activation_owner : NULL,
                              lv->use_site);
}

//! @brief Emit prepare lvalue ptr for compiler lvalue lowering diagnostics or output files.
bool emit_prepare_lvalue_ptr(Context *ctx, const LValueRef *lv, LValueAccessMode mode) {
   ContextEntry base_entry;
   char sym[256];
   const ASTNode *type;
   const ASTNode *decl;
   const char *abs_expr = NULL;

   if (!lv) {
      return false;
   }
   if ((mode == LVALUE_ACCESS_ADDRESS || mode == LVALUE_ACCESS_REF) && lv->is_bitfield) {
      return false;
   }
   if (mode == LVALUE_ACCESS_WRITE && lv->is_bitfield && lv->is_absolute_ref &&
       lv->read_expr && lv->write_expr && strcmp(lv->read_expr, lv->write_expr)) {
      const ASTNode *site = lv->use_site;
      error_user("[%s:%d.%d] split-address bitfield '%s' cannot be written because bitfield stores require a read-modify-write through one address",
                 site && site->file ? site->file : "<unknown>",
                 site ? site->line : 0, site ? site->column : 0,
                 lv->name ? lv->name : "<unnamed>");
   }

   emit_lvalue_semantic_use(ctx, lv,
      mode == LVALUE_ACCESS_READ ? "read" :
      mode == LVALUE_ACCESS_WRITE ? "write" :
      mode == LVALUE_ACCESS_REF ? "ref" : "address");

   if (lv->is_absolute_ref) {
      switch (mode) {
         case LVALUE_ACCESS_READ:
            abs_expr = lv->read_expr;
            break;
         case LVALUE_ACCESS_WRITE:
            abs_expr = lv->write_expr;
            break;
         case LVALUE_ACCESS_ADDRESS:
         case LVALUE_ACCESS_REF:
            if (lv->read_expr && lv->write_expr) {
               if (strcmp(lv->read_expr, lv->write_expr)) {
                  const ASTNode *site = lv->use_site;
                  error_user("[%s:%d.%d] absolute ref '%s' does not have a single address; address-taking, pointer decay, and ref passing are not supported for split-address objects (read %s, write %s)",
                             site && site->file ? site->file : "<unknown>",
                             site ? site->line : 0, site ? site->column : 0,
                             lv->name ? lv->name : "<unnamed>",
                             lv->read_expr, lv->write_expr);
               }
               abs_expr = lv->read_expr;
            }
            else {
               abs_expr = lv->read_expr ? lv->read_expr : lv->write_expr;
            }
            break;
      }
      if (!abs_expr || !*abs_expr) {
         return false;
      }
      emit_load_expr_address_to_ptr(0, abs_expr, lv->ptr_adjust);
      if (!lv->base_type) {
         return true;
      }
      type = lv->base_type;
      decl = lv->base_declarator;
      return emit_prepare_lvalue_ptr_suffixes(ctx, lv->suffixes, &type, &decl);
   }

   if (!lv->base_type) {
      if (lv->indirect) {
         if (lv->is_static || lv->is_zeropage || lv->is_global) {
            base_entry = (ContextEntry){ .name = lv->name, .type = lv->type, .declarator = lv->declarator, .is_static = lv->is_static, .is_zeropage = lv->is_zeropage, .is_global = lv->is_global, .is_ref = lv->is_ref, .is_absolute_ref = lv->is_absolute_ref, .read_expr = lv->read_expr, .write_expr = lv->write_expr, .offset = lv->offset, .size = lv->size };
            if (!entry_symbol_name(ctx, &base_entry, sym, sizeof(sym))) {
               return false;
            }
            emit_load_ptr_from_symbol(0, sym, 0);
         }
         else {
            emit_load_ptr_from_scratch(0, lv->offset);
         }
         emit_add_immediate_to_ptr(0, lv->ptr_adjust);
         return true;
      }
      if (lv->is_static || lv->is_zeropage || lv->is_global) {
         base_entry = (ContextEntry){ .name = lv->name, .type = lv->type, .declarator = lv->declarator, .is_static = lv->is_static, .is_zeropage = lv->is_zeropage, .is_global = lv->is_global, .is_ref = lv->is_ref, .is_absolute_ref = lv->is_absolute_ref, .read_expr = lv->read_expr, .write_expr = lv->write_expr, .offset = lv->offset, .size = lv->size };
         if (!entry_symbol_name(ctx, &base_entry, sym, sizeof(sym))) {
            return false;
         }
         emit_load_address_to_ptr(0, sym, 0);
      }
      else {
         emit_prepare_scratch_ptr(0, lv->offset);
      }
      emit_add_immediate_to_ptr(0, lv->ptr_adjust);
      return true;
   }

   base_entry = (ContextEntry){ .name = lv->name, .type = lv->base_type, .declarator = lv->base_declarator, .is_static = lv->is_static, .is_zeropage = lv->is_zeropage, .is_global = lv->is_global, .is_ref = lv->is_ref, .is_absolute_ref = lv->is_absolute_ref, .read_expr = lv->read_expr, .write_expr = lv->write_expr, .offset = lv->base_offset, .size = declarator_storage_size(lv->base_type, lv->base_declarator) };
   type = lv->base_type;
   decl = lv->base_declarator;

   if (lv->is_static || lv->is_zeropage || lv->is_global) {
      if (!entry_symbol_name(ctx, &base_entry, sym, sizeof(sym))) {
         return false;
      }
      if (lv->deref_depth > 0 || lv->is_ref) {
         int extra_derefs = lv->deref_depth;
         emit_load_ptr_from_symbol(0, sym, 0);
         if (!lv->is_ref && extra_derefs > 0) {
            extra_derefs--;
         }
         for (int i = 0; i < extra_derefs; i++) {
            emit_deref_ptr(0);
         }
      }
      else {
         emit_load_address_to_ptr(0, sym, 0);
      }
   }
   else {
      if (lv->deref_depth > 0 || lv->is_ref) {
         int extra_derefs = lv->deref_depth;
         emit_load_ptr_from_scratch(0, lv->base_offset);
         if (!lv->is_ref && extra_derefs > 0) {
            extra_derefs--;
         }
         for (int i = 0; i < extra_derefs; i++) {
            emit_deref_ptr(0);
         }
      }
      else {
         emit_prepare_scratch_ptr(0, lv->base_offset);
      }
   }

   return emit_prepare_lvalue_ptr_suffixes(ctx, lv->suffixes, &type, &decl);
}

//! @brief Emit copy bitfield lvalue to scratch for compiler lvalue lowering diagnostics or output files.
static bool emit_copy_bitfield_lvalue_to_scratch(Context *ctx, int dst_offset, const LValueRef *src, int size) {
   int copy_size = size < src->size ? size : src->size;
   bool is_signed;
   int src_byte_offset;
   int shift_bits;
   int raw_copy_size;
   int field_last_byte;
   int field_rem;

   if (copy_size <= 0) {
      return true;
   }
   if (!emit_prepare_lvalue_ptr(ctx, src, LVALUE_ACCESS_READ)) {
      return false;
   }
   emit_prepare_scratch_ptr(1, dst_offset);

   emit_runtime_fill_ptr1(copy_size, 0x00);

   src_byte_offset = src->bit_offset / 8;
   shift_bits = src->bit_offset % 8;
   raw_copy_size = src->size - src_byte_offset;
   if (raw_copy_size > copy_size) {
      raw_copy_size = copy_size;
   }
   if (raw_copy_size > 0) {
      if (src_byte_offset > 0) {
         emit_add_immediate_to_ptr(0, src_byte_offset);
      }
      emit_copy_ptr0_to_ptr1(raw_copy_size);
   }

   if (shift_bits > 0) {
      const char *outer_label = next_label("bitfield_load_shift_outer");
      const char *inner_label = next_label("bitfield_load_shift_inner");
      const char *done_label = next_label("bitfield_load_shift_done");

      emit(&es_code, "    ldx #$%02x\n", shift_bits & 0xff);
      emit(&es_code, "%s:\n", outer_label);
      emit(&es_code, "    cpx #0\n");
      emit(&es_code, "    beq %s\n", done_label);
      emit(&es_code, "    clc\n");
      emit(&es_code, "    ldy #$%02x\n", (copy_size - 1) & 0xff);
      emit(&es_code, "%s:\n", inner_label);
      emit(&es_code, "    lda (ptr1),y\n");
      emit(&es_code, "    ror a\n");
      emit(&es_code, "    sta (ptr1),y\n");
      emit(&es_code, "    dey\n");
      emit(&es_code, "    bpl %s\n", inner_label);
      emit(&es_code, "    dex\n");
      emit(&es_code, "    bne %s\n", outer_label);
      emit(&es_code, "%s:\n", done_label);
   }

   field_last_byte = (src->bit_width - 1) / 8;
   field_rem = src->bit_width % 8;
   if (src->bit_width > 0 && src->bit_width < copy_size * 8) {
      if (field_rem != 0) {
         emit(&es_code, "    ldy #%d\n", field_last_byte);
         emit(&es_code, "    lda (ptr1),y\n");
         emit(&es_code, "    and #$%02x\n", ((1 << field_rem) - 1) & 0xff);
         emit(&es_code, "    sta (ptr1),y\n");
      }
      if (copy_size - (field_last_byte + 1) > 0) {
         emit_add_immediate_to_ptr(1, field_last_byte + 1);
         emit_runtime_fill_ptr1(copy_size - (field_last_byte + 1), 0x00);
         emit_prepare_scratch_ptr(1, dst_offset);
      }
   }

   is_signed = src->type && type_is_signed_integer(src->type);
   if (is_signed && src->bit_width > 0 && src->bit_width < copy_size * 8) {
      int sign_byte = (src->bit_width - 1) / 8;
      int sign_mask = 1 << ((src->bit_width - 1) % 8);
      int rem = src->bit_width % 8;
      const char *skip_label = next_label("bitfield_signext_skip");
      emit(&es_code, "    ldy #%d\n", sign_byte);
      emit(&es_code, "    lda (ptr1),y\n");
      emit(&es_code, "    and #$%02x\n", sign_mask & 0xff);
      emit(&es_code, "    beq %s\n", skip_label);
      if (rem != 0) {
         emit(&es_code, "    ldy #%d\n", sign_byte);
         emit(&es_code, "    lda (ptr1),y\n");
         emit(&es_code, "    ora #$%02x\n", ((0xff << rem) & 0xff));
         emit(&es_code, "    sta (ptr1),y\n");
      }
      if (copy_size - (sign_byte + 1) > 0) {
         emit_add_immediate_to_ptr(1, sign_byte + 1);
         emit_runtime_fill_ptr1(copy_size - (sign_byte + 1), 0xff);
         emit_prepare_scratch_ptr(1, dst_offset);
      }
      emit(&es_code, "%s:\n", skip_label);
   }
   return true;
}

//! @brief Emit copy bitfield lvalue to a fixed symbol without software-stack scratch.
bool emit_copy_bitfield_lvalue_to_symbol(Context *ctx, const char *symbol, int symbol_offset,
                                         const LValueRef *src, int size) {
   int copy_size = size < src->size ? size : src->size;
   bool is_signed;
   int src_byte_offset;
   int shift_bits;
   int raw_copy_size;
   int field_last_byte;
   int field_rem;

   if (!symbol || copy_size <= 0) {
      return copy_size <= 0;
   }
   if (!emit_prepare_lvalue_ptr(ctx, src, LVALUE_ACCESS_READ)) {
      return false;
   }
   emit_load_address_to_ptr(1, symbol, symbol_offset);
   emit_runtime_fill_ptr1(copy_size, 0x00);

   src_byte_offset = src->bit_offset / 8;
   shift_bits = src->bit_offset % 8;
   raw_copy_size = src->size - src_byte_offset;
   if (raw_copy_size > copy_size) {
      raw_copy_size = copy_size;
   }
   if (raw_copy_size > 0) {
      if (src_byte_offset > 0) {
         emit_add_immediate_to_ptr(0, src_byte_offset);
      }
      emit_copy_ptr0_to_ptr1(raw_copy_size);
   }

   if (shift_bits > 0) {
      const char *outer_label = next_label("bitfield_symbol_shift_outer");
      const char *inner_label = next_label("bitfield_symbol_shift_inner");
      const char *done_label = next_label("bitfield_symbol_shift_done");
      emit(&es_code, "    ldx #$%02x\n", shift_bits & 0xff);
      emit(&es_code, "%s:\n", outer_label);
      emit(&es_code, "    cpx #0\n");
      emit(&es_code, "    beq %s\n", done_label);
      emit(&es_code, "    clc\n");
      emit(&es_code, "    ldy #$%02x\n", (copy_size - 1) & 0xff);
      emit(&es_code, "%s:\n", inner_label);
      emit(&es_code, "    lda (ptr1),y\n");
      emit(&es_code, "    ror a\n");
      emit(&es_code, "    sta (ptr1),y\n");
      emit(&es_code, "    dey\n");
      emit(&es_code, "    bpl %s\n", inner_label);
      emit(&es_code, "    dex\n");
      emit(&es_code, "    bne %s\n", outer_label);
      emit(&es_code, "%s:\n", done_label);
   }

   field_last_byte = (src->bit_width - 1) / 8;
   field_rem = src->bit_width % 8;
   if (src->bit_width > 0 && src->bit_width < copy_size * 8) {
      if (field_rem != 0) {
         emit(&es_code, "    ldy #%d\n", field_last_byte);
         emit(&es_code, "    lda (ptr1),y\n");
         emit(&es_code, "    and #$%02x\n", ((1 << field_rem) - 1) & 0xff);
         emit(&es_code, "    sta (ptr1),y\n");
      }
      if (copy_size - (field_last_byte + 1) > 0) {
         emit_add_immediate_to_ptr(1, field_last_byte + 1);
         emit_runtime_fill_ptr1(copy_size - (field_last_byte + 1), 0x00);
         emit_load_address_to_ptr(1, symbol, symbol_offset);
      }
   }

   is_signed = src->type && type_is_signed_integer(src->type);
   if (is_signed && src->bit_width > 0 && src->bit_width < copy_size * 8) {
      int sign_byte = (src->bit_width - 1) / 8;
      int sign_mask = 1 << ((src->bit_width - 1) % 8);
      int rem = src->bit_width % 8;
      const char *skip_label = next_label("bitfield_symbol_signext_skip");
      emit(&es_code, "    ldy #%d\n", sign_byte);
      emit(&es_code, "    lda (ptr1),y\n");
      emit(&es_code, "    and #$%02x\n", sign_mask & 0xff);
      emit(&es_code, "    beq %s\n", skip_label);
      if (rem != 0) {
         emit(&es_code, "    ldy #%d\n", sign_byte);
         emit(&es_code, "    lda (ptr1),y\n");
         emit(&es_code, "    ora #$%02x\n", ((0xff << rem) & 0xff));
         emit(&es_code, "    sta (ptr1),y\n");
      }
      if (copy_size - (sign_byte + 1) > 0) {
         emit_add_immediate_to_ptr(1, sign_byte + 1);
         emit_runtime_fill_ptr1(copy_size - (sign_byte + 1), 0xff);
         emit_load_address_to_ptr(1, symbol, symbol_offset);
      }
      emit(&es_code, "%s:\n", skip_label);
   }
   return true;
}

//! @brief Emit copy from a fixed symbol to an lvalue without software-stack scratch.
bool emit_copy_symbol_to_lvalue(Context *ctx, const LValueRef *dst, const char *symbol,
                                int symbol_offset, int size) {
   int copy_size;

   if (!dst || !symbol) {
      return false;
   }
   copy_size = size < dst->size ? size : dst->size;
   if (copy_size <= 0) {
      return true;
   }
   if (!emit_prepare_lvalue_ptr(ctx, dst, LVALUE_ACCESS_WRITE)) {
      return false;
   }

   if (dst->is_bitfield) {
      for (int bit = 0; bit < dst->bit_width; bit++) {
         int dst_byte = (dst->bit_offset + bit) / 8;
         int dst_mask = 1 << ((dst->bit_offset + bit) % 8);
         int src_byte = bit / 8;
         int src_mask = 1 << (bit % 8);
         const char *clear_label = next_label("bitfield_symbol_store_clear");
         const char *done_label = next_label("bitfield_symbol_store_done");
         emit(&es_code, "    ldy #%d\n", symbol_offset + src_byte);
         emit(&es_code, "    lda %s,y\n", symbol);
         emit(&es_code, "    and #$%02x\n", src_mask & 0xff);
         emit(&es_code, "    beq %s\n", clear_label);
         emit(&es_code, "    ldy #%d\n", dst_byte);
         emit(&es_code, "    lda (ptr0),y\n");
         emit(&es_code, "    ora #$%02x\n", dst_mask & 0xff);
         emit(&es_code, "    sta (ptr0),y\n");
         emit(&es_code, "    jmp %s\n", done_label);
         emit(&es_code, "%s:\n", clear_label);
         emit(&es_code, "    ldy #%d\n", dst_byte);
         emit(&es_code, "    lda (ptr0),y\n");
         emit(&es_code, "    and #$%02x\n", (0xff ^ dst_mask) & 0xff);
         emit(&es_code, "    sta (ptr0),y\n");
         emit(&es_code, "%s:\n", done_label);
      }
      return true;
   }

   for (int i = 0; i < copy_size; i++) {
      emit(&es_code, "    ldy #%d\n", symbol_offset + i);
      emit(&es_code, "    lda %s,y\n", symbol);
      emit(&es_code, "    ldy #%d\n", i);
      emit(&es_code, "    sta (ptr0),y\n");
   }
   return true;
}

//! @brief Emit copy scratch to bitfield lvalue for compiler lvalue lowering diagnostics or output files.
static bool emit_copy_scratch_to_bitfield_lvalue(Context *ctx, const LValueRef *dst, int src_offset, int size) {
   int copy_size = size < dst->size ? size : dst->size;
   bool src_direct = src_offset >= 0 && src_offset + copy_size <= 256;

   if (copy_size <= 0) {
      return true;
   }
   if (!emit_prepare_lvalue_ptr(ctx, dst, LVALUE_ACCESS_WRITE)) {
      return false;
   }
   if (!src_direct) {
      emit_prepare_scratch_ptr(1, src_offset);
   }
   for (int bit = 0; bit < dst->bit_width; bit++) {
      int dst_byte = (dst->bit_offset + bit) / 8;
      int dst_mask = 1 << ((dst->bit_offset + bit) % 8);
      int src_byte = bit / 8;
      int src_mask = 1 << (bit % 8);
      const char *clear_label = next_label("bitfield_store_clear");
      const char *done_label = next_label("bitfield_store_done");
      emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + src_byte) : src_byte);
      emit(&es_code, "    lda %s,y\n", src_direct ? compiler_scratch_active_symbol() : "(ptr1)");
      emit(&es_code, "    and #$%02x\n", src_mask & 0xff);
      emit(&es_code, "    beq %s\n", clear_label);
      emit(&es_code, "    ldy #%d\n", dst_byte);
      emit(&es_code, "    lda (ptr0),y\n");
      emit(&es_code, "    ora #$%02x\n", dst_mask & 0xff);
      emit(&es_code, "    sta (ptr0),y\n");
      emit(&es_code, "    jmp %s\n", done_label);
      emit(&es_code, "%s:\n", clear_label);
      emit(&es_code, "    ldy #%d\n", dst_byte);
      emit(&es_code, "    lda (ptr0),y\n");
      emit(&es_code, "    and #$%02x\n", (0xff ^ dst_mask) & 0xff);
      emit(&es_code, "    sta (ptr0),y\n");
      emit(&es_code, "%s:\n", done_label);
   }
   return true;
}

//! @brief Emit copy lvalue to scratch for compiler lvalue lowering diagnostics or output files.
bool emit_copy_lvalue_to_scratch(Context *ctx, int dst_offset, const LValueRef *src, int size) {
   int copy_size = size < src->size ? size : src->size;
   bool dst_direct = dst_offset >= 0 && dst_offset + copy_size <= 256;
   int saved_locals = ctx ? ctx->locals : 0;
   int protected_locals = saved_locals;

   if (src && src->is_bitfield) {
      return emit_copy_bitfield_lvalue_to_scratch(ctx, dst_offset, src, size);
   }
   if (absolute_ref_supports_direct_access(src)) {
      const char *read_expr = src->read_expr;
      emit_lvalue_semantic_use(ctx, src, "read");

      if (!read_expr || !*read_expr) {
         return false;
      }
      if (!dst_direct) {
         emit_prepare_scratch_ptr(1, dst_offset);
      }
      for (int i = 0; i < copy_size; i++) {
         emit_load_a_from_expr_address(read_expr, src->offset + i);
         emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + i) : i);
         emit(&es_code, "    sta %s,y\n", dst_direct ? compiler_scratch_active_symbol() : "(ptr1)");
      }
      return true;
   }
   if (copy_size <= 0) {
      return true;
   }
   if (dst_offset + copy_size > protected_locals) {
      protected_locals = dst_offset + copy_size;
   }
   if (ctx) {
      ctx_set_locals(ctx, protected_locals);
   }
   if (!emit_prepare_lvalue_ptr(ctx, src, LVALUE_ACCESS_READ)) {
      if (ctx) {
         ctx_set_locals(ctx, saved_locals);
      }
      return false;
   }
   if (!dst_direct) {
      emit_prepare_scratch_ptr(1, dst_offset);
   }
   for (int i = 0; i < copy_size; i++) {
      emit(&es_code, "    ldy #%d\n", i);
      emit(&es_code, "    lda (ptr0),y\n");
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + i) : i);
      emit(&es_code, "    sta %s,y\n", dst_direct ? compiler_scratch_active_symbol() : "(ptr1)");
   }
   if (ctx) {
      ctx_set_locals(ctx, saved_locals);
   }
   return true;
}

//! @brief Emit copy scratch to lvalue for compiler lvalue lowering diagnostics or output files.
bool emit_copy_scratch_to_lvalue(Context *ctx, const LValueRef *dst, int src_offset, int size) {
   int copy_size = size < dst->size ? size : dst->size;
   bool src_direct = src_offset >= 0 && src_offset + copy_size <= 256;
   int saved_locals = ctx ? ctx->locals : 0;
   int protected_locals = saved_locals;

   if (dst && dst->is_bitfield) {
      return emit_copy_scratch_to_bitfield_lvalue(ctx, dst, src_offset, size);
   }
   if (absolute_ref_supports_direct_access(dst)) {
      const char *write_expr = dst->write_expr;
      emit_lvalue_semantic_use(ctx, dst, "write");

      if (!write_expr || !*write_expr) {
         return false;
      }
      if (!src_direct) {
         emit_prepare_scratch_ptr(1, src_offset);
      }
      for (int i = 0; i < copy_size; i++) {
         emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + i) : i);
         emit(&es_code, "    lda %s,y\n", src_direct ? compiler_scratch_active_symbol() : "(ptr1)");
         emit_store_a_to_expr_address(write_expr, dst->offset + i);
      }
      return true;
   }
   if (copy_size <= 0) {
      return true;
   }
   if (src_offset + copy_size > protected_locals) {
      protected_locals = src_offset + copy_size;
   }
   if (ctx) {
      ctx_set_locals(ctx, protected_locals);
   }
   if (!emit_prepare_lvalue_ptr(ctx, dst, LVALUE_ACCESS_WRITE)) {
      if (ctx) {
         ctx_set_locals(ctx, saved_locals);
      }
      return false;
   }
   if (!src_direct) {
      emit_prepare_scratch_ptr(1, src_offset);
   }
   for (int i = 0; i < copy_size; i++) {
      emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + i) : i);
      emit(&es_code, "    lda %s,y\n", src_direct ? compiler_scratch_active_symbol() : "(ptr1)");
      emit(&es_code, "    ldy #%d\n", i);
      emit(&es_code, "    sta (ptr0),y\n");
   }
   if (ctx) {
      ctx_set_locals(ctx, saved_locals);
   }
   return true;
}
//! @brief Compute lvalue suffixes and update compiler lvalue lowering state once prerequisite pass data is available.
static bool resolve_lvalue_suffixes(Context *ctx, const ASTNode *suffixes, LValueRef *out) {
   if (!suffixes || is_empty(suffixes)) {
      return true;
   }
   if (suffixes->count > 0 && !resolve_lvalue_suffixes(ctx, suffixes->children[0], out)) {
      return false;
   }
   if (!strcmp(suffixes->name, "[")) {
      const ASTNode *idx = unwrap_expr_node(suffixes->children[1]);
      int elem_size = declarator_first_element_size(out->type, out->declarator);
      const ASTNode *next_decl = declarator_after_subscript(out->declarator);

      if (!idx || elem_size <= 0) {
         return false;
      }
      if (declarator_pointer_depth(out->declarator) > 0) {
         out->indirect = true;
         if (idx->kind == AST_INTEGER && !out->needs_runtime_address) {
            out->ptr_adjust += atoi(idx->strval) * elem_size;
         }
         else if (ctx) {
            out->needs_runtime_address = true;
         }
         else {
            return false;
         }
      }
      else if (declarator_array_count(out->declarator) > 0) {
         if (idx->kind == AST_INTEGER && !out->needs_runtime_address) {
            if (out->indirect) {
               out->ptr_adjust += atoi(idx->strval) * elem_size;
            }
            else {
               out->offset += atoi(idx->strval) * elem_size;
            }
         }
         else if (ctx) {
            out->needs_runtime_address = true;
         }
         else {
            return false;
         }
      }
      else {
         error_user("[%s:%d.%d] cannot subscript non-pointer/non-array '%s'",
               suffixes->file, suffixes->line, suffixes->column,
               out->name ? out->name : "<unnamed>");
      }
      out->declarator = next_decl;
      out->size = out->declarator ? declarator_storage_size(out->type, out->declarator) : get_size(type_name_from_node(out->type));
      out->is_bitfield = false;
      out->bit_offset = 0;
      out->bit_width = 0;
      out->bit_storage_size = 0;
      return true;
   }
   if (!strcmp(suffixes->name, ".") || !strcmp(suffixes->name, "->")) {
      AggregateMemberInfo info = {0};
      if (!find_aggregate_member_info(out->type, suffixes->children[1]->strval, &info)) {
         return false;
      }
      if (!strcmp(suffixes->name, "->")) {
         if (declarator_pointer_depth(out->declarator) <= 0) {
            error_user("[%s:%d.%d] cannot use '->' on non-pointer '%s'",
                  suffixes->file, suffixes->line, suffixes->column,
                  out->name ? out->name : "<unnamed>");
         }
         out->indirect = true;
         if (!out->needs_runtime_address) {
            out->ptr_adjust += info.byte_offset;
         }
      }
      else if (out->indirect) {
         if (!out->needs_runtime_address) {
            out->ptr_adjust += info.byte_offset;
         }
      }
      else {
         out->offset += info.byte_offset;
      }
      out->type = info.type;
      out->declarator = info.declarator;
      out->size = declarator_storage_size(info.type, info.declarator);
      out->is_bitfield = info.is_bitfield;
      out->bit_offset = info.bit_offset;
      out->bit_width = info.bit_width;
      out->bit_storage_size = info.storage_size;
      return true;
   }
   return true;
}
//! @brief Find lvalue entry in compiler lvalue lowering tables without transferring ownership.
static ContextEntry *lookup_lvalue_entry(Context *ctx, const char *name, ContextEntry *scratch) {
   ContextEntry *entry;
   const ASTNode *g;

   if (!name) {
      return NULL;
   }

   entry = ctx_lookup(ctx, name);
   if (entry) {
      return entry;
   }

   g = global_decl_lookup(name);
   if (g && g->count >= 3 && scratch && init_context_entry_from_global_decl(scratch, name, g)) {
      return scratch;
   }

   return NULL;
}

//! @brief Extract init lvalue from entry for compiler lvalue lowering.
static void init_lvalue_from_entry(LValueRef *out, const ContextEntry *entry, const char *fallback_name) {
   out->name = entry->name ? entry->name : fallback_name;
   out->type = entry->type;
   out->declarator = entry->declarator;
   out->base_type = entry->type;
   out->base_declarator = entry->declarator;
   out->is_static = entry->is_static;
   out->is_zeropage = entry->is_zeropage;
   out->is_global = entry->is_global;
   out->is_ref = entry->is_ref;
   out->is_absolute_ref = entry->is_absolute_ref;
   out->read_expr = entry->read_expr;
   out->write_expr = entry->write_expr;
   out->base_offset = entry->offset;
   out->offset = entry->offset;
   out->size = entry->is_ref
      ? declarator_storage_size(entry->type, entry->declarator)
      : entry->size;
   out->deref_depth = 0;
   out->indirect = entry->is_ref;
}

//! @brief Diagnose invalid use of the synthetic return-slot variable.
static void error_invalid_return_object_reference(const ASTNode *node) {
   error_user("[%s:%d.%d] '$$' is the current function's return object, so it is only valid inside a function that returns a value. "
              "Use it in a non-void function body, for example '$$.field := value; return;', or use 'return <expr>;' to have the compiler write the return object for you.",
              node ? node->file : "<unknown>",
              node ? node->line : 0,
              node ? node->column : 0);
}

//! @brief Compute lvalue base and update compiler lvalue lowering state once prerequisite pass data is available.
static bool resolve_lvalue_base(Context *ctx, ASTNode *base, LValueRef *out) {
   ContextEntry scratch;
   ContextEntry *entry;
   const char *name;

   if (!base || !out) {
      return false;
   }

   if (!strcmp(base->name, "lvalue")) {
      return resolve_lvalue(ctx, base, out);
   }

   if (!strcmp(base->name, "lvalue_base")) {
      if (base->count == 0 || base->children[0]->kind != AST_IDENTIFIER) {
         return false;
      }
      name = base->children[0]->strval;
      if (name && !strcmp(name, "$$")) {
         entry = ctx_lookup(ctx, "$$");
         if (!entry || entry->size <= 0) {
            error_invalid_return_object_reference(base->children[0]);
         }
         init_lvalue_from_entry(out, entry, name);
         return true;
      }
      entry = lookup_lvalue_entry(ctx, name, &scratch);
      if (!entry) {
         return false;
      }
      init_lvalue_from_entry(out, entry, name);
      return true;
   }

   if (!strcmp(base->name, "*") && base->count > 0) {
      if (base->children[0] && !strcmp(base->children[0]->name, "lvalue")) {
         if (!resolve_lvalue(ctx, base->children[0], out)) {
            return false;
         }
      }
      else if (!resolve_lvalue_base(ctx, base->children[0], out)) {
         return false;
      }
      if (declarator_pointer_depth(out->declarator) <= 0) {
         error_user("[%s:%d.%d] cannot dereference non-pointer '%s'",
               base->file, base->line, base->column,
               out->name ? out->name : "<unnamed>");
      }
      out->declarator = declarator_after_deref(out->declarator);
      out->size = out->declarator ? declarator_storage_size(out->type, out->declarator) : get_size(type_name_from_node(out->type));
      out->indirect = true;
      out->deref_depth++;
      return true;
   }

   return false;
}

//! @brief Compute lvalue and update compiler lvalue lowering state once prerequisite pass data is available.
bool resolve_lvalue(Context *ctx, ASTNode *node, LValueRef *out) {
   ASTNode *base;

   if (!node || strcmp(node->name, "lvalue") || node->count == 0 || !out) {
      return false;
   }

   memset(out, 0, sizeof(*out));
   out->use_site = node;
   out->suffixes = node->children[1];
   base = node->children[0];
   if (!base) {
      return false;
   }

   if (!resolve_lvalue_base(ctx, base, out)) {
      return false;
   }

   return resolve_lvalue_suffixes(ctx, node->children[1], out);
}

