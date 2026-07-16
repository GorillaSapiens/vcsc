//! @file compiler/compile_expr.c
//! @brief Implements expression lowering entry points for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>
#include <limits.h>

#include "ast.h"
#include "compile.h"
#include "compile_call.h"
#include "compile_expr.h"
#include "compile_expr_flow.h"
#include "compile_expr_info.h"
#include "compile_function.h"
#include "compile_init.h"
#include "compile_internal.h"
#include "compile_lvalue.h"
#include "compile_overload.h"
#include "compile_support.h"
#include "compile_type.h"
#include "emit.h"
#include "float.h"
#include "integer.h"
#include "memname.h"
#include "messages.h"
#include "pair.h"
#include "set.h"
#include "typename.h"
#include "xray.h"
#include "lextern.h"

//! @brief Handle expr eligible for weak builtin operator logic for compile expr.
bool expr_eligible_for_weak_builtin_operator(ASTNode *expr, Context *ctx,
                                                    const char **opname_out,
                                                    const ASTNode **ret_type_out,
                                                    const ASTNode **ret_decl_out,
                                                    int *ret_size_out,
                                                    int *arg_count_out,
                                                    ASTNode **arg_exprs_out,
                                                    const ASTNode **arg_types_out,
                                                    const ASTNode **arg_decls_out) {
   (void) expr;
   (void) ctx;
   (void) opname_out;
   (void) ret_type_out;
   (void) ret_decl_out;
   (void) ret_size_out;
   (void) arg_count_out;
   (void) arg_exprs_out;
   (void) arg_types_out;
   (void) arg_decls_out;

   /* Exact visible overloads still resolve first. Otherwise same-type operators
    * now fall back to generic lowering unless the type opted into $exactops,
    * which is enforced separately at the call site. */
   return false;
}
//! @brief Create synthetic call expr for compile expr. The returned storage is owned by the caller or the object that immediately records it.
ASTNode *make_synthetic_call_expr(ASTNode *origin, const char *callee_name, ASTNode *args[], int argc) {
   ASTNode *call;
   ASTNode *arglist;

   if (!origin || !callee_name) {
      return NULL;
   }

   call = calloc(1, sizeof(ASTNode) + sizeof(ASTNode *) * 2);
   arglist = calloc(1, sizeof(ASTNode) + sizeof(ASTNode *) * (argc > 0 ? argc : 1));
   if (!call || !arglist) {
      free(call);
      free(arglist);
      return NULL;
   }

   call->name = "()";
   call->file = origin->file;
   call->line = origin->line;
   call->column = origin->column;
   call->handled = false;
   call->kind = AST_GENERIC;
   call->count = 2;
   call->children[0] = make_identifier_leaf(callee_name);
   call->children[0]->file = origin->file;
   call->children[0]->line = origin->line;
   call->children[0]->column = origin->column;

   arglist->name = "expr_args";
   arglist->file = origin->file;
   arglist->line = origin->line;
   arglist->column = origin->column;
   arglist->handled = false;
   arglist->kind = argc > 0 ? AST_GENERIC : AST_EMPTY;
   arglist->count = argc;
   for (int i = 0; i < argc; i++) {
      arglist->children[i] = args[i];
   }
   call->children[1] = arglist;
   return call;
}
//! @brief Return next label data used by compile expr; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *next_label(const char *prefix) {
   char buf[64];
   snprintf(buf, sizeof(buf), "@%s_%d", prefix, label_counter++);
   return strdup(buf);
}

