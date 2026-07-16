//! @file compiler/compile_stmt.h
//! @brief Declares statement lowering for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_STMT_H_
#define _INCLUDE_COMPILE_STMT_H_

#include "ast.h"
#include "compile_internal.h"

void predeclare_statement_list(ASTNode *node, Context *ctx);
void compile_statement_list(ASTNode *node, Context *ctx);

#endif
