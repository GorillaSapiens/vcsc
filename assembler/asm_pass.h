//! @file assembler/asm_pass.h
//! @brief Declares assembly pass orchestration for the VCSC assembler.
//! @ingroup assembler

#ifndef ASM_PASS_H
#define ASM_PASS_H

#include <stdio.h>
#include "ir.h"
#include "symtab.h"
#include "ihex.h"
#include "listing.h"

//! Imported symbol requested by object-mode assembly.
typedef struct import_name {
   char *name;
   const char *file;
   int line;
   int addr_size_zp;
   struct import_name *next;
} import_name_t;

typedef struct weak_name {
   char *name;
   const char *file;
   int line;
   struct weak_name *next;
} weak_name_t;

//! Explicit address-size contract for one segment family or named segment.
typedef struct segment_addrsize {
   char *name;
   const char *file;
   int line;
   int addr_size_zp;
   struct segment_addrsize *next;
} segment_addrsize_t;

//! Assembler segment placement and program-counter state.
typedef struct asm_segment {
   char *name;
   long base;
   long size;
   long pc;
   long used_size;
   int rorg_active;
   long rorg_pc;
   int defined;
   int overflow_warned;
   int page_contained;
   int index_range_set;
   long index_range_start;
   long index_range_max;
   /* In relocatable o26 mode, internal .align directives constrain absolute
      addresses reached inside the final component.  reloc_alignment is the
      largest power-of-two modulus; reloc_phase is the selected component-base
      residue that makes those interior alignments absolute after linking. */
   long explicit_reloc_alignment;
   long required_reloc_alignment;
   long selected_reloc_phase;
   int reloc_phase_locked;
   long reloc_alignment;
   long reloc_phase;
   struct asm_segment *next;
} asm_segment_t;

//! Mutable state shared across assembler relaxation and emission passes.
typedef struct asm_context {
   program_ir_t *prog;
   symtab_t symbols;
   long origin;
   ihex_image_t image;
   listing_writer_t *listing;
   int error_count;
   int object_mode_o26;
   import_name_t *imports;
   weak_name_t *weaks;
   segment_addrsize_t *segment_addrsizes;
   asm_segment_t *segments;
} asm_context_t;

void asm_context_init(asm_context_t *ctx, program_ir_t *prog, listing_writer_t *listing, int object_mode_o26);
void asm_context_free(asm_context_t *ctx);

int asm_relax(asm_context_t *ctx);
int asm_select_reloc_phases(asm_context_t *ctx);
void asm_reset_emit_modes(asm_context_t *ctx);
int asm_pass1(asm_context_t *ctx, int pass_index);
int asm_pass2(asm_context_t *ctx);

int asm_write_map_file(FILE *fp, const asm_context_t *ctx);

#endif

void asm_add_weak(asm_context_t *ctx, const stmt_t *stmt, const char *name);
int asm_symbol_is_weak(const asm_context_t *ctx, const char *name);
