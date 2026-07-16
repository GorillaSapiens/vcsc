//! @file compiler/typename.h
//! @brief Declares type-name registry for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_TYPENAME_H_
#define _INCLUDE_TYPENAME_H_

#include <stdbool.h>

#include "ast.h"

// determine if typename exists
bool typename_exists(const char* name);

// register a new typename
int register_typename(const char* name);

// attach an ASTNode to a registered typename
void attach_typename(const char *name, ASTNode *node);

// get the node attached to a typename
ASTNode *get_typename_node(const char *name);

// check for any null valued typenames
const char *typename_find_null(void);

#endif
