//! @file compiler/compile_support.c
//! @brief Implements shared compiler support routines for the VCSC compiler.
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
#include "compile_internal.h"
#include "compile_lvalue.h"
#include "compile_literal.h"
#include "compile_function_registry.h"
#include "compile_stmt.h"
#include "compile_support.h"
#include "compile_type.h"
#include "emit.h"
#include "integer.h"
#include "memname.h"
#include "messages.h"
#include "pair.h"
#include "set.h"
#include "typename.h"
#include "xform.h"
#include "xray.h"
#include "lextern.h"


#define COMPILER_SCRATCH_MAX_SCOPES 256
#define COMPILER_SCRATCH_MAX_SLOTS 64

typedef struct CompilerScratchSlot {
   int symbol_id;
   int max_size;
} CompilerScratchSlot;

typedef struct CompilerScratchScope {
   char *name;
   char *activation_owner;
   int depth;
   int slot_count;
   CompilerScratchSlot slots[COMPILER_SCRATCH_MAX_SLOTS];
} CompilerScratchScope;

static CompilerScratchScope compiler_scratch_scopes[COMPILER_SCRATCH_MAX_SCOPES];
static int compiler_scratch_scope_count = 0;
static int compiler_scratch_symbol_count = 0;
static CompilerScratchLease *compiler_scratch_active_stack[COMPILER_SCRATCH_MAX_SLOTS];
static int compiler_scratch_active_depth = 0;

//! @brief Warn when explicit runtime division/remainder uses a constant power-of-two divisor.
void diagnose_runtime_power_of_two_divisor(const ASTNode *origin,
                                           const ASTNode *divisor,
                                           const char *op) {
   long long value;
   unsigned long long uvalue;

   if (!origin || !divisor || !op ||
       !expr_is_integer_constant_expr(divisor, &value) || value <= 1) {
      return;
   }
   uvalue = (unsigned long long) value;
   if ((uvalue & (uvalue - 1ULL)) != 0) {
      return;
   }

   if (!strcmp(op, "/") || !strcmp(op, "/=")) {
      warning("[%s:%d.%d] runtime division by constant power of two %lld; "
              "consider an explicit shift if its signed rounding behavior is acceptable",
              origin->file, origin->line, origin->column, value);
   }
   else if (!strcmp(op, "%") || !strcmp(op, "%=")) {
      warning("[%s:%d.%d] runtime remainder by constant power of two %lld; "
              "consider an explicit mask if nonnegative modulo behavior is intended",
              origin->file, origin->line, origin->column, value);
   }
}

static int compiler_scratch_scope_for_context(const Context *ctx) {
   const char *name = (ctx && ctx->name && *ctx->name) ? ctx->name : "<translation-unit>";
   for (int i = 0; i < compiler_scratch_scope_count; i++) {
      if (!strcmp(compiler_scratch_scopes[i].name, name)) {
         return i;
      }
   }
   if (compiler_scratch_scope_count >= COMPILER_SCRATCH_MAX_SCOPES) {
      error_unreachable("too many compiler scratch scopes");
   }
   int index = compiler_scratch_scope_count++;
   memset(&compiler_scratch_scopes[index], 0, sizeof(compiler_scratch_scopes[index]));
   compiler_scratch_scopes[index].name = strdup(name);
   compiler_scratch_scopes[index].activation_owner =
      (ctx && ctx->activation_owner && *ctx->activation_owner)
         ? strdup(ctx->activation_owner) : NULL;
   if (!compiler_scratch_scopes[index].name ||
       ((ctx && ctx->activation_owner && *ctx->activation_owner) &&
        !compiler_scratch_scopes[index].activation_owner)) {
      error_unreachable("out of memory creating compiler scratch scope");
   }
   return index;
}

void compiler_scratch_reset(void) {
   for (int i = 0; i < compiler_scratch_scope_count; i++) {
      free(compiler_scratch_scopes[i].name);
      free(compiler_scratch_scopes[i].activation_owner);
   }
   memset(compiler_scratch_scopes, 0, sizeof(compiler_scratch_scopes));
   compiler_scratch_scope_count = 0;
   compiler_scratch_symbol_count = 0;
   memset(compiler_scratch_active_stack, 0, sizeof(compiler_scratch_active_stack));
   compiler_scratch_active_depth = 0;
}

const char *compiler_scratch_active_symbol(void) {
   if (compiler_scratch_active_depth <= 0) {
      error_unreachable("compiler scratch access without an active lease");
   }
   return compiler_scratch_active_stack[compiler_scratch_active_depth - 1]->symbol;
}

void compiler_scratch_acquire(Context *ctx, int reserved, CompilerScratchLease *lease) {
   CompilerScratchScope *scope;
   CompilerScratchSlot *slot;
   int scope_index;
   int slot_index;

   if (!lease) {
      error_unreachable("NULL compiler scratch lease");
   }
   memset(lease, 0, sizeof(*lease));
   scope_index = compiler_scratch_scope_for_context(ctx);
   scope = &compiler_scratch_scopes[scope_index];
   slot_index = scope->depth++;
   if (slot_index >= COMPILER_SCRATCH_MAX_SLOTS) {
      error_unreachable("compiler scratch nesting exceeds %d", COMPILER_SCRATCH_MAX_SLOTS);
   }
   if (slot_index >= scope->slot_count) {
      slot = &scope->slots[scope->slot_count++];
      slot->symbol_id = compiler_scratch_symbol_count++;
   }
   else {
      slot = &scope->slots[slot_index];
   }

   lease->scope_index = scope_index;
   lease->slot_index = slot_index;
   lease->saved_locals = ctx ? ctx->locals : 0;
   lease->saved_high_water = ctx ? ctx->locals_high_water : 0;
   lease->reserved = reserved > 0 ? reserved : 1;
   lease->used = lease->reserved;
   snprintf(lease->symbol, sizeof(lease->symbol), "__vcsc_scratch_%d", slot->symbol_id);
}

void compiler_scratch_note_used(CompilerScratchLease *lease, int used) {
   CompilerScratchScope *scope;
   CompilerScratchSlot *slot;
   if (!lease || lease->scope_index < 0 || lease->scope_index >= compiler_scratch_scope_count ||
       lease->slot_index < 0) {
      error_unreachable("invalid compiler scratch lease");
   }
   if (used < lease->reserved) {
      used = lease->reserved;
   }
   if (used > lease->used) {
      lease->used = used;
   }
   scope = &compiler_scratch_scopes[lease->scope_index];
   if (lease->slot_index >= scope->slot_count) {
      error_unreachable("invalid compiler scratch slot");
   }
   slot = &scope->slots[lease->slot_index];
   if (lease->used > slot->max_size) {
      slot->max_size = lease->used;
   }
}

