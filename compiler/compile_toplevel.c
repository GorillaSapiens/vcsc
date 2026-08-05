//! @file compiler/compile_toplevel.c
//! @brief Implements top-level declaration lowering for the VCSC compiler.
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
#include "abi_meta.h"
#include "compile.h"
#include "compile_declarator.h"
#include "compile_function.h"
#include "compile_init.h"
#include "compile_expr_info.h"
#include "compile_internal.h"
#include "compile_function_registry.h"
#include "compile_stmt.h"
#include "compile_support.h"
#include "compile_toplevel.h"
#include "compile_type.h"
#include "emit.h"
#include "integer.h"
#include "memname.h"
#include "messages.h"
#include "pair.h"
#include "set.h"
#include "typename.h"
#include "xray.h"
#include "lextern.h"

//! @brief Return whether one original source identifier uses the required template prefix.
static bool template_source_name_is_hygienic(const ASTNode *name) {
   const char *source;

   if (!name || !name->direct_template_source || !name->template_instance)
      return true;
   source = name->source_spelling;
   return source && (!strcmp(source, "TEMPLATE") || !strncmp(source, "TEMPLATE_", 9));
}

//! @brief Reject one directly template-owned file-scope name lacking TEMPLATE/TEMPLATE_.
static void require_hygienic_template_name(const ASTNode *name, const char *kind) {
   const char *source;

   if (template_source_name_is_hygienic(name))
      return;
   source = name && name->source_spelling ? name->source_spelling :
            (name && name->strval ? name->strval : "?");
   error_user("[%s:%d.%d] template hygiene: file-scope %s '%s' defined directly in a template must use 'TEMPLATE' or the 'TEMPLATE_' prefix",
              name && name->file ? name->file : "?",
              name ? name->line : 0,
              name ? name->column : 0,
              kind ? kind : "name", source);
}

//! @brief Check enum tag and enumerator names introduced directly by a template.
static void enforce_template_enum_hygiene(const ASTNode *node) {
   if (!node || node->count < 2)
      return;
   require_hygienic_template_name(node->children[0], "enum tag");
   const ASTNode *names = node->children[1];
   for (int i = 0; names && i < names->count; i++) {
      const ASTNode *value = names->children[i];
      if (value && value->count > 0)
         require_hygienic_template_name(value->children[0], "enum constant");
   }
}

//! @brief Check one ordinary file-scope object/function declaration or definition.
static void enforce_template_defdecl_hygiene(const ASTNode *node) {
   if (!node)
      return;

   if (node->count == 1 && node->children[0] &&
       !strcmp(node->children[0]->name, "decl_list")) {
      const ASTNode *list = node->children[0];
      for (int i = 0; i < list->count; i++) {
         const ASTNode *item = list->children[i];
         const ASTNode *decl = decl_node_declarator(item);
         const ASTNode *name = declarator_name_node(decl);
         require_hygienic_template_name(name,
               declarator_is_function(decl) ? "function" : "object");
      }
      return;
   }

   if (node->count == 3) {
      const ASTNode *decl = node->children[1];
      require_hygienic_template_name(declarator_name_node(decl), "function");
   }
}

//! @brief Return whether one byte can begin/continue an assembler identifier.
static bool asm_ident_start(unsigned char c) {
   return c == '_' || c >= 0x80 || isalpha(c);
}

static bool asm_ident_char(unsigned char c) {
   return c == '_' || c == '?' || c == '$' || c >= 0x80 || isalnum(c);
}

//! @brief Reject nonlocal source-visible inline-assembler labels lacking template prefixing.
static void enforce_template_asm_label_hygiene(const ASTNode *node) {
   const char *p;
   const char *start;
   size_t len;
   char *name;

   if (!node || node->kind != AST_ASM || !node->direct_template_source ||
       !node->template_instance || !node->source_spelling)
      return;

   p = node->source_spelling;
   while (*p && isspace((unsigned char)*p))
      p++;
   if (*p == '@' || !asm_ident_start((unsigned char)*p))
      return;
   start = p++;
   while (*p && asm_ident_char((unsigned char)*p))
      p++;
   len = (size_t)(p - start);
   while (*p && isspace((unsigned char)*p))
      p++;
   if (*p != ':')
      return;
   if ((len == 8 && !strncmp(start, "TEMPLATE", 8)) ||
       (len >= 9 && !strncmp(start, "TEMPLATE_", 9)))
      return;

   name = malloc(len + 1);
   if (!name)
      error_unreachable("out of memory checking template assembler label");
   memcpy(name, start, len);
   name[len] = 0;
   error_user("[%s:%d.%d] template hygiene: source-visible assembler symbol '%s' defined directly in a template must use 'TEMPLATE' or the 'TEMPLATE_' prefix",
              node->file ? node->file : "?", node->line, node->column, name);
}

//! @brief Recursively inspect inline assembly after checking top-level declaration names.
static void enforce_template_asm_hygiene_recursive(const ASTNode *node) {
   if (!node)
      return;
   enforce_template_asm_label_hygiene(node);
   for (int i = 0; i < node->count; i++)
      enforce_template_asm_hygiene_recursive(node->children[i]);
}

//! @brief Enforce direct-template file-scope names while exempting ordinary included support files.
void enforce_template_hygiene(ASTNode *program) {
   for (int i = 0; program && i < program->count; i++) {
      ASTNode *node = program->children[i];
      if (!node)
         continue;
      if (!strcmp(node->name, "bank_decl_stmt"))
         require_hygienic_template_name(node->children[0], "bank name");
      else if (!strcmp(node->name, "mem_decl_stmt"))
         require_hygienic_template_name(node->children[0], "memory name");
      else if (!strcmp(node->name, "type_decl_stmt")) {
         if (node->children[0] && node->children[0]->strval &&
             strcmp(node->children[0]->strval, "*"))
            require_hygienic_template_name(node->children[0], "type name");
      }
      else if (!strcmp(node->name, "typedef_decl_stmt"))
         require_hygienic_template_name(node->children[1], "typedef");
      else if (!strcmp(node->name, "enum_decl_stmt"))
         enforce_template_enum_hygiene(node);
      else if (!strcmp(node->name, "struct_decl_stmt") && node->kind != AST_EMPTY)
         require_hygienic_template_name(node->children[0], "struct tag");
      else if (!strcmp(node->name, "union_decl_stmt") && node->kind != AST_EMPTY)
         require_hygienic_template_name(node->children[0], "union tag");
      else if (!strcmp(node->name, "defdecl_stmt"))
         enforce_template_defdecl_hygiene(node);
   }
   enforce_template_asm_hygiene_recursive(program);
}

//! @brief Reject function-pointer declarators while retaining parser coverage for a useful diagnostic.
void reject_function_pointers(ASTNode *node) {
   if (!node) {
      return;
   }

   if (!strcmp(node->name, "declarator") &&
       declarator_has_parameter_list(node) &&
       declarator_function_pointer_depth(node) > 0) {
      error_user("[%s:%d.%d] function pointers are not supported",
                 node->file, node->line, node->column);
   }

   for (int i = 0; i < node->count; i++) {
      reject_function_pointers(node->children[i]);
   }
}

//! @brief Return decl subitem declarator data used by compile toplevel; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *decl_subitem_declarator(const ASTNode *node) {
   if (!node) {
      return NULL;
   }
   if (strcmp(node->name, "decl_subitem") || node->count <= 0) {
      return node;
   }
   return node->children[0];
}

//! @brief Return decl subitem address spec data used by compile toplevel; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *decl_subitem_address_spec(const ASTNode *node) {
   if (!node || strcmp(node->name, "decl_subitem") || node->count <= 1) {
      return NULL;
   }
   return node->children[1];
}

//! @brief Return decl node address spec data used by compile toplevel; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *decl_node_address_spec(const ASTNode *node) {
   if (!node || node->count < 3) {
      return NULL;
   }
   return decl_subitem_address_spec(node->children[2]);
}

//! @brief Return address spec read expr data used by compile toplevel; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *address_spec_read_expr(const ASTNode *node) {
   if (!node || is_empty(node)) {
      return NULL;
   }
   if (!strcmp(node->name, "rw_addr_spec")) {
      return (node->count > 0 && node->children[0] && !is_empty(node->children[0])) ? node->children[0]->strval : NULL;
   }
   return node->strval;
}

//! @brief Return address spec write expr data used by compile toplevel; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *address_spec_write_expr(const ASTNode *node) {
   if (!node || is_empty(node)) {
      return NULL;
   }
   if (!strcmp(node->name, "rw_addr_spec")) {
      return (node->count > 1 && node->children[1] && !is_empty(node->children[1])) ? node->children[1]->strval : NULL;
   }
   return node->strval;
}

