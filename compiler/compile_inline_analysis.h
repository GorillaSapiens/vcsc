//! @file compiler/compile_inline_analysis.h
//! @brief Tracks optimizer-facing single-direct-callsite facts.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_INLINE_ANALYSIS_H_
#define _INCLUDE_COMPILE_INLINE_ANALYSIS_H_

#include <stdbool.h>

/* These flags describe only baseline source/linkage facts. Later item-31
   legality/profitability passes add ABI, assembly-reference, placement, and
   size vetoes without teaching callsite counting about those policies. */
enum InlineFunctionFlags {
   INLINE_FUNCTION_DEFINED       = 1u << 0,
   INLINE_FUNCTION_INTERNAL      = 1u << 1,
   INLINE_FUNCTION_SOURCE_INLINE = 1u << 2
};

void inline_analysis_reset(void);
void inline_analysis_register_function(const void *function_identity, unsigned flags);
void inline_analysis_record_direct_call(const void *caller_identity,
                                        const void *callsite_identity,
                                        const void *callee_identity);
unsigned inline_analysis_direct_call_site_count(const void *function_identity);
const void *inline_analysis_single_direct_caller(const void *function_identity);
const void *inline_analysis_single_direct_callsite(const void *function_identity);
bool inline_analysis_is_baseline_candidate(const void *function_identity);

#endif
