//! @file compiler/compile_expr_flow.c
//! @brief Implements control-flow expression lowering for the VCSC compiler.
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

static const ASTNode *expr_lvalue_base_identifier_node(ASTNode *expr);

typedef CompilerScratchLease FlowFixedScratch;

//! @brief Prepare one fixed-address flow-expression working area without activating it.
static void flow_fixed_scratch_prepare(Context *ctx, int reserved,
                                       FlowFixedScratch *scratch) {
   compiler_scratch_acquire(ctx, reserved, scratch);
}

//! @brief Activate a prepared fixed-address flow-expression working area.
static void flow_fixed_scratch_activate(Context *ctx, FlowFixedScratch *scratch) {
   compiler_scratch_activate(ctx, scratch);
}

//! @brief Deactivate the flow scratch lease live for copy-out.
static void flow_fixed_scratch_deactivate(Context *ctx, FlowFixedScratch *scratch) {
   compiler_scratch_deactivate(ctx, scratch);
}

//! @brief Release one inactive flow scratch lease.
static void flow_fixed_scratch_finish(FlowFixedScratch *scratch) {
   compiler_scratch_release(scratch);
}

//! @brief Deactivate and release a flow scratch lease on an error path.
static void flow_fixed_scratch_abort(Context *ctx, FlowFixedScratch *scratch) {
   compiler_scratch_deactivate(ctx, scratch);
   compiler_scratch_release(scratch);
}

//! @brief Evaluate an expression in fixed BSS scratch and restore the caller frame.
static bool compile_expr_to_fixed_scratch(ASTNode *expr, Context *ctx,
                                          const ASTNode *type,
                                          const ASTNode *declarator,
                                          int size,
                                          bool target_typed,
                                          PointerAccessQualifier pointer_access,
                                          char *symbol,
                                          size_t symbol_size,
                                          int *allocated_size,
                                          CompilerScratchLease *scratch_out) {
   bool ok;
   ContextEntry tmp;

   if (!expr || !symbol || symbol_size == 0 || size <= 0 || !scratch_out) {
      return false;
   }

   compiler_scratch_acquire(ctx, size, scratch_out);
   snprintf(symbol, symbol_size, "%s", scratch_out->symbol);
   memset(&tmp, 0, sizeof(tmp));
   tmp.name = "$fixedtmp";
   tmp.type = type;
   tmp.declarator = declarator;
   tmp.target_typed = target_typed;
   tmp.pointer_access = pointer_access;
   tmp.offset = 0;
   tmp.size = size;

   compiler_scratch_activate(ctx, scratch_out);
   ok = compile_expr_to_slot(expr, ctx, &tmp);
   compiler_scratch_deactivate(ctx, scratch_out);
   if (allocated_size) {
      *allocated_size = scratch_out->used;
   }
   if (!ok) {
      compiler_scratch_release(scratch_out);
   }
   return ok;
}

//! @brief Return lvalue base identifier node data used by compiler short-circuit/control-flow expression lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
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

//! @brief Return expr lvalue base identifier node data used by compiler short-circuit/control-flow expression lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
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

//! @brief Return whether declarator is not pointer in compiler short-circuit/control-flow expression lowering.
static bool declarator_is_not_pointer(const ASTNode *declarator) {
   return declarator_pointer_depth(declarator) == 0;
}

//! @brief Return whether type node is plain void in compiler short-circuit/control-flow expression lowering.
static bool type_node_is_plain_void(const ASTNode *type, const ASTNode *declarator) {
   const char *name = type_name_from_node(type);
   return name && !strcmp(name, "void") && declarator_is_not_pointer(declarator);
}

//! @brief Return whether expr is plain void cast in compiler short-circuit/control-flow expression lowering.
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

//! @brief Report unknown identifier node diagnostics with the location/context expected by compiler short-circuit/control-flow expression lowering callers.
static void error_unknown_identifier_node(const ASTNode *idnode, const ASTNode *fallback, const char *ident) {
   error_user("[%s:%d.%d] unknown identifier '%s'",
         idnode && idnode->file ? idnode->file : (fallback && fallback->file ? fallback->file : "<unknown>"),
         idnode ? idnode->line : (fallback ? fallback->line : 0),
         idnode ? idnode->column : (fallback ? fallback->column : 0),
         ident ? ident : "<unknown>");
}

//! @brief Return whether a pointer-targeted assignment must decay an array RHS to its address.
static bool assignment_requires_array_decay(Context *ctx, const ContextEntry *dst, ASTNode *rhs) {
   const ASTNode *src_decl;

   if (!dst || !dst->declarator || declarator_pointer_depth(dst->declarator) <= 0) {
      return false;
   }
   src_decl = expr_value_declarator(rhs, ctx);
   return src_decl && declarator_pointer_depth(src_decl) == 0 && declarator_array_count(src_decl) > 0;
}

//! @brief Report unresolved assignment target diagnostics with the location/context expected by compiler short-circuit/control-flow expression lowering callers.
static void error_unresolved_assignment_target(Context *ctx, ASTNode *target, ASTNode *fallback) {
   const ASTNode *idnode = expr_lvalue_base_identifier_node(target);
   const char *ident = idnode ? idnode->strval : NULL;

   if (ident && !ctx_lookup(ctx, ident) && !global_decl_lookup(ident)) {
      error_unknown_identifier_node(idnode, target, ident);
   }
   error_user("[%s:%d.%d] invalid assignment target",
         target && target->file ? target->file : (fallback && fallback->file ? fallback->file : "<unknown>"),
         target ? target->line : (fallback ? fallback->line : 0),
         target ? target->column : (fallback ? fallback->column : 0));
}


//! @brief Zero a frame-pointer initializer target before applying a braced initializer.
static void emit_zero_assignment_initializer_scratch_target(int offset, int size) {
   if (size <= 0) {
      return;
   }
   emit_fill_scratch_bytes(offset, 0, size, 0x00);
}

//! @brief Lower simple assignment from a braced initializer into an lvalue target.
static bool compile_braced_assignment_to_lvalue(ASTNode *node, Context *ctx, const LValueRef *lv,
                                                const ContextEntry *dst, ASTNode *rhs) {
   int size;

   if (!node || !ctx || !lv || !dst || !rhs) {
      return false;
   }

   size = dst->size;
   if (size <= 0) {
      size = declarator_storage_size(dst->type, dst->declarator);
   }
   if (size <= 0) {
      size = type_size_from_node(dst->type);
   }
   if (size <= 0) {
      error_user("[%s:%d.%d] invalid braced assignment target size", node->file, node->line, node->column);
      return false;
   }

   {
      int tmp_offset = 0;
      char sym[256];
      FlowFixedScratch scratch;
      bool dst_symbol = !lv->is_bitfield && !lv->indirect && !lv->needs_runtime_address &&
                        !lv->is_absolute_ref && (dst->is_static || dst->is_zeropage || dst->is_global) &&
                        entry_symbol_name(ctx, dst, sym, sizeof(sym));
      bool dst_direct_scratch = !lv->is_bitfield && !lv->indirect && !lv->needs_runtime_address &&
                           !lv->is_absolute_ref && !dst->is_static && !dst->is_zeropage && !dst->is_global;

      flow_fixed_scratch_prepare(ctx, size, &scratch);
      flow_fixed_scratch_activate(ctx, &scratch);

      emit_zero_assignment_initializer_scratch_target(tmp_offset, size);
      if (!compile_initializer_to_scratch(rhs, ctx, dst->type, dst->declarator, tmp_offset, size)) {
         flow_fixed_scratch_abort(ctx, &scratch);
         error_user("[%s:%d.%d] invalid assignment initializer", node->file, node->line, node->column);
         return false;
      }

      flow_fixed_scratch_deactivate(ctx, &scratch);
      if (dst_symbol) {
         emit_copy_symbol_to_symbol_convert_offset(sym, lv->offset, size, dst->type,
                                                   scratch.symbol, tmp_offset, size, dst->type);
      }
      else if (dst_direct_scratch) {
         emit_copy_symbol_to_scratch_convert_offset(dst->offset, size, dst->type,
                                               scratch.symbol, tmp_offset, size, dst->type);
      }
      else if (!emit_copy_symbol_to_lvalue(ctx, lv, scratch.symbol, tmp_offset, size)) {
         flow_fixed_scratch_finish(&scratch);
         error_user("[%s:%d.%d] invalid assignment target", node->file, node->line, node->column);
         return false;
      }
      flow_fixed_scratch_finish(&scratch);

      return true;
   }
}

//! @brief Describe a one-byte lvalue for compact comparison lowering.
typedef struct DirectByteOperand {
   LValueRef lv;
   bool valid;
   bool direct_memory;
   bool local_scratch;
   int symbol_mode; /* 0 expression, 1 zero page, 2 absolute */
   char expr[256];
   int offset;
} DirectByteOperand;

