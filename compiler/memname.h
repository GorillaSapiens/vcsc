//! @file compiler/memname.h
//! @brief Declares memory-name declaration support for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_MEMNAME_H_
#define _INCLUDE_MEMNAME_H_

#include <stdbool.h>

#include "ast.h"

// determine if memname exists
bool memname_exists(const char* name);

// register a new memname
int register_memname(const char* name);

// attach an ASTNode to a registered memname
void attach_memname(const char *name, ASTNode *node);

// get the node attached to a memname
ASTNode *get_memname_node(const char *name);

#endif
