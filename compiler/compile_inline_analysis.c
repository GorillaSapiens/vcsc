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
} InlineFunctionInfo;

static InlineFunctionInfo *functions;
static size_t function_count;

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

   if (!callee) {
      return;
   }
   if (callee->direct_call_sites == 0) {
      callee->first_caller = caller_identity;
      callee->first_callsite = callsite_identity;
   }
   callee->direct_call_sites++;
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
   return info->direct_call_sites == 1;
}