//! @brief Classify an unsigned one-byte lvalue without emitting code.
static DirectByteOperand classify_direct_byte_operand(Context *ctx, ASTNode *expr,
                                                       bool allow_runtime_pointer) {
   DirectByteOperand out;
   ContextEntry entry;

   memset(&out, 0, sizeof(out));
   /* The compact compare path reads an lvalue directly and therefore must not
      accept valued ++/-- expressions whose required side effect is carried by
      the expression lowering path. */
   if (classify_incdec_lvalue_expr(expr, NULL, NULL)) {
      return out;
   }
   if (!resolve_ref_argument_lvalue(ctx, expr, &out.lv) || out.lv.size != 1 ||
       type_is_signed_integer(out.lv.type) || out.lv.is_bitfield) {
      return out;
   }
   out.valid = true;
   out.offset = out.lv.offset;

   if (out.lv.is_absolute_ref && out.lv.read_expr && *out.lv.read_expr &&
       !out.lv.indirect && !out.lv.needs_runtime_address) {
      snprintf(out.expr, sizeof(out.expr), "%s", out.lv.read_expr);
      out.direct_memory = true;
      out.symbol_mode = 0;
      return out;
   }

   if (!out.lv.indirect && !out.lv.needs_runtime_address &&
       (out.lv.is_static || out.lv.is_zeropage || out.lv.is_global)) {
      entry = (ContextEntry){ .name = out.lv.name, .type = out.lv.type,
         .declarator = out.lv.declarator, .is_static = out.lv.is_static,
         .is_zeropage = out.lv.is_zeropage, .is_global = out.lv.is_global,
         .offset = out.lv.offset, .size = out.lv.size };
      if (!entry_symbol_name(ctx, &entry, out.expr, sizeof(out.expr))) {
         out.valid = false;
         return out;
      }
      out.direct_memory = true;
      out.symbol_mode = out.lv.is_zeropage ? 1 : 2;
      return out;
   }

   if (!out.lv.indirect && !out.lv.needs_runtime_address && !out.lv.is_static &&
       !out.lv.is_zeropage && !out.lv.is_global && out.lv.offset >= 0 &&
       out.lv.offset <= 255) {
      out.local_scratch = true;
      return out;
   }

   if (!allow_runtime_pointer) {
      out.valid = false;
   }
   return out;
}

//! @brief Load a classified direct byte operand into A.
static bool emit_load_direct_byte_operand(Context *ctx, const DirectByteOperand *op) {
   if (!op || !op->valid) {
      return false;
   }
   emit_lvalue_semantic_use(ctx, &op->lv, "read");
   if (op->direct_memory) {
      if (op->symbol_mode != 0) {
         char expr_buf[256];
         const char *formatted = assembler_address_expr(op->expr, expr_buf, sizeof(expr_buf));
         if (op->offset == 0)
            emit(&es_code, op->symbol_mode == 1 ? "    lda.z %s\n" : "    lda.a %s\n", formatted);
         else
            emit(&es_code, op->symbol_mode == 1 ? "    lda.z %s + %d\n" : "    lda.a %s + %d\n", formatted, op->offset);
      }
      else {
         emit_load_a_from_expr_address(op->expr, op->offset);
      }
      return true;
   }
   if (op->local_scratch) {
      emit(&es_code, "    ldy #%d\n", op->offset);
      emit(&es_code, "    lda %s,y\n", compiler_scratch_active_symbol());
      return true;
   }
   if (!emit_prepare_lvalue_ptr(ctx, &op->lv, LVALUE_ACCESS_READ)) {
      return false;
   }
   emit(&es_code, "    ldy #0\n");
   emit(&es_code, "    lda (ptr0),y\n");
   return true;
}

//! @brief Compare A against a direct byte memory operand.
static bool emit_cmp_direct_byte_operand(Context *ctx, const DirectByteOperand *op) {
   char asm_expr[256];
   const char *formatted;

   if (!op || !op->valid) {
      return false;
   }
   emit_lvalue_semantic_use(ctx, &op->lv, "read");
   if (op->direct_memory) {
      formatted = assembler_address_expr(op->expr, asm_expr, sizeof(asm_expr));
      if (op->offset == 0) {
         if (op->symbol_mode == 1) emit(&es_code, "    cmp.z %s\n", formatted);
         else if (op->symbol_mode == 2) emit(&es_code, "    cmp.a %s\n", formatted);
         else emit(&es_code, "    cmp %s\n", formatted);
      }
      else {
         if (op->symbol_mode == 1) emit(&es_code, "    cmp.z %s + %d\n", formatted, op->offset);
         else if (op->symbol_mode == 2) emit(&es_code, "    cmp.a %s + %d\n", formatted, op->offset);
         else emit(&es_code, "    cmp %s + %d\n", formatted, op->offset);
      }
      return true;
   }
   if (op->local_scratch) {
      emit(&es_code, "    ldy #%d\n", op->offset);
      emit(&es_code, "    cmp %s,y\n", compiler_scratch_active_symbol());
      return true;
   }
   /* ptr0 must already have been prepared before loading A. */
   emit(&es_code, "    ldy #0\n");
   emit(&es_code, "    cmp (ptr0),y\n");
   return true;
}

//! @brief Emit the false branch for an unsigned byte comparison, if eligible.
static bool compile_direct_u8_compare_branch_false(ASTNode *expr, Context *ctx,
                                                   const char *false_label) {
   DirectByteOperand lhs;
   DirectByteOperand rhs;
   ASTNode *rhs_expr;
   const char *op;
   bool rhs_immediate = false;
   long rhs_value = 0;

   if (!expr || expr->count != 2) {
      return false;
   }
   op = expr->name;
   if (strcmp(op, "==") && strcmp(op, "!=") && strcmp(op, "<") &&
       strcmp(op, ">") && strcmp(op, "<=") && strcmp(op, ">=")) {
      return false;
   }

   lhs = classify_direct_byte_operand(ctx, expr->children[0], false);
   if (!lhs.valid) {
      return false;
   }

   rhs_expr = (ASTNode *) unwrap_expr_node(expr->children[1]);
   if (rhs_expr && rhs_expr->kind == AST_INTEGER) {
      char *end = NULL;
      rhs_value = strtol(rhs_expr->strval, &end, 0);
      rhs_immediate = end && *end == '\0' && rhs_value >= 0 &&
                      integer_value_fits_type(rhs_value, lhs.lv.type);
      if (!rhs_immediate) {
         return false;
      }
      if (!emit_load_direct_byte_operand(ctx, &lhs)) {
         return false;
      }
      if (type_is_bcd_integer(lhs.lv.type)) {
         unsigned char packed = 0;
         if (!encode_integer_initializer_value(rhs_value, &packed, 1, lhs.lv.type)) {
            return false;
         }
         emit(&es_code, "    cmp #$%02x\n", (unsigned int) packed);
      }
      else {
         emit(&es_code, "    cmp #$%02lx\n", rhs_value & 0xff);
      }
   }
   else {
      rhs = classify_direct_byte_operand(ctx, expr->children[1], true);
      if (!rhs.valid) {
         return false;
      }
      if (!rhs.direct_memory && !rhs.local_scratch) {
         if (!emit_prepare_lvalue_ptr(ctx, &rhs.lv, LVALUE_ACCESS_READ)) {
            return false;
         }
      }
      if (!emit_load_direct_byte_operand(ctx, &lhs) ||
          !emit_cmp_direct_byte_operand(ctx, &rhs)) {
         return false;
      }
   }

   if (!strcmp(op, "==")) {
      const char *true_label = next_label("u8_eq_true");
      emit(&es_code, "    beq %s\n", true_label);
      emit(&es_code, "    jmp %s\n", false_label);
      emit(&es_code, "%s:\n", true_label);
      free((void *) true_label);
   }
   else if (!strcmp(op, "!=")) {
      const char *true_label = next_label("u8_ne_true");
      emit(&es_code, "    bne %s\n", true_label);
      emit(&es_code, "    jmp %s\n", false_label);
      emit(&es_code, "%s:\n", true_label);
      free((void *) true_label);
   }
   else if (!strcmp(op, "<")) {
      const char *true_label = next_label("u8_lt_true");
      emit(&es_code, "    bcc %s\n", true_label);
      emit(&es_code, "    jmp %s\n", false_label);
      emit(&es_code, "%s:\n", true_label);
      free((void *) true_label);
   }
   else if (!strcmp(op, ">=")) {
      const char *true_label = next_label("u8_ge_true");
      emit(&es_code, "    bcs %s\n", true_label);
      emit(&es_code, "    jmp %s\n", false_label);
      emit(&es_code, "%s:\n", true_label);
      free((void *) true_label);
   }
   else if (!strcmp(op, ">")) {
      const char *true_label = next_label("u8_gt_true");
      const char *false_jump = next_label("u8_gt_false");
      emit(&es_code, "    bcc %s\n", false_jump);
      emit(&es_code, "    bne %s\n", true_label);
      emit(&es_code, "%s:\n", false_jump);
      emit(&es_code, "    jmp %s\n", false_label);
      emit(&es_code, "%s:\n", true_label);
      free((void *) false_jump);
      free((void *) true_label);
   }
   else { /* <= : false only when lhs > rhs. */
      const char *true_label = next_label("u8_le_true");
      emit(&es_code, "    bcc %s\n", true_label);
      emit(&es_code, "    beq %s\n", true_label);
      emit(&es_code, "    jmp %s\n", false_label);
      emit(&es_code, "%s:\n", true_label);
      free((void *) true_label);
   }
   return true;
}

//! @brief Lower truthy expression branch false from AST/semantic state into generated assembly or linker-visible metadata.
static bool compile_truthy_expr_branch_false(ASTNode *expr, Context *ctx,
                                             const ASTNode *type,
                                             const ASTNode *declarator,
                                             int size,
                                             const char *false_label) {
   char scratch_sym[96];
   CompilerScratchLease scratch;

   if (size <= 0) {
      size = expr_value_size(expr, ctx);
   }
   if (size <= 0) {
      size = 1;
   }
   if (!type) {
      type = expr_value_type(expr, ctx);
   }

   if (!compile_expr_to_fixed_scratch(expr, ctx, type, declarator, size,
                                      declarator != NULL, POINTER_ACCESS_READWRITE,
                                      scratch_sym,
                                      sizeof(scratch_sym), NULL, &scratch)) {
      return false;
   }

   emit(&es_code, "    lda #0\n");
   for (int i = 0; i < size; i++) {
      emit(&es_code, "    ldy #%d\n", i);
      emit(&es_code, "    ora %s,y\n", scratch_sym);
   }
   emit(&es_code, "    beq %s\n", false_label);
   compiler_scratch_release(&scratch);
   return true;
}

