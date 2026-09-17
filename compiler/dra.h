//! @file compiler/dra.h
//! @brief Direct Register Access syntax-surface validation and staged lowering gate.
//! @ingroup compiler

#ifndef _INCLUDE_DRA_H_
#define _INCLUDE_DRA_H_

#include <stdbool.h>

#include "ast.h"

//! Validate the DRA1 parser/semantic surface; true when the tree contains DRA.
bool dra_validate_surface(const ASTNode *root);

//! Reject valid DRA forms whose roadmap lowering slice is not implemented yet.
void dra_reject_unimplemented_codegen(const ASTNode *root);

#endif // _INCLUDE_DRA_H_
