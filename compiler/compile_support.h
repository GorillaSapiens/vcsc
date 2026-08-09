//! @file compiler/compile_support.h
//! @brief Declares shared compiler support routines for the VCSC compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_SUPPORT_H_
#define _INCLUDE_COMPILE_SUPPORT_H_

#include <stdbool.h>
#include <stddef.h>
#include "ast.h"
#include "compile_internal.h"
#include "compile_lvalue.h"

typedef struct CompilerScratchLease {
   int scope_index;
   int slot_index;
   int use_index;
   int saved_locals;
   int saved_high_water;
   int reserved;
   int used;
   bool active;
   char symbol[64];
} CompilerScratchLease;

void compiler_scratch_reset(void);
const char *compiler_scratch_active_symbol(void);
void compiler_scratch_acquire(Context *ctx, int reserved, CompilerScratchLease *lease);
void compiler_scratch_activate(Context *ctx, CompilerScratchLease *lease);
void compiler_scratch_deactivate(Context *ctx, CompilerScratchLease *lease);
void compiler_scratch_note_used(CompilerScratchLease *lease, int used);
void compiler_scratch_release(CompilerScratchLease *lease);
void compiler_scratch_emit_bss(void);
void build_activation_storage_segment(char *buf, size_t bufsize,
                                      const Context *ctx,
                                      const ASTNode *modifiers,
                                      const char *base_segment);
void build_activation_storage_segment_for_region(char *buf, size_t bufsize,
                                                 const Context *ctx,
                                                 const char *region_name,
                                                 const char *base_segment);

void diagnose_runtime_power_of_two_divisor(const ASTNode *origin,
                                           const ASTNode *divisor,
                                           const char *op);

const ASTNode *decl_node_declarator(const ASTNode *node);
bool entry_has_read_address(const ContextEntry *entry);
bool entry_has_write_address(const ContextEntry *entry);
bool entry_is_absolute_ref(const ContextEntry *entry);
void init_split_mem_entry_addresses_for_symbol(ContextEntry *entry, const char *symbol,
                                               const ASTNode *modifiers);
void init_split_mem_entry_addresses_for_region(ContextEntry *entry, const char *symbol,
                                               const char *region_name);
bool lvalue_fixed_symbol_name(Context *ctx, const LValueRef *lv, char *buf, size_t bufsize);
bool emit_copy_lvalue_to_symbol(Context *ctx, const char *symbol, int symbol_offset, const LValueRef *src, int size);
void emit_copy_scratch_to_symbol_offset(const char *symbol, int symbol_offset, int src_offset, int size);
void emit_copy_scratch_to_address_expr(const char *write_expr, int src_offset, int size);
void emit_fixed_address_op(const char *mnemonic, const char *expr, int addend);
void remember_symbol_import_mode(const char *name, bool is_zeropage);
void emit_mem_region_metadata_for_modifiers(const ASTNode *origin, const ASTNode *modifiers);
void emit_mem_region_metadata_for_name(const ASTNode *origin, const char *name);
void emit_mem_declaration_metadata(const ASTNode *mem_decl);
void emit_copy_symbol_to_scratch_convert_offset(int dst_offset, int dst_size, const ASTNode *dst_type,
                                           const char *symbol, int src_offset, int src_size,
                                           const ASTNode *src_type);
void emit_copy_symbol_to_scratch_convert(int dst_offset, int dst_size, const ASTNode *dst_type,
                                    const char *symbol, int src_size, const ASTNode *src_type);
void emit_copy_symbol_to_symbol_convert_offset(const char *dst_symbol, int dst_offset, int dst_size, const ASTNode *dst_type,
                                               const char *src_symbol, int src_offset, int src_size, const ASTNode *src_type);

#endif
