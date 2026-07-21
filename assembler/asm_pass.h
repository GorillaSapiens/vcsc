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
   asm_segment_t *segments;
} asm_context_t;

void asm_context_init(asm_context_t *ctx, program_ir_t *prog, listing_writer_t *listing, int object_mode_o26);
void asm_context_free(asm_context_t *ctx);

int asm_relax(asm_context_t *ctx);
int asm_pass1(asm_context_t *ctx, int pass_index);
int asm_pass2(asm_context_t *ctx);

int asm_write_map_file(FILE *fp, const asm_context_t *ctx);

#endif

void asm_add_weak(asm_context_t *ctx, const stmt_t *stmt, const char *name);
int asm_symbol_is_weak(const asm_context_t *ctx, const char *name);