//! @brief Lower condition branch false from AST/semantic state into generated assembly or linker-visible metadata.
bool compile_condition_branch_false(ASTNode *expr, Context *ctx, const char *false_label) {
   expr = (ASTNode *) unwrap_expr_node(expr);

   if (!expr || is_empty(expr)) {
      emit(&es_code, "    jmp %s\n", false_label);
      return true;
   }

   if (expr->count == 1 && !strcmp(expr->name, "!")) {
      const char *end_label = next_label("not_cond_end");
      if (!end_label) {
         return false;
      }
      if (!compile_condition_branch_false(expr->children[0], ctx, end_label)) {
         free((void *) end_label);
         return false;
      }
      emit(&es_code, "    jmp %s\n", false_label);
      emit(&es_code, "%s:\n", end_label);
      free((void *) end_label);
      return true;
   }

   if (expr->count == 2 && !strcmp(expr->name, "&&")) {
      if (!compile_condition_branch_false(expr->children[0], ctx, false_label)) {
         return false;
      }
      return compile_condition_branch_false(expr->children[1], ctx, false_label);
   }

   if (expr->count == 2 && !strcmp(expr->name, "||")) {
      const char *rhs_label = next_label("or_rhs");
      const char *end_label = next_label("or_end");
      if (!rhs_label || !end_label) {
         free((void *) rhs_label);
         free((void *) end_label);
         return false;
      }
      if (!compile_condition_branch_false(expr->children[0], ctx, rhs_label)) {
         free((void *) rhs_label);
         free((void *) end_label);
         return false;
      }
      emit(&es_code, "    jmp %s\n", end_label);
      emit(&es_code, "%s:\n", rhs_label);
      if (!compile_condition_branch_false(expr->children[1], ctx, false_label)) {
         free((void *) rhs_label);
         free((void *) end_label);
         return false;
      }
      emit(&es_code, "%s:\n", end_label);
      free((void *) rhs_label);
      free((void *) end_label);
      return true;
   }

   if (expr->kind == AST_INTEGER) {
      if (!expr->strval || !strcmp(expr->strval, "0")) {
         emit(&es_code, "    jmp %s\n", false_label);
      }
      return true;
   }

   require_no_mixed_signed_integer_binary_expr(expr, ctx);

   if (compile_direct_u8_compare_branch_false(expr, ctx, false_label)) {
      return true;
   }

   if (expr->count == 2 &&
       (!strcmp(expr->name, "==") || !strcmp(expr->name, "!=") ||
        !strcmp(expr->name, "<")  || !strcmp(expr->name, ">")  ||
        !strcmp(expr->name, "<=") || !strcmp(expr->name, ">="))) {
      const ASTNode *lhs_type = expr_value_type(expr->children[0], ctx);
      const ASTNode *rhs_type = expr_value_type(expr->children[1], ctx);
      const ASTNode *type = NULL;
      int size;
      int compare_size;
      CompilerScratchLease scratch;
      ContextEntry lhs;
      ContextEntry rhs;
      const char *helper = NULL;
      bool invert = false;
      bool ok;

      type = value_compare_integer_work_type(expr->children[0], expr->children[1], ctx, expr);
      if (!type) {
         type = lhs_type ? lhs_type : rhs_type;
      }
      size = type ? type_size_from_node(type) : 0;
      if (size <= 0) {
         size = expr_value_size(expr->children[0], ctx);
      }
      if (size <= 0) {
         size = expr_value_size(expr->children[1], ctx);
      }
      if (size <= 0) {
         size = 1;
      }
      compare_size = size * 2;
      compiler_scratch_acquire(ctx, compare_size, &scratch);
      lhs = (ContextEntry){ .name = "$lhs", .type = type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = true, .offset = 0, .size = size };
      rhs = (ContextEntry){ .name = "$rhs", .type = type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = true, .offset = size, .size = size };
      compiler_scratch_activate(ctx, &scratch);
      ok = compile_expr_to_slot(expr->children[0], ctx, &lhs) &&
           compile_expr_to_slot(expr->children[1], ctx, &rhs);
      if (!ok) {
         compiler_scratch_deactivate(ctx, &scratch);
         compiler_scratch_release(&scratch);
         return false;
      }

      if (!strcmp(expr->name, "==")) {
         helper = "==";
      }
      else if (!strcmp(expr->name, "!=")) {
         helper = "==";
         invert = true;
      }
      else if (!strcmp(expr->name, "<")) {
         helper = "<";
      }
      else if (!strcmp(expr->name, ">")) {
         helper = "<";
         ContextEntry t = lhs; lhs = rhs; rhs = t;
      }
      else if (!strcmp(expr->name, "<=")) {
         helper = "<=";
      }
      else if (!strcmp(expr->name, ">=")) {
         helper = "<=";
         ContextEntry t = lhs; lhs = rhs; rhs = t;
      }

      emit_fixed_compare_scratch(type, helper, lhs.offset, rhs.offset, size);
      compiler_scratch_deactivate(ctx, &scratch);
      compiler_scratch_release(&scratch);
      emit(&es_code, "    %s %s\n", invert ? "bne" : "beq", false_label);
      return true;
   }

   {
      const ASTNode *type = expr_value_type(expr, ctx);
      int size = expr_value_size(expr, ctx);
      return compile_truthy_expr_branch_false(expr, ctx, type, NULL, size, false_label);
   }
}

//! @brief Assign a constant byte directly without a fixed BSS bridge object.
static bool compile_direct_byte_constant_assignment(Context *ctx,
                                                    const LValueRef *dst,
                                                    ASTNode *rhs) {
   InitConstValue value = {0};
   ContextEntry entry;
   char symbol[256];
   unsigned char encoded = 0;
   unsigned int byte_value;

   if (!dst || dst->size != 1 || dst->is_bitfield ||
       !eval_constant_initializer_expr(rhs, &value) ||
       value.kind != INIT_CONST_INT || !integer_value_fits_type(value.i, dst->type)) {
      return false;
   }
   if (!encode_integer_initializer_value(value.i, &encoded, 1, dst->type)) {
      return false;
   }
   byte_value = encoded;

   if (dst->is_absolute_ref && !dst->indirect && !dst->needs_runtime_address) {
      if (!dst->write_expr || !*dst->write_expr) {
         return false;
      }
      emit(&es_code, "    lda #$%02x\n", byte_value);
      emit_store_a_to_expr_address(dst->write_expr, dst->offset);
      return true;
   }

   if (!dst->indirect && !dst->needs_runtime_address &&
       (dst->is_static || dst->is_zeropage || dst->is_global)) {
      entry = (ContextEntry){ .name = dst->name, .type = dst->type,
         .declarator = dst->declarator, .is_static = dst->is_static,
         .is_zeropage = dst->is_zeropage, .is_global = dst->is_global,
         .offset = dst->offset, .size = dst->size };
      if (!entry_symbol_name(ctx, &entry, symbol, sizeof(symbol))) {
         return false;
      }
      {
         char expr_buf[256];
         const char *formatted = assembler_address_expr(symbol, expr_buf, sizeof(expr_buf));
         emit(&es_code, "    lda #$%02x\n", byte_value);
         if (dst->offset == 0)
            emit(&es_code, dst->is_zeropage ? "    sta.z %s\n" : "    sta.a %s\n", formatted);
         else
            emit(&es_code, dst->is_zeropage ? "    sta.z %s + %d\n" : "    sta.a %s + %d\n", formatted, dst->offset);
      }
      return true;
   }

   if (!dst->indirect && !dst->needs_runtime_address && !dst->is_static &&
       !dst->is_zeropage && !dst->is_global && dst->offset >= 0 &&
       dst->offset <= 255) {
      emit(&es_code, "    lda #$%02x\n", byte_value);
      emit(&es_code, "    ldy #%d\n", dst->offset);
      emit(&es_code, "    sta %s,y\n", compiler_scratch_active_symbol());
      return true;
   }

   if (!emit_prepare_lvalue_ptr(ctx, dst, LVALUE_ACCESS_WRITE)) {
      return false;
   }
   emit(&es_code, "    lda #$%02x\n", byte_value);
   emit(&es_code, "    ldy #0\n");
   emit(&es_code, "    sta (ptr0),y\n");
   return true;
}

//! @brief Copy one byte directly from an lvalue into a write-only/read-write absolute external binding.
//!
//! This avoids allocating a one-byte BSS object merely to bridge an indexed
//! source and a memory-mapped VCS register.
static bool compile_direct_byte_lvalue_to_absolute_ref(Context *ctx,
                                                       const LValueRef *dst,
                                                       ASTNode *rhs) {
   LValueRef src;

   if (!dst || !dst->is_absolute_ref || dst->is_bitfield || dst->size != 1 ||
       dst->indirect || dst->needs_runtime_address ||
       !dst->write_expr || !*dst->write_expr ||
       !resolve_ref_argument_lvalue(ctx, rhs, &src) || src.is_bitfield ||
       src.size != 1) {
      return false;
   }

   if (src.is_absolute_ref && src.read_expr && *src.read_expr &&
       !src.indirect && !src.needs_runtime_address) {
      emit_load_a_from_expr_address(src.read_expr, src.offset);
   }
   else {
      if (!emit_prepare_lvalue_ptr(ctx, &src, LVALUE_ACCESS_READ)) {
         return false;
      }
      emit(&es_code, "    ldy #0\n");
      emit(&es_code, "    lda (ptr0),y\n");
   }
   emit_store_a_to_expr_address(dst->write_expr, dst->offset);
   return true;
}

