//! @file compiler/compile_stmt.c
//! @brief Implements statement lowering for the VCSC compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>

#include "ast.h"
#include "abi_meta.h"
#include "compile.h"
#include "compile_init.h"
#include "compile_expr_flow.h"
#include "compile_expr_info.h"
#include "compile_function.h"
#include "compile_function_registry.h"
#include "compile_internal.h"
#include "compile_support.h"
#include "compile_lvalue.h"
#include "compile_stmt.h"
#include "compile_type.h"
#include "emit.h"
#include "messages.h"
#include "pair.h"
#include "set.h"
#include "typename.h"
#include "xray.h"
#include "lextern.h"

void emit_mem_region_metadata_for_modifiers(const ASTNode *origin, const ASTNode *modifiers);

static const char *loop_break_stack[128];
static const char *loop_continue_stack[128];
static int loop_depth = 0;
static const char *named_loop_names[128];
static const char *named_loop_break_stack[128];
static const char *named_loop_continue_stack[128];
static int named_loop_depth = 0;
static const char *pending_loop_label_name = NULL;

void statement_compile_state_push(StatementCompileState *saved) {
   if (!saved) {
      return;
   }
   saved->loop_depth = loop_depth;
   saved->named_loop_depth = named_loop_depth;
   saved->pending_loop_label_name = pending_loop_label_name;
   loop_depth = 0;
   named_loop_depth = 0;
   pending_loop_label_name = NULL;
}

void statement_compile_state_pop(const StatementCompileState *saved) {
   if (!saved) {
      return;
   }
   if (loop_depth != 0 || named_loop_depth != 0 || pending_loop_label_name != NULL) {
      error_unreachable("unbalanced statement-control state while lowering inline function");
   }
   loop_depth = saved->loop_depth;
   named_loop_depth = saved->named_loop_depth;
   pending_loop_label_name = saved->pending_loop_label_name;
}

typedef CompilerScratchLease StmtFixedScratch;

//! @brief Prepare one reusable fixed-address statement working area.
static void stmt_fixed_scratch_prepare(Context *ctx, int reserved,
                                       StmtFixedScratch *scratch) {
   compiler_scratch_acquire(ctx, reserved, scratch);
}

//! @brief Activate a prepared fixed-address statement working area.
static void stmt_fixed_scratch_activate(Context *ctx, StmtFixedScratch *scratch) {
   compiler_scratch_activate(ctx, scratch);
}

//! @brief Deactivate a reusable statement scratch area after one use.
static void stmt_fixed_scratch_deactivate(Context *ctx, StmtFixedScratch *scratch) {
   compiler_scratch_deactivate(ctx, scratch);
}

//! @brief Declare the maximum fixed storage required by a statement scratch area.
static void stmt_fixed_scratch_finish(StmtFixedScratch *scratch) {
   compiler_scratch_release(scratch);
}

static void predeclare_local_decl_item(ASTNode *node, Context *ctx);
static void compile_local_decl_item(ASTNode *node, Context *ctx);
static bool compile_runtime_initializer_to_symbol(ASTNode *expression, Context *ctx,
      const ASTNode *type, const ASTNode *declarator,
      PointerAccessQualifier pointer_access, const char *symbol, int size);
static bool compile_expr_to_return_object(ASTNode *expr, Context *ctx, ContextEntry *ret);
static void compile_if_stmt(ASTNode *node, Context *ctx);
static void compile_while_stmt(ASTNode *node, Context *ctx);
static void compile_for_stmt(ASTNode *node, Context *ctx);
static void compile_break_stmt(ASTNode *node, Context *ctx);
static void compile_continue_stmt(ASTNode *node, Context *ctx);
static void compile_do_stmt(ASTNode *node, Context *ctx);
static void compile_label_stmt(ASTNode *node, Context *ctx);
static void compile_goto_stmt(ASTNode *node, Context *ctx);
static void compile_switch_stmt(ASTNode *node, Context *ctx);
static void compile_return_stmt(ASTNode *node, Context *ctx);
static void compile_asm_stmt(ASTNode *node, Context *ctx);

static void format_context_local_label(const Context *ctx, const char *base,
                                       char *buf, size_t bufsize) {
   if (!buf || bufsize == 0) {
      return;
   }
   if (ctx && ctx->inline_label_prefix && *ctx->inline_label_prefix) {
      snprintf(buf, bufsize, "@%s_%s", ctx->inline_label_prefix, base ? base : "");
   }
   else {
      snprintf(buf, bufsize, "@%s", base ? base : "");
   }
}

//! @brief Return decl subitem declarator data used by compiler statement lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *decl_subitem_declarator(const ASTNode *node) {
   if (!node) {
      return NULL;
   }
   if (strcmp(node->name, "decl_subitem") || node->count <= 0) {
      return node;
   }
   return node->children[0];
}

//! @brief Return decl subitem address spec data used by compiler statement lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *decl_subitem_address_spec(const ASTNode *node) {
   if (!node || strcmp(node->name, "decl_subitem") || node->count <= 1) {
      return NULL;
   }
   return node->children[1];
}

//! @brief Return decl node declarator data used by compiler statement lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *stmt_decl_node_declarator(const ASTNode *node) {
   if (!node || node->count < 3) {
      return NULL;
   }
   return decl_subitem_declarator(node->children[2]);
}

//! @brief Return decl node address spec data used by compiler statement lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *decl_node_address_spec(const ASTNode *node) {
   if (!node || node->count < 3) {
      return NULL;
   }
   return decl_subitem_address_spec(node->children[2]);
}

//! @brief Return address spec read expr data used by compiler statement lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *address_spec_read_expr(const ASTNode *node) {
   if (!node || is_empty(node)) {
      return NULL;
   }
   if (!strcmp(node->name, "rw_addr_spec")) {
      return (node->count > 0 && node->children[0] && !is_empty(node->children[0])) ? node->children[0]->strval : NULL;
   }
   return node->strval;
}

//! @brief Return address spec write expr data used by compiler statement lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *address_spec_write_expr(const ASTNode *node) {
   if (!node || is_empty(node)) {
      return NULL;
   }
   if (!strcmp(node->name, "rw_addr_spec")) {
      return (node->count > 1 && node->children[1] && !is_empty(node->children[1])) ? node->children[1]->strval : NULL;
   }
   return node->strval;
}

//! @brief Return whether address spec has read in compiler statement lowering.
static bool address_spec_has_read(const ASTNode *node) {
   return address_spec_read_expr(node) != NULL;
}

//! @brief Return whether address spec has write in compiler statement lowering.
static bool address_spec_has_write(const ASTNode *node) {
   return address_spec_write_expr(node) != NULL;
}

//! @brief Reject the legacy object-level ref spelling now reserved for parameters.
static void diagnose_ref_object_modifier(const ASTNode *node, const char *name) {
   if (!node) {
      error_unreachable("internal error: !node in %s %s:%d\n",
         __func__, __FILE__, __LINE__);
      return;
   }
   error_user("[%s:%d.%d] 'ref' applies only to function parameters; absolute external binding '%s' must use '@[read/write]' without 'ref'",
      node->file, node->line, node->column, name ? name : "?");
}

//! @brief Add loop labels to compiler statement lowering state, growing storage or preserving uniqueness as needed.
static void push_loop_labels(const char *break_label, const char *continue_label) {
   if (loop_depth < (int)(sizeof(loop_break_stack) / sizeof(loop_break_stack[0]))) {
      loop_break_stack[loop_depth] = break_label;
      loop_continue_stack[loop_depth] = continue_label;
      loop_depth++;
   }
}

//! @brief Handle pop loop labels logic for compiler statement lowering.
static void pop_loop_labels(void) {
   if (loop_depth > 0) {
      loop_depth--;
      loop_break_stack[loop_depth] = NULL;
      loop_continue_stack[loop_depth] = NULL;
   }
}

//! @brief Return current break label data used by compiler statement lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *current_break_label(void) {
   return loop_depth > 0 ? loop_break_stack[loop_depth - 1] : NULL;
}

//! @brief Return current continue label data used by compiler statement lowering; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *current_continue_label(void) {
   return loop_depth > 0 ? loop_continue_stack[loop_depth - 1] : NULL;
}

//! @brief Add named loop labels to compiler statement lowering state, growing storage or preserving uniqueness as needed.
static void push_named_loop_labels(const char *name, const char *break_label, const char *continue_label) {
   if (!name) {
      return;
   }
   if (named_loop_depth < (int)(sizeof(named_loop_names) / sizeof(named_loop_names[0]))) {
      named_loop_names[named_loop_depth] = name;
      named_loop_break_stack[named_loop_depth] = break_label;
      named_loop_continue_stack[named_loop_depth] = continue_label;
      named_loop_depth++;
   }
}

//! @brief Handle pop named loop labels logic for compiler statement lowering.
static void pop_named_loop_labels(void) {
   if (named_loop_depth > 0) {
      named_loop_depth--;
      named_loop_names[named_loop_depth] = NULL;
      named_loop_break_stack[named_loop_depth] = NULL;
      named_loop_continue_stack[named_loop_depth] = NULL;
   }
}

//! @brief Find named break label in compiler statement lowering tables without transferring ownership.
static const char *lookup_named_break_label(const char *name) {
   if (!name) {
      return NULL;
   }
   for (int i = named_loop_depth - 1; i >= 0; i--) {
      if (named_loop_names[i] && !strcmp(named_loop_names[i], name)) {
         return named_loop_break_stack[i];
      }
   }
   return NULL;
}

//! @brief Find named continue label in compiler statement lowering tables without transferring ownership.
static const char *lookup_named_continue_label(const char *name) {
   if (!name) {
      return NULL;
   }
   for (int i = named_loop_depth - 1; i >= 0; i--) {
      if (named_loop_names[i] && !strcmp(named_loop_names[i], name)) {
         return named_loop_continue_stack[i];
      }
   }
   return NULL;
}

//! @brief Return whether an lvalue carries one direct subscript suffix.
static bool stmt_lvalue_has_direct_subscript(ASTNode *expr) {
   ASTNode *suffix;

   expr = (ASTNode *)unwrap_expr_node(expr);
   if (!expr || strcmp(expr->name, "lvalue") || expr->count < 2) return false;
   suffix = expr->children[1];
   return suffix && !strcmp(suffix->name, "[") && suffix->count >= 2 &&
      is_empty(suffix->children[0]);
}

//! @brief Return whether one global array declaration guarantees a low-byte-zero base.
static bool global_array_guarantees_page_base(const ASTNode *g) {
   const ASTNode *modifiers;
   const ASTNode *declarator;
   unsigned int alignment = 0;
   int size;

   if (!g || g->count < 3 || !(modifiers = g->children[0])) return false;
   if (declaration_alignment(modifiers, &alignment) && alignment >= 256) return true;
   if (!has_modifier((ASTNode *)modifiers, "page")) return false;
   declarator = decl_node_declarator(g);
   if (!declarator) return false;
   size = declarator_storage_size(g->children[1], declarator);
   return size == 256;
}

//! @brief Return whether one direct assignment selects a guaranteed page-aligned array base.
static bool classify_page_pointer_base_assignment(ASTNode *stmt, Context *ctx,
                                                  const char **target_name_out) {
   const char *op;
   LValueRef dst;
   LValueRef src;
   ASTNode *rhs;
   const ASTNode *g;
   const ASTNode *modifiers;

   if (!stmt || strcmp(stmt->name, "assign_expr") || stmt->count != 3 ||
       !(op = stmt->children[0] ? stmt->children[0]->strval : NULL) || strcmp(op, ":=") ||
       !resolve_lvalue(ctx, stmt->children[1], &dst) || dst.is_bitfield || dst.indirect ||
       dst.needs_runtime_address || dst.is_absolute_ref || dst.size != 2 ||
       declarator_pointer_depth(dst.declarator) != 1) {
      return false;
   }
   rhs = (ASTNode *)unwrap_expr_node(stmt->children[2]);
   if (!rhs || strcmp(rhs->name, "lvalue") || stmt_lvalue_has_direct_subscript(rhs) ||
       !resolve_ref_argument_lvalue(ctx, rhs, &src) || !src.name || !src.is_global ||
       src.is_ref || src.is_absolute_ref || src.indirect || src.needs_runtime_address ||
       src.base_offset != 0 || declarator_pointer_depth(src.declarator) != 0 ||
       declarator_array_count(src.declarator) <= 0) {
      return false;
   }
   g = global_decl_lookup(src.name);
   if (!g || g->count < 3 || !(modifiers = g->children[0]) ||
       !global_array_guarantees_page_base(g)) {
      return false;
   }
   if (target_name_out) *target_name_out = dst.name;
   return dst.name != NULL;
}

enum { MAX_COMPACT_PAGE_SELECTOR_ARMS = 8 };

typedef struct {
   LValueRef selector;
   bool selector_set;
   LValueRef target;
   bool target_set;
   unsigned char limits[MAX_COMPACT_PAGE_SELECTOR_ARMS];
   const char *pages[MAX_COMPACT_PAGE_SELECTOR_ARMS + 1];
   int arm_count;
   const char *target_name;
} CompactPageSelector;

