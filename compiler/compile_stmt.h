//! @file compiler/compile_stmt.h
//! @brief Declares statement lowering for the VCSC compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_STMT_H_
#define _INCLUDE_COMPILE_STMT_H_

#include "ast.h"
#include "compile_internal.h"

typedef struct StatementCompileState {
   int loop_depth;
   int named_loop_depth;
   const char *pending_loop_label_name;
} StatementCompileState;

void predeclare_statement_list(ASTNode *node, Context *ctx);
void compile_statement_list(ASTNode *node, Context *ctx);
void statement_compile_state_push(StatementCompileState *saved);
void statement_compile_state_pop(const StatementCompileState *saved);

#endif
