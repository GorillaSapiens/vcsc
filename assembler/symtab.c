//! @file assembler/symtab.c
//! @brief Implements assembler symbol table for the VCSC assembler.
//! @ingroup assembler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "symtab.h"
#include "util.h"

//! @brief Handle symtab init logic for symtab.
void symtab_init(symtab_t *tab)
{
   tab->head = NULL;
}

//! @brief Release free storage owned by symtab.
void symtab_free(symtab_t *tab)
{
   symbol_t *sym;
   symbol_t *next;

   sym = tab->head;
   while (sym) {
      next = sym->next;
      free(sym->name);
      free(sym->segment_name);
      free(sym->def_file);
      free(sym);
      sym = next;
   }

   tab->head = NULL;
}

//! @brief Return symtab find data used by symtab; returned pointers alias existing storage unless explicitly allocated by the function name.
symbol_t *symtab_find(symtab_t *tab, const char *name)
{
   symbol_t *sym;

   for (sym = tab->head; sym; sym = sym->next) {
      if (!strcmp(sym->name, name))
         return sym;
   }

   return NULL;
}

//! @brief Return symtab find const data used by symtab; returned pointers alias existing storage unless explicitly allocated by the function name.
const symbol_t *symtab_find_const(const symtab_t *tab, const char *name)
{
   const symbol_t *sym;

   for (sym = tab->head; sym; sym = sym->next) {
      if (!strcmp(sym->name, name))
         return sym;
   }

   return NULL;
}

//! @brief Return symtab declare data used by symtab; returned pointers alias existing storage unless explicitly allocated by the function name.
symbol_t *symtab_declare(symtab_t *tab,
                         const char *name,
                         const char *def_file,
                         int def_line)
{
   symbol_t *sym;

   sym = symtab_find(tab, name);
   if (sym)
      return NULL;

   sym = (symbol_t *)calloc(1, sizeof(*sym));
   if (!sym) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   sym->name = xstrdup(name);
   sym->defined = 0;
   sym->segment_id = 1;
   sym->def_file = xstrdup(def_file ? def_file : "<input>");
   sym->def_line = def_line;
   sym->next = tab->head;
   tab->head = sym;
   return sym;
}

//! @brief Set whether a symbol can be updated by .set.
void symtab_set_mutable(symbol_t *sym, int mutable)
{
   if (sym)
      sym->mutable = mutable ? 1 : 0;
}

//! @brief Handle symtab set value logic for symtab.
void symtab_set_value(symbol_t *sym, long value)
{
   symtab_set_value_segment(sym, value, 1);
}

//! @brief Handle symtab set value segment logic for symtab.
void symtab_set_value_segment(symbol_t *sym, long value, int segment_id)
{
   if (!sym)
      return;

   symtab_set_value_segment_named(sym, value, segment_id, NULL);
}

//! @brief Handle symtab set value segment named logic for symtab.
void symtab_set_value_segment_named(symbol_t *sym, long value, int segment_id, const char *segment_name)
{
   if (!sym)
      return;

   free(sym->segment_name);
   sym->segment_name = segment_name ? xstrdup(segment_name) : NULL;
   sym->value = value;
   sym->defined = 1;
   sym->segment_id = segment_id;
}

//! @brief Return symtab reference data used by symtab; returned pointers alias existing storage unless explicitly allocated by the function name.
symbol_t *symtab_reference(symtab_t *tab, const char *name)
{
   symbol_t *sym;

   sym = symtab_find(tab, name);
   if (sym)
      return sym;

   sym = (symbol_t *)calloc(1, sizeof(*sym));
   if (!sym) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   sym->name = xstrdup(name);
   sym->defined = 0;
   sym->segment_id = 1;
   sym->def_file = NULL;
   sym->def_line = 0;
   sym->next = tab->head;
   tab->head = sym;
   return sym;
}