//! @brief Return one page-array source name from a selector leaf assignment.
static bool classify_page_pointer_leaf(ASTNode *stmt, Context *ctx,
                                       const char **target_name_out,
                                       const char **page_name_out,
                                       LValueRef *target_out) {
   LValueRef dst;
   LValueRef src;
   ASTNode *rhs;

   while (stmt && !strcmp(stmt->name, "statement_list") && stmt->count == 1)
      stmt = stmt->children[0];
   if (!classify_page_pointer_base_assignment(stmt, ctx, target_name_out)) return false;
   if (!resolve_lvalue(ctx, stmt->children[1], &dst)) return false;
   rhs = (ASTNode *)unwrap_expr_node(stmt->children[2]);
   if (!rhs || !resolve_ref_argument_lvalue(ctx, rhs, &src) || !src.name ||
       src.base_offset != 0) {
      return false;
   }
   if (page_name_out) *page_name_out = src.name;
   if (target_out) *target_out = dst;
   return true;
}

//! @brief Recognize an unsigned-byte "same selector < constant" page-choice condition.
static bool classify_compact_page_condition(ASTNode *expr, Context *ctx,
                                            CompactPageSelector *sel,
                                            unsigned char *limit_out) {
   LValueRef lv;
   InitConstValue value = {0};
   unsigned char encoded = 0;

   expr = (ASTNode *)unwrap_expr_node(expr);
   if (!expr || expr->count != 2 || strcmp(expr->name, "<") ||
       !resolve_lvalue(ctx, expr->children[0], &lv) || lv.is_bitfield || lv.indirect ||
       lv.needs_runtime_address || lv.is_absolute_ref || lv.size != 1 ||
       type_is_signed_integer(lv.type) || type_is_bcd_integer(lv.type) ||
       !eval_constant_initializer_expr(expr->children[1], &value) ||
       value.kind != INIT_CONST_INT ||
       !integer_value_fits_type(value.i, lv.type) ||
       !encode_integer_initializer_value(value.i, &encoded, 1, lv.type)) {
      return false;
   }

   if (!sel->selector_set) {
      sel->selector = lv;
      sel->selector_set = true;
   }
   else if (!sel->selector.name || !lv.name || strcmp(sel->selector.name, lv.name) ||
            sel->selector.offset != lv.offset || sel->selector.base_offset != lv.base_offset ||
            sel->selector.is_global != lv.is_global || sel->selector.is_static != lv.is_static ||
            sel->selector.is_zeropage != lv.is_zeropage) {
      return false;
   }
   if (limit_out) *limit_out = encoded;
   return true;
}

//! @brief Flatten a nested if/else page selector into ordered threshold/page arms.
static bool collect_compact_page_selector(ASTNode *stmt, Context *ctx,
                                          CompactPageSelector *sel) {
   const char *target = NULL;
   const char *page = NULL;

   if (!stmt || !sel) return false;
   if (!strcmp(stmt->name, "statement_list")) {
      if (stmt->count != 1) return false;
      return collect_compact_page_selector(stmt->children[0], ctx, sel);
   }
   if (!strcmp(stmt->name, "assign_expr")) {
      LValueRef dst;
      if (!classify_page_pointer_leaf(stmt, ctx, &target, &page, &dst) || !target || !page) {
         return false;
      }
      if (sel->target_name && strcmp(sel->target_name, target)) return false;
      sel->target_name = target;
      if (!sel->target_set) {
         sel->target = dst;
         sel->target_set = true;
      }
      sel->pages[sel->arm_count] = page;
      return true;
   }
   if (strcmp(stmt->name, "if_stmt") || stmt->count < 3 ||
       !stmt->children[1] || !stmt->children[2] || is_empty(stmt->children[2]) ||
       sel->arm_count >= MAX_COMPACT_PAGE_SELECTOR_ARMS) {
      return false;
   }
   if (!classify_compact_page_condition(stmt->children[0], ctx, sel,
                                        &sel->limits[sel->arm_count]) ||
       !classify_page_pointer_leaf(stmt->children[1], ctx, &target, &page, NULL) ||
       !target || !page || (sel->target_name && strcmp(sel->target_name, target))) {
      return false;
   }
   sel->target_name = target;
   sel->pages[sel->arm_count] = page;
   sel->arm_count++;
   return collect_compact_page_selector(stmt->children[2], ctx, sel);
}

//! @brief Emit one compact hard-page selector while preserving the page-low zero fact.
static bool compile_compact_page_pointer_selector(ASTNode *stmt, Context *ctx,
                                                  const char *expected_target) {
   CompactPageSelector sel = {0};
   ContextEntry dst_entry;
   char selector_symbol[256];
   char selector_buf[256];
   char dst_symbol[256];
   char dst_buf[256];
   const char *selector_fmt;
   const char *dst_fmt;
   const char *store_label;
   const char *leaf_labels[MAX_COMPACT_PAGE_SELECTOR_ARMS] = {0};

   if (!collect_compact_page_selector(stmt, ctx, &sel) || !sel.selector_set || !sel.target_set ||
       sel.arm_count <= 0 || !sel.target_name ||
       (expected_target && strcmp(expected_target, sel.target_name))) {
      return false;
   }
   {
      ContextEntry selector_entry = {
         .name = sel.selector.name, .type = sel.selector.type,
         .declarator = sel.selector.declarator, .is_static = sel.selector.is_static,
         .is_zeropage = sel.selector.is_zeropage, .is_global = sel.selector.is_global,
         .offset = sel.selector.offset, .size = sel.selector.size
      };
      if (!entry_symbol_name(ctx, &selector_entry, selector_symbol, sizeof(selector_symbol))) {
         return false;
      }
   }
   dst_entry = (ContextEntry){
      .name = sel.target.name, .type = sel.target.type, .declarator = sel.target.declarator,
      .is_static = sel.target.is_static, .is_zeropage = sel.target.is_zeropage,
      .is_global = sel.target.is_global, .offset = sel.target.offset, .size = sel.target.size
   };
   if (!entry_symbol_name(ctx, &dst_entry, dst_symbol, sizeof(dst_symbol))) return false;
   selector_fmt = assembler_address_expr(selector_symbol, selector_buf, sizeof(selector_buf));
   dst_fmt = assembler_address_expr(dst_symbol, dst_buf, sizeof(dst_buf));
   store_label = next_label("page_select_store");
   if (!store_label) return false;
   for (int i = 0; i < sel.arm_count; i++) {
      leaf_labels[i] = next_label("page_select_leaf");
      if (!leaf_labels[i]) {
         for (int j = 0; j < i; j++) free((void *)leaf_labels[j]);
         free((void *)store_label);
         return false;
      }
   }

   emit_lvalue_semantic_use(ctx, &sel.selector, "read");
   if (sel.selector.offset == 0) emit(&es_code, "    lda %s\n", selector_fmt);
   else emit(&es_code, "    lda %s + %d\n", selector_fmt, sel.selector.offset);
   for (int i = 0; i < sel.arm_count; i++) {
      emit(&es_code, "    cmp #$%02x\n", (unsigned int)sel.limits[i]);
      emit(&es_code, "    bcc %s\n", leaf_labels[i]);
   }
   emit(&es_code, "    lda #>{%s + 0}\n", sel.pages[sel.arm_count]);
   emit(&es_code, "    jmp %s\n", store_label);
   for (int i = 0; i < sel.arm_count; i++) {
      emit(&es_code, "%s:\n", leaf_labels[i]);
      emit(&es_code, "    lda #>{%s + 0}\n", sel.pages[i]);
      if (i + 1 < sel.arm_count) emit(&es_code, "    jmp %s\n", store_label);
   }
   emit(&es_code, "%s:\n", store_label);
   emit_lvalue_semantic_use(ctx, &sel.target, "write");
   emit(&es_code, "    sta %s + 1\n", dst_fmt);

   for (int i = 0; i < sel.arm_count; i++) free((void *)leaf_labels[i]);
   free((void *)store_label);
   return true;
}

//! @brief Prove every path through a structured selector assigns the same pointer from a page base.
static bool classify_page_pointer_selector(ASTNode *stmt, Context *ctx,
                                           const char **target_name_out) {
   const char *then_name = NULL;
   const char *else_name = NULL;

   if (!stmt) return false;
   if (!strcmp(stmt->name, "statement_list")) {
      if (stmt->count != 1) return false;
      return classify_page_pointer_selector(stmt->children[0], ctx, target_name_out);
   }
   if (!strcmp(stmt->name, "assign_expr")) {
      return classify_page_pointer_base_assignment(stmt, ctx, target_name_out);
   }
   if (strcmp(stmt->name, "if_stmt") || stmt->count < 3 ||
       !stmt->children[1] || !stmt->children[2] || is_empty(stmt->children[2])) {
      return false;
   }
   if (!classify_page_pointer_selector(stmt->children[1], ctx, &then_name) ||
       !classify_page_pointer_selector(stmt->children[2], ctx, &else_name) ||
       !then_name || !else_name || strcmp(then_name, else_name)) {
      return false;
   }
   if (target_name_out) *target_name_out = then_name;
   return true;
}

//! @brief Return whether a statement is a compatible byte-pointer update for one tracked pointer.
static bool classify_tracked_pointer_u8_update(ASTNode *stmt, Context *ctx,
                                               const char *target_name) {
   const char *op;
   LValueRef dst;
   int rhs_min = 0;
   int rhs_max = 255;

   if (!stmt || !target_name || strcmp(stmt->name, "assign_expr") || stmt->count != 3 ||
       !(op = stmt->children[0] ? stmt->children[0]->strval : NULL) || strcmp(op, "+=") ||
       !resolve_lvalue(ctx, stmt->children[1], &dst) || !dst.name || strcmp(dst.name, target_name) ||
       dst.is_bitfield || dst.indirect || dst.needs_runtime_address || dst.is_absolute_ref ||
       dst.size != 2 || declarator_pointer_depth(dst.declarator) != 1 ||
       declarator_first_element_size(dst.type, dst.declarator) != 1 ||
       !direct_u8_expr_range(ctx, stmt->children[2], &rhs_min, &rhs_max)) {
      return false;
   }
   return rhs_min >= 0 && rhs_max <= 255;
}

//! @brief Return the sole executable statement in a simple branch block.
static ASTNode *single_branch_statement(ASTNode *block) {
   while (block && !strcmp(block->name, "statement_list")) {
      if (block->count != 1) return NULL;
      block = block->children[0];
   }
   return block;
}

//! @brief Prove both arms of an if are byte updates of the same tracked pointer.
static bool classify_tracked_pointer_u8_conditional_update(ASTNode *stmt, Context *ctx,
                                                           const char *target_name) {
   ASTNode *then_stmt;
   ASTNode *else_stmt;

   if (!stmt || !target_name || strcmp(stmt->name, "if_stmt") || stmt->count < 3 ||
       !stmt->children[2] || is_empty(stmt->children[2])) return false;
   then_stmt = single_branch_statement(stmt->children[1]);
   else_stmt = single_branch_statement(stmt->children[2]);
   return then_stmt && else_stmt &&
      classify_tracked_pointer_u8_update(then_stmt, ctx, target_name) &&
      classify_tracked_pointer_u8_update(else_stmt, ctx, target_name);
}

static void clear_pointer_low_range_fact(Context *ctx);

//! @brief Lower a no-carry conditional byte-pointer update with one shared add/store suffix.
static bool compile_compact_pointer_u8_conditional_update(ASTNode *node, Context *ctx) {
   ASTNode *then_stmt;
   ASTNode *else_stmt;
   LValueRef dst;
   ContextEntry entry;
   char symbol[256];
   char addr_buf[256];
   const char *formatted;
   const char *false_label;
   const char *join_label;
   int then_min = 0, then_max = 255;
   int else_min = 0, else_max = 255;
   int base_min;
   int base_max;

   if (!ctx || !ctx->pointer_low_range_known || !ctx->pointer_low_range_name ||
       !classify_tracked_pointer_u8_conditional_update(node, ctx,
                                                      ctx->pointer_low_range_name)) {
      return false;
   }
   then_stmt = single_branch_statement(node->children[1]);
   else_stmt = single_branch_statement(node->children[2]);
   if (!then_stmt || !else_stmt ||
       !direct_u8_expr_range(ctx, then_stmt->children[2], &then_min, &then_max) ||
       !direct_u8_expr_range(ctx, else_stmt->children[2], &else_min, &else_max)) {
      return false;
   }
   base_min = ctx->pointer_low_range_min;
   base_max = ctx->pointer_low_range_max;
   if (base_max + then_max > 255 || base_max + else_max > 255 ||
       !resolve_lvalue(ctx, then_stmt->children[1], &dst) || dst.is_bitfield ||
       dst.indirect || dst.needs_runtime_address || dst.is_absolute_ref) {
      return false;
   }
   entry = (ContextEntry){ .name = dst.name, .type = dst.type,
      .declarator = dst.declarator, .is_static = dst.is_static,
      .is_zeropage = dst.is_zeropage, .is_global = dst.is_global,
      .offset = dst.offset, .size = dst.size };
   if (!entry_symbol_name(ctx, &entry, symbol, sizeof(symbol))) return false;
   formatted = assembler_address_expr(symbol, addr_buf, sizeof(addr_buf));
   false_label = next_label("ptr_cond_false");
   join_label = next_label("ptr_cond_value");
   if (!false_label || !join_label) {
      free((void *)false_label);
      free((void *)join_label);
      return false;
   }

   if (!compile_condition_branch_false(node->children[0], ctx, false_label) ||
       !compile_direct_u8_expr_to_a(ctx, then_stmt->children[2])) {
      free((void *)false_label);
      free((void *)join_label);
      return false;
   }
   emit(&es_code, "    jmp %s\n", join_label);
   emit(&es_code, "%s:\n", false_label);
   if (!compile_direct_u8_expr_to_a(ctx, else_stmt->children[2])) {
      free((void *)false_label);
      free((void *)join_label);
      return false;
   }
   emit(&es_code, "%s:\n", join_label);
   emit_lvalue_semantic_use(ctx, &dst, "read");
   emit_lvalue_semantic_use(ctx, &dst, "write");
   emit(&es_code, "    clc\n");
   emit(&es_code, "    adc %s + %d\n", formatted, dst.offset);
   emit(&es_code, "    sta %s + %d\n", formatted, dst.offset);
   ctx->pointer_low_range_min = base_min + (then_min < else_min ? then_min : else_min);
   ctx->pointer_low_range_max = base_max + (then_max > else_max ? then_max : else_max);
   ctx->pointer_low_range_known = true;
   free((void *)false_label);
   free((void *)join_label);
   return true;
}

