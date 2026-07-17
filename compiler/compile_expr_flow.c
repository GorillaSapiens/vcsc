//! @file compiler/compile_expr_flow.c
//! @brief Implements control-flow expression lowering for the n65 compiler.
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

static const ASTNode *expr_lvalue_base_identifier_node(ASTNode *expr);

typedef struct FlowFixedScratch {
   int saved_locals;
   int saved_high_water;
   int reserved;
   char symbol[96];
} FlowFixedScratch;

//! @brief Save the current frame pointer on the 6502 hardware stack.
static void emit_expr_scratch_save_fp(void) {
   emit(&es_code, "    lda fp+1\n");
   emit(&es_code, "    pha\n");
   emit(&es_code, "    lda fp\n");
   emit(&es_code, "    pha\n");
}

//! @brief Point fp at a fixed compiler-generated expression scratch symbol.
static void emit_expr_scratch_set_fp(const char *symbol) {
   emit(&es_code, "    lda #<%s\n", symbol);
   emit(&es_code, "    sta fp\n");
   emit(&es_code, "    lda #>%s\n", symbol);
   emit(&es_code, "    sta fp+1\n");
}

//! @brief Restore the frame pointer from the 6502 hardware stack.
static void emit_expr_scratch_restore_fp(void) {
   emit(&es_code, "    pla\n");
   emit(&es_code, "    sta fp\n");
   emit(&es_code, "    pla\n");
   emit(&es_code, "    sta fp+1\n");
}

//! @brief Prepare one fixed-address flow-expression working area without changing fp.
static void flow_fixed_scratch_prepare(Context *ctx, const char *prefix, int reserved,
                                       FlowFixedScratch *scratch) {
   memset(scratch, 0, sizeof(*scratch));
   scratch->saved_locals = ctx ? ctx->locals : 0;
   scratch->saved_high_water = ctx ? ctx->locals_high_water : 0;
   scratch->reserved = reserved > 0 ? reserved : 1;
   snprintf(scratch->symbol, sizeof(scratch->symbol), "__n65_%s_%d", prefix, label_counter++);
}

//! @brief Redirect fp to a prepared fixed-address flow-expression working area.
static void flow_fixed_scratch_activate(Context *ctx, FlowFixedScratch *scratch) {
   if (ctx) {
      ctx->locals = scratch->reserved;
      ctx->locals_high_water = scratch->reserved;
   }
   emit_expr_scratch_save_fp();
   emit_expr_scratch_set_fp(scratch->symbol);
}

//! @brief Restore fp, restore compiler frame accounting, and declare fixed scratch.
static void flow_fixed_scratch_end(Context *ctx, FlowFixedScratch *scratch) {
   int used = scratch->reserved;
   if (ctx && ctx->locals_high_water > used) {
      used = ctx->locals_high_water;
   }
   emit_expr_scratch_restore_fp();
   if (ctx) {
      ctx->locals = scratch->saved_locals;
      ctx->locals_high_water = scratch->saved_high_water;
   }
   emit(&es_bss, ".segment \"BSS\"\n");
   emit(&es_bss, "%s:\n", scratch->symbol);
   emit(&es_bss, "\t.res %d\n", used > 0 ? used : 1);
}

