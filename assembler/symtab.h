//! @file assembler/symtab.h
//! @brief Declares assembler symbol table for the VCSC assembler.
//! @ingroup assembler

#ifndef SYMTAB_H
#define SYMTAB_H

//! Assembler symbol entry with definition location and optional segment metadata.
typedef struct symbol {
   char *name;
   long value;
   int defined;
   int segment_id;
   int mutable;
   char *segment_name;
   char *def_file;
   int def_line;
   struct symbol *next;
} symbol_t;

//! Simple linked-list symbol table used by assembler passes.
typedef struct symtab {
   symbol_t *head;
} symtab_t;

void symtab_init(symtab_t *tab);
void symtab_free(symtab_t *tab);

symbol_t *symtab_find(symtab_t *tab, const char *name);
const symbol_t *symtab_find_const(const symtab_t *tab, const char *name);

/*
   Declare a symbol name at a specific source location.

   Returns:
   - existing/new symbol pointer on success
   - NULL if the name was already declared earlier in this pass
*/
symbol_t *symtab_declare(symtab_t *tab,
                         const char *name,
                         const char *def_file,
                         int def_line);

void symtab_set_mutable(symbol_t *sym, int mutable);
void symtab_set_value(symbol_t *sym, long value);
void symtab_set_value_segment(symbol_t *sym, long value, int segment_id);
void symtab_set_value_segment_named(symbol_t *sym, long value, int segment_id, const char *segment_name);

symbol_t *symtab_reference(symtab_t *tab, const char *name);

#endif