typedef struct {
   const char *name;
   int mask;
   int shift;
} U8MaskedShift;

//! @brief Recognize one byte expression as a masked value shifted left by a constant.
static bool classify_u8_masked_shift(ASTNode *expr, Context *ctx, U8MaskedShift *out) {
   long long shift = 0;
   long long mask = 0xff;
   ASTNode *value;
   ASTNode *mask_expr;
   const char *name;

   expr = (ASTNode *)unwrap_expr_node(expr);
   if (!expr || !out || !direct_u8_expr_range(ctx, expr, NULL, NULL)) return false;
   if (expr->count == 2 && !strcmp(expr->name, "<<")) {
      if (!expr_is_integer_constant_expr(expr->children[1], &shift) || shift < 0 || shift > 7)
         return false;
      expr = (ASTNode *)unwrap_expr_node(expr->children[0]);
   }
   if (expr && expr->count == 2 && !strcmp(expr->name, "&")) {
      value = expr->children[0];
      mask_expr = expr->children[1];
      if (!expr_is_integer_constant_expr(mask_expr, &mask)) {
         value = expr->children[1];
         mask_expr = expr->children[0];
         if (!expr_is_integer_constant_expr(mask_expr, &mask)) return false;
      }
      if (mask < 0 || mask > 255) return false;
   }
   else {
      value = expr;
   }
   name = expr_bare_identifier_name((ASTNode *)unwrap_expr_node(value));
   if (!name) return false;
   out->name = name;
   out->mask = (int)mask;
   out->shift = (int)shift;
   return true;
}

//! @brief Prove rhs_new is exactly twice rhs_old modulo one byte for every input value.
static bool u8_expr_is_double_mod256(ASTNode *old_expr, ASTNode *new_expr,
                                     Context *ctx, const char **name_out) {
   U8MaskedShift oldv;
   U8MaskedShift newv;

   if (!classify_u8_masked_shift(old_expr, ctx, &oldv) ||
       !classify_u8_masked_shift(new_expr, ctx, &newv) ||
       strcmp(oldv.name, newv.name)) return false;
   for (int x = 0; x < 256; x++) {
      unsigned int a = ((unsigned int)(x & oldv.mask) << oldv.shift) & 0xffu;
      unsigned int b = ((unsigned int)(x & newv.mask) << newv.shift) & 0xffu;
      if (b != ((a << 1) & 0xffu)) return false;
   }
   if (name_out) *name_out = oldv.name;
   return true;
}

//! @brief Compare simple expression trees used as duplicated selector conditions.
static bool simple_expr_same(ASTNode *a, ASTNode *b) {
   long long av, bv;
   const char *an;
   const char *bn;

   a = (ASTNode *)unwrap_expr_node(a);
   b = (ASTNode *)unwrap_expr_node(b);
   if (!a || !b) return a == b;
   an = expr_bare_identifier_name(a);
   bn = expr_bare_identifier_name(b);
   if (an || bn) return an && bn && !strcmp(an, bn);
   if (expr_is_integer_constant_expr(a, &av) && expr_is_integer_constant_expr(b, &bv))
      return av == bv;
   if (strcmp(a->name, b->name) || a->count != b->count) return false;
   for (int i = 0; i < a->count; i++) {
      if (!simple_expr_same(a->children[i], b->children[i])) return false;
   }
   return true;
}

//! @brief Prove two pointer-update statements compute byte offsets related by x2 modulo 256.
static bool pointer_update_is_double(ASTNode *old_stmt, ASTNode *new_stmt, Context *ctx,
                                     const char *target_name, const char **value_name_out) {
   old_stmt = single_branch_statement(old_stmt);
   new_stmt = single_branch_statement(new_stmt);
   if (!old_stmt || !new_stmt ||
       !classify_tracked_pointer_u8_update(old_stmt, ctx, target_name) ||
       !classify_tracked_pointer_u8_update(new_stmt, ctx, target_name)) return false;
   return u8_expr_is_double_mod256(old_stmt->children[2], new_stmt->children[2],
                                  ctx, value_name_out);
}

//! @brief Prove duplicated conditional pointer updates also double every selected offset.
static bool pointer_conditional_update_is_double(ASTNode *old_stmt, ASTNode *new_stmt,
                                                 Context *ctx, const char *target_name,
                                                 const char **value_name_out) {
   ASTNode *old_then;
   ASTNode *old_else;
   ASTNode *new_then;
   ASTNode *new_else;
   const char *then_name = NULL;
   const char *else_name = NULL;

   if (!old_stmt || !new_stmt || strcmp(old_stmt->name, "if_stmt") ||
       strcmp(new_stmt->name, "if_stmt") || old_stmt->count < 3 || new_stmt->count < 3 ||
       !simple_expr_same(old_stmt->children[0], new_stmt->children[0])) return false;
   old_then = single_branch_statement(old_stmt->children[1]);
   old_else = single_branch_statement(old_stmt->children[2]);
   new_then = single_branch_statement(new_stmt->children[1]);
   new_else = single_branch_statement(new_stmt->children[2]);
   if (!pointer_update_is_double(old_then, new_then, ctx, target_name, &then_name) ||
       !pointer_update_is_double(old_else, new_else, ctx, target_name, &else_name) ||
       !then_name || !else_name || strcmp(then_name, else_name)) return false;
   if (value_name_out) *value_name_out = then_name;
   return true;
}

//! @brief Conservatively reject loops that can alter values reused after the loop.
static bool ast_may_modify_reused_pointer_inputs(ASTNode *node, Context *ctx,
                                                 const char *pointer_name,
                                                 const char *value0,
                                                 const char *value1) {
   if (!node) return false;
   if (!strcmp(node->name, "asm_stmt") || !strcmp(node->name, "()")) return true;
   if (!strcmp(node->name, "assign_expr") && node->count >= 2) {
      LValueRef lv;
      if (resolve_lvalue(ctx, node->children[1], &lv) && lv.name &&
          (!strcmp(lv.name, pointer_name) || (value0 && !strcmp(lv.name, value0)) ||
           (value1 && !strcmp(lv.name, value1)))) return true;
   }
   if ((node->count == 1) && (!strcmp(node->name, "++") || !strcmp(node->name, "--"))) {
      LValueRef lv;
      if (resolve_lvalue(ctx, node->children[0], &lv) && lv.name &&
          (!strcmp(lv.name, pointer_name) || (value0 && !strcmp(lv.name, value0)) ||
           (value1 && !strcmp(lv.name, value1)))) return true;
   }
   for (int i = 0; i < node->count; i++) {
      if (ast_may_modify_reused_pointer_inputs(node->children[i], ctx, pointer_name,
                                               value0, value1)) return true;
   }
   return false;
}

//! @brief Reuse a packed page-pointer low byte when the next offsets are its proven double.
static bool compile_doubled_page_pointer_reuse(ASTNode *list, int index, Context *ctx,
                                               int *skip_out) {
   const char *old_target = NULL;
   const char *new_target = NULL;
   const char *value0 = NULL;
   const char *value1 = NULL;
   ASTNode *loop;
   LValueRef dst;
   ContextEntry entry;
   char symbol[256];
   char addr_buf[256];
   const char *formatted;

   if (!list || !ctx || index < 4 || index + 2 >= list->count ||
       !classify_page_pointer_selector(list->children[index - 4], ctx, &old_target) ||
       !classify_page_pointer_selector(list->children[index], ctx, &new_target) ||
       !old_target || !new_target || strcmp(old_target, new_target) ||
       !pointer_update_is_double(list->children[index - 3], list->children[index + 1],
                                 ctx, new_target, &value0)) return false;
   if (!pointer_update_is_double(list->children[index - 2], list->children[index + 2],
                                 ctx, new_target, &value1) &&
       !pointer_conditional_update_is_double(list->children[index - 2],
                                             list->children[index + 2], ctx,
                                             new_target, &value1)) return false;
   loop = list->children[index - 1];
   if (!loop || strcmp(loop->name, "for_stmt") ||
       ast_may_modify_reused_pointer_inputs(loop, ctx, new_target, value0, value1)) return false;

   {
      ASTNode *update = single_branch_statement(list->children[index + 1]);
      if (!update || !resolve_lvalue(ctx, update->children[1], &dst)) return false;
   }
   entry = (ContextEntry){ .name = dst.name, .type = dst.type,
      .declarator = dst.declarator, .is_static = dst.is_static,
      .is_zeropage = dst.is_zeropage, .is_global = dst.is_global,
      .offset = dst.offset, .size = dst.size };
   if (!entry_symbol_name(ctx, &entry, symbol, sizeof(symbol))) return false;
   formatted = assembler_address_expr(symbol, addr_buf, sizeof(addr_buf));
   emit_lvalue_semantic_use(ctx, &dst, "read");
   emit_lvalue_semantic_use(ctx, &dst, "write");
   emit(&es_code, "    asl %s + %d\n", formatted, dst.offset);
   if (!compile_compact_page_pointer_selector(list->children[index], ctx, new_target)) return false;
   clear_pointer_low_range_fact(ctx);
   if (skip_out) *skip_out = 2;
   return true;
}

//! @brief Drop the narrow page-pointer low-byte fact at a non-straight-line boundary.
static void clear_pointer_low_range_fact(Context *ctx) {
   if (!ctx) return;
   ctx->pointer_low_range_name = NULL;
   ctx->pointer_low_range_min = 0;
   ctx->pointer_low_range_max = 0;
   ctx->pointer_low_range_known = false;
}

//! @brief Lower if stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_if_stmt(ASTNode *node, Context *ctx) {
   if (compile_compact_pointer_u8_conditional_update(node, ctx)) return;

   const char *false_label = next_label("if_false");
   const char *end_label = next_label("if_end");
   ASTNode *cond = node->children[0];
   ASTNode *then_block = node->children[1];
   ASTNode *else_block = (node->count > 2) ? node->children[2] : NULL;
   const char *tracked_pointer = NULL;
   int base_min = 0;
   int base_max = 0;
   bool merge_pointer_range = false;

   if (ctx && ctx->pointer_low_range_known && ctx->pointer_low_range_name &&
       else_block && !is_empty(else_block) &&
       classify_tracked_pointer_u8_conditional_update(node, ctx,
                                                      ctx->pointer_low_range_name)) {
      tracked_pointer = ctx->pointer_low_range_name;
      base_min = ctx->pointer_low_range_min;
      base_max = ctx->pointer_low_range_max;
      merge_pointer_range = true;
   }

   if (!compile_condition_branch_false(cond, ctx, false_label)) {
      error_user("[%s:%d.%d] invalid if condition", node->file, node->line, node->column);
      free((void *) false_label);
      free((void *) end_label);
      return;
   }

   compile_statement_list(then_block, ctx);
   int then_min = 0;
   int then_max = 0;
   if (merge_pointer_range && ctx->pointer_low_range_known && ctx->pointer_low_range_name &&
       !strcmp(ctx->pointer_low_range_name, tracked_pointer)) {
      then_min = ctx->pointer_low_range_min;
      then_max = ctx->pointer_low_range_max;
   }
   else {
      merge_pointer_range = false;
   }
   if (else_block && !is_empty(else_block)) {
      emit(&es_code, "    jmp %s\n", end_label);
   }
   emit(&es_code, "%s:\n", false_label);
   if (else_block && !is_empty(else_block)) {
      if (merge_pointer_range) {
         ctx->pointer_low_range_name = tracked_pointer;
         ctx->pointer_low_range_min = base_min;
         ctx->pointer_low_range_max = base_max;
         ctx->pointer_low_range_known = true;
      }
      compile_statement_list(else_block, ctx);
      if (merge_pointer_range && ctx->pointer_low_range_known && ctx->pointer_low_range_name &&
          !strcmp(ctx->pointer_low_range_name, tracked_pointer)) {
         int else_min = ctx->pointer_low_range_min;
         int else_max = ctx->pointer_low_range_max;
         ctx->pointer_low_range_min = then_min < else_min ? then_min : else_min;
         ctx->pointer_low_range_max = then_max > else_max ? then_max : else_max;
      }
      else if (merge_pointer_range) {
         clear_pointer_low_range_fact(ctx);
      }
      emit(&es_code, "%s:\n", end_label);
   }
   free((void *) false_label);
   free((void *) end_label);
}