//! @brief Return whether address spec has read in compile toplevel.
static bool address_spec_has_read(const ASTNode *node) {
   return address_spec_read_expr(node) != NULL;
}

//! @brief Return whether address spec has write in compile toplevel.
static bool address_spec_has_write(const ASTNode *node) {
   return address_spec_write_expr(node) != NULL;
}

//! @brief Reject the legacy object-level ref spelling now reserved for parameters.
static void diagnose_ref_object_modifier(const ASTNode *node, const char *name) {
   if (!node) {
      error_unreachable("internal error: !node in %s %s:%d\n",
         __func__, __FILE__, __LINE__);
      return;
   }
   error_user("[%s:%d.%d] 'ref' applies only to function parameters; absolute external binding '%s' must use '@[read/write]' without 'ref'",
      node->file, node->line, node->column, name ? name : "?");
}

//! @brief Return whether two address expressions denote the same source-level address.
static bool address_exprs_equal(const char *a, const char *b) {
   char *aend = NULL;
   char *bend = NULL;
   unsigned long long av;
   unsigned long long bv;

   if ((a == NULL) != (b == NULL)) {
      return false;
   }
   if (!a && !b) {
      return true;
   }
   av = strtoull(a, &aend, 0);
   bv = strtoull(b, &bend, 0);
   if (aend && *aend == '\0' && bend && *bend == '\0') {
      return av == bv;
   }
   return !strcmp(a, b);
}

//! @brief Return whether two absolute address specifications are identical.
static bool address_specs_equal(const ASTNode *a, const ASTNode *b) {
   if ((a == NULL) != (b == NULL)) {
      return false;
   }
   if (!a && !b) {
      return true;
   }
   return address_exprs_equal(address_spec_read_expr(a), address_spec_read_expr(b)) &&
          address_exprs_equal(address_spec_write_expr(a), address_spec_write_expr(b));
}

//! @brief Lower function decl from AST/semantic state into generated assembly or linker-visible metadata.
void compile_function_decl(ASTNode *node) {
   ASTNode *modifiers  = node->children[0]->children[0];
   ASTNode *declarator = node->children[1];
   ASTNode *body       = node->children[2];
   const char *name    = declarator_name(declarator);
   const ASTNode *saved_call_graph_function = current_call_graph_function;
   int saved_call_graph_node = current_call_graph_node;
   char sym[256];
   bool has_return_object;
   bool return_is_zeropage = true;
   bool return_is_split = false;
   const char *code_region_name;
   const char *result_region_name;
   ContextEntry *return_entry;
   char return_sym[256];
   char return_write_expr[320];
   char *return_coalesce_meta = NULL;

   if (has_modifier(modifiers, "ref")) {
      error_user("[%s:%d.%d] 'ref' applies only to function parameters, not to function '%s'",
                 node->file, node->line, node->column, name ? name : "?");
   }
   validate_function_return_type(node);
   remember_function(node, name);
   code_region_name = function_primary_code_region_name(node);
   result_region_name = function_result_region_name(node);
   if (!function_symbol_name(node, name, sym, sizeof(sym))) {
      error_unreachable("[%s:%d.%d] could not mangle function '%s'", node->file, node->line, node->column, name);
   }
   emit_function_contract_metadata(node, sym);
   if (function_is_inline(node)) {
      return;
   }
   has_return_object = function_has_return_object(node);
   if (has_return_object &&
       !function_return_storage_addresses(node,
                                          return_sym, sizeof(return_sym),
                                          return_write_expr, sizeof(return_write_expr),
                                          &return_is_zeropage, &return_is_split)) {
      error_unreachable("[%s:%d.%d] invalid memory return symbol", node->file, node->line, node->column);
   }

   if (!has_modifier(modifiers, "static")) {
      emit(&es_export, ".export %s\n", sym);
      emit_function_parameter_exports(node);
      if (has_return_object) {
         emit(&es_export, return_is_zeropage ? ".zpexport %s\n" : ".export %s\n",
              return_sym);
      }
      emit_function_abi_metadata(node, sym, true);
   }

   Context ctx;
   memset(&ctx, 0, sizeof(ctx));
   ctx.name = strdup(sym);
   ctx.activation_owner = ctx.name;
   ctx.locals = 0;
   ctx.locals_high_water = 0;
   ctx.params = 0;
   ctx.vars = new_set();
   ctx.break_label = NULL;
   ctx.continue_label = NULL;
   ctx.return_label = "@fini";
   ctx.inline_label_prefix = NULL;
   build_function_context(node, &ctx);
   plan_function_return_coalescing(node, body, &ctx);
   return_entry = (ContextEntry *) set_get(ctx.vars, "$$");
   current_call_graph_function = node;
   current_call_graph_node = call_graph_node_index_for_function(node);

   if (!is_empty(body) && !strcmp(body->name, "statement_list")) {
      predeclare_statement_list(body, &ctx);
   }
   if (has_return_object) {
      if (!return_entry || return_entry->size < 1 || return_entry->size > 4) {
         error_unreachable("[%s:%d.%d] invalid memory return object", node->file, node->line, node->column);
      }
      if (return_entry->is_absolute_ref && return_entry->read_expr &&
          *return_entry->read_expr) {
         snprintf(return_sym, sizeof(return_sym), "%s", return_entry->read_expr);
      }
      else if (!entry_symbol_name(&ctx, return_entry, return_sym, sizeof(return_sym))) {
         error_unreachable("[%s:%d.%d] invalid memory return symbol", node->file, node->line, node->column);
      }
   }

   if (has_return_object && ctx.coalesced_return_local) {
      return_coalesce_meta = emit_return_coalesce_metadata(
         sym, ctx.coalesced_return_local, return_sym, result_region_name,
         return_entry->size);
   }

   emit_function_parameter_storage(node, &ctx);
   {
      FunctionRegionSpec regions;
      function_region_spec_collect(node, &regions);
      for (size_t i = 0; i < regions.code_region_count; i++) {
         emit_mem_region_metadata_for_name(node, regions.code_regions[i]);
         if (regions.code_region_count > 1) {
            emit_replica_metadata('F', sym, regions.code_regions[i]);
         }
      }
      function_region_spec_release(&regions);
   }
   if (result_region_name) {
      emit_mem_region_metadata_for_name(node, result_region_name);
   }
   if (has_return_object) {
      char segbuf[512];
      build_activation_storage_segment_for_region(segbuf, sizeof(segbuf), &ctx,
                                                  result_region_name,
                                                  return_is_zeropage ? "ZEROPAGE" : "BSS");
      if (return_is_zeropage) {
         emit(&es_zp, ".segment \"%s\"\n", segbuf);
         if (return_coalesce_meta) {
            emit(&es_zp, "%s:\n", return_coalesce_meta);
         }
         emit(&es_zp, "%s:\n", return_sym);
         emit(&es_zp, "\t.res %d\n", return_entry->size);
      }
      else {
         emit(&es_bss, ".segment \"%s\"\n", segbuf);
         if (return_coalesce_meta) {
            emit(&es_bss, "%s:\n", return_coalesce_meta);
         }
         emit(&es_bss, "%s:\n", return_sym);
         emit(&es_bss, "\t.res %d\n", return_entry->size);
      }
      free(return_coalesce_meta);
      return_coalesce_meta = NULL;
   }
   if (code_region_name && *code_region_name) {
      emit(&es_code, ".segment \"CODE.%s\"\n", code_region_name);
   }
   emit(&es_code, ".proc %s\n", sym);
   if (has_modifier(modifiers, "page")) {
      emit(&es_code, ".pagecontain\n");
   }

   if (!is_empty(body)) {
      if (!strcmp(body->name, "statement_list")) {
         compile_statement_list(body, &ctx);
      }
      else {
         error_unreachable("[%s:%d.%d] internal compiler error: unexpected function body node '%s'", body->file, body->line, body->column, body->name);
      }
   }

   emit(&es_code, "@fini:\n");
   emit(&es_code, "    rts\n");
   emit(&es_code, ".endproc\n");
   if (code_region_name) {
      emit(&es_code, ".segment \"CODE\"\n");
   }
   current_call_graph_function = saved_call_graph_function;
   current_call_graph_node = saved_call_graph_node;
}

#define CARTRIDGE_TOPOLOGY_META_PREFIX "__cartmeta$V1$"
#define BANK_TOPOLOGY_META_PREFIX "__bankmeta$V1$"