void compiler_scratch_activate(Context *ctx, CompilerScratchLease *lease) {
   if (!lease || lease->active) {
      error_unreachable("invalid compiler scratch activation");
   }
   if (compiler_scratch_active_depth >= COMPILER_SCRATCH_MAX_SLOTS) {
      error_unreachable("compiler scratch activation nesting exceeds %d", COMPILER_SCRATCH_MAX_SLOTS);
   }
   if (ctx) {
      ctx->locals = lease->reserved;
      ctx->locals_high_water = lease->reserved;
   }
   compiler_scratch_active_stack[compiler_scratch_active_depth++] = lease;
   lease->active = true;
}

void compiler_scratch_deactivate(Context *ctx, CompilerScratchLease *lease) {
   int used;
   if (!lease || !lease->active || compiler_scratch_active_depth <= 0 ||
       compiler_scratch_active_stack[compiler_scratch_active_depth - 1] != lease) {
      error_unreachable("invalid compiler scratch deactivation");
   }
   used = ctx ? ctx->locals_high_water : lease->reserved;
   compiler_scratch_note_used(lease, used);
   compiler_scratch_active_stack[--compiler_scratch_active_depth] = NULL;
   if (ctx) {
      ctx->locals = lease->saved_locals;
      ctx->locals_high_water = lease->saved_high_water;
   }
   lease->active = false;
}

void compiler_scratch_release(CompilerScratchLease *lease) {
   CompilerScratchScope *scope;
   if (!lease || lease->active || lease->scope_index < 0 ||
       lease->scope_index >= compiler_scratch_scope_count) {
      error_unreachable("invalid compiler scratch release");
   }
   compiler_scratch_note_used(lease, lease->used);
   scope = &compiler_scratch_scopes[lease->scope_index];
   if (scope->depth != lease->slot_index + 1) {
      error_unreachable("compiler scratch leases must be released in LIFO order");
   }
   scope->depth--;
   lease->scope_index = -1;
   lease->slot_index = -1;
}

void compiler_scratch_emit_bss(void) {
   if (compiler_scratch_active_depth != 0) {
      error_unreachable("active compiler scratch remains at end of code generation");
   }
   for (int i = 0; i < compiler_scratch_scope_count; i++) {
      CompilerScratchScope *scope = &compiler_scratch_scopes[i];
      if (scope->depth != 0) {
         error_unreachable("unreleased compiler scratch in scope '%s'", scope->name);
      }
      for (int j = 0; j < scope->slot_count; j++) {
         CompilerScratchSlot *slot = &scope->slots[j];
         if (slot->max_size <= 0) {
            continue;
         }
         {
            char segbuf[512];
            Context owner_ctx;
            memset(&owner_ctx, 0, sizeof(owner_ctx));
            owner_ctx.activation_owner = scope->activation_owner;
            build_activation_storage_segment(segbuf, sizeof(segbuf),
                                             &owner_ctx, NULL, "BSS");
            emit(&es_bss, ".segment \"%s\"\n", segbuf);
         }
         emit(&es_bss, "__vcsc_scratch_%d:\n", slot->symbol_id);
         emit(&es_bss, "\t.res %d\n", slot->max_size);
      }
   }
}

//! @brief Build a segment name for storage whose lifetime is one function activation.
void build_activation_storage_segment(char *buf, size_t bufsize,
                                      const Context *ctx,
                                      const ASTNode *modifiers,
                                      const char *base_segment) {
   const char *memname = find_mem_modifier_name(modifiers);

   build_activation_storage_segment_for_region(buf, bufsize, ctx, memname,
                                               base_segment);
}

//! @brief Build a function-activation segment with an explicitly classified region.
void build_activation_storage_segment_for_region(char *buf, size_t bufsize,
                                                 const Context *ctx,
                                                 const char *region_name,
                                                 const char *base_segment) {
   const char *owner = (ctx && ctx->activation_owner) ? ctx->activation_owner : NULL;

   if (!buf || bufsize == 0 || !base_segment) {
      return;
   }
   if (!owner || !*owner) {
      if (region_name && *region_name) {
         snprintf(buf, bufsize, "%s.%s", base_segment, region_name);
      }
      else {
         snprintf(buf, bufsize, "%s", base_segment);
      }
      return;
   }

   if (region_name && *region_name) {
      snprintf(buf, bufsize, "%s.%s.__vcsc_activation$%s",
               base_segment, region_name, owner);
   }
   else {
      snprintf(buf, bufsize, "%s.__vcsc_activation$%s",
               base_segment, owner);
   }
}

//! @brief Return context lookup data used by compiler code-generation support; returned pointers alias existing storage unless explicitly allocated by the function name.
ContextEntry *ctx_lookup(Context *ctx, const char *name) {
   return ctx ? (ContextEntry *) set_get(ctx->vars, name) : NULL;
}



#define MEM_REGION_META_PREFIX "__memmeta$V1$"
#define MEM_REGION_SPLIT_META_PREFIX "__memmeta$V2$"

static Set *emitted_mem_region_metadata = NULL;

//! @brief Parse unsigned integer flag from a mem declaration flag list.
static bool mem_metadata_parse_u16_flag(const ASTNode *flags, const char *prefix, unsigned int *out) {
   size_t prefix_len;

   if (!flags || is_empty(flags) || !prefix || !out) {
      return false;
   }

   prefix_len = strlen(prefix);
   for (int i = 0; i < flags->count; i++) {
      const char *text;
      char *end = NULL;
      unsigned long value;

      if (!flags->children[i] || !flags->children[i]->strval) {
         continue;
      }
      text = flags->children[i]->strval;
      if (strncmp(text, prefix, prefix_len)) {
         continue;
      }

      value = strtoul(text + prefix_len, &end, 0);
      if (!end || *end != '\0' || value > 0xFFFFul) {
         return false;
      }
      *out = (unsigned int)value;
      return true;
   }

   return false;
}