//! @brief Lower while stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_while_stmt(ASTNode *node, Context *ctx) {
   const char *start_label = next_label("while_start");
   const char *end_label = next_label("while_end");
   const char *named_loop = pending_loop_label_name;
   ASTNode *cond = node->children[0];
   ASTNode *body = node->children[1];

   pending_loop_label_name = NULL;

   if (!start_label || !end_label) {
      free((void *) start_label);
      free((void *) end_label);
      warning("[%s:%d.%d] while label generation failed", node->file, node->line, node->column);
      return;
   }

   push_loop_labels(end_label, start_label);
   if (named_loop) {
      push_named_loop_labels(named_loop, end_label, start_label);
   }
   emit(&es_code, "%s:\n", start_label);
   if (!compile_condition_branch_false(cond, ctx, end_label)) {
      error_user("[%s:%d.%d] invalid while condition", node->file, node->line, node->column);
      pop_loop_labels();
      if (named_loop) {
         pop_named_loop_labels();
      }
      free((void *) start_label);
      free((void *) end_label);
      return;
   }
   compile_statement_list(body, ctx);
   emit(&es_code, "    jmp %s\n", start_label);
   emit(&es_code, "%s:\n", end_label);
   pop_loop_labels();
   if (named_loop) {
      pop_named_loop_labels();
   }
   free((void *) start_label);
   free((void *) end_label);
}

//! @brief Read one unsigned-byte compile-time integer for counted-loop recognition.
static bool counted_loop_u8_constant(ASTNode *expr, int *out) {
   InitConstValue value = {0};
   expr = (ASTNode *)unwrap_expr_node(expr);
   if (!expr || !eval_constant_initializer_expr(expr, &value) ||
       value.kind != INIT_CONST_INT || value.i < 0 || value.i > 255) {
      return false;
   }
   if (out) *out = (int)value.i;
   return true;
}

//! @brief Return whether one expression shape stays in the compact A/Y byte path.
static bool counted_loop_x_safe_byte_expr(ASTNode *expr, Context *ctx) {
   const ASTNode *type;
   const ASTNode *decl;
   int constant;

   expr = (ASTNode *)unwrap_expr_node(expr);
   if (!expr) return false;
   if (counted_loop_u8_constant(expr, &constant)) return true;
   type = expr_value_type(expr, ctx);
   decl = expr_value_declarator(expr, ctx);
   if (!type || type_size_from_node(type) != 1 || type_is_signed_integer(type) ||
       type_is_bcd_integer(type) || (decl && declarator_pointer_depth(decl) > 0)) {
      return false;
   }
   if (!strcmp(expr->name, "lvalue")) {
      /* Scalar byte loads and one-dimensional byte array/pointer subscripts are
         exactly the direct forms used by the register-backed loop. */
      if (expr->count < 2 || is_empty(expr->children[1])) return true;
      if (strcmp(expr->children[1]->name, "[") || expr->children[1]->count < 2)
         return false;
      return counted_loop_x_safe_byte_expr(expr->children[1]->children[1], ctx);
   }
   if (expr->count == 2 && (!strcmp(expr->name, "&") || !strcmp(expr->name, "|") ||
                            !strcmp(expr->name, "^") || !strcmp(expr->name, "+") ||
                            !strcmp(expr->name, "-"))) {
      int left_constant;
      int right_constant;
      bool lc = counted_loop_u8_constant(expr->children[0], &left_constant);
      bool rc = counted_loop_u8_constant(expr->children[1], &right_constant);
      if (!strcmp(expr->name, "-") && !rc) return false;
      if (rc) return counted_loop_x_safe_byte_expr(expr->children[0], ctx);
      if (lc && strcmp(expr->name, "-"))
         return counted_loop_x_safe_byte_expr(expr->children[1], ctx);
      return false;
   }
   if (expr->count == 2 && (!strcmp(expr->name, "<<") || !strcmp(expr->name, ">>")) &&
       counted_loop_u8_constant(expr->children[1], &constant) && constant < 8) {
      return counted_loop_x_safe_byte_expr(expr->children[0], ctx);
   }
   return false;
}

//! @brief Verify one assignment target preserves an X-backed counted-loop index.
static bool counted_loop_x_safe_target(ASTNode *target, Context *ctx, const char *counter) {
   ASTNode *u = (ASTNode *)unwrap_expr_node(target);
   ASTNode *suffix;
   ASTNode *index;
   LValueRef lv;
   const char *name;
   int delta = 0;

   name = expr_bare_identifier_name(u);
   if (name) {
      if (counter && !strcmp(name, counter)) return false;
      if (!resolve_ref_argument_lvalue(ctx, u, &lv) || lv.size != 1 ||
          lv.is_bitfield || lv.indirect || lv.needs_runtime_address ||
          type_is_signed_integer(lv.type) || type_is_bcd_integer(lv.type)) {
         return false;
      }
      if (lv.is_absolute_ref) return lv.write_expr && *lv.write_expr;
      return true;
   }

   if (!u || strcmp(u->name, "lvalue") || u->count < 2) return false;
   suffix = u->children[1];
   if (!suffix || strcmp(suffix->name, "[") || suffix->count < 2 ||
       !is_empty(suffix->children[0])) return false;
   index = (ASTNode *)unwrap_expr_node(suffix->children[1]);
   name = expr_bare_identifier_name(index);
   if (!name || strcmp(name, counter)) {
      int value;
      if (!index || strcmp(index->name, "+") || index->count != 2 ||
          !(name = expr_bare_identifier_name((ASTNode *)unwrap_expr_node(index->children[0]))) ||
          strcmp(name, counter) || !counted_loop_u8_constant(index->children[1], &value) ||
          value < 0 || value > 1) return false;
      delta = value;
   }
   (void)delta;
   return resolve_ref_argument_lvalue(ctx, u, &lv) && lv.size == 1 &&
          !lv.is_bitfield && !lv.is_absolute_ref &&
          declarator_array_count(lv.base_declarator) > 0 &&
          declarator_first_element_size(lv.base_type, lv.base_declarator) == 1 &&
          !type_is_signed_integer(lv.type) && !type_is_bcd_integer(lv.type);
}

//! @brief Verify one discard store cannot clobber an X-backed counted-loop index.
static bool counted_loop_x_safe_discard_store(ASTNode *stmt, Context *ctx,
                                              const char *counter) {
   ASTNode *target;
   ASTNode *u;
   LValueRef lv;
   const char *name;

   if (!stmt || strcmp(stmt->name, "discard_store") || stmt->count != 1) return false;
   target = stmt->children[0];
   u = (ASTNode *)unwrap_expr_node(target);
   name = expr_bare_identifier_name(u);
   if (name && counter && !strcmp(name, counter)) return false;
   if (!resolve_ref_argument_lvalue(ctx, u, &lv) || lv.size != 1 ||
       lv.is_bitfield || lv.indirect || lv.needs_runtime_address) {
      return false;
   }
   if (lv.is_absolute_ref) return lv.write_expr && *lv.write_expr;
   return lv.is_static || lv.is_zeropage || lv.is_global ||
          (lv.offset >= 0 && lv.offset <= 255);
}

//! @brief Verify a small counted-loop body cannot clobber its X-backed counter.
static bool counted_loop_x_safe_body(ASTNode *body, Context *ctx, const char *counter) {
   if (!body || strcmp(body->name, "statement_list")) return false;
   for (int i = 0; i < body->count; ++i) {
      ASTNode *stmt = body->children[i];
      ASTNode *target;
      ASTNode *rhs;
      if (counted_loop_x_safe_discard_store(stmt, ctx, counter)) continue;
      if (!stmt || strcmp(stmt->name, "assign_expr") || stmt->count != 3 ||
          !stmt->children[0] || strcmp(stmt->children[0]->strval, ":=")) {
         return false;
      }
      target = stmt->children[1];
      rhs = stmt->children[2];
      if (!counted_loop_x_safe_target(target, ctx, counter) ||
          !counted_loop_x_safe_byte_expr(rhs, ctx)) {
         return false;
      }
   }
   return true;
}

//! @brief Return the bare object name operated on by one ++/-- expression.
static const char *counted_loop_incdec_name(ASTNode *expr) {
   ASTNode *base;

   expr = (ASTNode *)unwrap_expr_node(expr);
   if (!expr || !classify_incdec_lvalue_expr(expr, NULL, NULL) ||
       strcmp(expr->name, "lvalue") || expr->count < 3) {
      return NULL;
   }
   base = expr->children[0];
   if (!base || strcmp(base->name, "lvalue_base") || base->count != 1 ||
       !base->children[0] || base->children[0]->kind != AST_IDENTIFIER) {
      return NULL;
   }
   return base->children[0]->strval;
}

//! @brief Recognize a narrow register-backed unsigned-byte counted loop.
//!
//! Accepted shapes are the established ascending
//! `for (uint8_t i := C; i < N; i += S)` form and proven-nonempty countdowns
//! `for (uint8_t i := C; i; i--)` / `i > 0` / `i != 0`, where C is nonzero.
//! The latter can use DEX/BNE without materializing the source loop variable.
static bool classify_register_counted_for(ASTNode *node, Context *ctx,
                                          ContextEntry **entry_out,
                                          int *initial_out, int *limit_out,
                                          int *step_out) {
   ASTNode *init;
   ASTNode *cond;
   ASTNode *step;
   ASTNode *body;
   ASTNode *list;
   ASTNode *item;
   ASTNode *type;
   ASTNode *declarator;
   ASTNode *initializer;
   ASTNode *ucond;
   ASTNode *ustep;
   const char *name;
   const char *cond_name;
   const char *step_name;
   ContextEntry *entry;
   int initial, limit, step_value;
   bool decrement = false;

   if (!node || node->count < 4) return false;
   init = node->children[0];
   cond = node->children[1];
   step = node->children[2];
   body = node->children[3];
   if (!init || strcmp(init->name, "defdecl_stmt") || init->count < 1) return false;
   list = init->children[0];
   if (!list || list->count != 1) return false;
   item = list->children[0];
   if (!item || item->count < 4 || !is_empty(item->children[0])) return false;
   type = item->children[1];
   declarator = (ASTNode *)stmt_decl_node_declarator(item);
   initializer = item->children[item->count - 1];
   name = declarator_name(declarator);
   if (!name || type_size_from_node(type) != 1 || type_is_signed_integer(type) ||
       type_is_bcd_integer(type) || declarator_pointer_depth(declarator) != 0 ||
       !counted_loop_u8_constant(initializer, &initial)) {
      return false;
   }
   ustep = (ASTNode *)unwrap_expr_node(step);
   ucond = (ASTNode *)unwrap_expr_node(cond);

   /* Existing ascending form. */
   if (ucond && ucond->count == 2 && !strcmp(ucond->name, "<") &&
       (cond_name = expr_bare_identifier_name(ucond->children[0])) != NULL &&
       !strcmp(cond_name, name) && counted_loop_u8_constant(ucond->children[1], &limit) &&
       ustep && ustep->count == 3 && ustep->children[0] &&
       !strcmp(ustep->children[0]->strval, "+=") &&
       (step_name = expr_bare_identifier_name(ustep->children[1])) != NULL &&
       !strcmp(step_name, name) && counted_loop_u8_constant(ustep->children[2], &step_value) &&
       step_value > 0) {
      decrement = false;
   }
   else {
      bool inc = true;
      bool pre = false;
      bool zero_condition = false;
      const char *truth_name = expr_bare_identifier_name(ucond);

      if (truth_name && !strcmp(truth_name, name)) {
         zero_condition = true;
      }
      else if (ucond && ucond->count == 2 &&
               (!strcmp(ucond->name, ">") || !strcmp(ucond->name, "!=")) &&
               (cond_name = expr_bare_identifier_name(ucond->children[0])) != NULL &&
               !strcmp(cond_name, name) && counted_loop_u8_constant(ucond->children[1], &limit) &&
               limit == 0) {
         zero_condition = true;
      }

      if (!zero_condition || initial == 0 || !ustep ||
          !classify_incdec_lvalue_expr(ustep, &inc, &pre) || inc ||
          !(step_name = counted_loop_incdec_name(ustep)) || strcmp(step_name, name)) {
         return false;
      }
      (void)pre; /* Prefix/postfix value is discarded by the for-step clause. */
      limit = 0;
      step_value = -1;
      decrement = true;
   }
   entry = ctx_lookup(ctx, name);
   if (!entry || entry->size != 1 || !counted_loop_x_safe_body(body, ctx, name)) {
      return false;
   }
   if (entry_out) *entry_out = entry;
   if (initial_out) *initial_out = initial;
   if (limit_out) *limit_out = limit;
   if (step_out) *step_out = decrement ? -1 : step_value;
   return true;
}

