//! @file compiler/enumname.h
//! @brief Declares enum declaration support for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_ENUMNAME_H_
#define _INCLUDE_ENUMNAME_H_

#include <stdbool.h>

#include "ast.h"

// determine if enumname exists
bool enumname_exists(const char* name);

// register all enum names for an enum declaration and assign their values
int register_enumnames(ASTNode *node);

// get the node attached to an enum name
ASTNode *get_enumname_node(const char *name);

// make an integer-literal AST node for a registered enum constant
ASTNode *make_enumname_expr(const char *name);
ASTNode *make_enumname_expr_with_type(const char *name, ASTNode *type);

// check for any null valued typenames
const char *enumname_find_null(void);

#endif
