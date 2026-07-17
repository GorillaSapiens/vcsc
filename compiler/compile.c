//! @file compiler/compile.c
//! @brief Implements compiler front-end orchestration for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>

#include "ast.h"
#include "compile.h"
#include "compile_expr.h"
#include "compile_function.h"
#include "compile_init.h"
#include "compile_internal.h"
#include "compile_toplevel.h"
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

   reject_function_pointers(program);

   for (int i = 0; i < program->count; i++) {
      ASTNode *node = program->children[i];
      if (!strcmp(node->name, "include_stmt")) {
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

   static const char *required_types[] = {
      "void", "uint8_t"
   };

   for (size_t i = 0; i < sizeof(required_types) / sizeof(required_types[0]); i++) {
      if (!typename_exists(required_types[i])) {
         error_user("required type '%s' is not defined", required_types[i]);
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

   check_struct_union_undefined(program);
   crosscheck_struct_union_nesting(program);
   calculate_struct_union_sizes(program);
   predeclare_top_level_functions(program);

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

//! @brief Run the compile stage of the compiler tool pipeline.
void do_compile(FILE *out) {

   typesizes = pair_create();
   enumbackings = pair_create();

   emit(&es_header, "; this file produced by \"n65c\" compiler\n");
   emit(&es_header, ".include \"nlib.inc\"\n");
   emit(&es_code,   ".segment \"CODE\"\n");
   emit(&es_rodata, ".segment \"RODATA\"\n");
   emit(&es_data,   ".segment \"DATA\"\n");
   emit(&es_bss,    ".segment \"BSS\"\n");
   emit(&es_zp,     ".segment \"ZEROPAGE\"\n");
   emit(&es_zpdata, ".segment \"ZEROPAGE\"\n");
   emit(&es_import, "; imports\n");
   emit(&es_export, "; exports\n");

   compile(root);
   analyze_static_parameter_call_graph();
   emit_symbol_backed_call_graph_metadata();
   emit_runtime_global_init_function();
   emit_peephole_optimize(&es_code);

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
