//! @file compiler/compile.c
//! @brief Implements compiler front-end orchestration for the VCSC compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <limits.h>

#include "ast.h"
#include "compile.h"
#include "compile_expr.h"
#include "compile_function.h"
#include "compile_function_registry.h"
#include "compile_init.h"
#include "compile_internal.h"
#include "compile_inline_prepass.h"
#include "compile_inline_analysis.h"
#include "compile_inline_inliner.h"
#include "compile_inline_identity.h"
#include "compile_inline_specialize.h"
#include "compile_toplevel.h"
#include "compile_support.h"
#include "compile_type.h"
#include "emit.h"
#include "messages.h"
#include "pair.h"
#include "set.h"
#include "typename.h"
#include "lextern.h"

EmitSink es_header = EMIT_INIT;
EmitSink es_import = EMIT_INIT;
EmitSink es_export = EMIT_INIT;
EmitSink es_code   = EMIT_INIT;
EmitSink es_rodata = EMIT_INIT;
EmitSink es_data   = EMIT_INIT;
EmitSink es_bss    = EMIT_INIT;
EmitSink es_zp     = EMIT_INIT;
EmitSink es_zpdata = EMIT_INIT;

Pair *typesizes = NULL;
Pair *enumbackings = NULL;

Set *globals = NULL;
Set *functions = NULL;
Set *runtime_imports = NULL;
Set *imported_symbols = NULL;
Set *abi_metadata_symbols = NULL;
Set *string_literals = NULL;
int label_counter = 0;

//! One compiler/runtime zero-page workspace spelling and its exported symbol.
typedef struct RuntimeWorkspaceName {
   const char *name;
   const char *symbol;
} RuntimeWorkspaceName;

static const RuntimeWorkspaceName runtime_workspace_names[] = {
   { "arg0", "_vcsc_arg0" },
   { "arg1", "_vcsc_arg1" },
   { "ptr0", "_vcsc_ptr0" },
   { "ptr1", "_vcsc_ptr1" },
   { "ptr2", "_vcsc_ptr2" },
};

enum {
   RUNTIME_WORKSPACE_NAME_COUNT =
      (int)(sizeof(runtime_workspace_names) / sizeof(runtime_workspace_names[0]))
};

//! @brief Record a workspace import when one emitted assembler identifier names it.
static void remember_runtime_workspace_token(const char *start, size_t len) {
   for (int i = 0; i < RUNTIME_WORKSPACE_NAME_COUNT; i++) {
      const RuntimeWorkspaceName *entry = &runtime_workspace_names[i];
      if ((strlen(entry->name) == len && !strncmp(start, entry->name, len)) ||
          (strlen(entry->symbol) == len && !strncmp(start, entry->symbol, len))) {
         remember_symbol_import_mode(entry->symbol, true);
         return;
      }
   }
}

//! @brief Scan one emitted assembler stream for workspace references outside comments and strings.
static void scan_runtime_workspace_imports(const EmitSink *sink) {
   bool in_comment = false;
   bool in_string = false;
   bool escaped = false;

   for (const EmitPiece *piece = sink ? sink->head : NULL; piece; piece = piece->next) {
      const char *text = piece->txt;
      for (size_t i = 0; text && text[i]; ) {
         unsigned char ch = (unsigned char)text[i];

         if (in_comment) {
            if (ch == '\n')
               in_comment = false;
            i++;
            continue;
         }
         if (in_string) {
            if (escaped) {
               escaped = false;
            }
            else if (ch == '\\') {
               escaped = true;
            }
            else if (ch == '"') {
               in_string = false;
            }
            i++;
            continue;
         }
         if (ch == ';') {
            in_comment = true;
            i++;
            continue;
         }
         if (ch == '"') {
            in_string = true;
            i++;
            continue;
         }
         if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_') {
            size_t start = i++;
            while (text[i]) {
               unsigned char next = (unsigned char)text[i];
               if (!((next >= 'A' && next <= 'Z') ||
                     (next >= 'a' && next <= 'z') ||
                     (next >= '0' && next <= '9') || next == '_'))
                  break;
               i++;
            }
            remember_runtime_workspace_token(text + start, i - start);
            continue;
         }
         i++;
      }
   }
}

//! @brief Import only workspace cells still referenced after code generation and peephole removal.
static void emit_runtime_workspace_imports(void) {
   scan_runtime_workspace_imports(&es_export);
   scan_runtime_workspace_imports(&es_zp);
   scan_runtime_workspace_imports(&es_zpdata);
   scan_runtime_workspace_imports(&es_bss);
   scan_runtime_workspace_imports(&es_data);
   scan_runtime_workspace_imports(&es_rodata);
   scan_runtime_workspace_imports(&es_code);
}