static Set *emitted_topology_metadata;

//! @brief Parse one numeric topology flag and reject malformed or duplicate values.
static bool topology_parse_numeric_flag(const ASTNode *origin, const char *text,
                                        const char *key, unsigned long maximum,
                                        bool *seen, unsigned int *value) {
   size_t key_len;
   char *end = NULL;
   unsigned long parsed;

   if (!text || !key || !seen || !value)
      return false;
   key_len = strlen(key);
   if (strncmp(text, key, key_len) || text[key_len] != ':')
      return false;
   if (*seen) {
      error_user("[%s:%d.%d] %s declaration repeats '%s'",
                 origin->file, origin->line, origin->column,
                 origin->name && !strcmp(origin->name, "bank_decl_stmt") ? "bank" : "cartridge",
                 key);
   }
   parsed = strtoul(text + key_len + 1, &end, 0);
   if (!end || end == text + key_len + 1 || *end || parsed > maximum) {
      error_user("[%s:%d.%d] invalid topology flag '%s'",
                 origin->file, origin->line, origin->column, text);
   }
   *seen = true;
   *value = (unsigned int)parsed;
   return true;
}

//! @brief Emit one deduplicated absolute metadata symbol.
static void emit_topology_metadata_symbol(const char *symbol) {
   if (!emitted_topology_metadata)
      emitted_topology_metadata = new_set();
   if (set_get(emitted_topology_metadata, symbol))
      return;
   set_add(emitted_topology_metadata, strdup(symbol), (void *)1);
   emit(&es_export, "%s = 0\n", symbol);
   emit(&es_export, ".export %s\n", symbol);
}

//! @brief Encode a declaration location using symbol-safe hexadecimal bytes.
static char *topology_source_suffix(const ASTNode *node) {
   const unsigned char *src = (const unsigned char *)((node && node->file) ? node->file : "?");
   size_t src_len = strlen((const char *)src);
   size_t cap = 2u * src_len + 32u;
   char *suffix = (char *)malloc(cap);
   char *out;
   if (!suffix)
      error_unreachable("out of memory");
   out = suffix;
   *out++ = '$';
   *out++ = 'Q';
   while (*src) {
      static const char hex[] = "0123456789ABCDEF";
      *out++ = hex[*src >> 4];
      *out++ = hex[*src & 15u];
      src++;
   }
   snprintf(out, cap - (size_t)(out - suffix), "$N%08X$C%08X",
            node ? (unsigned int)node->line : 0u,
            node ? (unsigned int)node->column : 0u);
   return suffix;
}

//! @brief Lower one output-wide cartridge declaration to linker-visible metadata.
void compile_cartridge_decl_stmt(ASTNode *node) {
   const ASTNode *flags = node && node->count ? node->children[0] : NULL;
   enum { FILL, TRAMP_O, TRAMP_Z, BRIDGE_O, BRIDGE_Z, VECTORS_O, VECTORS_Z, FIELD_COUNT };
   static const char *keys[FIELD_COUNT] = {
      "$fill", "$trampoline_offset", "$trampoline_size",
      "$vector_bridge_offset", "$vector_bridge_size",
      "$vectors_offset", "$vectors_size"
   };
   bool seen[FIELD_COUNT] = { false };
   unsigned int value[FIELD_COUNT] = { 0 };
   unsigned int mask = 0;
   char symbol[4096];
   char *source_suffix;

   for (int i = 0; flags && !is_empty(flags) && i < flags->count; i++) {
      const char *text = flags->children[i]->strval;
      bool matched = false;
      for (int f = 0; f < FIELD_COUNT; f++) {
         unsigned long max = f == FILL ? 0xffu : 0xffffu;
         if (topology_parse_numeric_flag(node, text, keys[f], max,
                                         &seen[f], &value[f])) {
            matched = true;
            break;
         }
      }
      if (!matched)
         error_user("[%s:%d.%d] cartridge declaration has unknown flag '%s'",
                    node->file, node->line, node->column, text ? text : "?");
   }
   if (!seen[FILL])
      error_user("[%s:%d.%d] cartridge declaration requires '$fill:'",
                 node->file, node->line, node->column);
   if (seen[TRAMP_O] != seen[TRAMP_Z] || seen[BRIDGE_O] != seen[BRIDGE_Z] ||
       seen[VECTORS_O] != seen[VECTORS_Z]) {
      error_user("[%s:%d.%d] cartridge generated ranges require matching offset and size flags",
                 node->file, node->line, node->column);
   }
   for (int f = 0; f < FIELD_COUNT; f++)
      if (seen[f]) mask |= 1u << f;
   source_suffix = topology_source_suffix(node);
   snprintf(symbol, sizeof(symbol),
            CARTRIDGE_TOPOLOGY_META_PREFIX "P%02X$F%02X$T%04X$Z%04X$B%04X$Y%04X$V%04X$W%04X%s",
            mask, value[FILL], value[TRAMP_O], value[TRAMP_Z],
            value[BRIDGE_O], value[BRIDGE_Z], value[VECTORS_O], value[VECTORS_Z],
            source_suffix);
   free(source_suffix);
   emit_topology_metadata_symbol(symbol);
}

//! @brief Lower one physical output-bank declaration to linker-visible metadata.
void compile_bank_decl_stmt(ASTNode *node) {
   const char *name = node && node->count > 0 ? node->children[0]->strval : NULL;
   const ASTNode *flags = node && node->count > 1 ? node->children[1] : NULL;
   enum { IMAGE_Z, FILE_I, IMAGE_O, LINK_S, CPU_S, MAP_Z, SELECT_A, FIELD_COUNT };
   static const char *keys[FIELD_COUNT] = {
      "$image_size", "$file_index", "$image_offset", "$link_start",
      "$cpu_start", "$map_size", "$select_access"
   };
   bool seen[FIELD_COUNT] = { false };
   unsigned int value[FIELD_COUNT] = { 0 };
   bool startup = false;
   char symbol[4096];
   char *source_suffix;

   if (!name || !*name)
      error_user("[%s:%d.%d] bank declaration requires a name",
                 node->file, node->line, node->column);
   for (int i = 0; flags && !is_empty(flags) && i < flags->count; i++) {
      const char *text = flags->children[i]->strval;
      bool matched = false;
      if (text && !strcmp(text, "$startup")) {
         if (startup)
            error_user("[%s:%d.%d] bank '%s' repeats '$startup'",
                       node->file, node->line, node->column, name);
         startup = true;
         continue;
      }
      for (int f = 0; f < FIELD_COUNT; f++) {
         if (topology_parse_numeric_flag(node, text, keys[f], 0xffffu,
                                         &seen[f], &value[f])) {
            matched = true;
            break;
         }
      }
      if (!matched)
         error_user("[%s:%d.%d] bank '%s' has unknown flag '%s'",
                    node->file, node->line, node->column, name, text ? text : "?");
   }
   for (int f = 0; f < SELECT_A; f++) {
      if (!seen[f])
         error_user("[%s:%d.%d] bank '%s' requires '%s:'",
                    node->file, node->line, node->column, name, keys[f]);
   }
   if (value[IMAGE_Z] == 0 || value[MAP_Z] == 0)
      error_user("[%s:%d.%d] bank '%s' image and mapped sizes must be nonzero",
                 node->file, node->line, node->column, name);
   source_suffix = topology_source_suffix(node);
   snprintf(symbol, sizeof(symbol),
            BANK_TOPOLOGY_META_PREFIX "%s$I%04X$F%04X$O%04X$L%04X$C%04X$M%04X$P%d$S%04X$U%d%s",
            name, value[IMAGE_Z], value[FILE_I], value[IMAGE_O], value[LINK_S],
            value[CPU_S], value[MAP_Z], seen[SELECT_A] ? 1 : 0,
            value[SELECT_A], startup ? 1 : 0, source_suffix);
   free(source_suffix);
   emit_topology_metadata_symbol(symbol);
}

//! @brief Lower mem decl stmt from AST/semantic state into generated assembly or linker-visible metadata.
void compile_mem_decl_stmt(ASTNode *node) {
   attach_memname(node->children[0]->strval, node);
   emit_mem_declaration_metadata(node);
}

