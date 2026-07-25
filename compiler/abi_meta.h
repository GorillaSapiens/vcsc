//! @file compiler/abi_meta.h
//! @brief Declares ABI metadata emission for the VCSC compiler.
//! @ingroup compiler

#ifndef _INCLUDE_ABI_META_H_
#define _INCLUDE_ABI_META_H_

#include <stdbool.h>
#include "ast.h"

//! Prefix used for linker-visible ABI metadata symbols.
#define ABI_META_PREFIX "__abimeta$V1$"
#define CONTRACT_META_PREFIX "__contractmeta$V1$"

void emit_function_abi_metadata(const ASTNode *fn, const char *sym, bool is_definition);
void emit_global_abi_metadata(const ASTNode *node, const char *symname, bool is_definition, bool is_zeropage);
void emit_function_contract_metadata(const ASTNode *fn, const char *sym);
void emit_global_contract_metadata(const ASTNode *node, const char *symname, bool is_zeropage);

#endif