//! @brief Find read/write type flag from a mem declaration.
static const char *mem_metadata_type_flag(const ASTNode *flags) {
   bool have_rw = false;
   bool have_ro = false;

   if (!flags || is_empty(flags)) {
      return NULL;
   }

   for (int i = 0; i < flags->count; i++) {
      const char *text = (flags->children[i] && flags->children[i]->strval) ? flags->children[i]->strval : NULL;
      if (!text) {
         continue;
      }
      if (!strcmp(text, "$rw")) {
         have_rw = true;
      }
      else if (!strcmp(text, "$ro")) {
         have_ro = true;
      }
   }

   if (have_rw && have_ro) {
      return "conflict";
   }
   if (have_rw) {
      return "rw";
   }
   if (have_ro) {
      return "ro";
   }
   return NULL;
}

//! @brief Emit object metadata describing a used compiler mem region for later linker cfg validation.
void emit_mem_region_metadata_for_name(const ASTNode *origin, const char *name) {
   const ASTNode *mem_decl;
   const ASTNode *flags;
   unsigned int start = 0;
   unsigned int read_start = 0;
   unsigned int write_start = 0;
   unsigned int size = 0;
   unsigned int end = 0;
   bool have_start;
   bool have_read_start;
   bool have_write_start;
   bool have_size;
   bool have_end;
   bool split;
   const char *type;
   char sym[320];

   if (!name) {
      return;
   }

   if (!emitted_mem_region_metadata) {
      emitted_mem_region_metadata = new_set();
   }
   if (set_get(emitted_mem_region_metadata, name)) {
      return;
   }

   mem_decl = get_memname_node(name);
   if (!mem_decl || strcmp(mem_decl->name, "mem_decl_stmt") || mem_decl->count < 2) {
      error_user("[%s:%d.%d] mem region '%s' is used for storage but has no declaration metadata for linker validation",
            origin ? origin->file : __FILE__, origin ? origin->line : __LINE__, origin ? origin->column : 0, name);
   }

   flags = mem_decl->children[1];
   have_start = mem_metadata_parse_u16_flag(flags, "$start:", &start);
   have_read_start = mem_metadata_parse_u16_flag(flags, "$read_start:", &read_start);
   have_write_start = mem_metadata_parse_u16_flag(flags, "$write_start:", &write_start);
   have_size = mem_metadata_parse_u16_flag(flags, "$size:", &size);
   have_end = mem_metadata_parse_u16_flag(flags, "$end:", &end);
   type = mem_metadata_type_flag(flags);
   split = have_read_start || have_write_start;

   if (split) {
      if (have_start || !have_read_start || !have_write_start ||
          (!have_size && !have_end) || !type || strcmp(type, "rw")) {
         error_user("[%s:%d.%d] split-address mem region '%s' must declare $read_start, $write_start, $size or $end, and exactly $rw (not $start/$ro)",
               origin ? origin->file : mem_decl->file,
               origin ? origin->line : mem_decl->line,
               origin ? origin->column : mem_decl->column,
               name);
      }
      start = read_start;
   }
   else if (!have_start || (!have_size && !have_end) || !type || !strcmp(type, "conflict")) {
      error_user("[%s:%d.%d] mem region '%s' is used for storage and must declare $start plus $size or $end and exactly one of $rw/$ro so vcsc-ld can validate it against the linker cfg",
            origin ? origin->file : mem_decl->file,
            origin ? origin->line : mem_decl->line,
            origin ? origin->column : mem_decl->column,
            name);
   }

   if (!have_size) {
      if (end < start) {
         error_user("[%s:%d.%d] mem region '%s' has $end below its read/start address",
               mem_decl->file, mem_decl->line, mem_decl->column, name);
      }
      size = end - start;
   }

   if (size > 0x10000u || start + size > 0x10000u ||
       (split && write_start + size > 0x10000u)) {
      error_user("[%s:%d.%d] mem region '%s' aliases are outside the 6502 address space",
            mem_decl->file, mem_decl->line, mem_decl->column, name);
   }

   if (split) {
      snprintf(sym, sizeof(sym), "%s%s$R%04X$W%04X$Z%04X$T%s",
               MEM_REGION_SPLIT_META_PREFIX, name, read_start & 0xFFFFu,
               write_start & 0xFFFFu, size & 0xFFFFu, type);
   }
   else {
      snprintf(sym, sizeof(sym), "%s%s$S%04X$Z%04X$T%s", MEM_REGION_META_PREFIX, name, start & 0xFFFFu, size & 0xFFFFu, type);
   }
   set_add(emitted_mem_region_metadata, strdup(name), (void *)1);
   emit(&es_export, "%s = 0\n", sym);
   emit(&es_export, ".export %s\n", sym);
   if (split) {
      /* The VCS default BSS/DATA regions are zero page, but a named split
         region such as Superchip RAM lives in the cartridge address window.
         Override the inherited base-segment contract so unsuffixed accesses
         remain absolute until their aliases are resolved by the linker. */
      emit(&es_export, ".segmentaddrsize \"BSS.%s\", absolute\n", name);
      emit(&es_export, ".segmentaddrsize \"DATA.%s\", absolute\n", name);
   }
}

//! @brief Emit metadata for the sole named region on an ordinary declaration.
void emit_mem_region_metadata_for_modifiers(const ASTNode *origin, const ASTNode *modifiers) {
   emit_mem_region_metadata_for_name(origin, find_mem_modifier_name(modifiers));
}

//! @brief Return global decl lookup data used by compiler code-generation support; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *global_decl_lookup(const char *name) {
   const void *value;
   if (!globals || !name) {
      return NULL;
   }
   value = set_get(globals, name);
   if (!value || (uintptr_t) value < 4096) {
      return NULL;
   }
   return (const ASTNode *) value;
}

//! @brief Return decl subitem declarator data used by compiler code-generation support; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *decl_subitem_declarator(const ASTNode *node) {
   if (!node) {
      return NULL;
   }
   if (strcmp(node->name, "decl_subitem") || node->count <= 0) {
      return node;
   }
   return node->children[0];
}

//! @brief Return decl subitem address spec data used by compiler code-generation support; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *decl_subitem_address_spec(const ASTNode *node) {
   if (!node || strcmp(node->name, "decl_subitem") || node->count <= 1) {
      return NULL;
   }
   return node->children[1];
}

//! @brief Return decl node declarator data used by compiler code-generation support; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *decl_node_declarator(const ASTNode *node) {
   if (!node || node->count <= 2) {
      return NULL;
   }
   return decl_subitem_declarator(node->children[2]);
}