//! @brief Lower type decl stmt from AST/semantic state into generated assembly or linker-visible metadata.
void compile_type_decl_stmt(ASTNode *node) {
   const char *key = node->children[0]->strval;

   attach_typename(key, node);

   //debug("%s:%s", __func__, node->children[0]->strval);
   bool haveSize = false;
   int size = -1;
   bool haveEndian = false;
   const char *endian = NULL;
   bool haveInteger = false;
   const char *integer_style = NULL;
   bool haveBcd = false;
   bool integer_required;

   integer_required = key && strcmp(key, "void");

   // we need to guarantee a "size" and "endian"
   if (strcmp(node->children[1]->name, "empty")) {
      for (int i = 0; i < node->children[1]->count; i++) {
         ASTNode *item = node->children[1]->children[i];

         // check for $size, must be nonnegative
         if (!strncmp(item->strval, "$size:", 6)) {
            if (haveSize) {
               error_user("[%s:%d.%d] type_decl_stmt '%s' has multiple '$size:' flags",
                     node->file, node->line, node->column,
                     node->children[0]->strval);
            }
            char *p = strchr(item->strval, ':');
            p++;
            size = atoi(p);
            if (size < 0 || (size == 0 && strcmp(p, "0"))) {
               error_user("[%s:%d.%d] type_decl_stmt '%s' unrecognized '$size:%s' flag",
                     node->file, node->line, node->column,
                     node->children[0]->strval, p);
            }
            haveSize = true;
            pair_insert(typesizes, key, (void *)(intptr_t) size);
         }

         // Multibyte values are always little-endian.
         if (!strncmp(item->strval, "$endian:", 8)) {
            if (haveEndian) {
               error_user("[%s:%d.%d] type_decl_stmt '%s' has multiple '$endian:' flags",
                     node->file, node->line, node->column,
                     node->children[0]->strval);
            }
            endian = strchr(item->strval, ':');
            endian++;
            if (!strcmp(endian, "big")) {
               error_user("[%s:%d.%d] big-endian types are not supported",
                     node->file, node->line, node->column);
            }
            if (strcmp(endian, "little")) {
               error_user("[%s:%d.%d] type_decl_stmt '%s' unrecognized '$endian:%s' flag",
                     node->file, node->line, node->column,
                     node->children[0]->strval, endian);
            }

            haveEndian = true;
         }

         if (!strcmp(item->strval, "$signed") || !strcmp(item->strval, "$unsigned")) {
            error_user("[%s:%d.%d] type_decl_stmt '%s' must use '$integer:signed' or '$integer:unsigned' instead of '%s'",
                  node->file, node->line, node->column,
                  node->children[0]->strval, item->strval);
         }
         else if (!strcmp(item->strval, "$float") || !strncmp(item->strval, "$float:", 7)) {
            error_user("[%s:%d.%d] floating-point types are not supported",
                  node->file, node->line, node->column);
         }
         else if (!strncmp(item->strval, "$integer:", 9)) {
            const char *style = parse_integer_style_flag_text(item->strval);
            if (haveInteger) {
               error_user("[%s:%d.%d] type_decl_stmt '%s' has multiple '$integer' flags",
                     node->file, node->line, node->column,
                     node->children[0]->strval);
            }
            if (!style || (strcmp(style, "signed") && strcmp(style, "unsigned"))) {
               error_user("[%s:%d.%d] type_decl_stmt '%s' unrecognized '%s' flag",
                     node->file, node->line, node->column,
                     node->children[0]->strval, item->strval);
            }
            haveInteger = true;
            integer_style = style;
         }
         else if (!strcmp(item->strval, "$bcd")) {
            if (haveBcd) {
               error_user("[%s:%d.%d] type_decl_stmt '%s' has multiple '$bcd' flags",
                     node->file, node->line, node->column,
                     node->children[0]->strval);
            }
            haveBcd = true;
         }
      }
   }

   if (!haveSize) {
      error_user("[%s:%d.%d] type_decl_stmt '%s' missing '$size:' flag",
            node->file, node->line, node->column, node->children[0]->strval);
   }

   if (key && !strcmp(key, "*")) {
      if (haveBcd) {
         error_user("[%s:%d.%d] pointer type '*' cannot use '$bcd'",
               node->file, node->line, node->column);
      }
      if (size != 2 || !haveInteger || !integer_style || strcmp(integer_style, "unsigned")) {
         error_user("[%s:%d.%d] pointer type '*' must be a 2-byte unsigned integer",
               node->file, node->line, node->column);
      }
   }
   else if (haveBcd) {
      if (!haveInteger || !integer_style || strcmp(integer_style, "unsigned")) {
         error_user("[%s:%d.%d] packed-BCD type '%s' must use '$integer:unsigned'",
               node->file, node->line, node->column, node->children[0]->strval);
      }
      if (size < 1 || size > 4) {
         error_user("[%s:%d.%d] packed-BCD type '%s' has unsupported size %d; only 1-byte through 4-byte packed-BCD types are supported",
               node->file, node->line, node->column, node->children[0]->strval, size);
      }
   }
   else if (haveInteger && (size < 1 || size > 4)) {
      error_user("[%s:%d.%d] integer type '%s' has unsupported size %d; only 1-byte through 4-byte integers are supported",
            node->file, node->line, node->column, node->children[0]->strval, size);
   }

   if (!haveEndian && size > 1) {
      error_user("[%s:%d.%d] type_decl_stmt '%s' missing '$endian:' flag",
            node->file, node->line, node->column, node->children[0]->strval);
   }

   if (integer_required && !haveInteger) {
      error_user("[%s:%d.%d] type_decl_stmt '%s' missing '$integer:signed' or '$integer:unsigned' flag",
            node->file, node->line, node->column, node->children[0]->strval);
   }

   if (get_xray(XRAY_TYPEINFO)) {
      message("TYPEINFO: %s %d %s", key, haveSize ? size : -1, haveEndian ? endian : "unspec");
   }
}


//! @brief Attach a source-level typedef name to an existing named type.
void compile_typedef_decl_stmt(ASTNode *node) {
   const char *target_name;
   const char *alias_name;
   ASTNode *target;

   if (!node || node->count < 2 || !node->children[0] || !node->children[1]) {
      error_unreachable("[%s:%d] invalid typedef declaration", __FILE__, __LINE__);
   }

   target_name = node->children[0]->strval;
   alias_name = node->children[1]->strval;
   target = get_typename_node(target_name);
   if (!target) {
      error_user("[%s:%d.%d] typedef target type '%s' is not defined",
                 node->file, node->line, node->column, target_name ? target_name : "?");
   }

   attach_typename(alias_name, target);
}

//! @brief Return whether enum candidate is integer type in compile toplevel.
static bool enum_candidate_is_integer_type(const ASTNode *node) {
   if (!node || strcmp(node->name, "type_decl_stmt")) {
      return false;
   }

   return type_is_promotable_integer(node) && !type_is_bcd_integer(node);
}

//! @brief Return whether enum candidate can hold range in compile toplevel.
static bool enum_candidate_can_hold_range(const ASTNode *node, long long min_value, unsigned long long max_value, bool have_negative) {
   int size;
   int bits;
   bool is_unsigned;
   bool is_signed;
   unsigned long long signed_max;
   long long signed_min;
   unsigned long long unsigned_max;

   if (!enum_candidate_is_integer_type(node)) {
      return false;
   }

   size = type_size_from_node(node);
   if (size <= 0 || size > 8) {
      return false;
   }

   bits = size * 8;
   is_unsigned = type_is_unsigned_integer(node);
   is_signed = type_is_signed_integer(node);

   if (bits >= 64) {
      signed_max = LLONG_MAX;
      signed_min = LLONG_MIN;
      unsigned_max = ULLONG_MAX;
   }
   else {
      signed_max = (1ULL << (bits - 1)) - 1ULL;
      signed_min = -(long long) (1ULL << (bits - 1));
      unsigned_max = (1ULL << bits) - 1ULL;
   }

   if (is_unsigned) {
      return !have_negative && max_value <= unsigned_max;
   }

   if (have_negative) {
      return min_value >= signed_min && max_value <= signed_max;
   }

   if (is_signed) {
      return max_value <= signed_max;
   }

   return max_value <= unsigned_max;
}

