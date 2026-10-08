//! @file compiler/compile_toplevel.h
//! @brief Declares top-level declaration lowering for the VCSC compiler.
//! @ingroup compiler

#include <stdbool.h>

#ifndef _INCLUDE_COMPILE_TOPLEVEL_H_
#define _INCLUDE_COMPILE_TOPLEVEL_H_

#include "ast.h"

void compile_cartridge_decl_stmt(ASTNode *node);
void compile_bank_decl_stmt(ASTNode *node);
//! Return whether the current cartridge profile opts into the generic inline-target bank-call pilot.
bool compile_cartridge_supports_bankcall(void);
void compile_mem_decl_stmt(ASTNode *node);
void compile_type_decl_stmt(ASTNode *node);
void compile_typedef_decl_stmt(ASTNode *node);
void compile_enum_decl_stmt(ASTNode *node);
void compile_struct_decl_stmt(ASTNode *node);
void compile_union_decl_stmt(ASTNode *node);
void compile_global_decl_item(ASTNode *node);
void predeclare_top_level_objects(ASTNode *program);
void predeclare_top_level_functions(ASTNode *program);
void compile_defdecl_stmt(ASTNode *node);
void reject_function_pointers(ASTNode *node);
void enforce_template_hygiene(ASTNode *program);
void check_struct_union_undefined(ASTNode *program);
void crosscheck_struct_union_nesting(ASTNode *program);
void calculate_struct_union_sizes(ASTNode *program);

// Record a struct or union's size the moment its declaration closes.  A field's type
// must already be declared -- there are no forward references -- so the size is
// determined there and there is nothing for the fixed-point pass to find later.  This
// is what lets an array extent use sizeof(S), since an extent is folded while its
// declaration is parsed.  Uses the same field walk as calculate_struct_union_sizes so
// the recorded size and the laid-out size cannot disagree.
void record_declared_struct_union_size(ASTNode *decl, const char *name, bool is_struct);

#endif