//! @brief Lower for stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_for_stmt(ASTNode *node, Context *ctx) {
   const char *start_label = next_label("for_start");
   const char *step_label = next_label("for_step");
   const char *end_label = next_label("for_end");
   const char *named_loop = pending_loop_label_name;
   ASTNode *init = node->children[0];
   ASTNode *cond = node->children[1];
   ASTNode *step = node->children[2];
   ASTNode *body = node->children[3];

   pending_loop_label_name = NULL;

   if (!start_label || !step_label || !end_label) {
      free((void *) start_label);
      free((void *) step_label);
      free((void *) end_label);
      warning("[%s:%d.%d] for label generation failed", node->file, node->line, node->column);
      return;
   }

   {
      ContextEntry *register_entry = NULL;
      int initial = 0, limit = 0, increment = 0;
      if (classify_register_counted_for(node, ctx, &register_entry,
                                        &initial, &limit, &increment)) {
         register_entry->is_register_x = true;
         push_loop_labels(end_label, step_label);
         if (named_loop) push_named_loop_labels(named_loop, end_label, step_label);
         emit(&es_code, "    ldx #$%02x\n", (unsigned int)initial);
         emit(&es_code, "%s:\n", start_label);
         if (increment > 0 && initial >= limit) {
            emit(&es_code, "    cpx #$%02x\n", (unsigned int)limit);
            emit(&es_code, "    bcs %s\n", end_label);
         }
         compile_statement_list(body, ctx);
         emit(&es_code, "%s:\n", step_label);
         if (increment < 0) {
            emit(&es_code, "    dex\n");
            emit(&es_code, "    bne %s\n", start_label);
         }
         else {
            for (int i = 0; i < increment; ++i) emit(&es_code, "    inx\n");
         }
         if (increment > 0 && initial < limit) {
            emit(&es_code, "    cpx #$%02x\n", (unsigned int)limit);
            emit(&es_code, "    bcc %s\n", start_label);
         }
         else if (increment > 0) {
            emit(&es_code, "    jmp %s\n", start_label);
         }
         emit(&es_code, "%s:\n", end_label);
         pop_loop_labels();
         if (named_loop) pop_named_loop_labels();
         free((void *) start_label);
         free((void *) step_label);
         free((void *) end_label);
         return;
      }
   }

   push_loop_labels(end_label, step_label);
   if (named_loop) {
      push_named_loop_labels(named_loop, end_label, step_label);
   }
   if (init && !is_empty(init)) {
      if (!strcmp(init->name, "defdecl_stmt")) {
         ASTNode *list = init->children[0];
         for (int i = 0; i < list->count; i++) {
            compile_local_decl_item(list->children[i], ctx);
         }
      }
      else {
         compile_expr(init, ctx);
      }
   }

   emit(&es_code, "%s:\n", start_label);
   if (cond && !is_empty(cond)) {
      if (!compile_condition_branch_false(cond, ctx, end_label)) {
         error_user("[%s:%d.%d] invalid for condition", node->file, node->line, node->column);
         pop_loop_labels();
         if (named_loop) {
            pop_named_loop_labels();
         }
         free((void *) start_label);
         free((void *) step_label);
         free((void *) end_label);
         return;
      }
   }
   compile_statement_list(body, ctx);
   emit(&es_code, "%s:\n", step_label);
   if (step && !is_empty(step)) {
      compile_expr(step, ctx);
   }
   emit(&es_code, "    jmp %s\n", start_label);
   emit(&es_code, "%s:\n", end_label);
   pop_loop_labels();
   if (named_loop) {
      pop_named_loop_labels();
   }
   free((void *) start_label);
   free((void *) step_label);
   free((void *) end_label);
}

//! @brief Evaluate a runtime initializer in temporary frame scratch and copy it to a fixed symbol.
static bool compile_runtime_initializer_to_symbol(ASTNode *expression, Context *ctx,
      const ASTNode *type, const ASTNode *declarator,
      PointerAccessQualifier pointer_access, const char *symbol, int size) {
   StmtFixedScratch scratch;
   bool ok;

   if (!expression || is_empty(expression) || !ctx || !symbol || size <= 0) {
      return false;
   }

   stmt_fixed_scratch_prepare(ctx, size, &scratch);
   stmt_fixed_scratch_activate(ctx, &scratch);

   if (initializer_is_list(unwrap_expr_node(expression)) ||
       declarator_array_count(declarator) > 0 || type_is_aggregate(type)) {
      unsigned char *zeroes = (unsigned char *) calloc(size ? size : 1, sizeof(unsigned char));
      if (!zeroes) {
         error_unreachable("out of memory");
      }
      emit_store_immediate_to_scratch(0, zeroes, size);
      free(zeroes);
      ok = compile_initializer_to_scratch(expression, ctx, type, declarator, 0, size);
   }
   else {
      ContextEntry target = {
         .name = "$initializer",
         .type = type,
         .declarator = declarator,
         .is_static = false,
         .is_zeropage = false,
         .is_global = false,
         .target_typed = true,
         .pointer_access = pointer_access,
         .offset = 0,
         .size = size
      };
      ok = compile_expr_to_slot(expression, ctx, &target);
   }

   if (ok) {
      emit_copy_scratch_to_symbol(symbol, 0, size);
   }
   stmt_fixed_scratch_deactivate(ctx, &scratch);
   stmt_fixed_scratch_finish(&scratch);
   return ok;
}

//! @brief Lower expr to the current function return object from AST/semantic state into generated assembly or linker-visible metadata.
static bool compile_expr_to_return_object(ASTNode *expr, Context *ctx, ContextEntry *ret) {
   char sym[256];

   if (!ret) {
      return false;
   }
   if (entry_is_absolute_ref(ret)) {
      StmtFixedScratch scratch;
      ContextEntry target;
      bool ok;

      if (!entry_has_write_address(ret)) {
         return false;
      }
      stmt_fixed_scratch_prepare(ctx, ret->size, &scratch);
      stmt_fixed_scratch_activate(ctx, &scratch);
      memset(&target, 0, sizeof(target));
      target.name = "$return_value";
      target.type = ret->type;
      target.declarator = ret->declarator;
      target.pointer_access = ret->pointer_access;
      target.target_typed = true;
      target.offset = 0;
      target.size = ret->size;
      ok = compile_expr_to_slot(expr, ctx, &target);
      if (ok) {
         emit_copy_scratch_to_address_expr(ret->write_expr, 0, ret->size);
      }
      stmt_fixed_scratch_deactivate(ctx, &scratch);
      stmt_fixed_scratch_finish(&scratch);
      return ok;
   }

   if (!entry_symbol_name(ctx, ret, sym, sizeof(sym))) {
      return false;
   }
   return compile_runtime_initializer_to_symbol(expr, ctx, ret->type, ret->declarator,
                                                ret->pointer_access, sym, ret->size);
}

//! @brief Lower break stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_break_stmt(ASTNode *node, Context *ctx) {
   const char *target = current_break_label();

   (void) ctx;
   if (node->count > 0 && node->children[0] && !is_empty(node->children[0])) {
      target = lookup_named_break_label(node->children[0]->strval);
      if (!target) {
         warning("[%s:%d.%d] labeled break target '%s' not found", node->file, node->line, node->column, node->children[0]->strval);
         return;
      }
   }
   else if (!target) {
      error_user("[%s:%d.%d] break used outside loop", node->file, node->line, node->column);
      return;
   }

   emit(&es_code, "    jmp %s\n", target);
}

//! @brief Lower continue stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_continue_stmt(ASTNode *node, Context *ctx) {
   const char *target = current_continue_label();

   (void) ctx;
   if (node->count > 0 && node->children[0] && !is_empty(node->children[0])) {
      target = lookup_named_continue_label(node->children[0]->strval);
      if (!target) {
         warning("[%s:%d.%d] labeled continue target '%s' not found", node->file, node->line, node->column, node->children[0]->strval);
         return;
      }
   }
   else if (!target) {
      error_user("[%s:%d.%d] continue used outside loop", node->file, node->line, node->column);
      return;
   }

   emit(&es_code, "    jmp %s\n", target);
}

//! @brief Handle predeclare local decl item logic for compiler statement lowering.
static void predeclare_local_decl_item(ASTNode *node, Context *ctx) {
   ASTNode *modifiers  = node->children[0];
   ASTNode *type       = node->children[1];
   ASTNode *declarator = (ASTNode *) stmt_decl_node_declarator(node);
   const ASTNode *addrspec = decl_node_address_spec(node);
   const char *name    = declarator_name(declarator);
   ASTNode *expression = node->children[node->count - 1];
   int size            = declarator_storage_size(type, declarator);
   ContextEntry *entry = (ContextEntry *) set_get(ctx->vars, name);
   validate_nonreserved_implementation_name(name, node);
   validate_declaration_access_qualifiers(node, modifiers, declarator,
                                          "local object declaration");

   if (has_modifier(modifiers, "ref")) {
      diagnose_ref_object_modifier(node, name);
   }
   if (modifiers_imply_split_address(modifiers) && addrspec != NULL) {
      error_user("[%s:%d.%d] split-address mem region '%s' supplies allocated read/write aliases and cannot be combined with an '@' absolute binding",
                 node->file, node->line, node->column,
                 find_mem_modifier_name(modifiers));
   }
   emit_mem_region_metadata_for_modifiers(node, modifiers);

   if (has_modifier(modifiers, "inline")) {
      error_user("[%s:%d.%d] 'inline' applies only to function declarations and definitions",
                 node->file, node->line, node->column);
   }

   if (entry != NULL) {
      return;
   }

   if (context_local_decl_is_coalesced_return(ctx, node)) {
      ContextEntry *ret = (ContextEntry *) set_get(ctx->vars, "$$");
      if (!ret) {
         error_unreachable("coalesced return local '%s' has no hidden return object", name);
      }
      entry = (ContextEntry *) calloc(1, sizeof(ContextEntry));
      if (!entry) {
         error_unreachable("out of memory");
      }
      *entry = *ret;
      entry->name = strdup(ret->name);
      if (!entry->name) {
         error_unreachable("out of memory");
      }
      entry->type = type;
      entry->declarator = declarator;
      entry->is_ref = false;
      entry->is_global = false;
      entry->object_is_const = declaration_const_applies_to_object(modifiers, declarator);
      entry->pointer_access = declaration_pointer_access(modifiers, declarator);
      entry->size = size;
      set_add(ctx->vars, strdup(name), entry);
      return;
   }

   if (addrspec != NULL) {
      if (has_modifier(modifiers, "static") || has_modifier(modifiers, "extern") ||
          has_modifier(modifiers, "page") || has_modifier(modifiers, "align") || modifiers_imply_mem_storage(modifiers) ||
          declaration_has_use_contract(modifiers)) {
         error_user("[%s:%d.%d] absolute external binding '%s' cannot use allocation, linkage, or use-contract modifiers",
               node->file, node->line, node->column, name);
      }
      if (!is_empty(expression)) {
         error_user("[%s:%d.%d] absolute external binding '%s' cannot have an initializer",
               node->file, node->line, node->column, name);
      }
      if (!address_spec_has_read(addrspec) && !address_spec_has_write(addrspec)) {
         error_user("[%s:%d.%d] absolute external binding '%s' cannot use none for both read and write address",
               node->file, node->line, node->column, name);
      }
      emit_absolute_binding_region_guard_metadata(node, name,
                                                  address_spec_read_expr(addrspec),
                                                  address_spec_write_expr(addrspec),
                                                  size);
      entry = (ContextEntry *) malloc(sizeof(ContextEntry));
      if (!entry) {
         error_unreachable("out of memory");
      }
      entry->name = strdup(name);
      entry->is_static = false;
      entry->is_zeropage = false;
      entry->is_global = false;
      entry->is_ref = false;
      entry->is_register_x = false;
      entry->is_absolute_ref = true;
      entry->read_expr = address_spec_read_expr(addrspec);
      entry->write_expr = address_spec_write_expr(addrspec);
      entry->has_split_alias_delta = false;
      entry->split_alias_delta = 0;
      entry->target_typed = false;
      entry->object_is_const = declaration_const_applies_to_object(modifiers, declarator);
      entry->pointer_access = declaration_pointer_access(modifiers, declarator);
      entry->type = type;
      entry->declarator = declarator;
      entry->size = size;
      entry->offset = 0;
      set_add(ctx->vars, strdup(name), entry);
      return;
   }

   if (modifiers_imply_zeropage(modifiers)) {
      ctx_zeropage(ctx, type, name);
      entry = (ContextEntry *) set_get(ctx->vars, name);
   }
   else {
      ctx_static(ctx, type, name);
      entry = (ContextEntry *) set_get(ctx->vars, name);
   }

   if (entry != NULL) {
      entry->size = size;
      entry->declarator = declarator;
      entry->object_is_const = declaration_const_applies_to_object(modifiers, declarator);
      entry->pointer_access = declaration_pointer_access(modifiers, declarator);
      if (modifiers_imply_split_address(modifiers)) {
         char symbol[256];
         if (!entry_symbol_name(ctx, entry, symbol, sizeof(symbol))) {
            error_unreachable("[%s:%d.%d] could not construct split-address local symbol for '%s'",
                              node->file, node->line, node->column, name);
         }
         init_split_mem_entry_addresses_for_symbol(entry, symbol, modifiers);
      }
   }
}



