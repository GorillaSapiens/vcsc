//! @file compiler/compile_inline_prepass.c
//! @brief Builds optimizer direct-callsite facts before ordinary function lowering.
//! @ingroup compiler

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#include "ast.h"
#include "compile_declarator.h"
#include "compile_expr_info.h"
#include "compile_function_registry.h"
#include "compile_inline_analysis.h"
#include "compile_inline_prepass.h"
#include "compile_support.h"
#include "compile_type.h"

#define INLINE_PREPASS_MAX_DEPTH 128

//! @brief Register baseline source/linkage facts for one top-level function definition.
static void register_function_definition(const ASTNode *fn) {
   const ASTNode *modifiers;
   unsigned flags = 0;

   if (!fn || !function_has_body(fn)) {
      return;
   }
   modifiers = function_modifiers_node(fn);
   flags |= INLINE_FUNCTION_DEFINED;
   if (modifiers && has_modifier((ASTNode *)modifiers, "static")) {
      flags |= INLINE_FUNCTION_INTERNAL;
   }
   if (function_is_inline(fn)) {
      flags |= INLINE_FUNCTION_SOURCE_INLINE;
   }
   inline_analysis_register_function(fn, flags);
}

//! @brief Return the top-level function definition carried by one program child.
static ASTNode *program_child_function_definition(ASTNode *node) {
   if (!node || strcmp(node->name, "defdecl_stmt") || node->count != 3) {
      return NULL;
   }
   return node;
}

//! @brief Recursively count ordinary calls, expanding source-inline bodies per use.
static void scan_direct_calls(ASTNode *node, const ASTNode *ordinary_owner,
                              const ASTNode **inline_stack, int inline_depth) {
   if (!node) {
      return;
   }

   if (!strcmp(node->name, "()") && node->count >= 1) {
      ASTNode *callee = node->children[0];
      ASTNode *args = node->count > 1 ? node->children[1] : NULL;
      const char *callee_name = expr_bare_identifier_name(callee);
      const ASTNode *target = callee_name
         ? resolve_function_designator_target(callee_name) : NULL;

      /* Argument expressions execute at the caller before either an ordinary
         call or source-inline body, so count nested calls there exactly once. */
      if (args && !is_empty(args)) {
         scan_direct_calls(args, ordinary_owner, inline_stack, inline_depth);
      }

      if (target) {
         if (function_is_inline(target) && function_has_body(target)) {
            bool recursive = false;
            for (int i = 0; i < inline_depth; i++) {
               if (inline_stack[i] == target) {
                  recursive = true;
                  break;
               }
            }
            /* Invalid recursive source-inline programs are diagnosed by normal
               lowering. Stop this analysis path rather than recursing forever. */
            if (!recursive && inline_depth < INLINE_PREPASS_MAX_DEPTH) {
               inline_stack[inline_depth] = target;
               scan_direct_calls(target->children[2], ordinary_owner,
                                 inline_stack, inline_depth + 1);
            }
         }
         else {
            inline_analysis_record_direct_call(ordinary_owner, node, target);
         }
      }
      return;
   }

   for (int i = 0; i < node->count; i++) {
      scan_direct_calls(node->children[i], ordinary_owner,
                        inline_stack, inline_depth);
   }
}

//! @brief Build complete direct-call occurrence facts before function emission.
void analyze_optimizer_direct_calls(ASTNode *program) {
   const ASTNode *inline_stack[INLINE_PREPASS_MAX_DEPTH];

   inline_analysis_reset();
   if (!program) {
      return;
   }

   /* Register definitions first so zero-call functions and baseline linkage
      facts are visible before the first ordinary body is lowered. */
   for (int i = 0; i < program->count; i++) {
      ASTNode *fn = program_child_function_definition(program->children[i]);
      if (fn) {
         register_function_definition(fn);
      }
   }

   /* Ordinary functions are emitted once. Source-inline functions are not;
      their bodies are scanned only at each expansion site so nested ordinary
      calls acquire the same multiplicity they will have in generated code. */
   for (int i = 0; i < program->count; i++) {
      ASTNode *fn = program_child_function_definition(program->children[i]);
      if (!fn || function_is_inline(fn)) {
         continue;
      }
      scan_direct_calls(fn->children[2], fn, inline_stack, 0);
   }
}