//! @brief Find best enum backing type in compile toplevel tables without transferring ownership.
static const ASTNode *find_best_enum_backing_type(ASTNode *node) {
   long long min_value = 0;
   unsigned long long max_value = 0;
   bool have_range = false;
   bool have_negative = false;
   const ASTNode *best = NULL;
   int best_size = INT_MAX;

   if (!node || node->count < 2 || !node->children[1]) {
      error_unreachable("[%s:%d.%d] invalid enum declaration", node ? node->file : __FILE__, node ? node->line : __LINE__, node ? node->column : 0);
   }

   for (int i = 0; i < node->children[1]->count; i++) {
      ASTNode *entry = node->children[1]->children[i];
      long long value;
      unsigned long long uvalue;
      if (!entry || entry->count < 2 || !entry->children[1] || entry->children[1]->kind != AST_INTEGER) {
         error_user("[%s:%d.%d] enum value '%s' is not an integer constant", entry ? entry->file : node->file, entry ? entry->line : node->line, entry ? entry->column : node->column, (entry && entry->count > 0 && entry->children[0]) ? entry->children[0]->strval : "?");
      }
      value = parse_int(entry->children[1]->strval);
      uvalue = value < 0 ? 0ULL : (unsigned long long) value;
      if (!have_range) {
         min_value = value;
         max_value = uvalue;
         have_range = true;
      }
      else {
         if (value < min_value) {
            min_value = value;
         }
         if (uvalue > max_value) {
            max_value = uvalue;
         }
      }
      if (value < 0) {
         have_negative = true;
      }
   }

   if (!have_range) {
      error_user("[%s:%d.%d] enum '%s' is empty", node->file, node->line, node->column, node->children[0]->strval);
   }

   for (int i = 0; root && i < root->count; i++) {
      ASTNode *cand = root->children[i];
      int cand_size;
      if (!enum_candidate_can_hold_range(cand, min_value, max_value, have_negative)) {
         continue;
      }
      cand_size = type_size_from_node(cand);
      if (!best || cand_size < best_size) {
         best = cand;
         best_size = cand_size;
      }
   }

   if (!best) {
      error_user("[%s:%d.%d] enum '%s' has no declared integer type that can represent values %lld..%llu",
            node->file, node->line, node->column,
            node->children[0]->strval,
            min_value, max_value);
   }

   return best;
}

//! @brief Lower enum decl stmt from AST/semantic state into generated assembly or linker-visible metadata.
void compile_enum_decl_stmt(ASTNode *node) {
   const char *key = node->children[0]->strval;
   const ASTNode *backing = find_best_enum_backing_type(node);
   const char *backing_name = type_name_from_node(backing);
   int size = type_size_from_node(backing);

   attach_typename(key, node);
   pair_insert(typesizes, key, (void *)(intptr_t) size);
   pair_insert(enumbackings, key, (void *) backing_name);

   if (get_xray(XRAY_TYPEINFO)) {
      message("TYPEINFO: enum %s %d %s", key, size, backing_name ? backing_name : "?");
   }
}

//! @brief Reject file-scope use contracts on aggregate members.
static void validate_aggregate_member_use_contracts(const ASTNode *node) {
   for (int i = 1; node && i < node->count; i++) {
      const ASTNode *member = node->children[i];
      const ASTNode *modifiers = (member && member->count > 0) ? member->children[0] : NULL;
      const ASTNode *subitem = (member && member->count > 2) ? member->children[2] : NULL;
      const ASTNode *declarator = decl_subitem_declarator(subitem);
      const ASTNode *addrspec = decl_subitem_address_spec(subitem);
      const char *name = declarator ? declarator_name(declarator) : NULL;
      if (has_modifier((ASTNode *)modifiers, "ref")) {
         error_user("[%s:%d.%d] 'ref' applies only to function parameters, not to aggregate member '%s'",
                    member->file, member->line, member->column, name ? name : "?");
      }
      validate_declaration_access_qualifiers(member, modifiers, declarator,
                                              "aggregate member declaration");
      if (addrspec) {
         error_user("[%s:%d.%d] aggregate member '%s' cannot use an absolute address binding",
                    member->file, member->line, member->column, name ? name : "?");
      }
      if (declaration_has_use_contract(modifiers)) {
         error_user("[%s:%d.%d] aggregate member '%s' cannot use '%s'; use contracts apply only to file-scope objects and functions",
                    member->file, member->line, member->column, name ? name : "?",
                    declaration_use_contract(modifiers) == DECL_USE_CONTRACT_REQUIRE ? "require" : "recommend");
      }
   }
}

//! @brief Lower struct decl stmt from AST/semantic state into generated assembly or linker-visible metadata.
void compile_struct_decl_stmt(ASTNode *node) {
   const char *key = node->children[0]->strval;
   validate_aggregate_member_use_contracts(node);
   attach_typename(key, node);

}

//! @brief Lower union decl stmt from AST/semantic state into generated assembly or linker-visible metadata.
void compile_union_decl_stmt(ASTNode *node) {
   const char *key = node->children[0]->strval;
   validate_aggregate_member_use_contracts(node);
   attach_typename(key, node);

}


//! @brief Return the number of named mem modifiers on one file-scope object.
static size_t global_object_region_count(const ASTNode *modifiers) {
   MemRegionSet set;
   size_t count;
   mem_region_set_collect(modifiers, &set);
   count = set.count;
   mem_region_set_release(&set);
   return count;
}

//! @brief Return the deterministic primary region used for the emitted source copy.
static const char *global_object_primary_region(const ASTNode *modifiers) {
   return mem_region_set_first_sorted(modifiers);
}

//! @brief Return whether one object has exactly one region and that region is zero page.
static bool global_object_single_region_is_zeropage(const ASTNode *modifiers) {
   MemRegionSet set;
   bool result = false;
   mem_region_set_collect(modifiers, &set);
   if (set.count == 1) {
      result = mem_decl_is_zeropage(get_memname_node(set.names[0]));
   }
   mem_region_set_release(&set);
   return result;
}

//! @brief Return whether every named region on an object is read-only.
static bool global_object_regions_are_readonly(const ASTNode *modifiers) {
   MemRegionSet set;
   bool result = false;
   mem_region_set_collect(modifiers, &set);
   if (set.count > 0) {
      result = true;
      for (size_t i = 0; i < set.count; i++) {
         const ASTNode *mem_decl = get_memname_node(set.names[i]);
         if (!mem_decl_is_readonly(mem_decl) || mem_decl_is_writable(mem_decl)) {
            result = false;
            break;
         }
      }
   }
   mem_region_set_release(&set);
   return result;
}

//! @brief Return whether one object has exactly one split-address region.
static bool global_object_single_region_is_split(const ASTNode *modifiers) {
   MemRegionSet set;
   bool result = false;
   mem_region_set_collect(modifiers, &set);
   if (set.count == 1) {
      result = mem_decl_split_addresses(get_memname_node(set.names[0]), NULL, NULL);
   }
   mem_region_set_release(&set);
   return result;
}

//! @brief Emit every mem declaration used by one object for cfg validation.
static void emit_global_object_region_metadata(const ASTNode *node,
                                               const ASTNode *modifiers) {
   MemRegionSet set;
   mem_region_set_collect(modifiers, &set);
   mem_region_set_sort(&set);
   for (size_t i = 0; i < set.count; i++) {
      emit_mem_region_metadata_for_name(node, set.names[i]);
   }
   mem_region_set_release(&set);
}

//! @brief Build a named storage segment from one already-selected region.
static void build_storage_segment_for_region(char *buf, size_t bufsize,
                                             const char *region,
                                             const char *base_segment) {
   if (!buf || bufsize == 0) {
      return;
   }
   if (region && *region) {
      snprintf(buf, bufsize, "%s.%s", base_segment, region);
   }
   else {
      snprintf(buf, bufsize, "%s", base_segment);
   }
}

//! @brief Validate immutable multi-region object replication contracts.
static void validate_global_object_region_modifiers(const ASTNode *node,
                                                    const ASTNode *modifiers,
                                                    const ASTNode *declarator,
                                                    const char *name) {
   MemRegionSet set;
   mem_region_set_collect(modifiers, &set);
   if (set.count == 0) {
      mem_region_set_release(&set);
      return;
   }
   for (size_t i = 0; i < set.count; i++) {
      for (size_t j = 0; j < i; j++) {
         if (!strcmp(set.names[i], set.names[j])) {
            error_user("[%s:%d.%d] object '%s' repeats mem region modifier '%s'",
                       node->file, node->line, node->column,
                       name ? name : "<unnamed>", set.names[i]);
         }
      }
   }
   if (set.count > 1) {
      if (!declaration_const_applies_to_object(modifiers, declarator)) {
         error_user("[%s:%d.%d] mutable object '%s' cannot be duplicated across mem regions; multi-region object placement requires const immutable storage",
                    node->file, node->line, node->column,
                    name ? name : "<unnamed>");
      }
      for (size_t i = 0; i < set.count; i++) {
         const ASTNode *mem_decl = get_memname_node(set.names[i]);
         if (!mem_decl || !mem_decl_is_readonly(mem_decl) || mem_decl_is_writable(mem_decl)) {
            error_user("[%s:%d.%d] duplicated object '%s' uses mem region '%s', but every replicated object region must declare exactly $ro",
                       node->file, node->line, node->column,
                       name ? name : "<unnamed>", set.names[i]);
         }
         if (mem_decl_split_addresses(mem_decl, NULL, NULL)) {
            error_user("[%s:%d.%d] duplicated object '%s' cannot use split-address mem region '%s'",
                       node->file, node->line, node->column,
                       name ? name : "<unnamed>", set.names[i]);
         }
      }
   }
   mem_region_set_release(&set);
}