//! @brief Handle predeclare statement list logic for compiler statement lowering.
void predeclare_statement_list(ASTNode *node, Context *ctx) {
   if (!node || is_empty(node)) {
      return;
   }

   for (int i = 0; i < node->count; i++) {
      ASTNode *stmt = node->children[i];
      if (!strcmp(stmt->name, "defdecl_stmt")) {
         ASTNode *list = stmt->children[0];
         for (int j = 0; j < list->count; j++) {
            predeclare_local_decl_item(list->children[j], ctx);
         }
      }
      else if (!strcmp(stmt->name, "statement_list")) {
         predeclare_statement_list(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "if_stmt")) {
         predeclare_statement_list(stmt->children[1], ctx);
         if (stmt->count > 2) {
            predeclare_statement_list(stmt->children[2], ctx);
         }
      }
      else if (!strcmp(stmt->name, "while_stmt")) {
         predeclare_statement_list(stmt->children[1], ctx);
      }
      else if (!strcmp(stmt->name, "for_stmt")) {
         if (stmt->count > 0 && stmt->children[0] && !is_empty(stmt->children[0]) && !strcmp(stmt->children[0]->name, "defdecl_stmt")) {
            ASTNode *list = stmt->children[0]->children[0];
            for (int j = 0; j < list->count; j++) {
               predeclare_local_decl_item(list->children[j], ctx);
            }
         }
         if (stmt->count > 3) {
            predeclare_statement_list(stmt->children[3], ctx);
         }
      }
      else if (!strcmp(stmt->name, "do_stmt")) {
         predeclare_statement_list(stmt->children[0], ctx);
      }
      else if (!strcmp(stmt->name, "label_stmt")) {
         if (stmt->count > 1) {
            predeclare_statement_list(stmt->children[1], ctx);
         }
      }
      else if (!strcmp(stmt->name, "switch_stmt")) {
         if (stmt->count > 1) {
            predeclare_statement_list(stmt->children[1], ctx);
         }
      }
   }
}

//! @brief Lower local decl item from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_local_decl_item(ASTNode *node, Context *ctx) {
   ASTNode *modifiers  = node->children[0];
   ASTNode *type       = node->children[1];
   ASTNode *declarator = (ASTNode *) stmt_decl_node_declarator(node);
   const ASTNode *addrspec = decl_node_address_spec(node);
   const char *name    = declarator_name(declarator);
   ASTNode *expression = node->children[node->count - 1];
   validate_nonreserved_implementation_name(name, node);
   if (declaration_has_use_contract(modifiers)) {
      error_user("[%s:%d.%d] local object '%s' cannot use '%s'; use contracts apply only to file-scope objects and functions",
                 node->file, node->line, node->column, name,
                 declaration_use_contract(modifiers) == DECL_USE_CONTRACT_REQUIRE ? "require" : "recommend");
   }
   if (has_modifier(modifiers, "page")) {
      error_user("[%s:%d.%d] 'page' currently applies only to file-scope data-object definitions",
                 node->file, node->line, node->column);
   }
   if (has_modifier(modifiers, "align")) {
      error_user("[%s:%d.%d] align() applies only to file-scope data-object definitions",
                 node->file, node->line, node->column);
   }
   int size            = declarator_storage_size(type, declarator);
   ContextEntry *entry;

   entry = (ContextEntry *) set_get(ctx->vars, name);
   if (entry == NULL) {
      predeclare_local_decl_item(node, ctx);
      entry = (ContextEntry *) set_get(ctx->vars, name);
   }
   if (entry != NULL) {
      entry->size = size;
      entry->declarator = declarator;
   }

   while (expression && expression->count == 1 && !strcmp(expression->name, "assign_expr")) {
      expression = expression->children[0];
   }

   if (entry == NULL) {
      error_unreachable("[%s:%d.%d] internal compiler error: local declaration for '%s' was not predeclared", node->file, node->line, node->column, name);
      return;
   }

   if (!is_empty(expression) && declarator_pointer_depth(declarator) > 0 &&
       !integer_literal_is_zero_expr(expression)) {
      const ASTNode *src_type = NULL;
      const ASTNode *src_decl = NULL;
      expr_match_signature(expression, ctx, &src_type, &src_decl);
      if (src_type && src_decl && declarator_pointer_depth(src_decl) > 0) {
         validate_pointer_access_conversion(expression, entry->pointer_access,
                                            expr_pointer_access(expression, ctx),
                                            "local initializer");
      }
   }

   if (modifiers_imply_split_address(modifiers) &&
       !has_modifier(modifiers, "static") &&
       !context_local_decl_is_coalesced_return(ctx, node)) {
      char segbuf[512];
      if (is_empty(expression) && declaration_const_applies_to_object(modifiers, declarator)) {
         error_user("[%s:%d.%d] 'const' missing initializer", node->file, node->line, node->column);
      }
      if (!entry->read_expr || !*entry->read_expr) {
         error_unreachable("[%s:%d.%d] split-address local '%s' has no allocated read alias",
                           node->file, node->line, node->column, name);
      }
      build_activation_storage_segment(segbuf, sizeof(segbuf), ctx, modifiers, "BSS");
      emit(&es_bss, ".segment \"%s\"\n", segbuf);
      emit(&es_bss, "%s:\n", entry->read_expr);
      emit(&es_bss, "\t.res %d\n", size);
   }

   if (addrspec != NULL) {
      return;
   }

   if (entry->is_absolute_ref && !has_modifier(modifiers, "static")) {
      StmtFixedScratch scratch;
      LValueRef lv;
      bool ok;

      if (is_empty(expression)) {
         return;
      }

      stmt_fixed_scratch_prepare(ctx, size, &scratch);
      stmt_fixed_scratch_activate(ctx, &scratch);
      if (initializer_is_list(unwrap_expr_node(expression)) ||
          declarator_array_count(declarator) > 0 || type_is_aggregate(type)) {
         emit_fill_scratch_bytes(0, 0, size, 0x00);
         ok = compile_initializer_to_scratch(expression, ctx, type, declarator, 0, size);
      }
      else {
         ContextEntry tmp = {
            .name = "$tmp",
            .type = type,
            .declarator = declarator,
            .is_static = false,
            .is_zeropage = false,
            .is_global = false,
            .target_typed = true,
            .pointer_access = entry->pointer_access,
            .offset = 0,
            .size = size
         };
         ok = compile_expr_to_slot(expression, ctx, &tmp);
      }
      stmt_fixed_scratch_deactivate(ctx, &scratch);
      stmt_fixed_scratch_finish(&scratch);
      if (!ok) {
         error_user("[%s:%d.%d] invalid initializer for '%s'", node->file, node->line, node->column, name);
         return;
      }

      lv = (LValueRef){
         .name = entry->name,
         .type = entry->type,
         .declarator = entry->declarator,
         .base_type = entry->type,
         .base_declarator = entry->declarator,
         .is_static = entry->is_static,
         .is_zeropage = entry->is_zeropage,
         .is_global = entry->is_global,
         .is_ref = entry->is_ref,
         .is_absolute_ref = entry->is_absolute_ref,
         .read_expr = entry->read_expr,
         .write_expr = entry->write_expr,
         .has_split_alias_delta = entry->has_split_alias_delta,
         .split_alias_delta = entry->split_alias_delta,
         .offset = entry->offset,
         .size = entry->size
      };
      if (!emit_copy_symbol_to_lvalue(ctx, &lv, scratch.symbol, 0, size)) {
         error_user("[%s:%d.%d] invalid initializer for '%s'", node->file, node->line, node->column, name);
      }
      return;
   }

   if (is_empty(expression) && declaration_const_applies_to_object(modifiers, declarator)) {
      error_user("[%s:%d.%d] 'const' missing initializer", node->file, node->line, node->column);
   }

   {
      char sym[256];
      EmitSink *sink;
      if (modifiers_imply_split_address(modifiers) &&
          has_modifier(modifiers, "static")) {
         if (!entry->read_expr || !*entry->read_expr ||
             !entry->write_expr || !*entry->write_expr) {
            error_unreachable("[%s:%d.%d] split-address static local '%s' has incomplete allocated aliases",
                              node->file, node->line, node->column, name);
         }
         snprintf(sym, sizeof(sym), "%s", entry->read_expr);
      }
      else if (!entry_symbol_name(ctx, entry, sym, sizeof(sym))) {
         error_user("[%s:%d.%d] invalid initializer for '%s'", node->file, node->line, node->column, name);
         return;
      }

      /* Non-static source locals retain automatic initialization semantics,
         but their storage is a fixed per-function symbol. */
      if (!has_modifier(modifiers, "static")) {
         if (!context_local_decl_is_coalesced_return(ctx, node)) {
            if (entry->is_zeropage) {
               char segbuf[512];
               build_activation_storage_segment(segbuf, sizeof(segbuf), ctx, modifiers, "ZEROPAGE");
               sink = &es_zp;
               emit(sink, ".segment \"%s\"\n", segbuf);
            }
            else {
               char segbuf[512];
               build_activation_storage_segment(segbuf, sizeof(segbuf), ctx, modifiers, "BSS");
               sink = &es_bss;
               emit(sink, ".segment \"%s\"\n", segbuf);
            }
            emit(sink, "%s:\n", sym);
            emit(sink, "\t.res %d\n", size);
         }

         if (!is_empty(expression) &&
             !compile_runtime_initializer_to_symbol(expression, ctx, type, declarator,
                                                   entry->pointer_access, sym, size)) {
            error_user("[%s:%d.%d] invalid initializer for '%s'", node->file, node->line, node->column, name);
         }
         return;
      }

      if (is_empty(expression)) {
         if (entry->is_zeropage) {
            char segbuf[256];
            build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "ZEROPAGE");
            sink = &es_zp;
            emit(sink, ".segment \"%s\"\n", segbuf);
         }
         else {
            char segbuf[256];
            build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "BSS");
            sink = &es_bss;
            emit(sink, ".segment \"%s\"\n", segbuf);
         }
         emit(sink, "%s:\n", sym);
         emit(sink, "\t.res %d\n", size);
         return;
      }

      {
         EmitSink init_es = EMIT_INIT;

         if (emit_global_initializer(&init_es, type, declarator, expression, size)) {
            if (entry->is_zeropage) {
               char segbuf[256];
               sink = &es_zpdata;
               build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "ZEROPAGE");
               emit(sink, ".segment \"%s\"\n", segbuf);
            }
            else if (modifiers_imply_mem_storage(modifiers)) {
               char segbuf[256];
               sink = &es_data;
               build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "DATA");
               emit(sink, ".segment \"%s\"\n", segbuf);
            }
            else {
               sink = declaration_const_applies_to_object(modifiers, declarator) ? &es_rodata : &es_data;
            }
            emit(sink, "%s:\n", sym);
            emit_sink_append(sink, &init_es);
         }
         else {
            if (entry->is_zeropage) {
               char segbuf[256];
               build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "ZEROPAGE");
               sink = &es_zp;
               emit(sink, ".segment \"%s\"\n", segbuf);
            }
            else {
               char segbuf[256];
               build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "BSS");
               sink = &es_bss;
               emit(sink, ".segment \"%s\"\n", segbuf);
            }
            emit(sink, "%s:\n", sym);
            emit(sink, "\t.res %d\n", size);
            if (modifiers_imply_split_address(modifiers)) {
               remember_pending_global_init(name, sym, type, declarator, expression,
                                            size, false, true,
                                            entry->read_expr, entry->write_expr);
            }
            else {
               remember_pending_global_init(name, sym, type, declarator, expression,
                                            size, entry->is_zeropage, false,
                                            NULL, NULL);
            }
         }
      }
      return;
   }
}



//! @brief Lower do stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_do_stmt(ASTNode *node, Context *ctx) {
   const char *start_label = next_label("do_start");
   const char *cond_label = next_label("do_cond");
   const char *end_label = next_label("do_end");
   const char *named_loop = pending_loop_label_name;
   pending_loop_label_name = NULL;
   if (!start_label || !cond_label || !end_label) {
      free((void *) start_label);
      free((void *) cond_label);
      free((void *) end_label);
      warning("[%s:%d.%d] failed to allocate labels for do statement", node->file, node->line, node->column);
      return;
   }

   emit(&es_code, "%s:\n", start_label);
   push_loop_labels(end_label, cond_label);
   if (named_loop) {
      push_named_loop_labels(named_loop, end_label, cond_label);
   }
   compile_statement_list(node->children[0], ctx);
   emit(&es_code, "%s:\n", cond_label);
   if (!compile_condition_branch_false(node->children[1], ctx, end_label)) {
      error_user("[%s:%d.%d] invalid do/while condition", node->file, node->line, node->column);
   }
   emit(&es_code, "    jmp %s\n", start_label);
   emit(&es_code, "%s:\n", end_label);
   pop_loop_labels();
   if (named_loop) {
      pop_named_loop_labels();
   }

   free((void *) start_label);
   free((void *) cond_label);
   free((void *) end_label);
}

//! @brief Lower label stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_label_stmt(ASTNode *node, Context *ctx) {
   char label[512];
   char base[384];

   snprintf(base, sizeof(base), "user_%s", node->children[0]->strval);
   format_context_local_label(ctx, base, label, sizeof(label));
   emit(&es_code, "%s:\n", label);
   if (node->count > 1) {
      ASTNode *stmt = node->children[1];
      const char *saved_pending = pending_loop_label_name;
      if (!strcmp(stmt->name, "while_stmt") || !strcmp(stmt->name, "for_stmt") || !strcmp(stmt->name, "do_stmt") || !strcmp(stmt->name, "switch_stmt")) {
         pending_loop_label_name = node->children[0]->strval;
      }
      if (!strcmp(stmt->name, "return_stmt")) {
         compile_return_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "expr") || !strcmp(stmt->name, "assign_expr")) {
         compile_expr(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "if_stmt")) {
         compile_if_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "while_stmt")) {
         compile_while_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "for_stmt")) {
         compile_for_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "do_stmt")) {
         compile_do_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "break_stmt")) {
         compile_break_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "continue_stmt")) {
         compile_continue_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "goto_stmt")) {
         compile_goto_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "switch_stmt")) {
         compile_switch_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "label_stmt")) {
         compile_label_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "defdecl_stmt")) {
         ASTNode *list = stmt->children[0];
         for (int j = 0; j < list->count; j++) {
            compile_local_decl_item(list->children[j], ctx);
         }
      }
      else if (!strcmp(stmt->name, "asm_stmt")) {
         compile_asm_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "statement_list")) {
         compile_statement_list(stmt, ctx);
      }
      else if (is_empty(stmt) || !strcmp(stmt->name, "empty")) {
         /* labeled empty statement: no-op */
      }
      else {
         error_user("[%s:%d.%d] unsupported labeled statement '%s'", stmt->file, stmt->line, stmt->column, stmt->name);
      }
      pending_loop_label_name = saved_pending;
   }
}

