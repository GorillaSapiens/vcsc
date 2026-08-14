//! @file compiler/compile_inline_identity.c
//! @brief Enforces item-31 ABI/assembly identity and reachability boundaries.
//! @ingroup compiler

#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "ast.h"
#include "compile_function.h"
#include "compile_function_registry.h"
#include "compile_inline_analysis.h"
#include "compile_inline_identity.h"
#include "compile_inline_specialize.h"
#include "compile_init.h"
#include "compile_type.h"
#include "messages.h"

static ASTNode *identity_program;
static const ASTNode **asm_escaped;
static size_t asm_escaped_count;
static bool dead_pruning_enabled;

#define INLINE_IDENTITY_MAX_SOURCE_INLINE_DEPTH 128

static void reset_asm_escapes(void) {
   free(asm_escaped);
   asm_escaped = NULL;
   asm_escaped_count = 0;
}

static bool function_in_list(const ASTNode *fn, const ASTNode **list, size_t count) {
   for (size_t i = 0; i < count; i++) {
      if (list[i] == fn) return true;
   }
   return false;
}

static void remember_asm_escape(const ASTNode *fn) {
   const ASTNode **grown;
   if (!fn || function_in_list(fn, asm_escaped, asm_escaped_count)) return;
   grown = (const ASTNode **)realloc(asm_escaped,
      sizeof(*asm_escaped) * (asm_escaped_count + 1));
   if (!grown) error_unreachable("out of memory recording inline assembly escape");
   asm_escaped = grown;
   asm_escaped[asm_escaped_count++] = fn;
}

static bool asm_identifier_continue(unsigned char c) {
   return c == '_' || c == '$' || c == '?' ||
          (c >= '0' && c <= '9') ||
          (c >= 'A' && c <= 'Z') ||
          (c >= 'a' && c <= 'z');
}

/* Treat NAME itself and every NAME$... ABI-family symbol as one identity.
   Comments are intentionally not parsed away: a false-positive veto is safe,
   while missing an assembler-visible callable/activation symbol is not. */
static bool asm_text_mentions_family(const char *text, const char *name) {
   size_t n;
   if (!text || !name || !*name) return false;
   n = strlen(name);
   for (const char *p = text; (p = strstr(p, name)) != NULL; p++) {
      unsigned char before = p == text ? 0 : (unsigned char)p[-1];
      unsigned char after = (unsigned char)p[n];
      if (asm_identifier_continue(before)) continue;
      if (!asm_identifier_continue(after) || after == '$') return true;
   }
   return false;
}

static bool asm_leaf_mentions_function(const ASTNode *leaf, const ASTNode *fn) {
   const char *source_name;
   char asm_name[256];
   if (!leaf || !leaf->strval || !fn) return false;
   source_name = declarator_name(function_declarator_node((ASTNode *)fn));
   if (!source_name || !*source_name ||
       !function_symbol_name(fn, source_name, asm_name, sizeof(asm_name))) {
      return false;
   }
   return asm_text_mentions_family(leaf->strval, source_name) ||
          (strcmp(source_name, asm_name) && asm_text_mentions_family(leaf->strval, asm_name));
}

static void scan_asm_leaf_against_functions(const ASTNode *leaf, ASTNode *program) {
   if (!leaf || !program) return;
   for (int i = 0; i < program->count; i++) {
      ASTNode *fn = program->children[i];
      if (!fn || strcmp(fn->name, "defdecl_stmt") || !function_has_body(fn)) continue;
      if (asm_leaf_mentions_function(leaf, fn)) remember_asm_escape(fn);
   }
}

static void scan_asm_escapes(const ASTNode *node, ASTNode *program) {
   if (!node) return;
   if (!strcmp(node->name, "asm_stmt")) {
      for (int i = 0; i < node->count; i++) {
         const ASTNode *leaf = node->children[i];
         if (leaf && leaf->kind == AST_ASM) scan_asm_leaf_against_functions(leaf, program);
      }
      return;
   }
   for (int i = 0; i < node->count; i++) scan_asm_escapes(node->children[i], program);
}

