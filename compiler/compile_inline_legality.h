//! @file compiler/compile_inline_legality.h
//! @brief Placement/timing legality checks for optimizer-selected inlining.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_INLINE_LEGALITY_H_
#define _INCLUDE_COMPILE_INLINE_LEGALITY_H_

#include <stdbool.h>
#include "ast.h"

/* Return true only when moving FN into its unique direct caller is proven not to
   invalidate any currently supported hard code-placement/timing contract.  This
   is intentionally conservative: absence of a proof means keep the call. */
bool optimizer_inline_placement_legal(const ASTNode *fn);

/* Stable short diagnostic token used only by regression/debug code. NULL means
   legal.  This is not a user-facing compiler diagnostic. */
const char *optimizer_inline_placement_rejection(const ASTNode *fn);

#endif
