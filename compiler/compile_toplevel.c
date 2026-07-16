//! @file compiler/compile_toplevel.c
//! @brief Implements top-level declaration lowering for the n65 compiler.
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
#include "compile_init.h"
#include "compile_internal.h"
#include "compile_overload.h"
#include "compile_stmt.h"
#include "compile_toplevel.h"
#include "compile_type.h"
#include "emit.h"
#include "float.h"
#include "integer.h"
#include "memname.h"
#include "messages.h"
#include "pair.h"
#include "set.h"
#include "typename.h"
#include "xray.h"
#include "lextern.h"

void emit_mem_region_metadata_for_modifiers(const ASTNode *origin, const ASTNode *modifiers);

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

//! @brief Return decl node declarator data used by compile toplevel; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *decl_node_declarator(const ASTNode *node) {
   if (!node || node->count < 3) {
      return NULL;
   }
   return decl_subitem_declarator(node->children[2]);
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

//! @brief Report address spec without ref diagnostics with the location/context expected by compile toplevel callers.
static void warn_address_spec_without_ref(const ASTNode *node, const char *name) {
   if (!node) {
      error_unreachable("internal error: !node in %s %s:%d\n",
         __func__, __FILE__, __LINE__);
      return;
   }
   warning("[%s:%d.%d] '@' on non-ref declaration '%s' is ignored",
      node->file, node->line, node->column, name ? name : "?");
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

   remember_function(node, name);
   if (!function_symbol_name(node, name, sym, sizeof(sym))) {
      error_unreachable("[%s:%d.%d] could not mangle function '%s'", node->file, node->line, node->column, name);
   }

   if (!has_modifier(modifiers, "static")) {
      emit(&es_export, ".export %s\n", sym);
      emit_function_parameter_exports(node);
      emit_function_abi_metadata(node, sym, true);
   }

   Context ctx;
   ctx.name = strdup(sym);
   ctx.locals = 0;
   ctx.params = 0;
   ctx.vars = new_set();
   ctx.break_label = NULL;
   ctx.continue_label = NULL;
   build_function_context(node, &ctx);
   current_call_graph_function = node;
   current_call_graph_node = call_graph_node_index_for_function(node);

   if (!is_empty(body) && !strcmp(body->name, "statement_list")) {
      predeclare_statement_list(body, &ctx);
   }

   emit_function_parameter_storage(node, &ctx);
   emit(&es_code, ".proc %s\n", sym);
   emit(&es_code, "    lda sp+1\n");
   emit(&es_code, "    sta fp+1\n");
   emit(&es_code, "    lda sp\n");
   emit(&es_code, "    sta fp\n");
   if (ctx.locals > 0) {
      remember_runtime_import("pushN");
      emit(&es_code, "    lda #$%02x\n", ctx.locals & 0xff);
      emit(&es_code, "    sta arg0\n");
      emit(&es_code, "    jsr _pushN\n");
   }

   emit_variadic_hidden_local_setup(node, &ctx);

   if (!is_empty(body)) {
      if (!strcmp(body->name, "statement_list")) {
         compile_statement_list(body, &ctx);
      }
      else {
         error_unreachable("[%s:%d.%d] internal compiler error: unexpected function body node '%s'", body->file, body->line, body->column, body->name);
      }
   }

   emit(&es_code, "@fini:\n");
   if (ctx.locals > 0) {
      remember_runtime_import("popN");
      emit(&es_code, "    lda #$%02x\n", ctx.locals & 0xff);
      emit(&es_code, "    sta arg0\n");
      emit(&es_code, "    jsr _popN\n");
   }
   emit(&es_code, "    rts\n");
   emit(&es_code, ".endproc\n");
   current_call_graph_function = saved_call_graph_function;
   current_call_graph_node = saved_call_graph_node;
}