//! @brief Return decl node address spec data used by compiler code-generation support; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *decl_node_address_spec(const ASTNode *node) {
   if (!node || node->count <= 2) {
      return NULL;
   }
   return decl_subitem_address_spec(node->children[2]);
}

//! @brief Return address spec read expr data used by compiler code-generation support; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *address_spec_read_expr(const ASTNode *node) {
   if (!node || is_empty(node)) {
      return NULL;
   }
   if (!strcmp(node->name, "rw_addr_spec")) {
      return (node->count > 0 && node->children[0] && !is_empty(node->children[0])) ? node->children[0]->strval : NULL;
   }
   return node->strval;
}

//! @brief Return address spec write expr data used by compiler code-generation support; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *address_spec_write_expr(const ASTNode *node) {
   if (!node || is_empty(node)) {
      return NULL;
   }
   if (!strcmp(node->name, "rw_addr_spec")) {
      return (node->count > 1 && node->children[1] && !is_empty(node->children[1])) ? node->children[1]->strval : NULL;
   }
   return node->strval;
}

//! @brief Return whether entry has read address in compiler code-generation support.
bool entry_has_read_address(const ContextEntry *entry) {
   return entry && entry->is_absolute_ref && entry->read_expr && *entry->read_expr;
}

//! @brief Return whether entry has write address in compiler code-generation support.
bool entry_has_write_address(const ContextEntry *entry) {
   return entry && entry->is_absolute_ref && entry->write_expr && *entry->write_expr;
}

//! @brief Return whether entry is absolute external binding in compiler code-generation support.
bool entry_is_absolute_ref(const ContextEntry *entry) {
   return entry && entry->is_absolute_ref;
}

//! @brief Attach symbolic read/write aliases for an allocated split-address object.
void init_split_mem_entry_addresses_for_symbol(ContextEntry *entry, const char *symbol,
                                               const ASTNode *modifiers) {
   char write_expr[320];
   int delta = 0;

   if (!entry || !symbol || !*symbol || !modifiers_imply_split_address(modifiers)) {
      return;
   }
   if (!modifiers_split_address_delta(modifiers, &delta)) {
      error_unreachable("could not construct split-address aliases for '%s'", symbol);
   }
   entry->is_absolute_ref = true;
   entry->read_expr = strdup(symbol);
   if (delta == 0) {
      entry->write_expr = strdup(symbol);
   }
   else {
      snprintf(write_expr, sizeof(write_expr), "{%s %c %u}", symbol,
               delta < 0 ? '-' : '+', (unsigned)(delta < 0 ? -delta : delta));
      entry->write_expr = strdup(write_expr);
   }
   entry->has_split_alias_delta = true;
   entry->split_alias_delta = delta;
   if (!entry->read_expr || !entry->write_expr) {
      error_unreachable("out of memory constructing split-address aliases for '%s'", symbol);
   }
}

//! @brief Attach symbolic aliases using one explicitly classified split region.
void init_split_mem_entry_addresses_for_region(ContextEntry *entry, const char *symbol,
                                               const char *region_name) {
   const ASTNode *mem_decl = region_name ? get_memname_node(region_name) : NULL;
   unsigned int read_start = 0;
   unsigned int write_start = 0;
   char write_expr[320];
   int delta;

   if (!entry || !symbol || !*symbol ||
       !mem_decl_split_addresses(mem_decl, &read_start, &write_start)) {
      return;
   }
   delta = (int)write_start - (int)read_start;
   entry->is_absolute_ref = true;
   entry->read_expr = strdup(symbol);
   if (delta == 0) {
      entry->write_expr = strdup(symbol);
   }
   else {
      snprintf(write_expr, sizeof(write_expr), "{%s %c %u}", symbol,
               delta < 0 ? '-' : '+', (unsigned)(delta < 0 ? -delta : delta));
      entry->write_expr = strdup(write_expr);
   }
   entry->has_split_alias_delta = true;
   entry->split_alias_delta = delta;
   if (!entry->read_expr || !entry->write_expr) {
      error_unreachable("out of memory constructing split-address aliases for '%s'", symbol);
   }
}

static void init_split_mem_entry_addresses(ContextEntry *entry, const char *name,
                                           const ASTNode *modifiers) {
   char symbol[256];

   if (!entry || !name || !modifiers_imply_split_address(modifiers)) {
      return;
   }
   if (!format_user_asm_symbol(name, symbol, sizeof(symbol))) {
      error_unreachable("could not construct split-address aliases for '%s'", name);
   }
   init_split_mem_entry_addresses_for_symbol(entry, symbol, modifiers);
}

//! @brief Extract init context entry from global decl for compiler code-generation support.
bool init_context_entry_from_global_decl(ContextEntry *entry, const char *name, const ASTNode *g) {
   const ASTNode *modifiers;
   const ASTNode *type;
   const ASTNode *declarator;
   const ASTNode *addrspec;

   if (!entry || !g || g->count < 3) {
      return false;
   }

   modifiers = g->children[0];
   type = g->children[1];
   declarator = decl_node_declarator(g);
   addrspec = decl_node_address_spec(g);
   if (!type || !declarator) {
      return false;
   }

   memset(entry, 0, sizeof(*entry));
   entry->name = name;
   entry->type = type;
   entry->declarator = declarator;
   entry->is_static = false;
   {
      MemRegionSet regions;
      mem_region_set_collect(modifiers, &regions);
      entry->is_zeropage = regions.count == 1 &&
         mem_decl_is_zeropage(get_memname_node(regions.names[0]));
      mem_region_set_release(&regions);
   }
   entry->is_global = true;
   entry->is_ref = false;
   entry->is_absolute_ref = addrspec != NULL;
   entry->read_expr = address_spec_read_expr(addrspec);
   entry->write_expr = address_spec_write_expr(addrspec);
   entry->object_is_const = declaration_const_applies_to_object(modifiers, declarator);
   entry->pointer_access = declaration_pointer_access(modifiers, declarator);
   {
      MemRegionSet regions;
      mem_region_set_collect(modifiers, &regions);
      if (regions.count <= 1) {
         init_split_mem_entry_addresses(entry, name, modifiers);
      }
      mem_region_set_release(&regions);
   }
   entry->offset = 0;
   entry->size = declarator_storage_size(type, declarator);
   return true;
}

