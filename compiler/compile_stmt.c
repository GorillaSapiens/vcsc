//! @file compiler/compile_stmt.c
//! @brief Implements statement lowering for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>

#include "ast.h"
#include "compile.h"
#include "compile_init.h"
#include "compile_internal.h"
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

typedef struct StmtFixedScratch {
   int saved_locals;
   int saved_high_water;
   int reserved;
   int used;
   char symbol[96];
} StmtFixedScratch;

//! @brief Prepare one reusable fixed-address statement working area.
static void stmt_fixed_scratch_prepare(Context *ctx, const char *prefix, int reserved,
                                       StmtFixedScratch *scratch) {
   memset(scratch, 0, sizeof(*scratch));
   scratch->saved_locals = ctx ? ctx->locals : 0;
   scratch->saved_high_water = ctx ? ctx->locals_high_water : 0;
   scratch->reserved = reserved > 0 ? reserved : 1;
   scratch->used = scratch->reserved;
   snprintf(scratch->symbol, sizeof(scratch->symbol), "__n65_%s_%d", prefix, label_counter++);
}

//! @brief Redirect fp to a prepared fixed-address statement working area.
static void stmt_fixed_scratch_activate(Context *ctx, StmtFixedScratch *scratch) {
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

//! @brief Restore fp after one use of a reusable statement scratch area.
static void stmt_fixed_scratch_deactivate(Context *ctx, StmtFixedScratch *scratch) {
   if (ctx && ctx->locals_high_water > scratch->used) {
      scratch->used = ctx->locals_high_water;
   }
   emit(&es_code, "    pla\n");
   emit(&es_code, "    sta fp\n");
   emit(&es_code, "    pla\n");
   emit(&es_code, "    sta fp+1\n");
   if (ctx) {
      ctx->locals = scratch->saved_locals;
      ctx->locals_high_water = scratch->saved_high_water;
   }
}

//! @brief Declare the maximum fixed storage required by a statement scratch area.
static void stmt_fixed_scratch_finish(StmtFixedScratch *scratch) {
   emit(&es_bss, ".segment \"BSS\"\n");
   emit(&es_bss, "%s:\n", scratch->symbol);
   emit(&es_bss, "\t.res %d\n", scratch->used > 0 ? scratch->used : 1);
}

static void predeclare_local_decl_item(ASTNode *node, Context *ctx);
static void compile_local_decl_item(ASTNode *node, Context *ctx);
static bool compile_runtime_initializer_to_symbol(ASTNode *expression, Context *ctx,
      const ASTNode *type, const ASTNode *declarator, const char *symbol, int size);
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
static const ASTNode *decl_node_declarator(const ASTNode *node) {
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

//! @brief Report address spec without ref diagnostics with the location/context expected by compiler statement lowering callers.
static void warn_address_spec_without_ref(const ASTNode *node, const char *name) {
   if (!node) {
      error_unreachable("internal error: !node in %s %s:%d\n",
         __func__, __FILE__, __LINE__);
      return;
   }
   warning("[%s:%d.%d] '@' on non-ref declaration '%s' is ignored",
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

//! @brief Lower if stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_if_stmt(ASTNode *node, Context *ctx) {
   const char *false_label = next_label("if_false");
   const char *end_label = next_label("if_end");
   ASTNode *cond = node->children[0];
   ASTNode *then_block = node->children[1];
   ASTNode *else_block = (node->count > 2) ? node->children[2] : NULL;

   if (!compile_condition_branch_false(cond, ctx, false_label)) {
      error_user("[%s:%d.%d] invalid if condition", node->file, node->line, node->column);
      free((void *) false_label);
      free((void *) end_label);
      return;
   }

   compile_statement_list(then_block, ctx);
   if (else_block && !is_empty(else_block)) {
      emit(&es_code, "    jmp %s\n", end_label);
   }
   emit(&es_code, "%s:\n", false_label);
   if (else_block && !is_empty(else_block)) {
      compile_statement_list(else_block, ctx);
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
      const ASTNode *type, const ASTNode *declarator, const char *symbol, int size) {
   StmtFixedScratch scratch;
   bool ok;

   if (!expression || is_empty(expression) || !ctx || !symbol || size <= 0) {
      return false;
   }

   stmt_fixed_scratch_prepare(ctx, "inittmp", size, &scratch);
   stmt_fixed_scratch_activate(ctx, &scratch);

   if (initializer_is_list(unwrap_expr_node(expression)) ||
       declarator_array_count(declarator) > 0 || type_is_aggregate(type)) {
      unsigned char *zeroes = (unsigned char *) calloc(size ? size : 1, sizeof(unsigned char));
      if (!zeroes) {
         error_unreachable("out of memory");
      }
      emit_store_immediate_to_fp(0, zeroes, size);
      free(zeroes);
      ok = compile_initializer_to_fp(expression, ctx, type, declarator, 0, size);
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
         .offset = 0,
         .size = size
      };
      ok = compile_expr_to_slot(expression, ctx, &target);
   }

   if (ok) {
      emit_copy_fp_to_symbol(symbol, 0, size);
   }
   stmt_fixed_scratch_deactivate(ctx, &scratch);
   stmt_fixed_scratch_finish(&scratch);
   return ok;
}

//! @brief Lower expr to the current function return object from AST/semantic state into generated assembly or linker-visible metadata.
static bool compile_expr_to_return_object(ASTNode *expr, Context *ctx, ContextEntry *ret) {
   char sym[256];

   if (!ret || !entry_symbol_name(ctx, ret, sym, sizeof(sym))) {
      return false;
   }
   return compile_runtime_initializer_to_symbol(expr, ctx, ret->type, ret->declarator, sym, ret->size);
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
   ASTNode *declarator = (ASTNode *) decl_node_declarator(node);
   const ASTNode *addrspec = decl_node_address_spec(node);
   const char *name    = declarator_name(declarator);
   int size            = declarator_storage_size(type, declarator);
   ContextEntry *entry = (ContextEntry *) set_get(ctx->vars, name);
   validate_nonreserved_implementation_name(name, node);
   emit_mem_region_metadata_for_modifiers(node, modifiers);

   if (entry != NULL) {
      return;
   }

   if (addrspec != NULL && !has_modifier(modifiers, "ref")) {
      warn_address_spec_without_ref(node, name);
   }

   if (has_modifier(modifiers, "ref") && addrspec != NULL) {
      if (!address_spec_has_read(addrspec) && !address_spec_has_write(addrspec)) {
         error_user("[%s:%d.%d] absolute ref '%s' cannot use none for both read and write address",
               node->file, node->line, node->column, name);
      }
      entry = (ContextEntry *) malloc(sizeof(ContextEntry));
      if (!entry) {
         error_unreachable("out of memory");
      }
      entry->name = strdup(name);
      entry->is_static = false;
      entry->is_zeropage = false;
      entry->is_global = false;
      entry->is_ref = false;
      entry->is_absolute_ref = true;
      entry->read_expr = address_spec_read_expr(addrspec);
      entry->write_expr = address_spec_write_expr(addrspec);
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
   ASTNode *declarator = (ASTNode *) decl_node_declarator(node);
   const char *name    = declarator_name(declarator);
   ASTNode *expression = node->children[node->count - 1];
   validate_nonreserved_implementation_name(name, node);
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

   if (entry->is_absolute_ref) {
      StmtFixedScratch scratch;
      LValueRef lv;
      bool ok;

      if (is_empty(expression)) {
         return;
      }

      stmt_fixed_scratch_prepare(ctx, "absinittmp", size, &scratch);
      stmt_fixed_scratch_activate(ctx, &scratch);
      if (initializer_is_list(unwrap_expr_node(expression)) ||
          declarator_array_count(declarator) > 0 || type_is_aggregate(type)) {
         emit_fill_fp_bytes(0, 0, size, 0x00);
         ok = compile_initializer_to_fp(expression, ctx, type, declarator, 0, size);
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
      if (!entry_symbol_name(ctx, entry, sym, sizeof(sym))) {
         error_user("[%s:%d.%d] invalid initializer for '%s'", node->file, node->line, node->column, name);
         return;
      }

      /* Non-static source locals retain automatic initialization semantics,
         but their storage is a fixed per-function symbol. */
      if (!has_modifier(modifiers, "static")) {
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

         if (!is_empty(expression) &&
             !compile_runtime_initializer_to_symbol(expression, ctx, type, declarator, sym, size)) {
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
            remember_pending_global_init(name, sym, type, declarator, expression, size, entry->is_zeropage, false, NULL, NULL);
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
   (void) ctx;
   emit(&es_code, "@user_%s:\n", node->children[0]->strval);
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
   (void) ctx;
   if (node->count > 0 && !is_empty(node->children[0])) {
      emit(&es_code, "    jmp @user_%s\n", node->children[0]->strval);
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
   bool is_signed;

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
   is_signed = type_is_signed_integer(type);
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

   stmt_fixed_scratch_prepare(ctx, "switchtmp", compare_size, &scratch);
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
            emit_prepare_fp_ptr(0, lhs.offset);
            emit_prepare_fp_ptr(1, rhs.offset);
            emit(&es_code, "    lda #$%02x\n", size & 0xff);
            emit(&es_code, "    sta arg0\n");
            remember_runtime_import("eqN");
            emit(&es_code, "    jsr _eqN\n");
            stmt_fixed_scratch_deactivate(ctx, &scratch);
            emit(&es_code, "    lda arg1\n");
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
            const char *le_helper = is_signed ? (type_is_big_endian(type) ? "leNsbe" : "leNsle")
                                               : (type_is_big_endian(type) ? "leNube" : "leNule");

            if (!skip_label) {
               warning("[%s:%d.%d] switch case label generation failed", case_expr->file, case_expr->line, case_expr->column);
               continue;
            }

            if (eval_constant_initializer_expr(low, &low_value) &&
                eval_constant_initializer_expr(high, &high_value) &&
                low_value.kind == high_value.kind) {
               if ((low_value.kind == INIT_CONST_INT && low_value.i > high_value.i) ||
                   (low_value.kind == INIT_CONST_FLOAT && low_value.f > high_value.f)) {
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
            emit_prepare_fp_ptr(0, rhs.offset);
            emit_prepare_fp_ptr(1, lhs.offset);
            emit(&es_code, "    lda #$%02x\n", size & 0xff);
            emit(&es_code, "    sta arg0\n");
            remember_runtime_import(le_helper);
            emit(&es_code, "    jsr _%s\n", le_helper);
            stmt_fixed_scratch_deactivate(ctx, &scratch);
            emit(&es_code, "    lda arg1\n");
            emit(&es_code, "    beq %s\n", skip_label);

            stmt_fixed_scratch_activate(ctx, &scratch);
            if (!compile_constant_expr_to_slot(ordered_high, ctx, &rhs) &&
                !compile_expr_to_slot(ordered_high, ctx, &rhs)) {
               stmt_fixed_scratch_deactivate(ctx, &scratch);
               free((void *) skip_label);
               error_user("[%s:%d.%d] invalid case range end", ordered_high->file, ordered_high->line, ordered_high->column);
               continue;
            }
            emit_prepare_fp_ptr(0, lhs.offset);
            emit_prepare_fp_ptr(1, rhs.offset);
            emit(&es_code, "    lda #$%02x\n", size & 0xff);
            emit(&es_code, "    sta arg0\n");
            remember_runtime_import(le_helper);
            emit(&es_code, "    jsr _%s\n", le_helper);
            stmt_fixed_scratch_deactivate(ctx, &scratch);
            emit(&es_code, "    lda arg1\n");
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
      emit_prepare_fp_ptr(0, lhs.offset);
      emit_prepare_fp_ptr(1, rhs.offset);
      emit(&es_code, "    lda #$%02x\n", size & 0xff);
      emit(&es_code, "    sta arg0\n");
      remember_runtime_import("eqN");
      emit(&es_code, "    jsr _eqN\n");
      stmt_fixed_scratch_deactivate(ctx, &scratch);
      emit(&es_code, "    lda arg1\n");
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

   if (!expr || is_empty(expr)) {
      emit(&es_code, "    jmp @fini\n");
      return;
   }

   if (!ret) {
      error_user("[%s:%d.%d] void function cannot return a value", node->file, node->line, node->column);
   }

   if (!compile_expr_to_return_object(expr, ctx, ret)) {
      error_user("[%s:%d.%d] invalid return expression", node->file, node->line, node->column);
   }
   emit(&es_code, "    jmp @fini\n");
}


//! @brief Lower asm stmt from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_asm_stmt(ASTNode *node, Context *ctx) {
   (void) ctx;

   if (!node || is_empty(node) || node->count < 1 || !node->children[0]) {
      return;
   }

   const ASTNode *leaf = node->children[0];
   if (leaf->kind != AST_ASM || !leaf->strval) {
      warning("[%s:%d.%d] inline asm statement malformed", node->file, node->line, node->column);
      return;
   }

   emit(&es_code, EMIT_INLINE_ASM_BEGIN_MARKER "\n%s\n" EMIT_INLINE_ASM_END_MARKER "\n", leaf->strval);
}


//! @brief Lower statement list from AST/semantic state into generated assembly or linker-visible metadata.
void compile_statement_list(ASTNode *node, Context *ctx) {
   if (!node || is_empty(node)) {
      return;
   }

   for (int i = 0; i < node->count; i++) {
      ASTNode *stmt = node->children[i];
      if (!strcmp(stmt->name, "return_stmt")) {
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
   }
}