//! @brief Lower goto stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_goto_stmt(ASTNode *node, Context *ctx) {
   if (node->count > 0 && !is_empty(node->children[0])) {
      char label[512];
      char base[384];
      snprintf(base, sizeof(base), "user_%s", node->children[0]->strval);
      format_context_local_label(ctx, base, label, sizeof(label));
      emit(&es_code, "    jmp %s\n", label);
   }
}

//! @brief Lower switch stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_switch_stmt(ASTNode *node, Context *ctx) {
   const char *named_loop = pending_loop_label_name;
   ASTNode *expr;
   ASTNode *sections;
   const ASTNode *type;
   int size;
   int compare_size;
   StmtFixedScratch scratch;
   ContextEntry lhs;
   ContextEntry rhs;
   const char *cleanup_label;
   const char *default_label = NULL;
   const char *end_label = NULL;
   const char **case_labels = NULL;
   int section_count;

   pending_loop_label_name = NULL;

   if (!node || node->count < 2) {
      return;
   }

   expr = node->children[0];
   sections = node->children[1];
   if (!sections || is_empty(sections) || sections->count <= 0) {
      return;
   }

   type = expr_value_type(expr, ctx);
   size = expr_value_size(expr, ctx);
   if (size <= 0) {
      size = 1;
   }
   compare_size = size * 2;
   lhs = (ContextEntry){ .name = "$lhs", .type = type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .offset = 0, .size = size };
   rhs = (ContextEntry){ .name = "$rhs", .type = type, .declarator = NULL, .is_static = false, .is_zeropage = false, .is_global = false, .offset = size, .size = size };
   cleanup_label = next_label("switch_cleanup");
   end_label = next_label("switch_end");
   if (!cleanup_label || !end_label) {
      free((void *) cleanup_label);
      free((void *) end_label);
      warning("[%s:%d.%d] switch label generation failed", node->file, node->line, node->column);
      return;
   }

   section_count = sections->count;
   case_labels = calloc((size_t)section_count, sizeof(*case_labels));
   if (!case_labels) {
      free((void *) cleanup_label);
      free((void *) end_label);
      error_unreachable("out of memory");
   }

   stmt_fixed_scratch_prepare(ctx, compare_size, &scratch);
   stmt_fixed_scratch_activate(ctx, &scratch);
   if (!compile_expr_to_slot(expr, ctx, &lhs)) {
      stmt_fixed_scratch_deactivate(ctx, &scratch);
      stmt_fixed_scratch_finish(&scratch);
      error_user("[%s:%d.%d] invalid switch expression", node->file, node->line, node->column);
      free(case_labels);
      free((void *) cleanup_label);
      free((void *) end_label);
      return;
   }
   stmt_fixed_scratch_deactivate(ctx, &scratch);

   for (int i = 0; i < section_count; i++) {
      ASTNode *section = sections->children[i];
      case_labels[i] = next_label("case");
      if (!case_labels[i]) {
         warning("[%s:%d.%d] switch case label generation failed", node->file, node->line, node->column);
         default_label = cleanup_label;
         break;
      }
      if (section->children[0] && is_empty(section->children[0])) {
         default_label = case_labels[i];
      }
   }

   for (int i = 0; i < section_count; i++) {
      ASTNode *section = sections->children[i];
      ASTNode *case_expr = section->children[0];
      if (!case_labels[i] || (case_expr && is_empty(case_expr))) {
         continue;
      }

      if (!strcmp(case_expr->name, "case_choice")) {
         ASTNode *low = case_expr->count > 0 ? case_expr->children[0] : NULL;
         ASTNode *high = case_expr->count > 1 ? case_expr->children[1] : NULL;

         if (!low) {
            error_unreachable("[%s:%d.%d] malformed case label", case_expr->file, case_expr->line, case_expr->column);
            continue;
         }

         if (!high) {
            stmt_fixed_scratch_activate(ctx, &scratch);
            if (!compile_constant_expr_to_slot(low, ctx, &rhs) &&
                !compile_expr_to_slot(low, ctx, &rhs)) {
               stmt_fixed_scratch_deactivate(ctx, &scratch);
               error_user("[%s:%d.%d] invalid case expression", low->file, low->line, low->column);
               continue;
            }
            emit_fixed_compare_scratch(type, "==", lhs.offset, rhs.offset, size);
            stmt_fixed_scratch_deactivate(ctx, &scratch);
            emit(&es_code, "    bne %s\n", case_labels[i]);
            continue;
         }

         {
            InitConstValue low_value = {0};
            InitConstValue high_value = {0};
            bool swapped = false;
            ASTNode *ordered_low = low;
            ASTNode *ordered_high = high;
            const char *skip_label = next_label("case_skip");

            if (!skip_label) {
               warning("[%s:%d.%d] switch case label generation failed", case_expr->file, case_expr->line, case_expr->column);
               continue;
            }

            if (eval_constant_initializer_expr(low, &low_value) &&
                eval_constant_initializer_expr(high, &high_value) &&
                low_value.kind == high_value.kind) {
               if (low_value.kind == INIT_CONST_INT && low_value.i > high_value.i) {
                  swapped = true;
                  ordered_low = high;
                  ordered_high = low;
               }
            }

            if (swapped) {
               warning("[%s:%d.%d] case range bounds were reversed; compiling as the inclusive range in ascending order",
                       section->file, section->line, section->column);
            }

            stmt_fixed_scratch_activate(ctx, &scratch);
            if (!compile_constant_expr_to_slot(ordered_low, ctx, &rhs) &&
                !compile_expr_to_slot(ordered_low, ctx, &rhs)) {
               stmt_fixed_scratch_deactivate(ctx, &scratch);
               free((void *) skip_label);
               error_user("[%s:%d.%d] invalid case range start", ordered_low->file, ordered_low->line, ordered_low->column);
               continue;
            }
            emit_fixed_compare_scratch(type, "<=", rhs.offset, lhs.offset, size);
            stmt_fixed_scratch_deactivate(ctx, &scratch);
            emit(&es_code, "    beq %s\n", skip_label);

            stmt_fixed_scratch_activate(ctx, &scratch);
            if (!compile_constant_expr_to_slot(ordered_high, ctx, &rhs) &&
                !compile_expr_to_slot(ordered_high, ctx, &rhs)) {
               stmt_fixed_scratch_deactivate(ctx, &scratch);
               free((void *) skip_label);
               error_user("[%s:%d.%d] invalid case range end", ordered_high->file, ordered_high->line, ordered_high->column);
               continue;
            }
            emit_fixed_compare_scratch(type, "<=", lhs.offset, rhs.offset, size);
            stmt_fixed_scratch_deactivate(ctx, &scratch);
            emit(&es_code, "    bne %s\n", case_labels[i]);
            emit(&es_code, "%s:\n", skip_label);
            free((void *) skip_label);
            continue;
         }
      }

      stmt_fixed_scratch_activate(ctx, &scratch);
      if (!compile_expr_to_slot(case_expr, ctx, &rhs)) {
         stmt_fixed_scratch_deactivate(ctx, &scratch);
         error_user("[%s:%d.%d] invalid case expression", case_expr->file, case_expr->line, case_expr->column);
         continue;
      }
      emit_fixed_compare_scratch(type, "==", lhs.offset, rhs.offset, size);
      stmt_fixed_scratch_deactivate(ctx, &scratch);
      emit(&es_code, "    bne %s\n", case_labels[i]);
   }

   emit(&es_code, "    jmp %s\n", default_label ? default_label : cleanup_label);

   push_loop_labels(cleanup_label, current_continue_label());
   if (named_loop) {
      push_named_loop_labels(named_loop, cleanup_label, current_continue_label());
   }
   for (int i = 0; i < section_count; i++) {
      ASTNode *section = sections->children[i];
      ASTNode *body = (section->count > 1) ? section->children[1] : NULL;
      if (!case_labels[i]) {
         continue;
      }
      emit(&es_code, "%s:\n", case_labels[i]);
      if (body && !is_empty(body)) {
         compile_statement_list(body, ctx);
      }
   }
   pop_loop_labels();
   if (named_loop) {
      pop_named_loop_labels();
   }

   emit(&es_code, "%s:\n", cleanup_label);
   emit(&es_code, "%s:\n", end_label);
   stmt_fixed_scratch_finish(&scratch);

   for (int i = 0; i < section_count; i++) {
      free((void *) case_labels[i]);
   }
   free(case_labels);
   free((void *) cleanup_label);
   free((void *) end_label);
}

//! @brief Lower return stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_return_stmt(ASTNode *node, Context *ctx) {
   ContextEntry *ret = (ContextEntry *) set_get(ctx->vars, "$$");
   ASTNode *expr = (node->count > 0) ? node->children[0] : NULL;
   const char *return_label = (ctx && ctx->return_label) ? ctx->return_label : "@fini";

   if (!expr || is_empty(expr)) {
      emit(&es_code, "    jmp %s\n", return_label);
      return;
   }

   if (!ret) {
      error_user("[%s:%d.%d] void function cannot return a value", node->file, node->line, node->column);
   }

   if (!context_return_expr_is_coalesced_local(ctx, expr) &&
       !compile_expr_to_return_object(expr, ctx, ret)) {
      error_user("[%s:%d.%d] invalid return expression", node->file, node->line, node->column);
   }
   emit(&es_code, "    jmp %s\n", return_label);
}


typedef enum InlineAsmRefAccess {
   INLINE_ASM_REF_UNKNOWN = 0,
   INLINE_ASM_REF_READ,
   INLINE_ASM_REF_WRITE,
   INLINE_ASM_REF_READ_WRITE,
   INLINE_ASM_REF_ADDRESS
} InlineAsmRefAccess;

//! @brief Return whether a byte may begin an inline-assembly identifier token.
static bool inline_asm_identifier_start(unsigned char c) {
   return c == '_' || c == '$' || c >= 0x80 || isalpha(c);
}

//! @brief Return whether a byte may continue an inline-assembly identifier token.
static bool inline_asm_identifier_continue(unsigned char c) {
   return inline_asm_identifier_start(c) || isdigit(c);
}

//! @brief Classify how an inline-assembly opcode accesses its memory operand.
static InlineAsmRefAccess inline_asm_opcode_access(const char *mnemonic) {
   static const char *const read_ops[] = {
      "ADC", "AND", "BIT", "CMP", "CPX", "CPY", "EOR", "LDA", "LDX", "LDY", "ORA", "SBC",
      "ALR", "ANC", "ARR", "AXS", "LAS", "LAX", NULL
   };
   static const char *const write_ops[] = {
      "STA", "STX", "STY", "AHX", "SAX", "SHX", "SHY", "TAS", NULL
   };
   static const char *const read_write_ops[] = {
      "ASL", "DEC", "INC", "LSR", "ROL", "ROR", "DCP", "ISC", "ISB", "RLA", "RRA", "SLO", "SRE", NULL
   };
   static const char *const address_ops[] = {
      "BCC", "BCS", "BEQ", "BMI", "BNE", "BPL", "BRA", "BVC", "BVS", "JMP", "JSR", NULL
   };

   for (int i = 0; read_ops[i]; i++) {
      if (!strcmp(mnemonic, read_ops[i])) {
         return INLINE_ASM_REF_READ;
      }
   }
   for (int i = 0; write_ops[i]; i++) {
      if (!strcmp(mnemonic, write_ops[i])) {
         return INLINE_ASM_REF_WRITE;
      }
   }
   for (int i = 0; read_write_ops[i]; i++) {
      if (!strcmp(mnemonic, read_write_ops[i])) {
         return INLINE_ASM_REF_READ_WRITE;
      }
   }
   for (int i = 0; address_ops[i]; i++) {
      if (!strcmp(mnemonic, address_ops[i])) {
         return INLINE_ASM_REF_ADDRESS;
      }
   }
   return INLINE_ASM_REF_UNKNOWN;
}

//! @brief Resolve a source identifier to an absolute external binding visible at an inline-assembly statement.
//! @brief Record a writable file-scope object use found inside inline assembly.
static void inline_asm_note_phase_use(Context *ctx, const char *name) {
   const ASTNode *global;
   ContextEntry entry;
   char symbol[256];

   if (!name || !*name)
      return;
   global = global_decl_lookup(name);
   if (!global || !init_context_entry_from_global_decl(&entry, name, global) ||
       entry.is_absolute_ref)
      return;
   if (!format_user_asm_symbol(name, symbol, sizeof(symbol)))
      return;
   emit_phase_use_metadata(symbol, ctx ? ctx->phase_mask : 0);
}