//! @brief Handle entry symbol name logic for compiler code-generation support.
bool entry_symbol_name(Context *ctx, const ContextEntry *entry, char *buf, size_t bufsize) {
   if (!entry || !entry->name || !buf || bufsize < 8) {
      return false;
   }
   if (entry->is_absolute_ref) {
      return false;
   }
   if (entry->is_global) {
      return format_user_asm_symbol(entry->name, buf, bufsize);
   }
   if (entry->is_static || entry->is_zeropage) {
      char raw[256];
      snprintf(raw, sizeof(raw), "%s$%s", ctx && ctx->name ? ctx->name : "", entry->name);
      return format_user_asm_symbol(raw, buf, bufsize);
   }
   return false;
}

//! @brief Emit copy scratch to symbol offset for compiler code-generation support diagnostics or output files.
void emit_copy_scratch_to_symbol_offset(const char *symbol, int symbol_offset, int src_offset, int size) {
   bool src_direct = src_offset >= 0 && src_offset + size <= 256;
   if (!src_direct) {
      emit_prepare_scratch_ptr(1, src_offset);
   }
   for (int i = 0; i < size; i++) {
      emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + i) : i);
      emit(&es_code, "    lda %s,y\n", src_direct ? compiler_scratch_active_symbol() : "(ptr1)");
      emit(&es_code, "    ldy #%d\n", symbol_offset + i);
      emit(&es_code, "    sta %s,y\n", symbol);
   }
}

//! @brief Emit copy scratch to symbol for compiler code-generation support diagnostics or output files.
void emit_copy_scratch_to_symbol(const char *symbol, int src_offset, int size) {
   emit_copy_scratch_to_symbol_offset(symbol, 0, src_offset, size);
}

//! @brief Copy staged scratch bytes to an arbitrary writable address expression.
void emit_copy_scratch_to_address_expr(const char *write_expr, int src_offset, int size) {
   bool src_direct = src_offset >= 0 && src_offset + size <= 256;

   if (!write_expr || !*write_expr || size <= 0) {
      return;
   }
   if (!src_direct) {
      emit_prepare_scratch_ptr(1, src_offset);
   }
   for (int i = 0; i < size; i++) {
      emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + i) : i);
      emit(&es_code, "    lda %s,y\n",
           src_direct ? compiler_scratch_active_symbol() : "(ptr1)");
      emit_store_a_to_expr_address(write_expr, i);
   }
}

//! @brief Extract emit load a from expr address for compiler code-generation support.
void emit_load_a_from_expr_address(const char *expr, int addend) {
   char expr_buf[256];
   const char *asm_expr = assembler_address_expr(expr, expr_buf, sizeof(expr_buf));

   if (addend == 0) {
      emit(&es_code, "    lda  %s\n", asm_expr);
   }
   else {
      emit(&es_code, "    lda  %s + %d\n", asm_expr, addend);
   }
}

//! @brief Emit store a to expression address for compiler code-generation support diagnostics or output files.
void emit_store_a_to_expr_address(const char *expr, int addend) {
   char expr_buf[256];
   const char *asm_expr = assembler_address_expr(expr, expr_buf, sizeof(expr_buf));

   if (addend == 0) {
      emit(&es_code, "    sta  %s\n", asm_expr);
   }
   else {
      emit(&es_code, "    sta  %s + %d\n", asm_expr, addend);
   }
}

//! @brief Handle absolute external binding supports direct access logic for compiler code-generation support.
static bool absolute_ref_supports_direct_access(const LValueRef *lv) {
   return lv && lv->is_absolute_ref && !lv->is_bitfield && !lv->indirect && !lv->needs_runtime_address;
}


//! @brief Emit copy lvalue to symbol for compiler code-generation support diagnostics or output files.
bool emit_copy_lvalue_to_symbol(Context *ctx, const char *symbol, int symbol_offset, const LValueRef *src, int size) {
   int copy_size = size < src->size ? size : src->size;

   if (src && src->is_bitfield) {
      return emit_copy_bitfield_lvalue_to_symbol(ctx, symbol, symbol_offset, src, size);
   }
   if (absolute_ref_supports_direct_access(src)) {
      const char *read_expr = src->read_expr;
      emit_lvalue_semantic_use(ctx, src, "read");

      if (!read_expr || !*read_expr) {
         return false;
      }
      for (int i = 0; i < copy_size; i++) {
         emit_load_a_from_expr_address(read_expr, src->offset + i);
         emit(&es_code, "    ldy #%d\n", symbol_offset + i);
         emit(&es_code, "    sta %s,y\n", symbol);
      }
      return true;
   }
   if (copy_size <= 0) {
      return true;
   }
   if (!emit_prepare_lvalue_ptr(ctx, src, LVALUE_ACCESS_READ)) {
      return false;
   }
   for (int i = 0; i < copy_size; i++) {
      emit(&es_code, "    ldy #%d\n", i);
      emit(&es_code, "    lda (ptr0),y\n");
      emit(&es_code, "    ldy #%d\n", symbol_offset + i);
      emit(&es_code, "    sta %s,y\n", symbol);
   }
   return true;
}









//! @brief Fill bytes through ptr1, inlining scalar-width fills.
void emit_runtime_fill_ptr1(int count, unsigned char value) {
   const char *helper;

   if (count <= 0) {
      return;
   }

   if (count <= 4) {
      emit(&es_code, "    lda #$%02x\n", value);
      for (int i = 0; i < count; i++) {
         emit(&es_code, "    ldy #%d\n", i);
         emit(&es_code, "    sta (ptr1),y\n");
      }
      return;
   }

   helper = value == 0 ? "zero_bytes" : "fill_bytes";
   remember_runtime_import(helper);
   emit(&es_code, "    lda #$%02x\n", count & 0xff);
   emit(&es_code, "    sta arg0\n");
   if (value != 0) {
      emit(&es_code, "    lda #$%02x\n", value);
      emit(&es_code, "    sta arg1\n");
   }
   emit(&es_code, "    jsr _%s\n", helper);
}

//! @brief Copy bytes from ptr0 to ptr1, inlining scalar-width copies.
void emit_copy_ptr0_to_ptr1(int count) {
   if (count <= 0) {
      return;
   }

   if (count <= 4) {
      for (int i = 0; i < count; i++) {
         emit(&es_code, "    ldy #%d\n", i);
         emit(&es_code, "    lda (ptr0),y\n");
         emit(&es_code, "    sta (ptr1),y\n");
      }
      return;
   }

   remember_runtime_import("copy_bytes");
   emit(&es_code, "    lda #$%02x\n", count & 0xff);
   emit(&es_code, "    sta arg0\n");
   emit(&es_code, "    jsr _copy_bytes\n");
}