static bool subtree_contains_asm(const ASTNode *node) {
   if (!node) return false;
   if (node->kind == AST_ASM || !strcmp(node->name, "asm_stmt")) return true;
   for (int i = 0; i < node->count; i++) {
      if (subtree_contains_asm(node->children[i])) return true;
   }
   return false;
}

static bool function_has_merged_contract(const ASTNode *fn) {
   const char *name;
   if (!fn) return false;
   name = declarator_name(function_declarator_node((ASTNode *)fn));
   return name && declaration_symbol_use_contract(DECL_CONTRACT_FUNCTION, name, NULL) !=
                  DECL_USE_CONTRACT_NONE;
}

static bool function_is_internal_definition(const ASTNode *fn) {
   const ASTNode *mods;
   if (!fn || !function_has_body(fn) || function_is_inline(fn)) return false;
   mods = function_modifiers_node(fn);
   return mods && has_modifier((ASTNode *)mods, "static") &&
          !has_modifier((ASTNode *)mods, "extern");
}

void optimizer_inline_set_dead_pruning(bool enabled) {
   dead_pruning_enabled = enabled;
}

static void mark_identity_roots(ASTNode *program) {
   if (!program) return;
   for (int i = 0; i < program->count; i++) {
      ASTNode *fn = program->children[i];
      const ASTNode *mods;
      const char *name;
      bool root = false;
      if (!fn || strcmp(fn->name, "defdecl_stmt") || !function_has_body(fn) ||
          function_is_inline(fn)) {
         continue;
      }
      mods = function_modifiers_node(fn);
      name = declarator_name(function_declarator_node(fn));
      if (!mods || !has_modifier((ASTNode *)mods, "static")) root = true;
      if (name && !strcmp(name, "main")) root = true;
      if (function_has_merged_contract(fn)) root = true;
      if (function_in_list(fn, asm_escaped, asm_escaped_count)) root = true;
      if (root) inline_analysis_mark_reachable_root(fn);
   }
}

static bool specialized_condition_truth(const ASTNode *fn, ASTNode *expr,
                                        bool *truth_out) {
   InitConstValue value = {0};
   const char *name;
   const ASTNode *params;

   if (!fn || !expr || !truth_out) return false;
   if (eval_constant_initializer_expr(expr, &value) && value.kind == INIT_CONST_INT) {
      *truth_out = value.i != 0;
      return true;
   }
   name = expr_bare_identifier_name((ASTNode *)unwrap_expr_node(expr));
   if (!name) return false;
   params = declarator_parameter_list(function_declarator_node((ASTNode *)fn));
   if (!params || is_empty(params)) return false;
   for (int i = 0; i < params->count; i++) {
      const ASTNode *parameter = params->children[i];
      const char *pname;
      InlineValueSpecialization spec;
      if (!parameter || parameter_is_void(parameter) || !parameter_type(parameter)) continue;
      pname = parameter_name(parameter, i);
      if (!parameter_is_ref(parameter) && pname && !strcmp(name, pname) &&
          optimizer_value_parameter_specialization(fn, i, &spec) &&
          spec.kind == INLINE_VALUE_INTEGER_CONSTANT) {
         *truth_out = spec.constant_value != 0;
         return true;
      }
   }
   return false;
}

static void set_generated_calls_reachable(ASTNode *node, const ASTNode *owner,
                                          bool enabled,
                                          const ASTNode **inline_stack,
                                          int inline_depth) {
   if (!node || !owner) return;
   if (!strcmp(node->name, "()") && node->count >= 1) {
      ASTNode *callee = node->children[0];
      ASTNode *args = node->count > 1 ? node->children[1] : NULL;
      const char *callee_name = expr_bare_identifier_name(callee);
      const ASTNode *target = callee_name ? resolve_function_designator_target(callee_name) : NULL;

      if (args && !is_empty(args))
         set_generated_calls_reachable(args, owner, enabled, inline_stack, inline_depth);
      if (target) {
         if (function_is_inline(target) && function_has_body(target)) {
            bool recursive = false;
            for (int i = 0; i < inline_depth; i++) {
               if (inline_stack[i] == target) { recursive = true; break; }
            }
            if (!recursive && inline_depth < INLINE_IDENTITY_MAX_SOURCE_INLINE_DEPTH) {
               inline_stack[inline_depth] = target;
               set_generated_calls_reachable(target->children[2], owner, enabled,
                                             inline_stack, inline_depth + 1);
            }
         }
         else {
            inline_analysis_set_direct_call_reachability(owner, node, enabled);
         }
      }
      return;
   }
   for (int i = 0; i < node->count; i++)
      set_generated_calls_reachable(node->children[i], owner, enabled,
                                    inline_stack, inline_depth);
}

