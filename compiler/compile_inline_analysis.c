//! @file compiler/compile_inline_analysis.c
//! @brief Tracks optimizer-facing single-direct-callsite facts.
//! @ingroup compiler

#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "compile_inline_analysis.h"

typedef struct InlineFunctionInfo {
   const void *identity;
   const void *first_caller;
   const void *first_callsite;
   unsigned flags;
   unsigned direct_call_sites;
   bool external_root_call;
   bool reachable_root;
   bool reachable;
   bool in_cycle;
} InlineFunctionInfo;

typedef struct InlineCallEdge {
   const void *caller;
   const void *callsite;
   const void *callee;
   bool reachable_enabled;
} InlineCallEdge;

static InlineFunctionInfo *functions;
static size_t function_count;
static InlineCallEdge *edges;
static size_t edge_count;

static InlineFunctionInfo *find_function(const void *identity) {
   if (!identity) {
      return NULL;
   }
   for (size_t i = 0; i < function_count; i++) {
      if (functions[i].identity == identity) {
         return &functions[i];
      }
   }
   return NULL;
}

static InlineFunctionInfo *find_or_add_function(const void *identity) {
   InlineFunctionInfo *info = find_function(identity);
   InlineFunctionInfo *grown;

   if (info || !identity) {
      return info;
   }

   grown = (InlineFunctionInfo *)realloc(functions,
                                         sizeof(*functions) * (function_count + 1));
   if (!grown) {
      abort();
   }
   functions = grown;
   info = &functions[function_count++];
   memset(info, 0, sizeof(*info));
   info->identity = identity;
   return info;
}

//! @brief Clear all optimizer callsite facts before compiling one translation unit.
void inline_analysis_reset(void) {
   free(functions);
   functions = NULL;
   function_count = 0;
   free(edges);
   edges = NULL;
   edge_count = 0;
}

//! @brief Register or refine baseline facts for one source-level function.
void inline_analysis_register_function(const void *function_identity, unsigned flags) {
   InlineFunctionInfo *info = find_or_add_function(function_identity);
   if (info) {
      info->flags |= flags;
   }
}

//! @brief Record one ordinary direct call occurrence, preserving duplicates.
void inline_analysis_record_direct_call(const void *caller_identity,
                                        const void *callsite_identity,
                                        const void *callee_identity) {
   InlineFunctionInfo *callee = find_or_add_function(callee_identity);
   InlineCallEdge *grown;

   if (!callee) {
      return;
   }
   if (caller_identity) find_or_add_function(caller_identity);
   if (callee->direct_call_sites == 0) {
      callee->first_caller = caller_identity;
      callee->first_callsite = callsite_identity;
   }
   callee->direct_call_sites++;

   if (!caller_identity) {
      callee->external_root_call = true;
      callee->reachable_root = true;
      return;
   }
   grown = (InlineCallEdge *)realloc(edges, sizeof(*edges) * (edge_count + 1));
   if (!grown) abort();
   edges = grown;
   edges[edge_count].caller = caller_identity;
   edges[edge_count].callsite = callsite_identity;
   edges[edge_count].callee = callee_identity;
   edges[edge_count].reachable_enabled = true;
   edge_count++;
}

void inline_analysis_reset_reachability(void) {
   for (size_t i = 0; i < function_count; i++) {
      functions[i].reachable_root = functions[i].external_root_call;
      functions[i].reachable = false;
   }
   for (size_t i = 0; i < edge_count; i++) edges[i].reachable_enabled = true;
}

void inline_analysis_mark_reachable_root(const void *function_identity) {
   InlineFunctionInfo *info = find_or_add_function(function_identity);
   if (info) info->reachable_root = true;
}

void inline_analysis_set_direct_call_reachability(const void *caller_identity,
                                                  const void *callsite_identity,
                                                  bool enabled) {
   for (size_t i = 0; i < edge_count; i++) {
      if (edges[i].caller == caller_identity && edges[i].callsite == callsite_identity)
         edges[i].reachable_enabled = enabled;
   }
}

