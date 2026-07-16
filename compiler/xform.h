//! @file compiler/xform.h
//! @brief Declares AST transformation passes for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_XFORM_H_
#define _INCLUDE_XFORM_H_

#include <stdbool.h>

#include "ast.h"

// determine if xform exists
bool xform_exists(const char *name);

// register a new xform
int register_xform(const char *name, ASTNode *node);

// perform xform on string
ASTNode *do_xform(ASTNode *s, const char *name);

// get the node attached to a xform
ASTNode *get_xform_node(const char *name);

#endif