//! @brief Store a fixed assignment value into a simple absolute external binding without pointer setup.
static bool emit_fixed_assignment_value_to_lvalue(Context *ctx, const LValueRef *dst,
                                                  const char *symbol, int size) {
   return emit_copy_preserved_symbol_to_lvalue(ctx, dst, symbol, size);
}

//! @brief Lower a discarded one-byte increment/decrement without result scratch.
static bool compile_discarded_byte_incdec(Context *ctx, ASTNode *expr) {
   LValueRef lv;
   ContextEntry entry;
   const char *op;
   bool increment;
   char symbol[256];
   bool bcd;

   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || strcmp(expr->name, "lvalue") || expr->count < 3 ||
       !expr->children[2] || expr->children[2]->kind != AST_IDENTIFIER) {
      return false;
   }
   op = expr->children[2]->strval;
   if (!op || (strcmp(op, "pre++") && strcmp(op, "post++") &&
               strcmp(op, "pre--") && strcmp(op, "post--"))) {
      return false;
   }
   increment = !strcmp(op, "pre++") || !strcmp(op, "post++");
   if (!resolve_lvalue(ctx, expr, &lv) || lv.size != 1 || lv.is_bitfield) {
      return false;
   }
   emit_lvalue_semantic_use(ctx, &lv, "read");
   emit_lvalue_semantic_use(ctx, &lv, "write");
   bcd = type_is_bcd_integer(lv.type);

   if (lv.is_absolute_ref) {
      if (!lv.read_expr || !lv.write_expr || strcmp(lv.read_expr, lv.write_expr)) {
         return false;
      }
      emit_load_a_from_expr_address(lv.read_expr, lv.offset);
      if (bcd) emit(&es_code, "    sed\n");
      emit(&es_code, increment ? "    clc\n    adc #1\n" : "    sec\n    sbc #1\n");
      if (bcd) emit(&es_code, "    cld\n");
      emit_store_a_to_expr_address(lv.write_expr, lv.offset);
      return true;
   }

   if (!lv.indirect && !lv.needs_runtime_address &&
       (lv.is_static || lv.is_zeropage || lv.is_global)) {
      entry = (ContextEntry){ .name = lv.name, .type = lv.type,
         .declarator = lv.declarator, .is_static = lv.is_static,
         .is_zeropage = lv.is_zeropage, .is_global = lv.is_global,
         .offset = lv.offset, .size = lv.size };
      if (!entry_symbol_name(ctx, &entry, symbol, sizeof(symbol))) {
         return false;
      }
      {
         char expr_buf[256];
         const char *formatted = assembler_address_expr(symbol, expr_buf, sizeof(expr_buf));
         if (lv.offset == 0)
            emit(&es_code, lv.is_zeropage ? "    lda.z %s\n" : "    lda.a %s\n", formatted);
         else
            emit(&es_code, lv.is_zeropage ? "    lda.z %s + %d\n" : "    lda.a %s + %d\n", formatted, lv.offset);
         if (bcd) emit(&es_code, "    sed\n");
         emit(&es_code, increment ? "    clc\n    adc #1\n" : "    sec\n    sbc #1\n");
         if (bcd) emit(&es_code, "    cld\n");
         if (lv.offset == 0)
            emit(&es_code, lv.is_zeropage ? "    sta.z %s\n" : "    sta.a %s\n", formatted);
         else
            emit(&es_code, lv.is_zeropage ? "    sta.z %s + %d\n" : "    sta.a %s + %d\n", formatted, lv.offset);
      }
      return true;
   }

   if (!lv.indirect && !lv.needs_runtime_address && !lv.is_static &&
       !lv.is_zeropage && !lv.is_global && lv.offset >= 0 && lv.offset <= 255) {
      emit(&es_code, "    ldy #%d\n", lv.offset);
      emit(&es_code, "    lda %s,y\n", compiler_scratch_active_symbol());
      if (bcd) emit(&es_code, "    sed\n");
      emit(&es_code, increment ? "    clc\n    adc #1\n" : "    sec\n    sbc #1\n");
      if (bcd) emit(&es_code, "    cld\n");
      emit(&es_code, "    sta %s,y\n", compiler_scratch_active_symbol());
      return true;
   }

   if (!emit_prepare_lvalue_ptr(ctx, &lv, LVALUE_ACCESS_READ)) {
      return false;
   }
   emit(&es_code, "    ldy #0\n");
   emit(&es_code, "    lda (ptr0),y\n");
   if (bcd) emit(&es_code, "    sed\n");
   emit(&es_code, increment ? "    clc\n    adc #1\n" : "    sec\n    sbc #1\n");
   if (bcd) emit(&es_code, "    cld\n");
   emit(&es_code, "    sta (ptr0),y\n");
   return true;
}

#define DIRECT_BYTE_ASSIGN_CHAIN_MAX 64

//! @brief Return whether one assignment in a direct byte chain preserves A unchanged.
static bool direct_byte_assignment_preserves_a(const LValueRef *dst,
                                               const ASTNode *src_type,
                                               const ASTNode *src_declarator,
                                               ASTNode *rhs) {
   if (!dst || dst->size != 1 || dst->is_bitfield || dst->indirect ||
       dst->needs_runtime_address || declarator_pointer_depth(dst->declarator) > 0) {
      return false;
   }
   if (!(dst->is_absolute_ref || dst->is_static || dst->is_zeropage || dst->is_global)) {
      return false;
   }
   if (dst->is_absolute_ref && (!dst->write_expr || !*dst->write_expr)) {
      return false;
   }
   return bcd_implicit_conversion_allowed(dst->type, dst->declarator,
                                          src_type, src_declarator, rhs);
}

//! @brief Lower a discarded right-associated byte assignment chain through A.
//!
//! Stores run from the innermost target outward, and every accepted conversion
//! is a one-byte representation-preserving conversion.  STA therefore forwards
//! the assigned value for the next target without any compiler scratch or Y
//! traffic.
static bool compile_discarded_direct_byte_assignment_chain(Context *ctx,
                                                            ASTNode *node) {
   LValueRef targets[DIRECT_BYTE_ASSIGN_CHAIN_MAX];
   ASTNode *assignments[DIRECT_BYTE_ASSIGN_CHAIN_MAX];
   ASTNode *cursor = (ASTNode *) unwrap_expr_node(node);
   ASTNode *rhs;
   LValueRef source;
   InitConstValue constant = {0};
   unsigned char encoded = 0;
   const ASTNode *src_type = NULL;
   const ASTNode *src_declarator = NULL;
   int count = 0;
   bool source_is_lvalue = false;

   while (cursor && !strcmp(cursor->name, "assign_expr") && cursor->count == 3) {
      const char *op = cursor->children[0] ? cursor->children[0]->strval : NULL;
      ASTNode *next_rhs = cursor->children[2];

      if ((op && strcmp(op, ":=")) || initializer_is_list(unwrap_expr_node(next_rhs)) ||
          count >= DIRECT_BYTE_ASSIGN_CHAIN_MAX ||
          !resolve_lvalue(ctx, cursor->children[1], &targets[count])) {
         return false;
      }
      assignments[count++] = cursor;
      cursor = (ASTNode *) unwrap_expr_node(next_rhs);
   }

   if (count < 2 || !cursor) {
      return false;
   }
   rhs = cursor;

   if (eval_constant_initializer_expr(rhs, &constant) && constant.kind == INIT_CONST_INT &&
       integer_value_fits_type(constant.i, targets[count - 1].type) &&
       encode_integer_initializer_value(constant.i, &encoded, 1,
                                        targets[count - 1].type)) {
      src_type = literal_annotation_type(rhs);
      src_declarator = NULL;
   }
   else if (resolve_ref_argument_lvalue(ctx, rhs, &source) && source.size == 1 &&
            !source.is_bitfield && !source.indirect && !source.needs_runtime_address &&
            (source.is_absolute_ref || source.is_static || source.is_zeropage ||
             source.is_global) &&
            (!source.is_absolute_ref || (source.read_expr && *source.read_expr))) {
      source_is_lvalue = true;
      src_type = source.type;
      src_declarator = source.declarator;
   }
   else {
      return false;
   }

   for (int i = count - 1; i >= 0; i--) {
      if (!direct_byte_assignment_preserves_a(&targets[i], src_type, src_declarator,
                                              i == count - 1 ? rhs : assignments[i + 1])) {
         return false;
      }
      src_type = targets[i].type;
      src_declarator = targets[i].declarator;
   }

   if (source_is_lvalue) {
      emit_lvalue_semantic_use(ctx, &source, "read");
      if (!emit_load_direct_byte_lvalue_to_a(ctx, &source)) {
         return false;
      }
   }
   else {
      emit(&es_code, "    lda #$%02x\n", encoded);
   }

   for (int i = count - 1; i >= 0; i--) {
      emit_lvalue_semantic_use(ctx, &targets[i], "write");
      if (!emit_store_a_to_direct_byte_lvalue(ctx, &targets[i])) {
         return false;
      }
   }
   return true;
}