//! @brief Emit fill scratch bytes for compiler code-generation support diagnostics or output files.
void emit_fill_scratch_bytes(int dst_offset, int start, int count, unsigned char value) {
   if (count <= 0) {
      return;
   }

   emit_prepare_scratch_ptr(1, dst_offset + start);
   emit_runtime_fill_ptr1(count, value);
}

//! @brief Extract emit sign fill from masked a for compiler code-generation support.
static void emit_sign_fill_from_masked_a(void) {
   const char *zero_label = next_label("signext_zero");
   const char *done_label = next_label("signext_done");

   emit(&es_code, "    beq %s\n", zero_label);
   emit(&es_code, "    lda #$ff\n");
   emit(&es_code, "    bne %s\n", done_label);
   emit(&es_code, "%s:\n", zero_label);
   emit(&es_code, "    lda #$00\n");
   emit(&es_code, "%s:\n", done_label);
}

//! @brief Emit copy scratch to scratch convert for little-endian values.
void emit_copy_scratch_to_scratch_convert(int dst_offset, int dst_size, const ASTNode *dst_type, int src_offset, int src_size, const ASTNode *src_type) {
   bool is_signed = type_is_signed_integer(src_type);
   bool dst_direct;
   bool src_direct;
   int sign_src_mem;

   (void) dst_type;
   if (dst_size <= 0 || src_size <= 0) {
      return;
   }

   dst_direct = dst_offset >= 0 && dst_offset + dst_size <= 256;
   src_direct = src_offset >= 0 && src_offset + src_size <= 256;
   sign_src_mem = src_size - 1;
   if (!src_direct) {
      emit_prepare_scratch_ptr(0, src_offset);
   }
   if (!dst_direct) {
      emit_prepare_scratch_ptr(1, dst_offset);
   }

   if (dst_offset == src_offset) {
      /* Little-endian in-place truncation needs no copy.  In-place widening
         preserves the existing low bytes and writes only the new high bytes,
         so no hardware-stack shuffle is required. */
      if (dst_size <= src_size) {
         return;
      }
      if (is_signed) {
         emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + sign_src_mem) : sign_src_mem);
         emit(&es_code, "    lda %s,y\n", src_direct ? compiler_scratch_active_symbol() : "(ptr0)");
         emit(&es_code, "    and #$80\n");
         emit_sign_fill_from_masked_a();
      }
      else {
         emit(&es_code, "    lda #$00\n");
      }
      for (int j = src_size; j < dst_size; j++) {
         emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + j) : j);
         emit(&es_code, "    sta %s,y\n", dst_direct ? compiler_scratch_active_symbol() : "(ptr1)");
      }
      return;
   }

   for (int j = 0; j < dst_size; j++) {
      if (j < src_size) {
         emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + j) : j);
         emit(&es_code, "    lda %s,y\n", src_direct ? compiler_scratch_active_symbol() : "(ptr0)");
      }
      else if (is_signed) {
         emit(&es_code, "    ldy #%d\n", src_direct ? (src_offset + sign_src_mem) : sign_src_mem);
         emit(&es_code, "    lda %s,y\n", src_direct ? compiler_scratch_active_symbol() : "(ptr0)");
         emit(&es_code, "    and #$80\n");
         emit_sign_fill_from_masked_a();
      }
      else {
         emit(&es_code, "    lda #$00\n");
      }
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + j) : j);
      emit(&es_code, "    sta %s,y\n", dst_direct ? compiler_scratch_active_symbol() : "(ptr1)");
   }
}

//! @brief Emit copy symbol to scratch convert offset for little-endian values.
void emit_copy_symbol_to_scratch_convert_offset(int dst_offset, int dst_size, const ASTNode *dst_type, const char *symbol, int src_offset, int src_size, const ASTNode *src_type) {
   bool is_signed = type_is_signed_integer(src_type);
   bool dst_direct;
   int sign_src_mem;

   (void) dst_type;
   if (dst_size <= 0 || src_size <= 0) {
      return;
   }

   dst_direct = dst_offset >= 0 && dst_offset + dst_size <= 256;
   sign_src_mem = src_size - 1;
   if (!dst_direct) {
      emit_prepare_scratch_ptr(1, dst_offset);
   }

   for (int j = 0; j < dst_size; j++) {
      if (j < src_size) {
         emit(&es_code, "    ldy #%d\n", src_offset + j);
         emit(&es_code, "    lda %s,y\n", symbol);
      }
      else if (is_signed) {
         emit(&es_code, "    ldy #%d\n", src_offset + sign_src_mem);
         emit(&es_code, "    lda %s,y\n", symbol);
         emit(&es_code, "    and #$80\n");
         emit_sign_fill_from_masked_a();
      }
      else {
         emit(&es_code, "    lda #$00\n");
      }
      emit(&es_code, "    ldy #%d\n", dst_direct ? (dst_offset + j) : j);
      emit(&es_code, "    sta %s,y\n", dst_direct ? compiler_scratch_active_symbol() : "(ptr1)");
   }
}

//! @brief Emit copy symbol to scratch convert for compiler code-generation support diagnostics or output files.
void emit_copy_symbol_to_scratch_convert(int dst_offset, int dst_size, const ASTNode *dst_type, const char *symbol, int src_size, const ASTNode *src_type) {
   emit_copy_symbol_to_scratch_convert_offset(dst_offset, dst_size, dst_type, symbol, 0, src_size, src_type);
}

//! @brief Emit a converted copy between two fixed little-endian symbols.
void emit_copy_symbol_to_symbol_convert_offset(const char *dst_symbol, int dst_offset, int dst_size, const ASTNode *dst_type,
                                               const char *src_symbol, int src_offset, int src_size, const ASTNode *src_type) {
   bool is_signed = type_is_signed_integer(src_type);
   int sign_src_mem;

   (void) dst_type;
   if (!dst_symbol || !src_symbol || dst_size <= 0 || src_size <= 0) {
      return;
   }

   sign_src_mem = src_size - 1;
   for (int j = 0; j < dst_size; j++) {
      if (j < src_size) {
         emit(&es_code, "    ldy #%d\n", src_offset + j);
         emit(&es_code, "    lda %s,y\n", src_symbol);
      }
      else if (is_signed) {
         emit(&es_code, "    ldy #%d\n", src_offset + sign_src_mem);
         emit(&es_code, "    lda %s,y\n", src_symbol);
         emit(&es_code, "    and #$80\n");
         emit_sign_fill_from_masked_a();
      }
      else {
         emit(&es_code, "    lda #$00\n");
      }
      emit(&es_code, "    ldy #%d\n", dst_offset + j);
      emit(&es_code, "    sta %s,y\n", dst_symbol);
   }
}

