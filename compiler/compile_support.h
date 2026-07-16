//! @file compiler/compile_support.h
//! @brief Declares shared compiler support routines for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_SUPPORT_H_
#define _INCLUDE_COMPILE_SUPPORT_H_

#include <stdbool.h>
#include <stddef.h>
#include "ast.h"
#include "compile_internal.h"
#include "compile_lvalue.h"

const ASTNode *decl_node_declarator(const ASTNode *node);
bool entry_has_read_address(const ContextEntry *entry);
bool entry_has_write_address(const ContextEntry *entry);
bool entry_is_absolute_ref(const ContextEntry *entry);
bool emit_copy_lvalue_to_symbol(Context *ctx, const char *symbol, int symbol_offset, const LValueRef *src, int size);
void emit_copy_fp_to_symbol_offset(const char *symbol, int symbol_offset, int src_offset, int size);
void remember_symbol_import_mode(const char *name, bool is_zeropage);
void emit_mem_region_metadata_for_modifiers(const ASTNode *origin, const ASTNode *modifiers);
void emit_copy_symbol_to_fp_convert_offset(int dst_offset, int dst_size, const ASTNode *dst_type,
                                           const char *symbol, int src_offset, int src_size,
                                           const ASTNode *src_type);
void emit_copy_symbol_to_fp_convert(int dst_offset, int dst_size, const ASTNode *dst_type,
                                    const char *symbol, int src_size, const ASTNode *src_type);

#endif