//! @brief Lower a discarded simple assignment chain through one shared scratch value.
static bool compile_discarded_simple_assignment_chain(Context *ctx, ASTNode *node) {
   LValueRef targets[DIRECT_BYTE_ASSIGN_CHAIN_MAX];
   ASTNode *assignments[DIRECT_BYTE_ASSIGN_CHAIN_MAX];
   ASTNode *cursor = (ASTNode *) unwrap_expr_node(node);
   ASTNode *rhs;
   int sizes[DIRECT_BYTE_ASSIGN_CHAIN_MAX];
   int count = 0;
   int max_size = 0;
   int current_size;
   const ASTNode *current_type;
   FlowFixedScratch scratch;
   ContextEntry value;

   while (cursor && !strcmp(cursor->name, "assign_expr") && cursor->count == 3) {
      const char *op = cursor->children[0] ? cursor->children[0]->strval : NULL;
      ASTNode *next_rhs = cursor->children[2];
      int value_size;

      if ((op && strcmp(op, ":=")) || initializer_is_list(unwrap_expr_node(next_rhs)) ||
          count >= DIRECT_BYTE_ASSIGN_CHAIN_MAX ||
          !resolve_lvalue(ctx, cursor->children[1], &targets[count]) ||
          targets[count].is_bitfield) {
         return false;
      }
      if (targets[count].is_absolute_ref &&
          (!targets[count].write_expr || !*targets[count].write_expr)) {
         error_user("[%s:%d.%d] absolute external binding '%s' is read-only",
                    cursor->file ? cursor->file : "<unknown>", cursor->line,
                    cursor->column,
                    targets[count].name ? targets[count].name : "<unnamed>");
      }
      value_size = targets[count].size;
      if (value_size <= 0) {
         value_size = declarator_storage_size(targets[count].type,
                                               targets[count].declarator);
      }
      if (value_size <= 0) {
         value_size = type_size_from_node(targets[count].type);
      }
      if (value_size <= 0) {
         return false;
      }
      sizes[count] = value_size;
      if (value_size > max_size) {
         max_size = value_size;
      }
      assignments[count++] = cursor;
      cursor = (ASTNode *) unwrap_expr_node(next_rhs);
   }

   if (count < 2 || !cursor) {
      return false;
   }
   rhs = cursor;

   for (int i = count - 2; i >= 0; i--) {
      if (!bcd_implicit_conversion_allowed(targets[i].type,
                                           targets[i].declarator,
                                           targets[i + 1].type,
                                           targets[i + 1].declarator,
                                           assignments[i + 1])) {
         error_user("[%s:%d.%d] packed-BCD and binary integer values cannot be mixed implicitly",
                    assignments[i]->file ? assignments[i]->file : "<unknown>",
                    assignments[i]->line, assignments[i]->column);
      }
   }

   flow_fixed_scratch_prepare(ctx, max_size, &scratch);
   flow_fixed_scratch_activate(ctx, &scratch);
   value = (ContextEntry){ .name = "$assign_chain", .type = targets[count - 1].type,
                           .declarator = targets[count - 1].declarator,
                           .is_static = false, .is_zeropage = false,
                           .is_global = false, .target_typed = true,
                           .offset = 0, .size = sizes[count - 1] };
   if (!compile_expr_to_slot(rhs, ctx, &value)) {
      flow_fixed_scratch_abort(ctx, &scratch);
      return false;
   }
   flow_fixed_scratch_deactivate(ctx, &scratch);

   current_size = sizes[count - 1];
   current_type = targets[count - 1].type;
   for (int i = count - 1; i >= 0; i--) {
      if (i != count - 1) {
         flow_fixed_scratch_activate(ctx, &scratch);
         emit_copy_scratch_to_scratch_convert(0, sizes[i], targets[i].type,
                                              0, current_size, current_type);
         flow_fixed_scratch_deactivate(ctx, &scratch);
         current_size = sizes[i];
         current_type = targets[i].type;
      }
      emit_lvalue_semantic_use(ctx, &targets[i], "write");
      if (!emit_fixed_assignment_value_to_lvalue(ctx, &targets[i], scratch.symbol,
                                                 current_size)) {
         flow_fixed_scratch_finish(&scratch);
         return false;
      }
   }

   flow_fixed_scratch_finish(&scratch);
   return true;
}

//! @brief Validate one assignment-from-discard target.
static bool validate_discard_store_lvalue(const ASTNode *site, const LValueRef *lv,
                                          bool *valid) {
   if (valid) {
      *valid = false;
   }
   if (!site || !lv || !valid) {
      return false;
   }
   if (lv->is_absolute_ref && (!lv->write_expr || !*lv->write_expr)) {
      error_user("[%s:%d.%d] absolute external binding '%s' is read-only",
                 site->file, site->line, site->column,
                 lv->name ? lv->name : "<unnamed>");
      return true;
   }
   if (lv->size != 1 || lv->is_bitfield) {
      error_user("[%s:%d.%d] assignment from discard '_' requires a one-byte non-bitfield target",
                 site->file, site->line, site->column);
      return true;
   }
   *valid = true;
   return true;
}

//! @brief Store the current accumulator into one validated discard target while preserving A.
static bool emit_discard_store_lvalue(Context *ctx, const LValueRef *lv) {
   ContextEntry entry;
   char symbol[256];

   if (!ctx || !lv) {
      return false;
   }

   if (lv->is_absolute_ref && !lv->indirect && !lv->needs_runtime_address) {
      emit_lvalue_semantic_use(ctx, lv, "write");
      emit_store_a_to_expr_address(lv->write_expr, lv->offset);
      return true;
   }

   if (!lv->indirect && !lv->needs_runtime_address &&
       (lv->is_static || lv->is_zeropage || lv->is_global)) {
      char expr_buf[256];
      const char *formatted;
      emit_lvalue_semantic_use(ctx, lv, "write");
      entry = (ContextEntry){ .name = lv->name, .type = lv->type,
         .declarator = lv->declarator, .is_static = lv->is_static,
         .is_zeropage = lv->is_zeropage, .is_global = lv->is_global,
         .offset = lv->offset, .size = lv->size };
      if (!entry_symbol_name(ctx, &entry, symbol, sizeof(symbol))) {
         return false;
      }
      formatted = assembler_address_expr(symbol, expr_buf, sizeof(expr_buf));
      if (lv->offset == 0) {
         emit(&es_code, lv->is_zeropage ? "    sta.z %s\n" : "    sta.a %s\n", formatted);
      }
      else {
         emit(&es_code, lv->is_zeropage ? "    sta.z %s + %d\n" : "    sta.a %s + %d\n",
              formatted, lv->offset);
      }
      return true;
   }

   if (!lv->indirect && !lv->needs_runtime_address &&
       !lv->is_static && !lv->is_zeropage && !lv->is_global &&
       lv->offset >= 0 && lv->offset <= 255) {
      emit_lvalue_semantic_use(ctx, lv, "write");
      emit(&es_code, "    ldy #%d\n", lv->offset);
      emit(&es_code, "    sta %s,y\n", compiler_scratch_active_symbol());
      return true;
   }

   if (!emit_prepare_lvalue_ptr(ctx, lv, LVALUE_ACCESS_WRITE)) {
      return false;
   }
   emit(&es_code, "    ldy #0\n");
   emit(&es_code, "    sta (ptr0),y\n");
   return true;
}

//! @brief Return whether discard-store lowering leaves the accumulator unchanged.
static bool discard_store_lvalue_preserves_a(const LValueRef *lv) {
   if (!lv || lv->size != 1 || lv->is_bitfield || lv->indirect ||
       lv->needs_runtime_address) {
      return false;
   }
   if (lv->is_absolute_ref) {
      return lv->write_expr && *lv->write_expr;
   }
   if (lv->is_static || lv->is_zeropage || lv->is_global) {
      return true;
   }
   return lv->offset >= 0 && lv->offset <= 255;
}

//! @brief Store the current accumulator into a one-byte lvalue without producing a source value.
static bool compile_discard_store_assignment(Context *ctx, ASTNode *node) {
   LValueRef lv;
   bool valid;

   if (!node || strcmp(node->name, "discard_store") || node->count != 1 ||
       !resolve_lvalue(ctx, node->children[0], &lv)) {
      return false;
   }
   if (!validate_discard_store_lvalue(node, &lv, &valid)) {
      return false;
   }
   return !valid || emit_discard_store_lvalue(ctx, &lv);
}

//! @brief Lower a right-associated assignment chain whose terminal source is discard '_'.
//!
//! Every target receives the accumulator value that existed on entry. Stores run
//! from the innermost target outward, matching ordinary chained-assignment order,
//! but the terminal discard deliberately produces no expression value.
static bool compile_discard_store_chain(Context *ctx, ASTNode *node) {
   LValueRef targets[DIRECT_BYTE_ASSIGN_CHAIN_MAX];
   ASTNode *sites[DIRECT_BYTE_ASSIGN_CHAIN_MAX];
   ASTNode *cursor = (ASTNode *) unwrap_expr_node(node);
   int count = 0;

   while (cursor && !strcmp(cursor->name, "assign_expr") && cursor->count == 3) {
      const char *op = cursor->children[0] ? cursor->children[0]->strval : NULL;
      ASTNode *next_rhs = cursor->children[2];

      if ((op && strcmp(op, ":=")) ||
          initializer_is_list(unwrap_expr_node(next_rhs)) ||
          count >= DIRECT_BYTE_ASSIGN_CHAIN_MAX - 1 ||
          !resolve_lvalue(ctx, cursor->children[1], &targets[count])) {
         return false;
      }
      sites[count] = cursor;
      count++;
      cursor = (ASTNode *) unwrap_expr_node(next_rhs);
   }

   if (count < 1 || !cursor || strcmp(cursor->name, "discard_store") ||
       cursor->count != 1 ||
       !resolve_lvalue(ctx, cursor->children[0], &targets[count])) {
      return false;
   }
   sites[count] = cursor;
   count++;

   for (int i = 0; i < count; i++) {
      bool valid;
      if (!validate_discard_store_lvalue(sites[i], &targets[i], &valid)) {
         return false;
      }
      if (!valid) {
         return true;
      }
      if (!discard_store_lvalue_preserves_a(&targets[i])) {
         error_user("[%s:%d.%d] chained assignment from discard '_' requires directly addressable one-byte targets",
                    sites[i]->file, sites[i]->line, sites[i]->column);
         return true;
      }
   }
   for (int i = count - 1; i >= 0; i--) {
      if (!emit_discard_store_lvalue(ctx, &targets[i])) {
         return false;
      }
   }
   return true;
}

