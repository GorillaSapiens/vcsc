//! @file compiler/compile_inline_inliner.h
//! @brief Plans optimizer-selected ordinary-function inline expansion.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_INLINE_INLINER_H_
#define _INCLUDE_COMPILE_INLINE_INLINER_H_

#include <stdbool.h>
#include "ast.h"

void analyze_optimizer_inline_candidates(ASTNode *program);
bool optimizer_inline_function_selected(const ASTNode *fn);
void optimizer_inline_request_selection(const char *name);
void optimizer_inline_set_candidate_manifest(const char *path);

#endif