//! @brief Lower mem decl stmt from AST/semantic state into generated assembly or linker-visible metadata.
void compile_mem_decl_stmt(ASTNode *node) {
   attach_memname(node->children[0]->strval, node);
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
   bool haveFloat = false;
   const char *float_style = NULL;
   bool haveInteger = false;
   const char *integer_style = NULL;
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

         // check for $endian, must be "big" or "little"
         if (!strncmp(item->strval, "$endian:", 8)) {
            if (haveEndian) {
               error_user("[%s:%d.%d] type_decl_stmt '%s' has multiple '$endian:' flags",
                     node->file, node->line, node->column,
                     node->children[0]->strval);
            }
            endian = strchr(item->strval, ':');
            endian++;
            if (strcmp(endian, "big") && strcmp(endian, "little")) {
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
         else if (!strcmp(item->strval, "$float")) {
            error_user("[%s:%d.%d] type_decl_stmt '%s' must use '$float:ieee754' or '$float:simple'",
                  node->file, node->line, node->column,
                  node->children[0]->strval);
         }
         else if (!strncmp(item->strval, "$float:", 7)) {
            const char *style = parse_float_style_flag_text(item->strval);
            if (haveFloat) {
               error_user("[%s:%d.%d] type_decl_stmt '%s' has multiple '$float' flags",
                     node->file, node->line, node->column,
                     node->children[0]->strval);
            }
            if (!style || !float_style_is_known(style)) {
               error_user("[%s:%d.%d] type_decl_stmt '%s' unrecognized '%s' flag",
                     node->file, node->line, node->column,
                     node->children[0]->strval, item->strval);
            }
            haveFloat = true;
            float_style = style;
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
      }
   }

   if (!haveSize) {
      error_user("[%s:%d.%d] type_decl_stmt '%s' missing '$size:' flag",
            node->file, node->line, node->column, node->children[0]->strval);
   }

   if (!haveEndian && size > 1) {
      error_user("[%s:%d.%d] type_decl_stmt '%s' missing '$endian:' flag",
            node->file, node->line, node->column, node->children[0]->strval);
   }

   if (haveFloat && haveInteger) {
      error_user("[%s:%d.%d] type_decl_stmt '%s' cannot combine '$float:*' with '$integer:%s'",
            node->file, node->line, node->column,
            node->children[0]->strval,
            integer_style ? integer_style : "?");
   }

   if (!haveFloat && integer_required && !haveInteger) {
      error_user("[%s:%d.%d] type_decl_stmt '%s' missing '$integer:signed' or '$integer:unsigned' flag",
            node->file, node->line, node->column, node->children[0]->strval);
   }

   if (key && !strcmp(key, "bool") && haveInteger && (!integer_style || strcmp(integer_style, "unsigned"))) {
      error_user("[%s:%d.%d] type_decl_stmt '%s' must use '$integer:unsigned'",
            node->file, node->line, node->column, node->children[0]->strval);
   }

   if (haveFloat) {
      int expbits = float_style_expbits_for_size(float_style, size);
      if (expbits < 0) {
         error_user("[%s:%d.%d] type_decl_stmt '%s' float style '%s' does not support $size:%d",
               node->file, node->line, node->column,
               node->children[0]->strval,
               float_style ? float_style : "(null)",
               size);
      }
   }

   if (get_xray(XRAY_TYPEINFO)) {
      message("TYPEINFO: %s %d %s", key, haveSize ? size : -1, haveEndian ? endian : "unspec");
   }
}

//! @brief Return whether enum candidate is integer type in compile toplevel.
static bool enum_candidate_is_integer_type(const ASTNode *node) {
   if (!node || strcmp(node->name, "type_decl_stmt")) {
      return false;
   }

   return type_is_promotable_integer(node) && !type_is_bool(node);
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

//! @brief Lower struct decl stmt from AST/semantic state into generated assembly or linker-visible metadata.
void compile_struct_decl_stmt(ASTNode *node) {
   const char *key = node->children[0]->strval;
   attach_typename(key, node);

}

//! @brief Lower union decl stmt from AST/semantic state into generated assembly or linker-visible metadata.
void compile_union_decl_stmt(ASTNode *node) {
   const char *key = node->children[0]->strval;
   attach_typename(key, node);

}


//! @brief Lower global decl item from AST/semantic state into generated assembly or linker-visible metadata.
void compile_global_decl_item(ASTNode *node) {
   ASTNode *modifiers  = node->children[0];
   ASTNode *type       = node->children[1];
   ASTNode *declarator = (ASTNode *) decl_node_declarator(node);
   const ASTNode *addrspec = decl_node_address_spec(node);
   const char *name    = declarator_name(declarator);
   ASTNode *expression = node->children[node->count - 1];
   validate_nonreserved_variadic_name(name, node);
   ASTNode *uexpr;
   EmitSink init_es = EMIT_INIT;

   if (!globals) {
      globals = new_set();
   }

   const ASTNode *value = set_get(globals, name);
   if (value != NULL) {
      error_user("[%s:%d.%d] duplicate symbol '%s' first defined at [%s:%d.%d]",
            node->file, node->line, node->column,
            name,
            value->file, value->line, value->column);
   }
   set_add(globals, strdup(name), node);

   bool is_extern = has_modifier(modifiers, "extern");
   bool is_const = declaration_const_applies_to_object(modifiers, declarator);
   bool is_static = has_modifier(modifiers, "static");
   bool is_zeropage = modifiers_imply_zeropage(modifiers);
   bool is_ref = has_modifier(modifiers, "ref");
   bool is_absolute_ref = is_ref && addrspec != NULL;
   emit_mem_region_metadata_for_modifiers(node, modifiers);
   int size = declarator_storage_size(type, declarator);
   char symname[256];
   format_user_asm_symbol(name, symname, sizeof(symname));

   if (addrspec != NULL && !is_ref) {
      warn_address_spec_without_ref(node, name);
   }

   if (is_ref && !is_absolute_ref) {
      error_user("[%s:%d.%d] 'ref' not allowed in global declaration without an absolute address binding",
            node->file, node->line, node->column);
   }

   if (is_absolute_ref) {
      if (!address_spec_has_read(addrspec) && !address_spec_has_write(addrspec)) {
         error_user("[%s:%d.%d] absolute ref '%s' cannot use none for both read and write address",
               node->file, node->line, node->column, name);
      }
      if (is_extern) {
         error_user("[%s:%d.%d] 'extern' not allowed on absolute ref '%s'",
               node->file, node->line, node->column, name);
      }
      if (!is_empty(expression)) {
         ASTNode *runtime_expr = (ASTNode *) unwrap_expr_node(expression);
         if (!address_spec_has_write(addrspec)) {
            error_user("[%s:%d.%d] global absolute ref '%s' with initializer must be writable",
                  node->file, node->line, node->column, name);
         }
         remember_pending_global_init(name,
                                      NULL,
                                      type,
                                      declarator,
                                      runtime_expr ? runtime_expr : expression,
                                      size,
                                      false,
                                      true,
                                      address_spec_read_expr(addrspec),
                                      address_spec_write_expr(addrspec));
      }
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

   if (is_empty(expression)) {
      if (is_const) {
         error_user("[%s:%d.%d] 'const' missing initializer",
               node->file, node->line, node->column);
      }
      if (is_zeropage) {
         char segbuf[256];
         build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "ZEROPAGE");
         emit(&es_zp, ".segment \"%s\"\n", segbuf);
         emit(&es_zp, "%s:\n", symname);
         emit(&es_zp, "\t.res %d\n", size);
      }
      else {
         char segbuf[256];
         build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "BSS");
         emit(&es_bss, ".segment \"%s\"\n", segbuf);
         emit(&es_bss, "%s:\n", symname);
         emit(&es_bss, "\t.res %d\n", size);
      }
      return;
   }

   uexpr = (ASTNode *) unwrap_expr_node(expression);

   {
      char symbuf[256];
      snprintf(symbuf, sizeof(symbuf), "%s", symname);

      if (emit_global_initializer(&init_es, type, declarator, uexpr ? uexpr : expression, size)) {
         if (is_zeropage) {
            char segbuf[256];
            build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "ZEROPAGE");
            emit(&es_zpdata, ".segment \"%s\"\n", segbuf);
            emit(&es_zpdata, "%s:\n", symname);
            emit_sink_append(&es_zpdata, &init_es);
         }
         else if (modifiers_imply_mem_storage(modifiers)) {
            char segbuf[256];
            build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "DATA");
            emit(&es_data, ".segment \"%s\"\n", segbuf);
            emit(&es_data, "%s:\n", symname);
            emit_sink_append(&es_data, &init_es);
         }
         else {
            EmitSink *es = is_const ? &es_rodata : &es_data;
            emit(es, "%s:\n", symname);
            emit_sink_append(es, &init_es);
         }
         return;
      }

      if (is_zeropage) {
         char segbuf[256];
         build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "ZEROPAGE");
         emit(&es_zp, ".segment \"%s\"\n", segbuf);
         emit(&es_zp, "%s:\n", symname);
         emit(&es_zp, "\t.res %d\n", size);
      }
      else {
         char segbuf[256];
         build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "BSS");
         emit(&es_bss, ".segment \"%s\"\n", segbuf);
         emit(&es_bss, "%s:\n", symname);
         emit(&es_bss, "\t.res %d\n", size);
      }
      remember_pending_global_init(name, symbuf, type, declarator, uexpr ? uexpr : expression, size, is_zeropage, false, NULL, NULL);
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

   remember_function(node, name);

   if (!has_modifier(modifiers, "static")) {
      if (!function_symbol_name(node, name, sym, sizeof(sym))) {
         error_unreachable("[%s:%d.%d] could not mangle function '%s'", node->file, node->line, node->column, name);
      }
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
            if (declarator_pointer_depth(child_decl) <= 0 && declarator_function_pointer_depth(child_decl) <= 0) {
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
                  bool isptr = declarator_pointer_depth(decl) > 0 || declarator_function_pointer_depth(decl) > 0;
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
                     if (declarator_pointer_depth(decl) > 0 || declarator_function_pointer_depth(decl) > 0 || declarator_array_count(decl) > 0) {
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
                     if (has_flag(tname, "$endian:big")) {
                        error_user("[%s:%d.%d] bitfield '%s' does not support big-endian type '%s'",
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