static bool inline_asm_lookup_absolute_ref(Context *ctx, const char *name, ContextEntry *out) {
   ContextEntry *local;
   const ASTNode *global;

   if (!name || !*name || !out) {
      return false;
   }

   local = ctx_lookup(ctx, name);
   if (local && local->is_absolute_ref) {
      *out = *local;
      return true;
   }

   global = global_decl_lookup(name);
   return global && init_context_entry_from_global_decl(out, name, global) && out->is_absolute_ref;
}

//! @brief Select the legal address expression for one inline-assembly absolute-binding use.
static const char *inline_asm_ref_address(const ASTNode *node, const char *mnemonic,
                                          InlineAsmRefAccess access, const ContextEntry *entry,
                                          char *buf, size_t buf_size) {
   char read_buf[256];
   char write_buf[256];
   const char *read_expr = (entry && entry->read_expr && *entry->read_expr)
      ? assembler_address_expr(entry->read_expr, read_buf, sizeof(read_buf)) : NULL;
   const char *write_expr = (entry && entry->write_expr && *entry->write_expr)
      ? assembler_address_expr(entry->write_expr, write_buf, sizeof(write_buf)) : NULL;

   switch (access) {
      case INLINE_ASM_REF_READ:
         if (!read_expr) {
            error_user("[%s:%d.%d] inline asm '%s' reads from write-only absolute binding '%s'",
                       node->file, node->line, node->column, mnemonic, entry->name);
         }
         snprintf(buf, buf_size, "%s", read_expr);
         return buf;

      case INLINE_ASM_REF_WRITE:
         if (!write_expr) {
            error_user("[%s:%d.%d] inline asm '%s' writes to read-only absolute binding '%s'",
                       node->file, node->line, node->column, mnemonic, entry->name);
         }
         snprintf(buf, buf_size, "%s", write_expr);
         return buf;

      case INLINE_ASM_REF_READ_WRITE:
         if (!read_expr || !write_expr) {
            error_user("[%s:%d.%d] inline asm read-modify-write '%s' requires both read and write addresses for ref '%s'",
                       node->file, node->line, node->column, mnemonic, entry->name);
         }
         if (strcmp(read_expr, write_expr)) {
            error_user("[%s:%d.%d] inline asm read-modify-write '%s' cannot use split-address absolute binding '%s' (%s read, %s write)",
                       node->file, node->line, node->column, mnemonic, entry->name, read_expr, write_expr);
         }
         snprintf(buf, buf_size, "%s", read_expr);
         return buf;

      case INLINE_ASM_REF_ADDRESS:
         if (!read_expr || !write_expr || strcmp(read_expr, write_expr)) {
            error_user("[%s:%d.%d] inline asm address use of ref '%s' requires one identical read/write address",
                       node->file, node->line, node->column, entry->name);
         }
         snprintf(buf, buf_size, "%s", read_expr);
         return buf;

      case INLINE_ASM_REF_UNKNOWN:
      default:
         error_user("[%s:%d.%d] inline asm opcode '%s' has unknown ref access semantics for '%s'",
                    node->file, node->line, node->column, mnemonic, entry->name);
   }
}

//! @brief Append bytes to a dynamically grown inline-assembly rewrite buffer.
static void inline_asm_append(char **buf, size_t *len, size_t *cap, const char *text, size_t text_len) {
   size_t needed = *len + text_len + 1;
   if (needed > *cap) {
      size_t new_cap = *cap ? *cap : 128;
      while (new_cap < needed) {
         new_cap *= 2;
      }
      char *grown = realloc(*buf, new_cap);
      if (!grown) {
         free(*buf);
         error_unreachable("out of memory rewriting inline asm");
      }
      *buf = grown;
      *cap = new_cap;
   }
   memcpy(*buf + *len, text, text_len);
   *len += text_len;
   (*buf)[*len] = '\0';
}

//! @brief Resolve absolute-binding source names in one inline assembly statement.
static char *rewrite_inline_asm_refs(const ASTNode *node, Context *ctx, const char *line) {
   const char *p = line;
   const char *mnemonic_start;
   const char *mnemonic_end;
   const char *operand_start;
   char mnemonic[32];
   size_t mnemonic_len;
   InlineAsmRefAccess access;
   char *out = NULL;
   size_t out_len = 0;
   size_t out_cap = 0;
   char quote = '\0';

   while (isspace((unsigned char)*p)) {
      p++;
   }
   mnemonic_start = p;
   while (*p && !isspace((unsigned char)*p)) {
      p++;
   }
   mnemonic_end = p;

   /* Permit an assembler label before the instruction on the same line. */
   if (mnemonic_end > mnemonic_start && mnemonic_end[-1] == ':') {
      while (isspace((unsigned char)*p)) {
         p++;
      }
      if (!*p) {
         return strdup(line);
      }
      mnemonic_start = p;
      while (*p && !isspace((unsigned char)*p)) {
         p++;
      }
      mnemonic_end = p;
   }

   mnemonic_len = (size_t)(mnemonic_end - mnemonic_start);
   if (mnemonic_len == 0 || mnemonic_len >= sizeof(mnemonic)) {
      return strdup(line);
   }
   for (size_t i = 0; i < mnemonic_len; i++) {
      unsigned char c = (unsigned char)mnemonic_start[i];
      if (c == '.') {
         mnemonic_len = i;
         break;
      }
      mnemonic[i] = (char)toupper(c);
   }
   mnemonic[mnemonic_len] = '\0';
   operand_start = mnemonic_end;
   while (isspace((unsigned char)*operand_start)) {
      operand_start++;
   }

   access = inline_asm_opcode_access(mnemonic);
   if (*operand_start == '#') {
      access = INLINE_ASM_REF_ADDRESS;
   }

   inline_asm_append(&out, &out_len, &out_cap, line, (size_t)(operand_start - line));
   p = operand_start;
   while (*p) {
      if (quote) {
         inline_asm_append(&out, &out_len, &out_cap, p, 1);
         if (*p == '\\' && p[1]) {
            p++;
            inline_asm_append(&out, &out_len, &out_cap, p, 1);
         }
         else if (*p == quote) {
            quote = '\0';
         }
         p++;
         continue;
      }
      if (*p == '\'' || *p == '"') {
         quote = *p;
         inline_asm_append(&out, &out_len, &out_cap, p, 1);
         p++;
         continue;
      }
      if (inline_asm_identifier_start((unsigned char)*p)) {
         const char *start = p;
         ContextEntry entry;
         char name[256];
         size_t name_len;
         char address[256];
         const char *replacement;

         while (inline_asm_identifier_continue((unsigned char)*p)) {
            p++;
         }
         name_len = (size_t)(p - start);
         if (name_len >= sizeof(name)) {
            inline_asm_append(&out, &out_len, &out_cap, start, name_len);
            continue;
         }
         memcpy(name, start, name_len);
         name[name_len] = '\0';

         /* @name is an assembler-local label, never a source ref identifier. */
         if (start > operand_start && start[-1] == '@') {
            inline_asm_append(&out, &out_len, &out_cap, start, name_len);
            continue;
         }

         inline_asm_note_phase_use(ctx, name);

         if (!inline_asm_lookup_absolute_ref(ctx, name, &entry)) {
            inline_asm_append(&out, &out_len, &out_cap, start, name_len);
            continue;
         }

         replacement = inline_asm_ref_address(node, mnemonic, access, &entry, address, sizeof(address));
         inline_asm_append(&out, &out_len, &out_cap, replacement, strlen(replacement));
         continue;
      }
      inline_asm_append(&out, &out_len, &out_cap, p, 1);
      p++;
   }

   if (!out) {
      return strdup(line);
   }
   return out;
}

//! @brief Give assembler-local labels inside one inline expansion a call-site prefix.
static char *rewrite_inline_asm_local_labels(const Context *ctx, const char *line) {
   const char *p = line;
   char *out = NULL;
   size_t out_len = 0;
   size_t out_cap = 0;
   char quote = '\0';

   if (!ctx || !ctx->inline_label_prefix || !*ctx->inline_label_prefix || !line) {
      return strdup(line ? line : "");
   }

   while (*p) {
      if (quote) {
         inline_asm_append(&out, &out_len, &out_cap, p, 1);
         if (*p == '\\' && p[1]) {
            p++;
            inline_asm_append(&out, &out_len, &out_cap, p, 1);
         }
         else if (*p == quote) {
            quote = '\0';
         }
         p++;
         continue;
      }
      if (*p == '\'' || *p == '"') {
         quote = *p;
         inline_asm_append(&out, &out_len, &out_cap, p, 1);
         p++;
         continue;
      }
      if (*p == ';') {
         inline_asm_append(&out, &out_len, &out_cap, p, strlen(p));
         break;
      }
      if (*p == '@' && inline_asm_identifier_start((unsigned char)p[1]) &&
          (p == line || (!inline_asm_identifier_continue((unsigned char)p[-1]) && p[-1] != '?'))) {
         const char *name_start = p + 1;
         const char *name_end = name_start;
         char prefix[320];

         while (inline_asm_identifier_continue((unsigned char)*name_end)) {
            name_end++;
         }
         snprintf(prefix, sizeof(prefix), "@%s_asm_", ctx->inline_label_prefix);
         inline_asm_append(&out, &out_len, &out_cap, prefix, strlen(prefix));
         inline_asm_append(&out, &out_len, &out_cap, name_start,
                           (size_t)(name_end - name_start));
         p = name_end;
         continue;
      }
      inline_asm_append(&out, &out_len, &out_cap, p, 1);
      p++;
   }

   return out ? out : strdup(line);
}

//! @brief Lower asm stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_asm_stmt(ASTNode *node, Context *ctx) {
   char *rewritten;
   char *localized;

   if (!node || is_empty(node) || node->count < 1 || !node->children[0]) {
      return;
   }

   const ASTNode *leaf = node->children[0];
   if (leaf->kind != AST_ASM || !leaf->strval) {
      warning("[%s:%d.%d] inline asm statement malformed", node->file, node->line, node->column);
      return;
   }

   rewritten = rewrite_inline_asm_refs(node, ctx, leaf->strval);
   if (!rewritten) {
      error_unreachable("out of memory rewriting inline asm");
   }
   localized = rewrite_inline_asm_local_labels(ctx, rewritten);
   if (!localized) {
      free(rewritten);
      error_unreachable("out of memory localizing inline asm labels");
   }
   emit(&es_code, EMIT_INLINE_ASM_BEGIN_MARKER "\n%s\n" EMIT_INLINE_ASM_END_MARKER "\n", localized);
   free(localized);
   free(rewritten);
}


//! @brief Lower statement list from AST/semantic state into generated assembly or linker-visible metadata.
void compile_statement_list(ASTNode *node, Context *ctx) {
   if (!node || is_empty(node)) {
      return;
   }

   for (int i = 0; i < node->count; i++) {
      ASTNode *stmt = node->children[i];
      const char *page_selector_target = NULL;
      bool page_selector_sequence = false;
      int reused_pointer_skip = 0;

      if (compile_doubled_page_pointer_reuse(node, i, ctx, &reused_pointer_skip)) {
         i += reused_pointer_skip;
         continue;
      }

      if (ctx && i + 1 < node->count &&
          classify_page_pointer_selector(stmt, ctx, &page_selector_target) &&
          page_selector_target &&
          classify_tracked_pointer_u8_update(node->children[i + 1], ctx,
                                             page_selector_target)) {
         clear_pointer_low_range_fact(ctx);
         ctx->suppress_page_pointer_low_name = page_selector_target;
         page_selector_sequence = true;
      }
      else if (ctx && ctx->pointer_low_range_known && ctx->pointer_low_range_name &&
               !classify_tracked_pointer_u8_update(stmt, ctx,
                                                   ctx->pointer_low_range_name) &&
               !classify_tracked_pointer_u8_conditional_update(stmt, ctx,
                                                               ctx->pointer_low_range_name)) {
         clear_pointer_low_range_fact(ctx);
      }

      if (page_selector_sequence &&
          compile_compact_page_pointer_selector(stmt, ctx, page_selector_target)) {
         /* The compact selector installs only the proven page high byte. */
      }
      else if (!strcmp(stmt->name, "return_stmt")) {
         compile_return_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "expr") || !strcmp(stmt->name, "assign_expr")) {
         compile_expr(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "defdecl_stmt")) {
         ASTNode *list = stmt->children[0];
         for (int j = 0; j < list->count; j++) {
            compile_local_decl_item(list->children[j], ctx);
         }
      }
      else if (!strcmp(stmt->name, "if_stmt")) {
         compile_if_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "while_stmt")) {
         compile_while_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "for_stmt")) {
         compile_for_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "break_stmt")) {
         compile_break_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "continue_stmt")) {
         compile_continue_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "do_stmt")) {
         compile_do_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "label_stmt")) {
         compile_label_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "goto_stmt")) {
         compile_goto_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "switch_stmt")) {
         compile_switch_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "asm_stmt")) {
         compile_asm_stmt(stmt, ctx);
      }
      else if (!strcmp(stmt->name, "statement_list")) {
         compile_statement_list(stmt, ctx);
      }
      else {
         compile_expr(stmt, ctx);
      }

      if (page_selector_sequence && ctx) {
         ctx->suppress_page_pointer_low_name = NULL;
         ctx->pointer_low_range_name = page_selector_target;
         ctx->pointer_low_range_min = 0;
         ctx->pointer_low_range_max = 0;
         ctx->pointer_low_range_known = true;
      }
   }
}

