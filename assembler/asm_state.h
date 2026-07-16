//! @file assembler/asm_state.h
//! @brief Declares assembler state management for the n65 assembler.
//! @ingroup assembler

#ifndef ASM_STATE_H
#define ASM_STATE_H

#include "asm_pass.h"

#define DEFAULT_SEGMENT_NAME "__default__"
#define O65_SEG_UNDEF 0
#define O65_SEG_ABS   1
#define O65_SEG_TEXT  2
#define O65_SEG_DATA  3
#define O65_SEG_BSS   4
#define O65_SEG_ZP    5

void asm_error(asm_context_t *ctx, const stmt_t *stmt, const char *fmt, ...);
void asm_warning(const stmt_t *stmt, const char *fmt, ...);

int import_is_zp(const asm_context_t *ctx, const char *name);
int segment_name_to_o65(const char *name);
asm_segment_t *segment_find(asm_context_t *ctx, const char *name);
void reset_segment_pcs(asm_context_t *ctx);
void snapshot_segment_used_sizes(asm_context_t *ctx);
void ensure_default_segment(asm_context_t *ctx);
const char *proc_decl_name(const stmt_t *stmt);
void publish_segment_symbols(asm_context_t *ctx);
void gather_segment_defs(asm_context_t *ctx);
void validate_segment_defs(asm_context_t *ctx);
int declare_symbol_or_report(asm_context_t *ctx, const char *name, const stmt_t *stmt);
symbol_t *find_declared_symbol(symtab_t *tab, const program_ir_t *prog, const stmt_t *stmt, const char *name);
void gather_imports(asm_context_t *ctx);
void validate_imports(asm_context_t *ctx);
void asm_prepare_context_state(asm_context_t *ctx);
void asm_free_context_state(asm_context_t *ctx);

#endif