//! @brief Lower expr from AST/semantic state into generated assembly or linker-visible metadata.
void compile_expr(ASTNode *node, Context *ctx) {
   if (!node || is_empty(node)) {
      return;
   }

   node = (ASTNode *) unwrap_expr_node(node);

   if (expr_is_plain_void_cast(node)) {
      if (node->count > 1) {
         compile_expr(node->children[1], ctx);
      }
      return;
   }

   if (!strcmp(node->name, "discard_result") && node->count == 1) {
      compile_expr(node->children[0], ctx);
      return;
   }

   if (!strcmp(node->name, "discard_store")) {
      if (!compile_discard_store_assignment(ctx, node)) {
         error_user("[%s:%d.%d] invalid discard assignment target",
                    node->file, node->line, node->column);
      }
      return;
   }

   if (!strcmp(node->name, "()")) {
      if (!compile_call_expr_to_slot(node, ctx, NULL)) {
         error_user("[%s:%d.%d] invalid call expression", node->file, node->line, node->column);
      }
      return;
   }

   if (!node || strcmp(node->name, "assign_expr") || node->count != 3) {
      if (compile_discarded_byte_incdec(ctx, node)) {
         return;
      }
      const ASTNode *type = expr_value_type(node, ctx);
      int size = expr_value_size(node, ctx);
      char scratch_sym[96];
      CompilerScratchLease scratch;
      if (size <= 0) {
         size = 1;
      }
      if (!compile_expr_to_fixed_scratch(node, ctx, type, NULL, size,
                                         false, POINTER_ACCESS_READWRITE, scratch_sym,
                                         sizeof(scratch_sym), NULL, &scratch)) {
         error_user("[%s:%d.%d] invalid expression", node->file, node->line, node->column);
         return;
      }
      compiler_scratch_release(&scratch);
      return;
   }

   if (compile_discard_store_chain(ctx, node)) {
      return;
   }
   if (compile_discarded_direct_byte_assignment_chain(ctx, node)) {
      return;
   }
   if (compile_discarded_simple_assignment_chain(ctx, node)) {
      return;
   }

   LValueRef lv;
   ContextEntry dst_store;
   ContextEntry *dst;
   const char *op = node->children[0] ? node->children[0]->strval : NULL;
   ASTNode *rhs = node->children[2];
   ASTNode *urhs = (ASTNode *) unwrap_expr_node(rhs);
   if (!resolve_lvalue(ctx, node->children[1], &lv)) {
      error_unresolved_assignment_target(ctx, node->children[1], node);
      return;
   }
   dst_store = (ContextEntry){ .name = lv.name, .type = lv.type, .declarator = lv.declarator, .is_static = lv.is_static, .is_zeropage = lv.is_zeropage, .is_global = lv.is_global, .is_ref = lv.is_ref, .is_absolute_ref = lv.is_absolute_ref, .read_expr = lv.read_expr, .write_expr = lv.write_expr, .target_typed = true,
      .pointer_access = lv.pointer_access, .offset = lv.offset, .size = lv.size };
   dst = &dst_store;

   if (!op || !strcmp(op, ":=")) {
      emit_lvalue_semantic_use(ctx, &lv, "write");
   }
   else {
      emit_lvalue_semantic_use(ctx, &lv, "read");
      emit_lvalue_semantic_use(ctx, &lv, "write");
   }

   if (lv.is_absolute_ref && (!op || !strcmp(op, ":="))) {
      if (!entry_has_write_address(dst)) {
         error_user("[%s:%d.%d] absolute external binding '%s' is read-only", node->file, node->line, node->column, lv.name ? lv.name : "<unnamed>");
      }
   }
   else if (lv.is_absolute_ref) {
      if (!entry_has_read_address(dst)) {
         error_user("[%s:%d.%d] absolute external binding '%s' is write-only", node->file, node->line, node->column, lv.name ? lv.name : "<unnamed>");
      }
      if (!entry_has_write_address(dst)) {
         error_user("[%s:%d.%d] absolute external binding '%s' is read-only", node->file, node->line, node->column, lv.name ? lv.name : "<unnamed>");
      }
   }

   if ((!op || !strcmp(op, ":=")) && dst->declarator &&
       declarator_pointer_depth(dst->declarator) > 0 &&
       !integer_literal_is_zero_expr(rhs)) {
      const ASTNode *src_type = NULL;
      const ASTNode *src_decl = NULL;
      expr_match_signature(rhs, ctx, &src_type, &src_decl);
      if (src_type && src_decl && declarator_pointer_depth(src_decl) > 0) {
         validate_pointer_access_conversion(rhs, dst->pointer_access,
                                            expr_pointer_access(rhs, ctx),
                                            "assignment");
      }
   }

   if (initializer_is_list(urhs)) {
      if (op && strcmp(op, ":=")) {
         error_user("[%s:%d.%d] braced initializer not valid in compound assignment", urhs->file, urhs->line, urhs->column);
         return;
      }
      compile_braced_assignment_to_lvalue(node, ctx, &lv, dst, rhs);
      return;
   }

   {
      const ASTNode *literal_type = literal_annotation_type(rhs);
      bool constant_without_bcd_type = expr_is_integer_constant_expr(rhs, NULL) &&
                                       (!literal_type || !type_is_bcd_integer(literal_type));
      bool bcd_special_compound = false;
      const ASTNode *rhs_type = NULL;
      const ASTNode *rhs_decl = NULL;

      if (op && type_is_bcd_integer(dst->type) &&
          (!strcmp(op, "*=") || !strcmp(op, "/=") || !strcmp(op, "%="))) {
         bool copy_value;
         long long multiplier;
         bool cheap_multiplier =
            !strcmp(op, "*=") &&
            bcd_cheap_multiplier_constant_expr(rhs, NULL, NULL, NULL) &&
            expr_is_integer_constant_expr(rhs, &multiplier) &&
            integer_value_fits_type(multiplier, dst->type);

         bcd_special_compound =
            classify_trivial_integer_compound(op, dst->type, dst->declarator,
                                              rhs, &copy_value) ||
            bcd_power_of_ten_constant_expr(rhs, NULL) ||
            (!strcmp(op, "%=") && bcd_small_remainder_constant_expr(rhs, NULL)) ||
            cheap_multiplier;
      }

      if (type_is_bcd_integer(dst->type) || !constant_without_bcd_type) {
         rhs_type = expr_value_type(rhs, ctx);
         rhs_decl = expr_value_declarator(rhs, ctx);
      }

      if (type_is_bcd_integer(dst->type) && lv.is_bitfield) {
         error_user("[%s:%d.%d] packed-BCD bitfields are not supported",
                    node->file, node->line, node->column);
      }
      if (!bcd_special_compound &&
          (type_is_bcd_integer(dst->type) || rhs_type) &&
          !bcd_implicit_conversion_allowed(dst->type, dst->declarator,
                                           rhs_type, rhs_decl, rhs)) {
         error_user("[%s:%d.%d] packed-BCD and binary integer values cannot be mixed implicitly",
                    node->file, node->line, node->column);
      }
      if (op && strcmp(op, ":=") &&
          (type_is_bcd_integer(dst->type) || type_is_bcd_integer(rhs_type)) &&
          strcmp(op, "+=") && strcmp(op, "-=") && !bcd_special_compound) {
         error_user("[%s:%d.%d] compound operator '%s' is not supported for packed-BCD values",
                    node->file, node->line, node->column, op);
      }
   }

   if (!op || !strcmp(op, ":=")) {
      if (compile_direct_byte_constant_assignment(ctx, &lv, rhs)) {
         return;
      }
      if (compile_direct_byte_lvalue_to_absolute_ref(ctx, &lv, rhs)) {
         return;
      }
      if (!lv.is_bitfield && !lv.is_absolute_ref && !lv.indirect && !lv.needs_runtime_address && (dst->is_static || dst->is_zeropage || dst->is_global)) {
         char sym[256];
         LValueRef rhs_lv;
         if (!entry_symbol_name(ctx, dst, sym, sizeof(sym))) {
            error_user("[%s:%d.%d] invalid assignment target", node->file, node->line, node->column);
            return;
         }
         if (!assignment_requires_array_decay(ctx, dst, rhs) &&
             !classify_incdec_lvalue_expr(rhs, NULL, NULL) &&
             resolve_ref_argument_lvalue(ctx, rhs, &rhs_lv) && rhs_lv.size == dst->size &&
             !strcmp(type_name_from_node(rhs_lv.type), type_name_from_node(dst->type)) && !rhs_lv.is_bitfield) {
            if (!emit_copy_lvalue_to_symbol(ctx, sym, lv.offset, &rhs_lv, dst->size)) {
               error_user("[%s:%d.%d] invalid assignment value", node->file, node->line, node->column);
            }
            return;
         }
         char scratch_sym[96];
         CompilerScratchLease scratch;
         if (!compile_expr_to_fixed_scratch(rhs, ctx, dst->type, dst->declarator,
                                            dst->size, true, dst->pointer_access,
                                            scratch_sym,
                                            sizeof(scratch_sym), NULL, &scratch)) {
            error_user("[%s:%d.%d] invalid assignment value", node->file, node->line, node->column);
            return;
         }
         emit_copy_symbol_to_symbol_convert_offset(sym, lv.offset, dst->size, dst->type,
                                                   scratch_sym, 0, dst->size, dst->type);
         compiler_scratch_release(&scratch);
         return;
      }
      if (lv.is_bitfield || lv.indirect || lv.needs_runtime_address || lv.is_absolute_ref) {
         int tmp_size = dst->size > 0 ? dst->size : expr_value_size(rhs, ctx);
         char scratch_sym[96];
         CompilerScratchLease scratch;
         if (tmp_size <= 0) {
            tmp_size = 1;
         }
         if (!compile_expr_to_fixed_scratch(rhs, ctx, dst->type, dst->declarator,
                                            tmp_size, true, dst->pointer_access,
                                            scratch_sym,
                                            sizeof(scratch_sym), NULL, &scratch)) {
            error_user("[%s:%d.%d] invalid assignment value", node->file, node->line, node->column);
            return;
         }
         if (!emit_fixed_assignment_value_to_lvalue(ctx, &lv, scratch_sym, tmp_size)) {
            compiler_scratch_release(&scratch);
            error_user("[%s:%d.%d] invalid assignment target", node->file, node->line, node->column);
            return;
         }
         compiler_scratch_release(&scratch);
      }
      else if (!compile_expr_to_slot(rhs, ctx, dst)) {
         error_user("[%s:%d.%d] invalid assignment value", node->file, node->line, node->column);
      }
      return;
   }

   rhs = (ASTNode *) unwrap_expr_node(rhs);
   if (!rhs) {
      error_user("[%s:%d.%d] invalid assignment value", node->file, node->line, node->column);
      return;
   }

   {
      bool copy_value = false;

      if (classify_trivial_integer_compound(op, dst->type, dst->declarator,
                                              rhs, &copy_value)) {
         int value_size = dst->size;
         int result_offset = value_size;
         FlowFixedScratch scratch;

         if (value_size <= 0) {
            error_user("[%s:%d.%d] invalid compound assignment width",
                       node->file, node->line, node->column);
            return;
         }
         flow_fixed_scratch_prepare(ctx, value_size * 2, &scratch);
         if (!emit_copy_lvalue_to_symbol(ctx, scratch.symbol, 0, &lv, value_size)) {
            flow_fixed_scratch_finish(&scratch);
            error_user("[%s:%d.%d] invalid compound assignment target",
                       node->file, node->line, node->column);
            return;
         }
         flow_fixed_scratch_activate(ctx, &scratch);
         if (copy_value) {
            emit_copy_scratch_to_scratch(result_offset, 0, value_size);
         }
         else {
            unsigned char *zeroes = (unsigned char *) calloc(value_size, 1);
            if (!zeroes) {
               error_unreachable("out of memory");
            }
            emit_store_immediate_to_scratch(result_offset, zeroes, value_size);
            free(zeroes);
         }
         flow_fixed_scratch_deactivate(ctx, &scratch);
         if (!emit_copy_symbol_to_lvalue(ctx, &lv, scratch.symbol,
                                         result_offset, value_size)) {
            flow_fixed_scratch_finish(&scratch);
            error_user("[%s:%d.%d] invalid compound assignment target",
                       node->file, node->line, node->column);
            return;
         }
         flow_fixed_scratch_finish(&scratch);
         return;
      }
   }

   if (type_is_bcd_integer(dst->type) &&
       (!strcmp(op, "*=") || !strcmp(op, "/=") || !strcmp(op, "%="))) {
      int decimal_digits;

      if (bcd_power_of_ten_constant_expr(rhs, &decimal_digits)) {
         int value_size = dst->size;
         int result_offset = value_size;
         FlowFixedScratch scratch;

         if (value_size <= 0) {
            error_user("[%s:%d.%d] invalid packed-BCD compound assignment width",
                       node->file, node->line, node->column);
            return;
         }

         flow_fixed_scratch_prepare(ctx, value_size * 2, &scratch);
         if (!emit_copy_lvalue_to_symbol(ctx, scratch.symbol, 0, &lv, value_size)) {
            flow_fixed_scratch_finish(&scratch);
            error_user("[%s:%d.%d] invalid compound assignment target",
                       node->file, node->line, node->column);
            return;
         }
         flow_fixed_scratch_activate(ctx, &scratch);
         emit_bcd_power_of_ten_scratch(op, result_offset, 0, value_size,
                                       decimal_digits);
         flow_fixed_scratch_deactivate(ctx, &scratch);
         if (!emit_copy_symbol_to_lvalue(ctx, &lv, scratch.symbol,
                                         result_offset, value_size)) {
            flow_fixed_scratch_finish(&scratch);
            error_user("[%s:%d.%d] invalid compound assignment target",
                       node->file, node->line, node->column);
            return;
         }
         flow_fixed_scratch_finish(&scratch);
         return;
      }
   }


   if (type_is_bcd_integer(dst->type) && !strcmp(op, "%=")) {
      int divisor;

      if (bcd_small_remainder_constant_expr(rhs, &divisor)) {
         int value_size = dst->size;
         int result_offset = value_size;
         FlowFixedScratch scratch;

         flow_fixed_scratch_prepare(ctx, value_size * 2, &scratch);
         if (!emit_copy_lvalue_to_symbol(ctx, scratch.symbol, 0, &lv, value_size)) {
            flow_fixed_scratch_finish(&scratch);
            error_user("[%s:%d.%d] invalid compound assignment target",
                       node->file, node->line, node->column);
            return;
         }
         flow_fixed_scratch_activate(ctx, &scratch);
         emit_bcd_small_remainder_scratch(result_offset, 0, value_size, divisor);
         flow_fixed_scratch_deactivate(ctx, &scratch);
         if (!emit_copy_symbol_to_lvalue(ctx, &lv, scratch.symbol,
                                         result_offset, value_size)) {
            flow_fixed_scratch_finish(&scratch);
            error_user("[%s:%d.%d] invalid compound assignment target",
                       node->file, node->line, node->column);
            return;
         }
         flow_fixed_scratch_finish(&scratch);
         return;
      }
   }

   if (type_is_bcd_integer(dst->type) && !strcmp(op, "*=")) {
      int power_a;
      int power_b;
      bool subtract;
      long long multiplier;

      if (bcd_cheap_multiplier_constant_expr(rhs, &power_a, &power_b,
                                             &subtract) &&
          expr_is_integer_constant_expr(rhs, &multiplier) &&
          integer_value_fits_type(multiplier, dst->type)) {
         int value_size = dst->size;
         int term_a_offset = value_size;
         int term_b_offset = value_size * 2;
         FlowFixedScratch scratch;

         flow_fixed_scratch_prepare(ctx, value_size * 3, &scratch);
         if (!emit_copy_lvalue_to_symbol(ctx, scratch.symbol, 0, &lv, value_size)) {
            flow_fixed_scratch_finish(&scratch);
            error_user("[%s:%d.%d] invalid compound assignment target",
                       node->file, node->line, node->column);
            return;
         }
         flow_fixed_scratch_activate(ctx, &scratch);
         emit_bcd_power_of_ten_scratch("*", term_a_offset, 0,
                                       value_size, power_a);
         emit_bcd_power_of_ten_scratch("*", term_b_offset, 0,
                                       value_size, power_b);
         if (subtract) {
            emit_sub_scratch_from_scratch(dst->type, term_a_offset,
                                          term_b_offset, value_size);
         }
         else {
            emit_add_scratch_to_scratch(dst->type, term_a_offset,
                                        term_b_offset, value_size);
         }
         flow_fixed_scratch_deactivate(ctx, &scratch);
         if (!emit_copy_symbol_to_lvalue(ctx, &lv, scratch.symbol,
                                         term_a_offset, value_size)) {
            flow_fixed_scratch_finish(&scratch);
            error_user("[%s:%d.%d] invalid compound assignment target",
                       node->file, node->line, node->column);
            return;
         }
         flow_fixed_scratch_finish(&scratch);
         return;
      }
   }

   if (!strcmp(op, "+=") || !strcmp(op, "-=") || !strcmp(op, "&=") || !strcmp(op, "|=") ||
       !strcmp(op, "^=") || !strcmp(op, "*=") || !strcmp(op, "/=") || !strcmp(op, "%=") ||
       !strcmp(op, "<<=") || !strcmp(op, ">>=")) {
      char dst_sym[256];
      bool dst_symbol = !lv.is_bitfield && !lv.indirect && !lv.needs_runtime_address && (dst->is_static || dst->is_zeropage || dst->is_global) && entry_symbol_name(ctx, dst, dst_sym, sizeof(dst_sym));
      bool scaled_pointer_assign = dst->declarator && declarator_pointer_depth(dst->declarator) > 0 && (!strcmp(op, "+=") || !strcmp(op, "-="));
      const ASTNode *rhs_type = expr_value_type(rhs, ctx);
      const ASTNode *work_type = NULL;
      const ASTNode *rhs_slot_type = NULL;
      int work_size = 0;
      int rhs_work_size = 0;
      int tmp_total;
      int lhs_tmp_offset;
      int rhs_tmp_offset;
      int aux_offset;
      int factor_offset = 0;
      int scaled_rhs_offset = 0;
      int rhs_value_offset;
      int store_offset = 0;
      bool need_store_tmp = false;
      int pointer_scale = 1;
      ContextEntry rhs_tmp;
      const char *helper = NULL;
      FlowFixedScratch scratch;

      if (scaled_pointer_assign) {
         work_type = dst->type;
         rhs_slot_type = expr_is_literal_node(rhs) ? work_type : (rhs_type ? rhs_type : work_type);
         work_size = dst->size;
         pointer_scale = declarator_first_element_size(dst->type, dst->declarator);
         if (pointer_scale <= 0) {
            pointer_scale = 1;
         }
      }
      else if (!strcmp(op, "<<=") || !strcmp(op, ">>=")) {
         work_type = dst->type ? dst->type : rhs_type;
         rhs_slot_type = expr_is_literal_node(rhs) ? work_type : (rhs_type ? rhs_type : work_type);
         work_size = work_type ? type_size_from_node(work_type) : 0;
         rhs_work_size = rhs_slot_type ? type_size_from_node(rhs_slot_type) : 0;
      }
      else {
         if (dst->type && rhs_type && type_is_promotable_integer(dst->type) && type_is_promotable_integer(rhs_type) &&
             !expr_is_literal_node(rhs) && type_is_signed_integer(dst->type) != type_is_signed_integer(rhs_type)) {
            error_user("[%s:%d.%d] mixed signed/unsigned ordinary integer operator '%c' requires an explicit cast",
                       node->file, node->line, node->column, op ? op[0] : '?');
         }
         work_type = compound_integer_work_type(dst->type, dst->declarator, rhs, ctx, node);
         if (!work_type) {
            work_type = dst->type ? dst->type : rhs_type;
         }
         rhs_slot_type = work_type;
         work_size = work_type ? type_size_from_node(work_type) : 0;
      }

      if (work_size <= 0) {
         work_size = dst->size;
      }
      if (work_size <= 0) {
         work_size = expr_value_size(rhs, ctx);
      }
      if (work_size <= 0) {
         work_size = 1;
      }
      if (!work_type) {
         work_type = dst->type;
      }
      if (!rhs_slot_type) {
         rhs_slot_type = work_type;
      }
      if (rhs_work_size <= 0) {
         rhs_work_size = rhs_slot_type ? type_size_from_node(rhs_slot_type) : 0;
      }
      if (rhs_work_size <= 0) {
         rhs_work_size = expr_value_size(rhs, ctx);
      }
      if (rhs_work_size <= 0) {
         rhs_work_size = work_size;
      }
      if (rhs_work_size <= 0) {
         rhs_work_size = 1;
      }

      if (!strcmp(op, "<<=") || !strcmp(op, ">>=")) {
         diagnose_constant_shift_count(rhs, work_size * 8);
      }

      tmp_total = work_size + rhs_work_size;
      lhs_tmp_offset = 0;
      rhs_tmp_offset = work_size;
      aux_offset = rhs_tmp_offset + rhs_work_size;
      rhs_value_offset = rhs_tmp_offset;

      if (!strcmp(op, "*=")) {
         tmp_total += work_size;
      }
      else if (!strcmp(op, "/=") || !strcmp(op, "%=")) {
         tmp_total += work_size * 2;
      }
      else if (!strcmp(op, "<<=") || !strcmp(op, ">>=")) {
         tmp_total += work_size;
      }

      if (scaled_pointer_assign && pointer_scale != 1) {
         factor_offset = aux_offset;
         scaled_rhs_offset = factor_offset + work_size;
         rhs_value_offset = scaled_rhs_offset;
         tmp_total += work_size * 2;
      }

      need_store_tmp = true;
      store_offset = tmp_total;
      tmp_total += dst->size;

      rhs_tmp = (ContextEntry){ .name = "$rhs_tmp", .type = rhs_slot_type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = true, .offset = rhs_tmp_offset, .size = rhs_work_size };

      flow_fixed_scratch_prepare(ctx, tmp_total, &scratch);
      if (dst_symbol) {
         emit_copy_symbol_to_symbol_convert_offset(scratch.symbol, lhs_tmp_offset, work_size, work_type,
                                                   dst_sym, lv.offset, dst->size, dst->type);
      }
      else {
         int lhs_src_size = dst->size < work_size ? dst->size : work_size;
         if (!emit_copy_lvalue_to_symbol(ctx, scratch.symbol, lhs_tmp_offset, &lv, lhs_src_size)) {
            flow_fixed_scratch_finish(&scratch);
            error_user("[%s:%d.%d] invalid compound assignment target", node->file, node->line, node->column);
            return;
         }
      }

      flow_fixed_scratch_activate(ctx, &scratch);
      if (!dst_symbol) {
         int lhs_src_size = dst->size < work_size ? dst->size : work_size;
         emit_copy_scratch_to_scratch_convert(lhs_tmp_offset, work_size, work_type, lhs_tmp_offset, lhs_src_size, dst->type);
      }
      if (!compile_expr_to_slot(rhs, ctx, &rhs_tmp)) {
         flow_fixed_scratch_abort(ctx, &scratch);
         error_user("[%s:%d.%d] invalid assignment value", node->file, node->line, node->column);
         return;
      }

      if (scaled_pointer_assign && pointer_scale != 1) {
         unsigned char *factor_bytes = (unsigned char *) calloc(work_size ? work_size : 1, sizeof(unsigned char));
         char scaled_buf[64];
         const ASTNode *factor_type = rhs_slot_type ? rhs_slot_type : work_type;
         if (!factor_bytes) {
            flow_fixed_scratch_abort(ctx, &scratch);
            return;
         }
         snprintf(scaled_buf, sizeof(scaled_buf), "%d", pointer_scale);
         make_le_int(scaled_buf, factor_bytes, work_size);
         emit_store_immediate_to_scratch(factor_offset, factor_bytes, work_size);
         free(factor_bytes);
         emit_runtime_binary_scratch(int_mul_helper_name(factor_type ? factor_type : work_type), scaled_rhs_offset, rhs_tmp_offset, factor_offset, work_size);
         rhs_value_offset = int_mul_result_offset(factor_type ? factor_type : work_type, scaled_rhs_offset, work_size);
      }

      if (!strcmp(op, "+=")) {
         emit_add_scratch_to_scratch(work_type, lhs_tmp_offset, rhs_value_offset, work_size);
      }
      else if (!strcmp(op, "-=")) {
         emit_sub_scratch_from_scratch(work_type, lhs_tmp_offset, rhs_value_offset, work_size);
      }
      else if (!strcmp(op, "&=")) {
         emit_fixed_bitwise_scratch("and", lhs_tmp_offset, lhs_tmp_offset, rhs_tmp_offset, work_size);
      }
      else if (!strcmp(op, "|=")) {
         emit_fixed_bitwise_scratch("ora", lhs_tmp_offset, lhs_tmp_offset, rhs_tmp_offset, work_size);
      }
      else if (!strcmp(op, "^=")) {
         emit_fixed_bitwise_scratch("eor", lhs_tmp_offset, lhs_tmp_offset, rhs_tmp_offset, work_size);
      }
      else if (!strcmp(op, "*=")) {
         emit_runtime_binary_scratch(int_mul_helper_name(work_type), aux_offset, lhs_tmp_offset, rhs_tmp_offset, work_size);
         emit_copy_scratch_to_scratch(lhs_tmp_offset, int_mul_result_offset(work_type, aux_offset, work_size), work_size);
      }
      else if (!strcmp(op, "/=") || !strcmp(op, "%=")) {
         int quo_offset = aux_offset;
         int rem_offset = aux_offset + work_size;
         diagnose_runtime_power_of_two_divisor(node, rhs, op);
         emit_prepare_scratch_ptr(0, lhs_tmp_offset);
         emit_prepare_scratch_ptr(1, rhs_tmp_offset);
         emit_prepare_scratch_ptr(2, quo_offset);
         (void) rem_offset;
         remember_runtime_import(int_div_helper_name(work_type));
         emit(&es_code, "    jsr _%s\n", int_div_helper_name(work_type));
         emit_copy_scratch_to_scratch(lhs_tmp_offset, !strcmp(op, "/=") ? quo_offset : rem_offset, work_size);
      }
      else if (!strcmp(op, "<<=") || !strcmp(op, ">>=")) {
         helper = int_shift_helper_name(work_type, !strcmp(op, "<<="));
         emit_fixed_shift_scratch(helper, lhs_tmp_offset, aux_offset, rhs_tmp_offset, rhs_slot_type, rhs_work_size, work_size);
         emit_copy_scratch_to_scratch(lhs_tmp_offset, aux_offset, work_size);
      }
      else {
         flow_fixed_scratch_abort(ctx, &scratch);
         error_user("[%s:%d.%d] unsupported compound assignment operator '%s'", node->file, node->line, node->column, op);
         return;
      }

      if (need_store_tmp) {
         emit_copy_scratch_to_scratch_convert(store_offset, dst->size, dst->type, lhs_tmp_offset, work_size, work_type);
      }
      flow_fixed_scratch_deactivate(ctx, &scratch);
      if (dst_symbol) {
         emit_copy_symbol_to_symbol_convert_offset(dst_sym, lv.offset, dst->size, dst->type,
                                                   scratch.symbol, store_offset, dst->size, dst->type);
      }
      else if (!emit_copy_symbol_to_lvalue(ctx, &lv, scratch.symbol, store_offset, dst->size)) {
         flow_fixed_scratch_finish(&scratch);
         error_user("[%s:%d.%d] invalid compound assignment target", node->file, node->line, node->column);
         return;
      }
      flow_fixed_scratch_finish(&scratch);
      return;
   }

   error_user("[%s:%d.%d] unsupported assignment operator '%s'", node->file, node->line, node->column, op ? op : "?");
}