static int function_index(const void *identity) {
   for (size_t i = 0; i < function_count; i++) {
      if (functions[i].identity == identity) return (int)i;
   }
   return -1;
}

static void mark_cycle_dfs(int v, unsigned char *color, int *stack, int *stack_top) {
   color[v] = 1;
   stack[(*stack_top)++] = v;
   for (size_t i = 0; i < edge_count; i++) {
      int w;
      if (edges[i].caller != functions[v].identity) continue;
      w = function_index(edges[i].callee);
      if (w < 0) continue;
      if (color[w] == 0) {
         mark_cycle_dfs(w, color, stack, stack_top);
      }
      else if (color[w] == 1) {
         for (int j = *stack_top - 1; j >= 0; j--) {
            functions[stack[j]].in_cycle = true;
            if (stack[j] == w) break;
         }
      }
   }
   (*stack_top)--;
   color[v] = 2;
}

void inline_analysis_compute_reachability(void) {
   bool changed;
   unsigned char *color;
   int *stack;
   int stack_top = 0;

   for (size_t i = 0; i < function_count; i++) {
      functions[i].reachable = functions[i].reachable_root;
      functions[i].in_cycle = false;
   }
   do {
      changed = false;
      for (size_t i = 0; i < edge_count; i++) {
         InlineFunctionInfo *caller = find_function(edges[i].caller);
         InlineFunctionInfo *callee = find_function(edges[i].callee);
         if (edges[i].reachable_enabled && caller && callee &&
             caller->reachable && !callee->reachable) {
            callee->reachable = true;
            changed = true;
         }
      }
   } while (changed);

   color = (unsigned char *)calloc(function_count ? function_count : 1, sizeof(*color));
   stack = (int *)malloc((function_count ? function_count : 1) * sizeof(*stack));
   if (!color || !stack) abort();
   for (size_t i = 0; i < function_count; i++) {
      if (color[i] == 0) mark_cycle_dfs((int)i, color, stack, &stack_top);
   }
   free(color);
   free(stack);
}

bool inline_analysis_is_reachable(const void *function_identity) {
   InlineFunctionInfo *info = find_function(function_identity);
   return info && info->reachable;
}

bool inline_analysis_is_in_cycle(const void *function_identity) {
   InlineFunctionInfo *info = find_function(function_identity);
   return info && info->in_cycle;
}

//! @brief Return the number of ordinary direct call occurrences for one function.
unsigned inline_analysis_direct_call_site_count(const void *function_identity) {
   InlineFunctionInfo *info = find_function(function_identity);
   return info ? info->direct_call_sites : 0;
}

//! @brief Return the caller only when exactly one ordinary direct callsite exists.
const void *inline_analysis_single_direct_caller(const void *function_identity) {
   InlineFunctionInfo *info = find_function(function_identity);
   if (!info || info->direct_call_sites != 1) {
      return NULL;
   }
   return info->first_caller;
}

//! @brief Return the exact source call expression when one direct callsite exists.
const void *inline_analysis_single_direct_callsite(const void *function_identity) {
   InlineFunctionInfo *info = find_function(function_identity);
   if (!info || info->direct_call_sites != 1) {
      return NULL;
   }
   return info->first_callsite;
}

//! @brief Return whether baseline source/linkage facts admit item-31 optimization.
bool inline_analysis_is_baseline_candidate(const void *function_identity) {
   InlineFunctionInfo *info = find_function(function_identity);
   unsigned required = INLINE_FUNCTION_DEFINED | INLINE_FUNCTION_INTERNAL;

   if (!info || (info->flags & required) != required) {
      return false;
   }
   if (info->flags & INLINE_FUNCTION_SOURCE_INLINE) {
      return false;
   }
   /* A call emitted by a runtime global initializer has no ordinary AST
      function caller into which this body can be expanded. */
   if (info->external_root_call) {
      return false;
   }
   return info->direct_call_sites == 1;
}
