//! @file compiler/compile_inline_inliner.c
//! @brief Plans optimizer-selected ordinary-function inline expansion.
//! @ingroup compiler

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast.h"
#include "compile_function.h"
#include "compile_function_registry.h"
#include "compile_inline_inliner.h"
#include "compile_inline_identity.h"
#include "compile_inline_legality.h"
#include "compile_type.h"
#include "messages.h"
#include "xray.h"

typedef struct OptimizerInlinePlan {
   const ASTNode *fn;
} OptimizerInlinePlan;

static OptimizerInlinePlan *plans;
static size_t plan_count;
static char **requested_names;
static size_t requested_name_count;
static const char *candidate_manifest_path;

static void reset_plans(void) {
   free(plans);
   plans = NULL;
   plan_count = 0;
}

void optimizer_inline_request_selection(const char *name) {
   char **grown;
   if (!name || !*name) return;
   for (size_t i = 0; i < requested_name_count; i++) {
      if (!strcmp(requested_names[i], name)) return;
   }
   grown = (char **)realloc(requested_names,
                            sizeof(*requested_names) * (requested_name_count + 1));
   if (!grown) error_unreachable("out of memory recording optimizer inline selection");
   requested_names = grown;
   requested_names[requested_name_count] = strdup(name);
   if (!requested_names[requested_name_count])
      error_unreachable("out of memory recording optimizer inline selection");
   requested_name_count++;
}

void optimizer_inline_set_candidate_manifest(const char *path) {
   candidate_manifest_path = path;
}

static bool optimizer_inline_name_requested(const ASTNode *fn) {
   const char *name;
   if (!fn) return false;
   name = declarator_name(function_declarator_node((ASTNode *)fn));
   if (!name) return false;
   for (size_t i = 0; i < requested_name_count; i++) {
      if (!strcmp(requested_names[i], name)) return true;
   }
   return false;
}


/* Subsection 3 supplies the control-flow transformation.  Forced test-mode
   selection bypasses measured profitability only; subsection-4 placement and
   subsection-6 identity/assembly safety gates still apply. */
static bool mechanically_safe_for_forced_inline(const ASTNode *fn) {
   const ASTNode *mods;
   FunctionRegionSpec regions;
   bool ok;

   if (!fn || !function_is_single_direct_callsite_candidate(fn) ||
       !function_has_body(fn) || function_is_inline(fn)) {
      return false;
   }
   mods = function_modifiers_node(fn);
   if (!mods || !optimizer_inline_identity_legal(fn)) {
      return false;
   }

   /* Subsection 4 owns physical placement/timing legality. Forced test-mode
      inlining bypasses profitability, never legality. */
   if (!optimizer_inline_placement_legal(fn)) {
      return false;
   }

   /* The identity gate owns ABI/assembly contracts; keep this local assertion
      as a defense that independently placeable function regions never reach
      the expansion mechanism. */
   function_region_spec_collect(fn, &regions);
   ok = regions.code_region_count == 0 && regions.result_region == NULL;
   function_region_spec_release(&regions);
   return ok;
}

void analyze_optimizer_inline_candidates(ASTNode *program) {
   FILE *manifest = NULL;
   reset_plans();

   if (!program || strcmp(program->name, "program")) {
      return;
   }

   if (candidate_manifest_path) {
      manifest = fopen(candidate_manifest_path, "w");
      if (!manifest)
         error_user("cannot write optimizer inline candidate manifest '%s'",
                    candidate_manifest_path);
   }

   for (int i = 0; i < program->count; i++) {
      ASTNode *node = program->children[i];
      OptimizerInlinePlan *grown;
      if (!node || strcmp(node->name, "defdecl_stmt") || node->count != 3 ||
          !mechanically_safe_for_forced_inline(node)) {
         continue;
      }
      if (manifest) {
         const char *name = declarator_name(function_declarator_node(node));
         if (name) fprintf(manifest, "%s\n", name);
      }
      /* XRAY inlineir remains the regression-only "select every legal candidate"
         switch.  The driver profitability loop instead supplies an explicit set
         of names after measuring real final links. */
      if (!get_xray(XRAY_INLINEIR) && !optimizer_inline_name_requested(node))
         continue;
      grown = (OptimizerInlinePlan *)realloc(plans, sizeof(*plans) * (plan_count + 1));
      if (!grown) error_unreachable("out of memory recording optimizer inline plan");
      plans = grown;
      plans[plan_count++].fn = node;
   }
   if (manifest && fclose(manifest) != 0)
      error_user("cannot close optimizer inline candidate manifest '%s'",
                 candidate_manifest_path);
}

bool optimizer_inline_function_selected(const ASTNode *fn) {
   for (size_t i = 0; i < plan_count; i++) {
      if (plans[i].fn == fn) return true;
   }
   return false;
}