//! @brief Lower compile from AST/semantic state into generated assembly or linker-visible metadata.
static void compile(ASTNode *program) {

   if (!program) {
      error_unreachable("internal NULL program node");
      // error calls exit()
   }

   if (strcmp(program->name, "program")) {
      error_unreachable("internal non program node '%s' [%s:%d.%d]",
            program->name,
            program->file, program->line, program->column);
      // error calls exit()
   }

   enforce_template_hygiene(program);
   reject_function_pointers(program);

   for (int i = 0; i < program->count; i++) {
      ASTNode *node = program->children[i];
      if (!strcmp(node->name, "include_stmt") || !strcmp(node->name, "instantiate_stmt") || !strcmp(node->name, "parameter_decl_stmt")) {
         node->handled = true;
         // ignore these, they're handled in the parser
      }
      else if (!strcmp(node->name, "xform_decl_stmt")) {
         node->handled = true;
         // literally nothing to do here, parser.y has it covered.
      }
      else if (!strcmp(node->name, "empty")) {
         node->handled = true;
         // literally nothing to do here, parser.y has it covered.
      }
   }

   for (int i = 0; i < program->count; i++) {
      ASTNode *node = program->children[i];
      if (!strcmp(node->name, "cartridge_decl_stmt")) {
         node->handled = true;
         compile_cartridge_decl_stmt(node);
      }
      else if (!strcmp(node->name, "bank_decl_stmt")) {
         node->handled = true;
         compile_bank_decl_stmt(node);
      }
   }

   for (int i = 0; i < program->count; i++) {
      ASTNode *node = program->children[i];
      if (!strcmp(node->name, "mem_decl_stmt")) {
         node->handled = true;
         compile_mem_decl_stmt(node);
      }
   }

   for (int i = 0; i < program->count; i++) {
      ASTNode *node = program->children[i];
      if (!strcmp(node->name, "type_decl_stmt")) {
         node->handled = true;
         compile_type_decl_stmt(node);
      }
   }

   for (int i = 0; i < program->count; i++) {
      ASTNode *node = program->children[i];
      if (!strcmp(node->name, "enum_decl_stmt")) {
         node->handled = true;
         compile_enum_decl_stmt(node);
      }
   }

   for (int i = 0; i < program->count; i++) {
      ASTNode *node = program->children[i];
      if (!strcmp(node->name, "struct_decl_stmt")) {
         node->handled = true;
         compile_struct_decl_stmt(node);
      }
      else if (!strcmp(node->name, "union_decl_stmt")) {
         node->handled = true;
         compile_union_decl_stmt(node);
      }
   }

   for (int i = 0; i < program->count; i++) {
      ASTNode *node = program->children[i];
      if (!strcmp(node->name, "typedef_decl_stmt")) {
         node->handled = true;
         compile_typedef_decl_stmt(node);
      }
   }

   static const char *required_types[] = {
      "void", "uint8_t"
   };

   for (size_t i = 0; i < sizeof(required_types) / sizeof(required_types[0]); i++) {
      if (!typename_exists(required_types[i])) {
         error_user("required type '%s' is not defined", required_types[i]);
      }
   }

   check_struct_union_undefined(program);
   crosscheck_struct_union_nesting(program);
   calculate_struct_union_sizes(program);
   predeclare_top_level_objects(program);
   predeclare_top_level_functions(program);
   analyze_optimizer_direct_calls(program);
   analyze_optimizer_inline_identity(program);
   {
      /* Specialization can prune a branch, which can turn a formerly
         multi-call callee into a one-effective-call candidate.  Iterate the
         specialization/reachability pair until the effective call graph stops
         changing.  Ordinary inlining itself does not require another census:
         substituting a function that has exactly one callsite moves each nested
         direct call occurrence without changing its multiplicity. */
      uint64_t previous_signature = UINT64_MAX;
      for (int iteration = 0; iteration <= program->count; iteration++) {
         uint64_t signature;
         analyze_optimizer_ref_specializations(program);
         analyze_optimizer_value_specializations(program);
         recompute_optimizer_inline_reachability(program);
         signature = inline_analysis_reachability_signature();
         if (signature == previous_signature) break;
         previous_signature = signature;
      }
   }
   analyze_optimizer_inline_candidates(program);

   for (int i = 0; i < program->count; i++) {
      ASTNode *node = program->children[i];
      if (!strcmp(node->name, "defdecl_stmt")) {
         node->handled = true;
         compile_defdecl_stmt(node);
      }
   }

   for (int i = 0; i < program->count; i++) {
      ASTNode *node = program->children[i];
      if (!node->handled) {
         error_unreachable("[%s:%d.%d] unrecognized AST node '%s'",
               node->file, node->line, node->column,
               node->name);
         // error calls exit()
      }
   }
}