//! @brief Add runtime import to compiler code-generation support state, growing storage or preserving uniqueness as needed.
void remember_runtime_import(const char *name) {
   if (!runtime_imports) {
      runtime_imports = new_set();
   }
   if (!set_get(runtime_imports, name)) {
      set_add(runtime_imports, strdup(name), (void *)1);
      emit(&es_import, ".import _%s\n", name);
   }
}

//! @brief Add symbol import to compiler code-generation support state, growing storage or preserving uniqueness as needed.
void remember_symbol_import(const char *name) {
   if (!imported_symbols) {
      imported_symbols = new_set();
   }
   if (!set_get(imported_symbols, name)) {
      set_add(imported_symbols, strdup(name), (void *)1);
      emit(&es_import, ".import %s\n", name);
   }
}

//! @brief Add symbol import mode to compiler code-generation support state, growing storage or preserving uniqueness as needed.
void remember_symbol_import_mode(const char *name, bool is_zeropage) {
   char key[320];

   if (!name) {
      return;
   }
   if (!imported_symbols) {
      imported_symbols = new_set();
   }

   snprintf(key, sizeof(key), "%c:%s", is_zeropage ? 'Z' : 'A', name);
   if (!set_get(imported_symbols, key)) {
      set_add(imported_symbols, strdup(key), (void *)1);
      emit(&es_import,
           is_zeropage ? ".zpimport %s\n" : ".import %s\n",
           name);
   }
}



//! @brief Set current compiler scratch depth and retain its high-water mark.
void ctx_set_locals(Context *ctx, int value) {
   if (!ctx) {
      return;
   }
   ctx->locals = value;
   if (value > ctx->locals_high_water) {
      ctx->locals_high_water = value;
   }
}

//! @brief Add to current compiler scratch depth and retain its high-water mark.
void ctx_add_locals(Context *ctx, int value) {
   if (!ctx) {
      return;
   }
   ctx_set_locals(ctx, ctx->locals + value);
}

//! @brief Handle context push logic for compiler code-generation support.
void ctx_push(Context *ctx, const ASTNode *type, const char *name) {
   ContextEntry *entry = (ContextEntry *) set_get(ctx->vars, name);
   if (entry != NULL) {
      error_user("[%s:%d.%d] duplicate symbol '%s' first defined at [%s:%d.%d]",
            type->file, type->line, type->column,
            name,
            entry->type->file, entry->type->line, entry->type->column);
   }

   entry = (ContextEntry *) calloc(1, sizeof(ContextEntry));
   entry->name = strdup(name);
   entry->is_static = false;
   entry->is_zeropage = false;
   entry->is_global = false;
   entry->is_ref = false;
   entry->is_absolute_ref = false;
   entry->read_expr = NULL;
   entry->write_expr = NULL;
   entry->has_split_alias_delta = false;
   entry->split_alias_delta = 0;
   entry->target_typed = false;
   entry->pointer_access = POINTER_ACCESS_READWRITE;
   entry->type = type;
   entry->declarator = NULL;
   entry->size = get_size(type_name_from_node(type));
   entry->offset = ctx->locals;
   ctx_add_locals(ctx, entry->size);
   debug("[%s:%d] ctx_push(%s, %s, %d, %d)", __FILE__, __LINE__, type->strval, name, entry->size, entry->offset);
   set_add(ctx->vars, strdup(name), entry);
}

//! @brief Handle context resize last push logic for compiler code-generation support.
void ctx_resize_last_push(Context *ctx, const ASTNode *type, const ASTNode *declarator, const char *name) {
   ContextEntry *entry = (ContextEntry *) set_get(ctx->vars, name);
   int base_size;
   int value_size;

   if (!entry || !type) {
      return;
   }

   base_size = get_size(type_name_from_node(type));
   value_size = declarator_value_size(type, declarator);
   entry->size = value_size;
   entry->declarator = declarator;
   ctx_add_locals(ctx, (value_size - base_size));
}


//! @brief Handle context static logic for compiler code-generation support.
void ctx_static(Context *ctx, const ASTNode *type, const char *name) {
   ContextEntry *entry = (ContextEntry *) set_get(ctx->vars, name);
   if (entry != NULL) {
      error_user("[%s:%d.%d] duplicate symbol '%s' first defined at [%s:%d.%d]",
            type->file, type->line, type->column,
            name,
            entry->type->file, entry->type->line, entry->type->column);
   }

   entry = (ContextEntry *) calloc(1, sizeof(ContextEntry));
   entry->name = strdup(name);
   entry->is_static = true;
   entry->is_zeropage = false;
   entry->is_global = false;
   entry->is_ref = false;
   entry->is_absolute_ref = false;
   entry->read_expr = NULL;
   entry->write_expr = NULL;
   entry->has_split_alias_delta = false;
   entry->split_alias_delta = 0;
   entry->target_typed = false;
   entry->pointer_access = POINTER_ACCESS_READWRITE;
   entry->type = type;
   entry->declarator = NULL;
   entry->size = get_size(type_name_from_node(type));
   entry->offset = 0;
   debug("[%s:%d] ctx_static(%s, %s$%s, %d, %d)", __FILE__, __LINE__, type->strval, ctx->name, name, entry->size, entry->offset);
   set_add(ctx->vars, strdup(name), entry);
}