//! @brief Select a unique compiler-owned segment for one file-scope data object.
static void emit_data_object_segment(EmitSink *sink, const char *base_segment,
                                     const char *symname, bool hard_page, int size) {
   emit(sink, ".segment \"%s.__vcsc_object$%s\"\n", base_segment, symname);
   if (hard_page) {
      emit(sink, ".pagecontain\n");
      if (size > 0 && size <= 256)
         emit(sink, ".indexrange 0, %d\n", size - 1);
   }
}

//! @brief Restore the ordinary compiler segment after one private data object.
static void restore_object_segment(EmitSink *sink, const char *base_segment) {
   emit(sink, ".segment \"%s\"\n", base_segment);
}

//! @brief Return whether one file-scope object declaration allocates or binds the object.
static bool global_object_is_definition(const ASTNode *node) {
   const ASTNode *modifiers = (node && node->count > 0) ? node->children[0] : NULL;
   return !has_modifier((ASTNode *)modifiers, "extern") && decl_node_address_spec(node) == NULL;
}

//! @brief Return whether two object declarations have the same source-level storage ABI.
static bool global_object_same_declaration(const ASTNode *a, const ASTNode *b) {
   const ASTNode *amod = (a && a->count > 0) ? a->children[0] : NULL;
   const ASTNode *bmod = (b && b->count > 0) ? b->children[0] : NULL;
   const ASTNode *atype = (a && a->count > 1) ? a->children[1] : NULL;
   const ASTNode *btype = (b && b->count > 1) ? b->children[1] : NULL;
   const ASTNode *adecl = decl_node_declarator(a);
   const ASTNode *bdecl = decl_node_declarator(b);
   const char *aname = type_name_from_node(atype);
   const char *bname = type_name_from_node(btype);
   const ASTNode *aaddr = decl_node_address_spec(a);
   const ASTNode *baddr = decl_node_address_spec(b);

   if (!aname || !bname || strcmp(aname, bname) ||
       !declarator_signature_matches(adecl, bdecl)) {
      return false;
   }
   if (has_modifier((ASTNode *)amod, "static") != has_modifier((ASTNode *)bmod, "static") ||
       declaration_const_applies_to_object(amod, adecl) != declaration_const_applies_to_object(bmod, bdecl) ||
       declaration_pointer_access(amod, adecl) != declaration_pointer_access(bmod, bdecl) ||
       global_object_single_region_is_zeropage(amod) != global_object_single_region_is_zeropage(bmod) ||
       !address_specs_equal(aaddr, baddr)) {
      return false;
   }
   if (!mem_region_sets_equal(amod, bmod)) {
      return false;
   }
   return true;
}

//! @brief Register all file-scope objects, selecting one declaration for lowering.
void predeclare_top_level_objects(ASTNode *program) {
   if (!globals) {
      globals = new_set();
   }

   for (int i = 0; program && i < program->count; i++) {
      ASTNode *stmt = program->children[i];
      if (!stmt || strcmp(stmt->name, "defdecl_stmt") || stmt->count != 1 ||
          strcmp(stmt->children[0]->name, "decl_list")) {
         continue;
      }
      ASTNode *list = stmt->children[0];
      for (int j = 0; j < list->count; j++) {
         ASTNode *node = list->children[j];
         const ASTNode *declarator = decl_node_declarator(node);
         const ASTNode *modifiers;
         const ASTNode *previous;
         const char *name;

         if (!declarator || declarator_is_function(declarator)) {
            continue;
         }
         modifiers = node->children[0];
         name = declarator_name(declarator);
         validate_nonreserved_implementation_name(name, node);
         validate_declaration_access_qualifiers(node, modifiers, declarator,
                                                "file-scope object declaration");
         validate_global_object_region_modifiers(node, modifiers, declarator, name);
         if (has_modifier((ASTNode *)modifiers, "ref")) {
            diagnose_ref_object_modifier(node, name);
         }
         if (!name) {
            error_user("[%s:%d.%d] unnamed file-scope object declaration is not supported",
                       node->file, node->line, node->column);
         }
         previous = (const ASTNode *)set_get(globals, name);
         if (!previous) {
            set_add(globals, strdup(name), node);
            remember_declaration_use_contract(DECL_CONTRACT_OBJECT, name, modifiers);
            continue;
         }
         if (!global_object_same_declaration(previous, node)) {
            error_user("[%s:%d.%d] vs [%s:%d.%d] conflicting declarations for object '%s'",
                       node->file, node->line, node->column,
                       previous->file, previous->line, previous->column, name);
         }
         if (global_object_is_definition(previous) && global_object_is_definition(node)) {
            error_user("[%s:%d.%d] duplicate symbol '%s' first defined at [%s:%d.%d]",
                       node->file, node->line, node->column, name,
                       previous->file, previous->line, previous->column);
         }
         remember_declaration_use_contract(DECL_CONTRACT_OBJECT, name, modifiers);
         if (!global_object_is_definition(previous) && global_object_is_definition(node)) {
            set_rm(globals, name);
            set_add(globals, strdup(name), node);
         }
      }
   }
}