//! @brief Return whether a mem declaration flag list contains one exact flag.
static bool mem_flags_contain(const ASTNode *flags, const char *want) {
   if (!flags || is_empty(flags) || !want) {
      return false;
   }
   for (int i = 0; i < flags->count; i++) {
      const char *text = (flags->children[i] && flags->children[i]->strval)
         ? flags->children[i]->strval : NULL;
      if (text && !strcmp(text, want)) {
         return true;
      }
   }
   return false;
}

//! @brief Read the optional priority of one mem declaration; absent means zero.
static long mem_decl_priority(const ASTNode *mem_decl) {
   const ASTNode *flags;
   long priority = 0;
   bool found = false;

   if (!mem_decl || strcmp(mem_decl->name, "mem_decl_stmt") || mem_decl->count < 2) {
      return 0;
   }
   flags = mem_decl->children[1];
   if (!flags || is_empty(flags)) {
      return 0;
   }
   for (int i = 0; i < flags->count; i++) {
      const char *text = (flags->children[i] && flags->children[i]->strval)
         ? flags->children[i]->strval : NULL;
      char *end = NULL;
      long value;

      if (!text || strncmp(text, "$priority:", 10)) {
         continue;
      }
      value = strtol(text + 10, &end, 0);
      if (!end || *end != '\0') {
         error_user("[%s:%d.%d] mem declaration has invalid priority flag '%s'",
                    mem_decl->file, mem_decl->line, mem_decl->column, text);
      }
      if (found) {
         error_user("[%s:%d.%d] mem declaration has multiple priority flags",
                    mem_decl->file, mem_decl->line, mem_decl->column);
      }
      priority = value;
      found = true;
   }
   return priority;
}

//! @brief Determine whether plain writable storage is guaranteed to be in page zero.
static bool default_writable_storage_is_zeropage(const ASTNode *program) {
   const ASTNode *best = NULL;
   long best_priority = LONG_MIN;
   bool tied = false;

   if (!program || strcmp(program->name, "program")) {
      return false;
   }
   for (int i = 0; i < program->count; i++) {
      const ASTNode *node = program->children[i];
      const ASTNode *flags;
      long priority;

      if (!node || strcmp(node->name, "mem_decl_stmt") || node->count < 2) {
         continue;
      }
      flags = node->children[1];
      if (!mem_flags_contain(flags, "$rw")) {
         continue;
      }
      priority = mem_decl_priority(node);
      if (!best || priority > best_priority) {
         best = node;
         best_priority = priority;
         tied = false;
      }
      else if (priority == best_priority) {
         tied = true;
      }
   }

   /* An ambiguous highest-priority region is not enough evidence for an
      addressing-mode contraction.  The assembler will retain absolute mode. */
   return best && !tied && mem_decl_is_zeropage(best);
}

static bool peephole_enabled = true;

//! @brief Enable or disable the compiler assembly peephole pass.
void set_peephole_enabled(bool enabled) {
   peephole_enabled = enabled;
}

//! @brief Run the compile stage of the compiler tool pipeline.
void do_compile(FILE *out) {

   typesizes = pair_create();
   compiler_scratch_reset();
   enumbackings = pair_create();

   emit(&es_header, "; this file produced by \"vcsc-cc1\" compiler\n");
   emit(&es_header, ".include \"vcsc-runtime.inc\"\n");
   emit(&es_code,   ".segment \"CODE\"\n");
   emit(&es_rodata, ".segment \"RODATA\"\n");
   emit(&es_data,   ".segment \"DATA\"\n");
   emit(&es_bss,    ".segment \"BSS\"\n");
   emit(&es_zp,     ".segment \"ZEROPAGE\"\n");
   emit(&es_zpdata, ".segment \"ZEROPAGE\"\n");
   emit(&es_import, "; imports\n");
   emit(&es_export, "; exports\n");

   compile(root);
   if (default_writable_storage_is_zeropage(root)) {
      emit(&es_export, ".segmentaddrsize \"BSS\", zp\n");
      emit(&es_export, ".segmentaddrsize \"DATA\", zp\n");
   }
   analyze_static_parameter_call_graph();
   validate_main_signature(resolve_function_designator_target("main"));
   emit_symbol_backed_call_graph_metadata();
   emit_runtime_global_init_function();
   compiler_scratch_emit_bss();
   emit_peephole_optimize(&es_code, peephole_enabled);
   emit_runtime_workspace_imports();

   emit_print(&es_header, out);
   fprintf(out, "\n");

   emit_print(&es_import, out);
   fprintf(out, "\n");

   emit_print(&es_export, out);
   fprintf(out, "\n");

   emit_print(&es_zp, out);
   fprintf(out, "\n");

   emit_print(&es_zpdata, out);
   fprintf(out, "\n");

   emit_print(&es_bss, out);
   fprintf(out, "\n");

   emit_print(&es_data, out);
   fprintf(out, "\n");

   emit_print(&es_rodata, out);
   fprintf(out, "\n");

   emit_print(&es_code, out);
}