//! @brief Handle context zeropage logic for compiler code-generation support.
void ctx_zeropage(Context *ctx, const ASTNode *type, const char *name) {
   ContextEntry *entry = (ContextEntry *) set_get(ctx->vars, name);
   if (entry != NULL) {
      error_user("[%s:%d.%d] duplicate symbol '%s' first defined at [%s:%d.%d]",
            type->file, type->line, type->column,
            name,
            entry->type->file, entry->type->line, entry->type->column);
   }

   entry = (ContextEntry *) calloc(1, sizeof(ContextEntry));
   entry->name = strdup(name);
   entry->is_static = false;
   entry->is_zeropage = true;
   entry->is_global = false;
   entry->is_ref = false;
   entry->is_absolute_ref = false;
   entry->read_expr = NULL;
   entry->write_expr = NULL;
   entry->has_split_alias_delta = false;
   entry->split_alias_delta = 0;
   entry->target_typed = false;
   entry->pointer_access = POINTER_ACCESS_READWRITE;
   entry->type = type;
   entry->declarator = NULL;
   entry->size = get_size(type_name_from_node(type));
   entry->offset = 0;
   debug("[%s:%d] ctx_zeropage(%s, %s$%s, %d, %d)", __FILE__, __LINE__, type->strval, ctx->name, name, entry->size, entry->offset);
   set_add(ctx->vars, strdup(name), entry);
}

// caution, returns pointer to static buffer overwritten w/ each call





//! @brief Emit prepare scratch ptr for compiler code-generation support diagnostics or output files.
void emit_prepare_scratch_ptr(int ptrno, int offset) {
   if (ptrno < 0 || ptrno > 2) {
      ptrno = 0;
   }
   emit_load_address_to_ptr(ptrno, compiler_scratch_active_symbol(), offset);
}

//! @brief Emit load address to ptr for compiler code-generation support diagnostics or output files.
void emit_load_address_to_ptr(int ptrno, const char *symbol, int addend) {
   emit(&es_code, "    lda #<{%s + %d}\n", symbol, addend);
   emit(&es_code, "    sta ptr%d\n", ptrno);
   emit(&es_code, "    lda #>{%s + %d}\n", symbol, addend);
   emit(&es_code, "    sta ptr%d+1\n", ptrno);
}

//! @brief Return assembler address expr data used by compiler code-generation support; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *assembler_address_expr(const char *expr, char *buf, size_t buf_size) {
   const char *p = expr;
   bool neg = false;

   if (!expr || !*expr) {
      if (buf_size > 0) {
         buf[0] = '\0';
      }
      return expr;
   }

   if (*p == '-') {
      neg = true;
      p++;
   }

   if (*p >= '0' && *p <= '9') {
      if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
         snprintf(buf, buf_size, "%s$%s", neg ? "-" : "", p + 2);
         return buf;
      }
      if (p[0] == '0' && (p[1] == 'b' || p[1] == 'B')) {
         snprintf(buf, buf_size, "%s%%%s", neg ? "-" : "", p + 2);
         return buf;
      }
      snprintf(buf, buf_size, "%s%s", neg ? "-" : "", p);
      return buf;
   }

   return expr;
}

//! @brief Emit load expression address to ptr for compiler code-generation support diagnostics or output files.
void emit_load_expr_address_to_ptr(int ptrno, const char *expr, int addend) {
   char expr_buf[256];
   const char *asm_expr = assembler_address_expr(expr, expr_buf, sizeof(expr_buf));

   emit(&es_code, "    lda #<{%s + %d}\n", asm_expr, addend);
   emit(&es_code, "    sta ptr%d\n", ptrno);
   emit(&es_code, "    lda #>{%s + %d}\n", asm_expr, addend);
   emit(&es_code, "    sta ptr%d+1\n", ptrno);
}

//! @brief Extract emit load ptr from symbol for compiler code-generation support.
void emit_load_ptr_from_symbol(int ptrno, const char *symbol, int addend) {
   emit(&es_code, "    ldy #0\n");
   emit(&es_code, "    lda %s + %d,y\n", symbol, addend);
   emit(&es_code, "    sta ptr%d\n", ptrno);
   emit(&es_code, "    iny\n");
   emit(&es_code, "    lda %s + %d,y\n", symbol, addend);
   emit(&es_code, "    sta ptr%d+1\n", ptrno);
}

//! @brief Emit deref ptr for compiler code-generation support diagnostics or output files.
void emit_deref_ptr(int ptrno) {
   emit(&es_code, "    ldy #0\n");
   emit(&es_code, "    lda (ptr%d),y\n", ptrno);
   emit(&es_code, "    sta arg0\n");
   emit(&es_code, "    iny\n");
   emit(&es_code, "    lda (ptr%d),y\n", ptrno);
   emit(&es_code, "    sta arg1\n");
   emit(&es_code, "    lda arg0\n");
   emit(&es_code, "    sta ptr%d\n", ptrno);
   emit(&es_code, "    lda arg1\n");
   emit(&es_code, "    sta ptr%d+1\n", ptrno);
}

//! @brief Emit add scratch to ptr for compiler code-generation support diagnostics or output files.
void emit_add_scratch_to_ptr(int ptrno, int src_offset, int src_size) {
   bool direct = src_offset >= 0 && src_offset + src_size <= 256;
   int src_ptr = ptrno == 0 ? 1 : 0;
   int ptr_size = get_size("*");

   if (!direct) {
      emit_prepare_scratch_ptr(src_ptr, src_offset);
   }

   emit(&es_code, "    clc\n");
   for (int i = 0; i < ptr_size; i++) {
      emit(&es_code, "    lda ptr%d%s\n", ptrno, i == 0 ? "" : "+1");
      if (i < src_size) {
         emit(&es_code, "    ldy #%d\n", direct ? (src_offset + i) : i);
         emit(&es_code, "    adc %s,y\n", direct ? compiler_scratch_active_symbol() : (src_ptr == 0 ? "(ptr0)" : "(ptr1)"));
      }
      else {
         emit(&es_code, "    adc #0\n");
      }
      emit(&es_code, "    sta ptr%d%s\n", ptrno, i == 0 ? "" : "+1");
   }
}

//! @brief Emit store immediate to scratch for compiler code-generation support diagnostics or output files.
void emit_store_immediate_to_scratch(int offset, const unsigned char *bytes, int size) {
   if (offset >= 0 && offset + size <= 256) {
      for (int i = 0; i < size; i++) {
         emit(&es_code, "    ldy #%d\n", offset + i);
         emit(&es_code, "    lda #$%02x\n", bytes[i]);
         emit(&es_code, "    sta %s,y\n", compiler_scratch_active_symbol());
      }
      return;
   }

   emit_prepare_scratch_ptr(0, offset);
   for (int i = 0; i < size; i++) {
      emit(&es_code, "    ldy #%d\n", i);
      emit(&es_code, "    lda #$%02x\n", bytes[i]);
      emit(&es_code, "    sta (ptr0),y\n");
   }
}