//! @brief Lower global decl item from AST/semantic state into generated assembly or linker-visible metadata.
void compile_global_decl_item(ASTNode *node) {
   ASTNode *modifiers  = node->children[0];
   ASTNode *type       = node->children[1];
   ASTNode *declarator = (ASTNode *) decl_node_declarator(node);
   const ASTNode *addrspec = decl_node_address_spec(node);
   const char *name    = declarator_name(declarator);
   ASTNode *expression = node->children[node->count - 1];
   validate_nonreserved_implementation_name(name, node);
   validate_declaration_access_qualifiers(node, modifiers, declarator,
                                          "file-scope object declaration");
   validate_global_object_region_modifiers(node, modifiers, declarator, name);
   ASTNode *uexpr;
   EmitSink init_es = EMIT_INIT;

   if (has_modifier(modifiers, "inline")) {
      error_user("[%s:%d.%d] 'inline' applies only to function declarations and definitions",
                 node->file, node->line, node->column);
   }

   const ASTNode *selected = globals ? (const ASTNode *)set_get(globals, name) : NULL;
   if (!selected) {
      error_unreachable("[%s:%d.%d] file-scope object '%s' was not predeclared",
                        node->file, node->line, node->column, name);
   }

   bool is_extern = has_modifier(modifiers, "extern");
   bool is_const = declaration_const_applies_to_object(modifiers, declarator);
   bool is_static = has_modifier(modifiers, "static");
   size_t region_count = global_object_region_count(modifiers);
   const char *primary_region = global_object_primary_region(modifiers);
   bool is_zeropage = global_object_single_region_is_zeropage(modifiers);
   bool is_readonly_mem = global_object_regions_are_readonly(modifiers);
   bool is_split_mem = global_object_single_region_is_split(modifiers);
   bool is_ref = has_modifier(modifiers, "ref");
   bool is_page = has_modifier(modifiers, "page");
   bool is_absolute_binding = addrspec != NULL;
   int size = declarator_storage_size(type, declarator);
   char symname[256];
   format_user_asm_symbol(name, symname, sizeof(symname));

   if (is_page && region_count > 0) {
      error_user("[%s:%d.%d] 'page' with a named mem region is not supported until region-aware object naming is added",
                 node->file, node->line, node->column);
   }
   if (is_split_mem && (is_ref || is_absolute_binding)) {
      error_user("[%s:%d.%d] split-address mem region '%s' supplies allocated read/write aliases and cannot be combined with an '@' absolute binding",
                 node->file, node->line, node->column,
                 primary_region ? primary_region : "<unknown>");
   }
   if (is_readonly_mem && !is_const && !is_extern) {
      error_user("[%s:%d.%d] object '%s' placed in a $ro mem region must be const",
                 node->file, node->line, node->column, name);
   }
   if (is_page && (is_extern || is_absolute_binding)) {
      error_user("[%s:%d.%d] 'page' requires a file-scope data-object definition",
                 node->file, node->line, node->column);
   }

   if (is_ref) {
      diagnose_ref_object_modifier(node, name);
   }

   if (selected != node) {
      return;
   }
   emit_global_object_region_metadata(node, modifiers);
   emit_global_contract_metadata(node, symname, is_zeropage);

   if (is_absolute_binding) {
      if (!address_spec_has_read(addrspec) && !address_spec_has_write(addrspec)) {
         error_user("[%s:%d.%d] absolute external binding '%s' cannot use none for both read and write address",
               node->file, node->line, node->column, name);
      }
      if (is_extern || is_static || is_page || region_count > 0) {
         error_user("[%s:%d.%d] absolute external binding '%s' cannot use allocation or linkage modifiers",
               node->file, node->line, node->column, name);
      }
      if (declaration_has_use_contract(modifiers)) {
         error_user("[%s:%d.%d] absolute external binding '%s' cannot use a file-scope use contract",
               node->file, node->line, node->column, name);
      }
      if (!is_empty(expression)) {
         error_user("[%s:%d.%d] absolute external binding '%s' cannot have an initializer",
               node->file, node->line, node->column, name);
      }
      emit_absolute_binding_region_guard_metadata(node, name,
                                                  address_spec_read_expr(addrspec),
                                                  address_spec_write_expr(addrspec),
                                                  size);
      emit_global_abi_metadata(node, symname, false, false);
      return;
   }

   if (is_extern) {
      if (is_static) {
         error_user("[%s:%d.%d] 'extern' and 'static' don't mix",
               node->file, node->line, node->column);
      }

      if (is_zeropage) {
         emit(&es_import, ".zpimport %s\n", symname);
      }
      else {
         emit(&es_import, ".import %s\n", symname);
      }
      emit_global_abi_metadata(node, symname, false, is_zeropage);
      return;
   }

   if (!is_static) {
      if (is_zeropage) {
         emit(&es_export, ".zpexport %s\n", symname);
      }
      else {
         emit(&es_export, ".export %s\n", symname);
      }
      emit_global_abi_metadata(node, symname, true, is_zeropage);
   }

   if (region_count > 1) {
      MemRegionSet regions;
      mem_region_set_collect(modifiers, &regions);
      mem_region_set_sort(&regions);
      for (size_t i = 0; i < regions.count; i++) {
         emit_replica_metadata('O', symname, regions.names[i]);
      }
      mem_region_set_release(&regions);
   }

   if (is_empty(expression)) {
      if (is_const) {
         error_user("[%s:%d.%d] 'const' missing initializer",
               node->file, node->line, node->column);
      }
      if (is_zeropage) {
         char segbuf[256];
         build_storage_segment_for_region(segbuf, sizeof(segbuf), primary_region, "ZEROPAGE");
         emit_data_object_segment(&es_zp, segbuf, symname, is_page, size);
         emit(&es_zp, "%s:\n", symname);
         emit(&es_zp, "\t.res %d\n", size);
         restore_object_segment(&es_zp, segbuf);
      }
      else {
         char segbuf[256];
         build_storage_segment_for_region(segbuf, sizeof(segbuf), primary_region, "BSS");
         emit_data_object_segment(&es_bss, segbuf, symname, is_page, size);
         emit(&es_bss, "%s:\n", symname);
         emit(&es_bss, "\t.res %d\n", size);
         restore_object_segment(&es_bss, segbuf);
      }
      return;
   }

   uexpr = (ASTNode *) unwrap_expr_node(expression);

   if (declarator_pointer_depth(declarator) > 0 &&
       !integer_literal_is_zero_expr(expression)) {
      const ASTNode *src_type = NULL;
      const ASTNode *src_decl = NULL;
      expr_match_signature(expression, NULL, &src_type, &src_decl);
      if (src_type && src_decl && declarator_pointer_depth(src_decl) > 0) {
         validate_pointer_access_conversion(expression,
            declaration_pointer_access(modifiers, declarator),
            expr_pointer_access(expression, NULL), "file-scope initializer");
      }
   }

   {
      char symbuf[256];
      snprintf(symbuf, sizeof(symbuf), "%s", symname);

      if (emit_global_initializer(&init_es, type, declarator, uexpr ? uexpr : expression, size)) {
         if (is_zeropage) {
            char segbuf[256];
            build_storage_segment_for_region(segbuf, sizeof(segbuf), primary_region, "ZEROPAGE");
            emit_data_object_segment(&es_zpdata, segbuf, symname, is_page, size);
            emit(&es_zpdata, "%s:\n", symname);
            emit_sink_append(&es_zpdata, &init_es);
            restore_object_segment(&es_zpdata, segbuf);
         }
         else if (region_count > 0 && is_const && is_readonly_mem) {
            char segbuf[256];
            build_storage_segment_for_region(segbuf, sizeof(segbuf), primary_region, "RODATA");
            emit_data_object_segment(&es_rodata, segbuf, symname, is_page, size);
            emit(&es_rodata, "%s:\n", symname);
            emit_sink_append(&es_rodata, &init_es);
            restore_object_segment(&es_rodata, segbuf);
         }
         else if (region_count > 0) {
            char segbuf[256];
            build_storage_segment_for_region(segbuf, sizeof(segbuf), primary_region, "DATA");
            emit_data_object_segment(&es_data, segbuf, symname, is_page, size);
            emit(&es_data, "%s:\n", symname);
            emit_sink_append(&es_data, &init_es);
            restore_object_segment(&es_data, segbuf);
         }
         else {
            EmitSink *es = is_const ? &es_rodata : &es_data;
            const char *base = is_const ? "RODATA" : "DATA";
            emit_data_object_segment(es, base, symname, is_page, size);
            emit(es, "%s:\n", symname);
            emit_sink_append(es, &init_es);
            restore_object_segment(es, base);
         }
         return;
      }

      if (is_readonly_mem) {
         error_user("[%s:%d.%d] object '%s' placed in a $ro mem region requires a link-time initializer",
                    node->file, node->line, node->column, name);
      }

      if (is_zeropage) {
         char segbuf[256];
         build_storage_segment_for_region(segbuf, sizeof(segbuf), primary_region, "ZEROPAGE");
         emit_data_object_segment(&es_zp, segbuf, symname, is_page, size);
         emit(&es_zp, "%s:\n", symname);
         emit(&es_zp, "\t.res %d\n", size);
         restore_object_segment(&es_zp, segbuf);
      }
      else {
         char segbuf[256];
         build_storage_segment_for_region(segbuf, sizeof(segbuf), primary_region, "BSS");
         emit_data_object_segment(&es_bss, segbuf, symname, is_page, size);
         emit(&es_bss, "%s:\n", symname);
         emit(&es_bss, "\t.res %d\n", size);
         restore_object_segment(&es_bss, segbuf);
      }
      if (is_split_mem) {
         ContextEntry split_entry;
         if (!init_context_entry_from_global_decl(&split_entry, name, node)) {
            error_unreachable("[%s:%d.%d] could not construct split-address initializer target for '%s'",
                              node->file, node->line, node->column, name);
         }
         remember_pending_global_init(name, symbuf, type, declarator,
                                      uexpr ? uexpr : expression, size, false, true,
                                      split_entry.read_expr, split_entry.write_expr);
      }
      else {
         remember_pending_global_init(name, symbuf, type, declarator,
                                      uexpr ? uexpr : expression, size, is_zeropage,
                                      false, NULL, NULL);
      }
   }
}


//! @brief Handle predeclare top level functions logic for compile toplevel.
void predeclare_top_level_functions(ASTNode *program) {
   if (!functions) {
      functions = new_set();
   }

   for (int i = 0; i < program->count; i++) {
      ASTNode *node = program->children[i];
      if (strcmp(node->name, "defdecl_stmt")) {
         continue;
      }

      if (node->count == 1 && !strcmp(node->children[0]->name, "decl_list")) {
         ASTNode *list = node->children[0];
         for (int j = 0; j < list->count; j++) {
            ASTNode *item = list->children[j];
            ASTNode *declarator = item->children[2];
            if (declarator_is_function(declarator)) {
               remember_function(item, declarator_name(declarator));
            }
         }
      }
      else if (node->count == 3) {
         ASTNode *declarator = node->children[1];
         remember_function(node, declarator_name(declarator));
      }
   }
}