//! @brief Evaluate an expression in fixed BSS scratch and restore the caller frame.
static bool compile_expr_to_fixed_scratch(ASTNode *expr, Context *ctx,
                                          const ASTNode *type,
                                          const ASTNode *declarator,
                                          int size,
                                          bool target_typed,
                                          const char *prefix,
                                          char *symbol,
                                          size_t symbol_size,
                                          int *allocated_size) {
   int saved_locals = ctx ? ctx->locals : 0;
   int saved_high_water = ctx ? ctx->locals_high_water : 0;
   int used = size;
   bool ok;
   ContextEntry tmp;

   if (!expr || !prefix || !symbol || symbol_size == 0 || size <= 0) {
      return false;
   }

   snprintf(symbol, symbol_size, "__n65_%s_%d", prefix, label_counter++);
   memset(&tmp, 0, sizeof(tmp));
   tmp.name = "$fixedtmp";
   tmp.type = type;
   tmp.declarator = declarator;
   tmp.target_typed = target_typed;
   tmp.offset = 0;
   tmp.size = size;

   if (ctx) {
      ctx->locals = size;
      ctx->locals_high_water = size;
   }

   emit_expr_scratch_save_fp();
   emit_expr_scratch_set_fp(symbol);
   ok = compile_expr_to_slot(expr, ctx, &tmp);
   if (ctx && ctx->locals_high_water > used) {
      used = ctx->locals_high_water;
   }
   emit_expr_scratch_restore_fp();

   if (ctx) {
      ctx->locals = saved_locals;
      ctx->locals_high_water = saved_high_water;
   }

   if (used <= 0) {
      used = 1;
   }
   emit(&es_bss, ".segment \"BSS\"\n");
   emit(&es_bss, "%s:\n", symbol);
   emit(&es_bss, "\t.res %d\n", used);
   if (allocated_size) {
      *allocated_size = used;
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
static void emit_zero_assignment_initializer_fp_target(int offset, int size) {
   if (size <= 0) {
      return;
   }
   emit_fill_fp_bytes(offset, 0, size, 0x00);
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
      bool dst_direct_fp = !lv->is_bitfield && !lv->indirect && !lv->needs_runtime_address &&
                           !lv->is_absolute_ref && !dst->is_static && !dst->is_zeropage && !dst->is_global;

      flow_fixed_scratch_prepare(ctx, "bracedtmp", size, &scratch);
      flow_fixed_scratch_activate(ctx, &scratch);

      emit_zero_assignment_initializer_fp_target(tmp_offset, size);
      if (!compile_initializer_to_fp(rhs, ctx, dst->type, dst->declarator, tmp_offset, size)) {
         flow_fixed_scratch_end(ctx, &scratch);
         error_user("[%s:%d.%d] invalid assignment initializer", node->file, node->line, node->column);
         return false;
      }

      flow_fixed_scratch_end(ctx, &scratch);
      if (dst_symbol) {
         emit_copy_symbol_to_symbol_convert_offset(sym, lv->offset, size, dst->type,
                                                   scratch.symbol, tmp_offset, size, dst->type);
      }
      else if (dst_direct_fp) {
         emit_copy_symbol_to_fp_convert_offset(dst->offset, size, dst->type,
                                               scratch.symbol, tmp_offset, size, dst->type);
      }
      else if (!emit_copy_symbol_to_lvalue(ctx, lv, scratch.symbol, tmp_offset, size)) {
         error_user("[%s:%d.%d] invalid assignment target", node->file, node->line, node->column);
         return false;
      }

      return true;
   }
}

//! @brief Lower truthy expression branch false from AST/semantic state into generated assembly or linker-visible metadata.
static bool compile_truthy_expr_branch_false(ASTNode *expr, Context *ctx,
                                             const ASTNode *type,
                                             const ASTNode *declarator,
                                             int size,
                                             const char *false_label) {
   char scratch_sym[96];

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
                                      declarator != NULL, "truthtmp", scratch_sym,
                                      sizeof(scratch_sym), NULL)) {
      return false;
   }

   emit(&es_code, "    lda #0\n");
   for (int i = 0; i < size; i++) {
      emit(&es_code, "    ldy #%d\n", i);
      emit(&es_code, "    ora %s,y\n", scratch_sym);
   }
   emit(&es_code, "    beq %s\n", false_label);
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

   if (expr->count == 2 &&
       (!strcmp(expr->name, "==") || !strcmp(expr->name, "!=") ||
        !strcmp(expr->name, "<")  || !strcmp(expr->name, ">")  ||
        !strcmp(expr->name, "<=") || !strcmp(expr->name, ">="))) {
      const ASTNode *lhs_type = expr_value_type(expr->children[0], ctx);
      const ASTNode *rhs_type = expr_value_type(expr->children[1], ctx);
      const ASTNode *type = NULL;
      int size;
      int compare_size;
      int saved_locals = ctx ? ctx->locals : 0;
      int saved_high_water = ctx ? ctx->locals_high_water : 0;
      int scratch_size;
      char scratch_sym[96];
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
      scratch_size = compare_size;
      snprintf(scratch_sym, sizeof(scratch_sym), "__n65_comparetmp_%d", label_counter++);
      lhs = (ContextEntry){ .name = "$lhs", .type = type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = true, .offset = 0, .size = size };
      rhs = (ContextEntry){ .name = "$rhs", .type = type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .target_typed = true, .offset = size, .size = size };
      if (ctx) {
         ctx->locals = compare_size;
         ctx->locals_high_water = compare_size;
      }
      emit_expr_scratch_save_fp();
      emit_expr_scratch_set_fp(scratch_sym);
      ok = compile_expr_to_slot(expr->children[0], ctx, &lhs) &&
           compile_expr_to_slot(expr->children[1], ctx, &rhs);
      if (ctx && ctx->locals_high_water > scratch_size) {
         scratch_size = ctx->locals_high_water;
      }
      if (!ok) {
         emit_expr_scratch_restore_fp();
         if (ctx) {
            ctx->locals = saved_locals;
            ctx->locals_high_water = saved_high_water;
         }
         emit(&es_bss, ".segment \"BSS\"\n");
         emit(&es_bss, "%s:\n", scratch_sym);
         emit(&es_bss, "\t.res %d\n", scratch_size > 0 ? scratch_size : 1);
         return false;
      }

      if (!strcmp(expr->name, "==")) {
         helper = "eqN";
      }
      else if (!strcmp(expr->name, "!=")) {
         helper = "eqN";
         invert = true;
      }
      else if (!strcmp(expr->name, "<")) {
         helper = int_compare_helper_name(type, expr->name);
      }
      else if (!strcmp(expr->name, ">")) {
         helper = int_compare_helper_name(type, expr->name);
         ContextEntry t = lhs; lhs = rhs; rhs = t;
      }
      else if (!strcmp(expr->name, "<=")) {
         helper = int_compare_helper_name(type, expr->name);
      }
      else if (!strcmp(expr->name, ">=")) {
         helper = int_compare_helper_name(type, expr->name);
         ContextEntry t = lhs; lhs = rhs; rhs = t;
      }

      emit_prepare_fp_ptr(0, lhs.offset);
      emit_prepare_fp_ptr(1, rhs.offset);
      emit(&es_code, "    lda #$%02x\n", size & 0xff);
      emit(&es_code, "    sta arg0\n");
      remember_runtime_import(helper);
      emit(&es_code, "    jsr _%s\n", helper);
      emit_expr_scratch_restore_fp();
      if (ctx) {
         ctx->locals = saved_locals;
         ctx->locals_high_water = saved_high_water;
      }
      emit(&es_bss, ".segment \"BSS\"\n");
      emit(&es_bss, "%s:\n", scratch_sym);
      emit(&es_bss, "\t.res %d\n", scratch_size > 0 ? scratch_size : 1);
      emit(&es_code, "    lda arg1\n");
      emit(&es_code, "    %s %s\n", invert ? "bne" : "beq", false_label);
      return true;
   }

   {
      const ASTNode *type = expr_value_type(expr, ctx);
      int size = expr_value_size(expr, ctx);
      return compile_truthy_expr_branch_false(expr, ctx, type, NULL, size, false_label);
   }
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

   if (!strcmp(node->name, "()")) {
      if (!compile_call_expr_to_slot(node, ctx, NULL)) {
         error_user("[%s:%d.%d] invalid call expression", node->file, node->line, node->column);
      }
      return;
   }

   if (!node || strcmp(node->name, "assign_expr") || node->count != 3) {
      const ASTNode *type = expr_value_type(node, ctx);
      int size = expr_value_size(node, ctx);
      char scratch_sym[96];
      if (size <= 0) {
         size = 1;
      }
      if (!compile_expr_to_fixed_scratch(node, ctx, type, NULL, size,
                                         false, "discardtmp", scratch_sym,
                                         sizeof(scratch_sym), NULL)) {
         error_user("[%s:%d.%d] invalid expression", node->file, node->line, node->column);
         return;
      }
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
   dst_store = (ContextEntry){ .name = lv.name, .type = lv.type, .declarator = lv.declarator, .is_static = lv.is_static, .is_zeropage = lv.is_zeropage, .is_global = lv.is_global, .is_ref = lv.is_ref, .is_absolute_ref = lv.is_absolute_ref, .read_expr = lv.read_expr, .write_expr = lv.write_expr, .target_typed = true, .offset = lv.offset, .size = lv.size };
   dst = &dst_store;

   if (lv.is_absolute_ref && (!op || !strcmp(op, ":="))) {
      if (!entry_has_write_address(dst)) {
         error_user("[%s:%d.%d] absolute ref '%s' is read-only", node->file, node->line, node->column, lv.name ? lv.name : "<unnamed>");
      }
   }
   else if (lv.is_absolute_ref) {
      if (!entry_has_read_address(dst)) {
         error_user("[%s:%d.%d] absolute ref '%s' is write-only", node->file, node->line, node->column, lv.name ? lv.name : "<unnamed>");
      }
      if (!entry_has_write_address(dst)) {
         error_user("[%s:%d.%d] absolute ref '%s' is read-only", node->file, node->line, node->column, lv.name ? lv.name : "<unnamed>");
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

   if (!op || !strcmp(op, ":=")) {
      if (!lv.is_bitfield && !lv.is_absolute_ref && !lv.indirect && !lv.needs_runtime_address && (dst->is_static || dst->is_zeropage || dst->is_global)) {
         char sym[256];
         LValueRef rhs_lv;
         if (!entry_symbol_name(ctx, dst, sym, sizeof(sym))) {
            error_user("[%s:%d.%d] invalid assignment target", node->file, node->line, node->column);
            return;
         }
         if (resolve_ref_argument_lvalue(ctx, rhs, &rhs_lv) && rhs_lv.size == dst->size && !strcmp(type_name_from_node(rhs_lv.type), type_name_from_node(dst->type)) && !rhs_lv.is_bitfield) {
            if (!emit_copy_lvalue_to_symbol(ctx, sym, lv.offset, &rhs_lv, dst->size)) {
               error_user("[%s:%d.%d] invalid assignment value", node->file, node->line, node->column);
            }
            return;
         }
         char scratch_sym[96];
         if (!compile_expr_to_fixed_scratch(rhs, ctx, dst->type, dst->declarator,
                                            dst->size, true, "assigntmp", scratch_sym,
                                            sizeof(scratch_sym), NULL)) {
            error_user("[%s:%d.%d] invalid assignment value", node->file, node->line, node->column);
            return;
         }
         emit_expr_scratch_save_fp();
         emit_expr_scratch_set_fp(scratch_sym);
         emit_copy_fp_to_symbol_offset(sym, lv.offset, 0, dst->size);
         emit_expr_scratch_restore_fp();
         return;
      }
      if (lv.is_bitfield || lv.indirect || lv.needs_runtime_address || lv.is_absolute_ref) {
         int tmp_size = dst->size > 0 ? dst->size : expr_value_size(rhs, ctx);
         char scratch_sym[96];
         if (tmp_size <= 0) {
            tmp_size = 1;
         }
         if (!compile_expr_to_fixed_scratch(rhs, ctx, dst->type, dst->declarator,
                                            tmp_size, true, "lvalueassigntmp", scratch_sym,
                                            sizeof(scratch_sym), NULL)) {
            error_user("[%s:%d.%d] invalid assignment value", node->file, node->line, node->column);
            return;
         }
         if (!emit_copy_symbol_to_lvalue(ctx, &lv, scratch_sym, 0, tmp_size)) {
            error_user("[%s:%d.%d] invalid assignment target", node->file, node->line, node->column);
            return;
         }
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
             !type_is_bool(dst->type) && !type_is_bool(rhs_type) &&
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

      if (!strcmp(op, "*=") || !strcmp(op, "/=") || !strcmp(op, "%=")) {
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

      flow_fixed_scratch_prepare(ctx, "compoundtmp", tmp_total, &scratch);
      if (dst_symbol) {
         emit_copy_symbol_to_symbol_convert_offset(scratch.symbol, lhs_tmp_offset, work_size, work_type,
                                                   dst_sym, lv.offset, dst->size, dst->type);
      }
      else {
         int lhs_src_size = dst->size < work_size ? dst->size : work_size;
         if (!emit_copy_lvalue_to_symbol(ctx, scratch.symbol, lhs_tmp_offset, &lv, lhs_src_size)) {
            error_user("[%s:%d.%d] invalid compound assignment target", node->file, node->line, node->column);
            return;
         }
      }

      flow_fixed_scratch_activate(ctx, &scratch);
      if (!dst_symbol) {
         int lhs_src_size = dst->size < work_size ? dst->size : work_size;
         emit_copy_fp_to_fp_convert(lhs_tmp_offset, work_size, work_type, lhs_tmp_offset, lhs_src_size, dst->type);
      }
      if (!compile_expr_to_slot(rhs, ctx, &rhs_tmp)) {
         flow_fixed_scratch_end(ctx, &scratch);
         error_user("[%s:%d.%d] invalid assignment value", node->file, node->line, node->column);
         return;
      }

      if (scaled_pointer_assign && pointer_scale != 1) {
         unsigned char *factor_bytes = (unsigned char *) calloc(work_size ? work_size : 1, sizeof(unsigned char));
         char scaled_buf[64];
         const ASTNode *factor_type = rhs_slot_type ? rhs_slot_type : work_type;
         if (!factor_bytes) {
            flow_fixed_scratch_end(ctx, &scratch);
            return;
         }
         snprintf(scaled_buf, sizeof(scaled_buf), "%d", pointer_scale);
         make_le_int(scaled_buf, factor_bytes, work_size);
         emit_store_immediate_to_fp(factor_offset, factor_bytes, work_size);
         free(factor_bytes);
         emit_runtime_binary_fp_fp(int_mul_helper_name(factor_type ? factor_type : work_type), scaled_rhs_offset, rhs_tmp_offset, factor_offset, work_size);
         rhs_value_offset = int_mul_result_offset(factor_type ? factor_type : work_type, scaled_rhs_offset, work_size);
      }

      if (!strcmp(op, "+=")) {
         emit_add_fp_to_fp(work_type, lhs_tmp_offset, rhs_value_offset, work_size);
      }
      else if (!strcmp(op, "-=")) {
         emit_sub_fp_from_fp(work_type, lhs_tmp_offset, rhs_value_offset, work_size);
      }
      else if (!strcmp(op, "&=")) {
         emit_runtime_binary_fp_fp("bit_andN", lhs_tmp_offset, lhs_tmp_offset, rhs_tmp_offset, work_size);
      }
      else if (!strcmp(op, "|=")) {
         emit_runtime_binary_fp_fp("bit_orN", lhs_tmp_offset, lhs_tmp_offset, rhs_tmp_offset, work_size);
      }
      else if (!strcmp(op, "^=")) {
         emit_runtime_binary_fp_fp("bit_xorN", lhs_tmp_offset, lhs_tmp_offset, rhs_tmp_offset, work_size);
      }
      else if (!strcmp(op, "*=")) {
         emit_runtime_binary_fp_fp(int_mul_helper_name(work_type), aux_offset, lhs_tmp_offset, rhs_tmp_offset, work_size);
         emit_copy_fp_to_fp(lhs_tmp_offset, int_mul_result_offset(work_type, aux_offset, work_size), work_size);
      }
      else if (!strcmp(op, "/=") || !strcmp(op, "%=")) {
         int quo_offset = aux_offset;
         int rem_offset = aux_offset + work_size;
         emit_prepare_fp_ptr(0, lhs_tmp_offset);
         emit_prepare_fp_ptr(1, rhs_tmp_offset);
         emit_prepare_fp_ptr(2, quo_offset);
         emit_prepare_fp_ptr(3, rem_offset);
         emit(&es_code, "    lda #$%02x\n", work_size & 0xff);
         emit(&es_code, "    sta arg0\n");
         remember_runtime_import(int_div_helper_name(work_type));
         emit(&es_code, "    jsr _%s\n", int_div_helper_name(work_type));
         emit_copy_fp_to_fp(lhs_tmp_offset, !strcmp(op, "/=") ? quo_offset : rem_offset, work_size);
      }
      else if (!strcmp(op, "<<=") || !strcmp(op, ">>=")) {
         helper = int_shift_helper_name(work_type, !strcmp(op, "<<="));
         emit_runtime_shift_fp(helper, lhs_tmp_offset, aux_offset, rhs_tmp_offset, rhs_slot_type, rhs_work_size, work_size);
         emit_copy_fp_to_fp(lhs_tmp_offset, aux_offset, work_size);
      }
      else {
         flow_fixed_scratch_end(ctx, &scratch);
         error_user("[%s:%d.%d] unsupported compound assignment operator '%s'", node->file, node->line, node->column, op);
         return;
      }

      if (need_store_tmp) {
         emit_copy_fp_to_fp_convert(store_offset, dst->size, dst->type, lhs_tmp_offset, work_size, work_type);
      }
      flow_fixed_scratch_end(ctx, &scratch);
      if (dst_symbol) {
         emit_copy_symbol_to_symbol_convert_offset(dst_sym, lv.offset, dst->size, dst->type,
                                                   scratch.symbol, store_offset, dst->size, dst->type);
      }
      else if (!emit_copy_symbol_to_lvalue(ctx, &lv, scratch.symbol, store_offset, dst->size)) {
         error_user("[%s:%d.%d] invalid compound assignment target", node->file, node->line, node->column);
         return;
      }
      return;
   }

   error_user("[%s:%d.%d] unsupported assignment operator '%s'", node->file, node->line, node->column, op ? op : "?");
}