static void apply_specialized_branch_reachability(ASTNode *node, const ASTNode *owner,
                                                   const ASTNode **inline_stack,
                                                   int inline_depth) {
   if (!node || !owner) return;
   if (!strcmp(node->name, "if_stmt") && node->count >= 2) {
      bool truth = false;
      if (specialized_condition_truth(owner, node->children[0], &truth)) {
         ASTNode *selected = truth ? node->children[1]
                                   : (node->count > 2 ? node->children[2] : NULL);
         ASTNode *discarded = truth ? (node->count > 2 ? node->children[2] : NULL)
                                    : node->children[1];
         if (discarded)
            set_generated_calls_reachable(discarded, owner, false, inline_stack, inline_depth);
         if (selected)
            apply_specialized_branch_reachability(selected, owner, inline_stack, inline_depth);
         return;
      }
   }
   for (int i = 0; i < node->count; i++)
      apply_specialized_branch_reachability(node->children[i], owner,
                                            inline_stack, inline_depth);
}

void analyze_optimizer_inline_identity(ASTNode *program) {
   identity_program = program;
   reset_asm_escapes();
   if (!program) return;

   scan_asm_escapes(program, program);
   inline_analysis_reset_reachability();
   mark_identity_roots(program);
   inline_analysis_compute_reachability();
}

void recompute_optimizer_inline_reachability(ASTNode *program) {
   const ASTNode *inline_stack[INLINE_IDENTITY_MAX_SOURCE_INLINE_DEPTH];
   if (!program || program != identity_program) return;
   inline_analysis_reset_reachability();
   mark_identity_roots(program);
   for (int i = 0; i < program->count; i++) {
      ASTNode *fn = program->children[i];
      if (!fn || strcmp(fn->name, "defdecl_stmt") || !function_has_body(fn) ||
          function_is_inline(fn)) continue;
      apply_specialized_branch_reachability(fn->children[2], fn, inline_stack, 0);
   }
   inline_analysis_compute_reachability();
}

bool optimizer_inline_function_reachable(const ASTNode *fn) {
   return inline_analysis_is_reachable(fn);
}

const char *optimizer_inline_identity_rejection(const ASTNode *fn) {
   const ASTNode *mods;
   if (!fn || !function_has_body(fn)) return "no-body";
   if (function_is_inline(fn)) return "source-inline";
   mods = function_modifiers_node(fn);
   if (!mods || has_modifier((ASTNode *)mods, "extern")) return "extern-abi";
   if (!has_modifier((ASTNode *)mods, "static")) return "exported-abi";
   if (function_has_merged_contract(fn)) return "contract-identity";
   if (subtree_contains_asm(fn)) return "callee-inline-asm";
   if (function_in_list(fn, asm_escaped, asm_escaped_count)) return "asm-escaped-identity";
   if (!inline_analysis_is_reachable(fn)) return "unreachable";
   return NULL;
}

bool optimizer_inline_identity_legal(const ASTNode *fn) {
   return optimizer_inline_identity_rejection(fn) == NULL;
}

bool optimizer_inline_function_dead(const ASTNode *fn) {
   if (!dead_pruning_enabled || !function_is_internal_definition(fn)) return false;
   if (function_has_merged_contract(fn)) return false;
   /* Inline assembly is opaque: even an otherwise unreachable body may define
      an assembler-visible label/export consumed by another link input. */
   if (subtree_contains_asm(fn)) return false;
   if (function_in_list(fn, asm_escaped, asm_escaped_count)) return false;
   if (inline_analysis_is_in_cycle(fn)) return false;
   return !inline_analysis_is_reachable(fn);
}