//! @brief Lower function signature from AST/semantic state into generated assembly or linker-visible metadata.
static void compile_function_signature(ASTNode *node) {
   ASTNode *modifiers  = node->children[0];
   ASTNode *declarator = node->children[2];
   const char *name    = declarator_name(declarator);
   char sym[256];

   validate_function_return_type(node);
   remember_function(node, name);

   if (!function_symbol_name(node, name, sym, sizeof(sym))) {
      error_unreachable("[%s:%d.%d] could not mangle function '%s'", node->file, node->line, node->column, name);
   }
   emit_function_contract_metadata(node, sym);
   if (function_is_inline(node)) {
      return;
   }

   {
      FunctionRegionSpec regions;
      function_region_spec_collect(node, &regions);
      for (size_t i = 0; i < regions.code_region_count; i++) {
         emit_mem_region_metadata_for_name(node, regions.code_regions[i]);
      }
      if (regions.result_region) {
         emit_mem_region_metadata_for_name(node, regions.result_region);
      }
      function_region_spec_release(&regions);
   }

   if (!has_modifier(modifiers, "static")) {
      emit_function_abi_metadata(node, sym, false);
   }

   if (has_modifier(modifiers, "extern") && !has_modifier(modifiers, "static")) {
      remember_symbol_import(sym);
   }
}


//! @brief Lower defdecl stmt from AST/semantic state into generated assembly or linker-visible metadata.
void compile_defdecl_stmt(ASTNode *node) {
   if (node->count == 1 && !strcmp(node->children[0]->name, "decl_list")) {
      ASTNode *list = node->children[0];
      for (int i = 0; i < list->count; i++) {
         ASTNode *item = list->children[i];
         ASTNode *declarator = item->children[2];
         if (declarator_is_function(declarator)) {
            compile_function_signature(item);
         }
         else {
            compile_global_decl_item(item);
         }
      }
      return;
   }

   if (node->count == 3) {
      compile_function_decl(node);
      return;
   }

   error_unreachable("[%s:%d.%d] unsupported defdecl_stmt shape", node->file, node->line, node->column);
}

//! @brief Validate struct union undefined invariants before later compiler stages depend on them.
void check_struct_union_undefined(ASTNode *program) {
   // undefined struct/union is always an error
   const char *undefined = typename_find_null();
   if (undefined) {
      ASTNode *node = NULL;

      // as an artifact of parsing,
      // floaters have an empty node
      // in the program tree
      for (int i = 0; i < program->count; i++) {
         if (!strcmp(program->children[i]->name, "empty")) {
            if (!strcmp(program->children[i]->strval, undefined)) {
               node = program->children[i];
            }
         }
      }

      if (node) {
         error_user("undefined struct/union '%s' [%s:%d.%d]",
               undefined, node->file, node->line, node->column);
      }
      else {
         error_unreachable("undefined struct/union '%s'", undefined); // this is probably unreachable
      }
      // error_user() calls exit()
   }
}

//! @brief Handle crosscheck helper logic for compile toplevel.
static bool crosscheck_helper(Pair *markers, const char *name) {
   const char *childname;
   ASTNode *child;
   pair_insert(markers, name, (void *)1);
   ASTNode *node = get_typename_node(name);
   if (node && (!strcmp(node->name, "struct_decl_stmt") || !strcmp(node->name, "union_decl_stmt"))) {
      for (int i = 1; i < node->count; i++) {
         child = node->children[i];
         {
            const ASTNode *child_decl = child->children[2];
            if (declarator_pointer_depth(child_decl) <= 0) {
               childname = child->children[1]->strval;
               void *color = pair_get(markers, childname);
               if (color == 0) {
                  if (crosscheck_helper(markers, childname)) {
                     goto problem;
                  }
               }
               else if ((intptr_t)color == 1) {
                  goto problem;
               }
            }
         }
      }
   }
   pair_insert(markers, name, (void *) 2);
   return false;

problem:
   warning("struct/union '%s' contains '%s' [%s:%d.%d]",
         name, childname,
         child->file, child->line, child->column);
   return true;
}

//! @brief Handle crosscheck struct union nesting logic for compile toplevel.
void crosscheck_struct_union_nesting(ASTNode *program) {
   Pair *markers = pair_create();

   for (int i = 0; i < program->count; i++) {
      if (!strcmp(program->children[i]->name, "struct_decl_stmt") ||
          !strcmp(program->children[i]->name, "union_decl_stmt")) {
         ASTNode *node = program->children[i]->children[0];
         pair_insert(markers, node->strval, 0);
      }
   }

   for (int i = 0; i < program->count; i++) {
      if (!strcmp(program->children[i]->name, "struct_decl_stmt") ||
          !strcmp(program->children[i]->name, "union_decl_stmt")) {
         ASTNode *node = program->children[i]->children[0];
         if (pair_get(markers, node->strval) == 0) {
            if (crosscheck_helper(markers, node->strval)) {
               error_user("cyclic struct/union detected");
               // error_user() calls exit()
            }
         }
      }
   }

   pair_destroy(markers);
}

//! @brief Handle calculate struct union sizes logic for compile toplevel.
void calculate_struct_union_sizes(ASTNode *program) {
   // everybody uses pointers, let's just do that now...

   if (!typename_exists("*")) {
      error_user("required pointer type '*' is not defined");
   }

   int sizeof_ptr = (intptr_t) pair_get(typesizes, "*");

   bool done = false;

   while (!done) {
      done = true;

      for (int i = 0; i < program->count; i++) {
         bool is_struct = false;
         bool is_union = false;

         if (!strcmp(program->children[i]->name, "struct_decl_stmt")) {
            is_struct = true;
         }
         else if (!strcmp(program->children[i]->name, "union_decl_stmt")) {
            is_union = true;
         }
         // else if (!strcmp(program->children[i]->name, "type_decl_stmt")) {
         // // types have already been done.
         // }

         if (is_struct || is_union) {
            ASTNode *node = program->children[i];
            const char *name = node->children[0]->strval;
            int size = 0;
            int bit_cursor = 0;

            if (!pair_exists(typesizes, name)) {
               for (int j = 1; j < node->count; j++) {
                  ASTNode *item = node->children[j];
                  const ASTNode *type = item->children[1];
                  const char *tname = type->strval;
                  const ASTNode *decl = item->children[2];
                  int mult = declarator_array_multiplier(decl);
                  bool isptr = declarator_pointer_depth(decl) > 0;
                  int bit_width = declarator_bitfield_width(decl);
                  int othersize;

                  if (isptr) {
                     othersize = sizeof_ptr;
                  }
                  else if (pair_exists(typesizes, tname)) {
                     othersize = (intptr_t) pair_get(typesizes, tname);
                  }
                  else {
                     othersize = -1;
                  }

                  if (othersize == -1) {
                     size = -1;
                     break;
                  }

                  if (bit_width > 0) {
                     if (declarator_pointer_depth(decl) > 0 || declarator_array_count(decl) > 0) {
                        error_user("[%s:%d.%d] bitfield '%s' must be a plain scalar field",
                              decl->file, decl->line, decl->column,
                              declarator_name(decl) ? declarator_name(decl) : "<unnamed>");
                     }
                     if (has_flag_prefix(tname, "$float:")) {
                        error_user("[%s:%d.%d] bitfield '%s' cannot use floating type '%s'",
                              decl->file, decl->line, decl->column,
                              declarator_name(decl) ? declarator_name(decl) : "<unnamed>",
                              tname);
                     }
                     if (bit_width <= 0 || bit_width > othersize * 8) {
                        error_user("[%s:%d.%d] bitfield '%s' width %d exceeds storage of '%s' (%d bits)",
                              decl->file, decl->line, decl->column,
                              declarator_name(decl) ? declarator_name(decl) : "<unnamed>",
                              bit_width, tname, othersize * 8);
                     }
                     if (mult != 1) {
                        error_user("[%s:%d.%d] bitfield '%s' cannot be an array",
                              decl->file, decl->line, decl->column,
                              declarator_name(decl) ? declarator_name(decl) : "<unnamed>");
                     }
                     if (is_struct) {
                        bit_cursor += bit_width;
                        size = (bit_cursor + 7) / 8;
                     }
                     else {
                        int field_size = (bit_width + 7) / 8;
                        if (field_size > size) {
                           size = field_size;
                        }
                     }
                  }
                  else if (is_struct) {
                     if (bit_cursor % 8) {
                        bit_cursor = ((bit_cursor + 7) / 8) * 8;
                     }
                     bit_cursor += othersize * mult * 8;
                     size = bit_cursor / 8;
                  }
                  else if (is_union) {
                     if (othersize * mult > size) {
                        size = othersize * mult;
                     }
                  }
               }

               if (size == -1) {
                  done = false;
               }
               else {
                  pair_insert(typesizes, name, (void *)(intptr_t)size);
                  debug("sizeof(%s) == %d", name, size);
               }
            }
         }
      }
   }
}

