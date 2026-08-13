//! @file compiler/compile_inline_legality.c
//! @brief Placement/timing legality checks for optimizer-selected inlining.
//! @ingroup compiler

#include <stdbool.h>
#include <string.h>

#include "ast.h"
#include "compile_expr_info.h"
#include "compile_function.h"
#include "compile_function_registry.h"
#include "compile_inline_legality.h"
#include "compile_type.h"

//! @brief Return whether inline-asm text carries a hard conditional-branch page policy.
static bool asm_text_has_hard_branch_page_policy(const char *text) {
   /* .same/.cross are assembler addressing-mode suffixes. A textual scan is
      deliberately conservative here: even an unusual macro/comment spelling is
      safer treated as placement-sensitive than moved without a proof. */
   return text && (strstr(text, ".same") != NULL || strstr(text, ".cross") != NULL);
}

#define INLINE_LEGALITY_MAX_SOURCE_INLINE_DEPTH 128

//! @brief Return whether generated code from a subtree can contain hard branch policy.
static bool subtree_has_hard_branch_page_policy_inner(
      const ASTNode *node, const ASTNode **inline_stack, int inline_depth) {
   if (!node) return false;
   if (node->kind == AST_ASM && asm_text_has_hard_branch_page_policy(node->strval)) {
      return true;
   }

   /* Source-inline bodies are not lexical children of their callsites, but they
      become generated code there. Follow those expansions just like the direct-
      call census does, otherwise a .same/.cross hidden in an inline wrapper can
      make a caller placement-sensitive without this gate noticing. */
   if (!strcmp(node->name, "()") && node->count >= 1) {
      const char *callee_name = expr_bare_identifier_name(node->children[0]);
      const ASTNode *target = callee_name
         ? resolve_function_designator_target(callee_name) : NULL;
      if (target && function_is_inline(target) && function_has_body(target)) {
         bool recursive = false;
         for (int i = 0; i < inline_depth; i++) {
            if (inline_stack[i] == target) {
               recursive = true;
               break;
            }
         }
         if (!recursive && inline_depth < INLINE_LEGALITY_MAX_SOURCE_INLINE_DEPTH) {
            inline_stack[inline_depth] = target;
            if (subtree_has_hard_branch_page_policy_inner(
                   target->children[2], inline_stack, inline_depth + 1)) {
               return true;
            }
         }
      }
   }

   for (int i = 0; i < node->count; i++) {
      if (subtree_has_hard_branch_page_policy_inner(
             node->children[i], inline_stack, inline_depth)) {
         return true;
      }
   }
   return false;
}

static bool subtree_has_hard_branch_page_policy(const ASTNode *node) {
   const ASTNode *inline_stack[INLINE_LEGALITY_MAX_SOURCE_INLINE_DEPTH];
   return subtree_has_hard_branch_page_policy_inner(node, inline_stack, 0);
}

//! @brief Return whether one function has an independently placeable code/result contract.
static bool function_has_independent_region_contract(const ASTNode *fn) {
   FunctionRegionSpec regions;
   bool ret;

   if (!fn) return false;
   function_region_spec_collect(fn, &regions);
   ret = regions.code_region_count != 0 || regions.result_region != NULL;
   function_region_spec_release(&regions);
   return ret;
}

//! @brief Return a stable short reason when moving FN into its caller is not proven legal.
const char *optimizer_inline_placement_rejection(const ASTNode *fn) {
   const ASTNode *caller;
   const ASTNode *mods;
   const ASTNode *caller_mods;

   if (!fn) return "no-function";
   caller = function_single_direct_caller(fn);
   if (!caller) return "no-unique-caller";

   mods = function_modifiers_node(fn);
   caller_mods = function_modifiers_node(caller);

   /* A standalone page-contained function can be placed independently. Moving
      it destroys that exact layout boundary. Likewise, growing a page-contained
      caller can make its previously satisfiable <=256-byte contract impossible. */
   if (mods && has_modifier((ASTNode *)mods, "page")) return "callee-page";
   if (caller_mods && has_modifier((ASTNode *)caller_mods, "page")) return "caller-page";

   /* Named function regions are explicit independently placeable contracts.
      Until the optimizer/linker can trial-place and roll back a candidate, keep
      either side independent instead of silently changing its region geometry. */
   if (function_has_independent_region_contract(fn)) return "callee-region";
   if (function_has_independent_region_contract(caller)) return "caller-region";

   /* Hard branch timing in either moved code or surrounding caller code depends
      on final physical page placement. The compiler cannot prove final linker
      placement here, so absence of such annotations is the current proof. */
   if (subtree_has_hard_branch_page_policy(fn)) return "callee-hard-branch";
   if (subtree_has_hard_branch_page_policy(caller)) return "caller-hard-branch";

   return NULL;
}

bool optimizer_inline_placement_legal(const ASTNode *fn) {
   return optimizer_inline_placement_rejection(fn) == NULL;
}
