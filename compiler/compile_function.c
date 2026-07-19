//! @file compiler/compile_function.c
//! @brief Implements function ABI lowering for the VCSC compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>
#include <limits.h>

#include "ast.h"
#include "compile.h"
#include "compile_function.h"
#include "compile_init.h"
#include "compile_internal.h"
#include "compile_lvalue.h"
#include "compile_function_registry.h"
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

void emit_mem_region_metadata_for_modifiers(const ASTNode *origin, const ASTNode *modifiers);

typedef struct CallGraphNode {
   const ASTNode *fn;
   char *sym;
   bool has_static_activation;
} CallGraphNode;

typedef struct CallGraphEdge {
   int from;
   int to;
} CallGraphEdge;


static bool implementation_name_reserved(const char *name);
static bool symbol_backed_metadata_function_name(char *buf, size_t bufsize, const char *sym);
static bool symbol_backed_metadata_edge_name(char *buf, size_t bufsize, const char *caller_sym, const char *callee_sym);
static void call_graph_tarjan_visit(int v, int *index_counter, int *stack, int *stack_top,
                                    int *indices, int *lowlink, unsigned char *onstack,
                                    int *component, int *component_sizes, int *component_count);

static CallGraphNode *call_graph_nodes = NULL;
static int call_graph_node_count = 0;
static CallGraphEdge *call_graph_edges = NULL;
static int call_graph_edge_count = 0;
int current_call_graph_node = -1;
const ASTNode *current_call_graph_function = NULL;

//! @brief Return whether a function return type is plain void.
bool return_type_is_void(const ASTNode *type, const ASTNode *declarator) {
   const char *name = type_name_from_node(type);

   return name && !strcmp(name, "void") &&
          declarator_pointer_depth(declarator) == 0 &&
          declarator_array_count(declarator) == 0;
}

//! @brief Return whether a function return type is supported by the VCSC memory-return ABI.
bool return_type_is_supported(const ASTNode *type, const ASTNode *declarator) {
   int size;

   if (!type) {
      return false;
   }

   if (return_type_is_void(type, declarator)) {
      return true;
   }

   if (declarator_array_count(declarator) > 0) {
      return false;
   }

   size = declarator_value_size(type, declarator);

   /* A pointer value is always a 16-bit little-endian address. */
   if (declarator_pointer_depth(declarator) > 0) {
      return size == 2;
   }

   if (type_is_aggregate(type) || !type_is_promotable_integer(type)) {
      return false;
   }

   if (type_is_bcd_integer(type)) {
      return size >= 1 && size <= 4;
   }

   return size >= 1 && size <= 4;
}

//! @brief Return whether a supported function type has a value return object.
bool return_type_has_value(const ASTNode *type, const ASTNode *declarator) {
   return return_type_is_supported(type, declarator) &&
          !return_type_is_void(type, declarator);
}

//! @brief Return whether a function owns a callee-side return object.
bool function_has_return_object(const ASTNode *fn) {
   const ASTNode *declarator;

   if (!fn) {
      return false;
   }

   declarator = function_declarator_node(fn);
   return return_type_has_value(function_return_type(fn),
                                function_return_declarator_from_callable(declarator));
}

//! @brief Build the hidden callee-owned return-object symbol for a function.
bool function_return_symbol_name(const ASTNode *fn, char *buf, size_t bufsize) {
   char function_sym[256];
   char raw[320];

   if (!fn || !buf || bufsize == 0 ||
       !function_symbol_name(fn, declarator_name(function_declarator_node(fn)),
                             function_sym, sizeof(function_sym))) {
      return false;
   }
   if ((size_t) snprintf(raw, sizeof(raw), "%s$__return", function_sym) >= sizeof(raw)) {
      return false;
   }
   return format_user_asm_symbol(raw, buf, bufsize);
}

//! @brief Reject function return types outside the VCSC memory-return ABI.
void validate_function_return_type(const ASTNode *fn) {
   const ASTNode *type;
   const ASTNode *declarator;
   const ASTNode *return_decl;
   const char *name;

   if (!fn) {
      return;
   }

   type = function_return_type(fn);
   declarator = function_declarator_node(fn);
   return_decl = function_return_declarator_from_callable(declarator);
   if (return_type_is_supported(type, return_decl)) {
      return;
   }

   name = declarator_name(declarator);
   error_user("[%s:%d.%d] function '%s' has an unsupported return type; functions may return only void, a supported binary integer, a packed-BCD integer through bcd32_t, or a 16-bit pointer",
              fn->file, fn->line, fn->column,
              (name && *name) ? name : "<unnamed>");
}

//! @brief Return whether a parameter of a directly named function uses callee-owned storage.
bool function_parameter_uses_symbol_storage(const ASTNode *fn, const ASTNode *parameter) {
   (void) fn;
   return parameter && !parameter_is_void(parameter);
}

//! @brief Handle function parameter symbol name logic for compiler function lowering.
bool function_parameter_symbol_name(const ASTNode *fn, const ASTNode *parameter, int index,
                                           char *buf, size_t bufsize, bool *is_zeropage_out) {
   const ASTNode *ptype;
   const ASTNode *pdecl;
   const ASTNode *decl_specs;
   const ASTNode *modifiers;
   const char *pname;
   char callee_sym[256];
   Context callee_ctx;
   ContextEntry pentry;

   if (!fn || !parameter || !buf || bufsize == 0 ||
       !function_parameter_uses_symbol_storage(fn, parameter)) {
      return false;
   }

   ptype = parameter_type(parameter);
   pdecl = parameter_declarator(parameter);
   decl_specs = parameter_decl_specifiers(parameter);
   modifiers = (decl_specs && decl_specs->count > 0) ? decl_specs->children[0] : NULL;
   pname = parameter_name(parameter, index);
   if (!ptype || !pname) {
      return false;
   }

   if (!function_symbol_name(fn, declarator_name(function_declarator_node(fn)), callee_sym, sizeof(callee_sym))) {
      return false;
   }

   memset(&callee_ctx, 0, sizeof(callee_ctx));
   callee_ctx.name = callee_sym;

   pentry.name = (char *) pname;
   pentry.type = ptype;
   pentry.declarator = pdecl;
   pentry.is_zeropage = modifiers_imply_zeropage(modifiers);
   pentry.is_static = !pentry.is_zeropage;
   pentry.is_global = false;
   pentry.is_ref = parameter_is_ref(parameter);
   pentry.is_absolute_ref = false;
   pentry.read_expr = NULL;
   pentry.write_expr = NULL;
   pentry.offset = 0;
   pentry.size = declarator_storage_size(ptype, pdecl);

   if (is_zeropage_out) {
      *is_zeropage_out = pentry.is_zeropage;
   }

   return entry_symbol_name(&callee_ctx, &pentry, buf, bufsize);
}

//! @brief Handle implementation-reserved name logic for compiler function lowering.
static bool implementation_name_reserved(const char *name) {
   return name && !strcmp(name, "$$");
}

//! @brief Validate implementation-reserved names before later compiler stages depend on them.
void validate_nonreserved_implementation_name(const char *name, const ASTNode *node) {
   if (!node || !implementation_name_reserved(name)) {
      return;
   }
   if (name && !strcmp(name, "$$")) {
      error_user("[%s:%d.%d] '$$' is reserved for the current function's return object; do not declare it. "
                 "Inside a non-void function body, assign to '$$' directly, then use 'return;' to leave the function.",
                 node->file, node->line, node->column);
   }
   error_user("[%s:%d.%d] '%s' is a reserved implementation name", node->file, node->line, node->column, name);
}

//! @brief Validate function implementation-reserved names before later compiler stages depend on them.
void validate_function_nonreserved_implementation_names(const ASTNode *fn) {
   const ASTNode *declarator;
   const ASTNode *params;

   if (!fn) {
      return;
   }

   declarator = function_declarator_node(fn);
   if (declarator) {
      validate_nonreserved_implementation_name(declarator_name(declarator), fn);
      params = declarator_parameter_list(declarator);
      if (params && !is_empty(params)) {
         for (int i = 0; i < params->count; i++) {
            const ASTNode *parameter = params->children[i];
            const ASTNode *pdecl = parameter ? parameter_declarator(parameter) : NULL;
            validate_nonreserved_implementation_name(pdecl ? declarator_name(pdecl) : NULL, parameter ? parameter : fn);
         }
      }
   }
}

//! @brief Validate function parameter storage modifier combinations before later compiler stages depend on them.
void validate_function_parameter_storage_modifiers(const ASTNode *fn) {
   const ASTNode *declarator;
   const ASTNode *params;
   const char *fname;

   if (!fn) {
      return;
   }

   declarator = function_declarator_node(fn);
   fname = declarator_name(declarator);
   if (!fname || !*fname) {
      fname = "<unnamed>";
   }

   params = declarator_parameter_list(declarator);
   if (!params || is_empty(params)) {
      return;
   }

   for (int i = 0; i < params->count; i++) {
      const ASTNode *parameter = params->children[i];
      const ASTNode *decl_specs = parameter ? parameter_decl_specifiers(parameter) : NULL;
      const ASTNode *modifiers = (decl_specs && decl_specs->count > 0) ? decl_specs->children[0] : NULL;
      const ASTNode *pdecl = parameter ? parameter_declarator(parameter) : NULL;
      const char *memname;
      const char *pname;

      if (!parameter || parameter_is_void(parameter) || !modifiers) {
         continue;
      }

      if (!has_modifier((ASTNode *) modifiers, "static")) {
         continue;
      }

      memname = find_mem_modifier_name(modifiers);
      if (!memname) {
         continue;
      }

      pname = pdecl ? declarator_name(pdecl) : NULL;
      if (pname && *pname) {
         error_user("[%s:%d.%d] parameter '%s' of function '%s' combines 'static' with mem region '%s'. This is redundant and ambiguous: use '%s <type> %s' to place the symbol-backed parameter in that mem region, or use 'static <type> %s' for default BSS-backed parameter storage; do not write both.",
                    parameter->file, parameter->line, parameter->column,
                    pname, fname, memname, memname, pname, pname);
      }

      error_user("[%s:%d.%d] parameter %d of function '%s' combines 'static' with mem region '%s'. This is redundant and ambiguous: use '%s <type>' to place the symbol-backed parameter in that mem region, or use 'static <type>' for default BSS-backed parameter storage; do not write both.",
                 parameter->file, parameter->line, parameter->column,
                 i + 1, fname, memname, memname);
   }
}

//! @brief Handle build function context logic for compiler function lowering.
void build_function_context(const ASTNode *node, Context *ctx) {
   const ASTNode *declarator = node->children[1];
   const ASTNode *params = declarator_parameter_list(declarator);
   int i = 0;

   if (params && !is_empty(params)) {
      for (int j = 0; j < params->count; j++) {
         const ASTNode *parameter = params->children[j];
         const ASTNode *type = parameter_type(parameter);
         const char *name = parameter_name(parameter, i);
         const ASTNode *decl_specs = parameter_decl_specifiers(parameter);
         const ASTNode *modifiers = (decl_specs && decl_specs->count > 0) ? decl_specs->children[0] : NULL;
         const ASTNode *param_decl = call_adjusted_parameter_declarator(parameter_declarator(parameter), parameter_is_ref(parameter));
         int slot_size;
         ContextEntry *entry;

         if (!type || parameter_is_void(parameter)) {
            continue;
         }

         slot_size = parameter_storage_size(parameter);
         if (modifiers_imply_zeropage(modifiers)) {
            ctx_zeropage(ctx, type, name);
         }
         else {
            ctx_static(ctx, type, name);
         }
         entry = (ContextEntry *) set_get(ctx->vars, name);
         entry->size = slot_size;
         entry->declarator = param_decl;
         entry->is_ref = parameter_is_ref(parameter);
         i++;
      }
   }


   if (function_has_return_object(node)) {
      ContextEntry *return_entry;
      ctx_zeropage(ctx, node->children[0]->children[1], "$$");
      return_entry = (ContextEntry *) set_get(ctx->vars, "$$");
      if (!return_entry) {
         error_unreachable("internal missing memory return object");
      }
      /* Keep the source-level lookup key "$$", but use a plain assembler
         symbol component. Repeated '$' characters are ambiguous in the
         object-format expression encoder. */
      free((void *) return_entry->name);
      return_entry->name = strdup("__return");
      if (!return_entry->name) {
         error_unreachable("out of memory");
      }
      return_entry->declarator = function_return_declarator_from_callable(declarator);
      return_entry->size = declarator_value_size(return_entry->type, return_entry->declarator);
   }

}

//! @brief Return whether function has static parameters in compiler function lowering.
bool function_has_static_parameters(const ASTNode *fn) {
   const ASTNode *declarator = function_declarator_node(fn);
   const ASTNode *params = declarator_parameter_list(declarator);

   if (!params || is_empty(params)) {
      return false;
   }

   for (int i = 0; i < params->count; i++) {
      const ASTNode *parameter = params->children[i];
      if (function_parameter_uses_symbol_storage(fn, parameter)) {
         return true;
      }
   }

   return false;
}

//! @brief Handle call graph node index for function logic for compiler function lowering.
int call_graph_node_index_for_function(const ASTNode *fn) {
   char sym[256];

   if (!fn) {
      return -1;
   }

   for (int i = 0; i < call_graph_node_count; i++) {
      if (call_graph_nodes[i].fn == fn) {
         return i;
      }
   }

   if (!function_symbol_name(fn, declarator_name(function_declarator_node(fn)), sym, sizeof(sym))) {
      return -1;
   }

   call_graph_nodes = (CallGraphNode *) realloc(call_graph_nodes, sizeof(CallGraphNode) * (call_graph_node_count + 1));
   if (!call_graph_nodes) {
      error_unreachable("out of memory");
   }
   call_graph_nodes[call_graph_node_count].fn = fn;
   call_graph_nodes[call_graph_node_count].sym = strdup(sym);
   /* Every defined VCSC function has a single static activation, even when
      that activation is empty. Recursion and mutual recursion are therefore
      forbidden uniformly rather than only for parameterized functions. */
   call_graph_nodes[call_graph_node_count].has_static_activation = function_has_body(fn);
   return call_graph_node_count++;
}

//! @brief Handle symbol backed metadata function name logic for compiler function lowering.
static bool symbol_backed_metadata_function_name(char *buf, size_t bufsize, const char *sym) {
   if (!buf || bufsize == 0 || !sym || !*sym) {
      return false;
   }
   if ((size_t) snprintf(buf, bufsize, SYMBOL_BACKED_META_PREFIX "F$%s", sym) >= bufsize) {
      return false;
   }
   return true;
}

//! @brief Handle symbol backed metadata edge name logic for compiler function lowering.
static bool symbol_backed_metadata_edge_name(char *buf, size_t bufsize, const char *caller_sym, const char *callee_sym) {
   if (!buf || bufsize == 0 || !caller_sym || !*caller_sym || !callee_sym || !*callee_sym) {
      return false;
   }
   if ((size_t) snprintf(buf, bufsize, SYMBOL_BACKED_META_PREFIX "E$%s$%s", caller_sym, callee_sym) >= bufsize) {
      return false;
   }
   return true;
}

//! @brief Add call graph edge to compiler function lowering state, growing storage or preserving uniqueness as needed.
void record_call_graph_edge(const ASTNode *caller, const ASTNode *callee) {
   int from = call_graph_node_index_for_function(caller);
   int to = call_graph_node_index_for_function(callee);

   if (from < 0 || to < 0) {
      return;
   }

   for (int i = 0; i < call_graph_edge_count; i++) {
      if (call_graph_edges[i].from == from && call_graph_edges[i].to == to) {
         return;
      }
   }

   call_graph_edges = (CallGraphEdge *) realloc(call_graph_edges, sizeof(CallGraphEdge) * (call_graph_edge_count + 1));
   if (!call_graph_edges) {
      error_unreachable("out of memory");
   }
   call_graph_edges[call_graph_edge_count].from = from;
   call_graph_edges[call_graph_edge_count].to = to;
   call_graph_edge_count++;
}

//! @brief Handle call graph tarjan visit logic for compiler function lowering.
static void call_graph_tarjan_visit(int v, int *index_counter, int *stack, int *stack_top,
                                    int *indices, int *lowlink, unsigned char *onstack,
                                    int *component, int *component_sizes, int *component_count) {
   indices[v] = *index_counter;
   lowlink[v] = *index_counter;
   (*index_counter)++;
   stack[(*stack_top)++] = v;
   onstack[v] = 1;

   for (int i = 0; i < call_graph_edge_count; i++) {
      if (call_graph_edges[i].from != v) {
         continue;
      }
      int w = call_graph_edges[i].to;
      if (indices[w] < 0) {
         call_graph_tarjan_visit(w, index_counter, stack, stack_top, indices, lowlink, onstack, component, component_sizes, component_count);
         if (lowlink[w] < lowlink[v]) {
            lowlink[v] = lowlink[w];
         }
      }
      else if (onstack[w] && indices[w] < lowlink[v]) {
         lowlink[v] = indices[w];
      }
   }

   if (lowlink[v] == indices[v]) {
      int cid = (*component_count)++;
      component_sizes[cid] = 0;
      for (;;) {
         int w = stack[--(*stack_top)];
         onstack[w] = 0;
         component[w] = cid;
         component_sizes[cid]++;
         if (w == v) {
            break;
         }
      }
   }
}

//! @brief Handle analyze static parameter call graph logic for compiler function lowering.
void analyze_static_parameter_call_graph(void) {
   int n = call_graph_node_count;
   int *indices;
   int *lowlink;
   int *stack;
   int *component;
   int *component_sizes;
   unsigned char *onstack;
   unsigned char *component_has_static;
   unsigned char *component_has_cycle;
   int stack_top = 0;
   int index_counter = 0;
   int component_count = 0;

   if (n <= 0) {
      return;
   }

   indices = (int *) malloc(sizeof(int) * n);
   lowlink = (int *) malloc(sizeof(int) * n);
   stack = (int *) malloc(sizeof(int) * n);
   component = (int *) malloc(sizeof(int) * n);
   component_sizes = (int *) calloc(n, sizeof(int));
   onstack = (unsigned char *) calloc(n, sizeof(unsigned char));
   component_has_static = (unsigned char *) calloc(n, sizeof(unsigned char));
   component_has_cycle = (unsigned char *) calloc(n, sizeof(unsigned char));
   if (!indices || !lowlink || !stack || !component || !component_sizes || !onstack || !component_has_static || !component_has_cycle) {
      error_unreachable("out of memory");
   }

   for (int i = 0; i < n; i++) {
      indices[i] = -1;
      lowlink[i] = -1;
      component[i] = -1;
   }

   for (int i = 0; i < n; i++) {
      if (indices[i] < 0) {
         call_graph_tarjan_visit(i, &index_counter, stack, &stack_top, indices, lowlink, onstack, component, component_sizes, &component_count);
      }
   }

   for (int i = 0; i < n; i++) {
      if (component[i] >= 0 && call_graph_nodes[i].has_static_activation) {
         component_has_static[component[i]] = 1;
      }
   }
   for (int i = 0; i < component_count; i++) {
      if (component_sizes[i] > 1) {
         component_has_cycle[i] = 1;
      }
   }
   for (int i = 0; i < call_graph_edge_count; i++) {
      if (component[call_graph_edges[i].from] == component[call_graph_edges[i].to]) {
         component_has_cycle[component[call_graph_edges[i].from]] = 1;
      }
   }

   for (int i = 0; i < component_count; i++) {
      if (!component_has_cycle[i] || !component_has_static[i]) {
         continue;
      }

      for (int j = 0; j < n; j++) {
         if (component[j] != i || !call_graph_nodes[j].has_static_activation) {
            continue;
         }
         error_user("call graph cycle reaches function '%s' with static activation storage", declarator_name(function_declarator_node((ASTNode *) call_graph_nodes[j].fn)));
      }
   }

   free(indices);
   free(lowlink);
   free(stack);
   free(component);
   free(component_sizes);
   free(onstack);
   free(component_has_static);
   free(component_has_cycle);
}

//! @brief Emit symbol backed call graph metadata for compiler function lowering diagnostics or output files.
void emit_symbol_backed_call_graph_metadata(void) {
   char meta[768];

   for (int i = 0; i < call_graph_node_count; i++) {
      if (!call_graph_nodes[i].has_static_activation || !function_has_body(call_graph_nodes[i].fn)) {
         continue;
      }
      if (!symbol_backed_metadata_function_name(meta, sizeof(meta), call_graph_nodes[i].sym)) {
         error_user("symbol-backed metadata name too long for function '%s'", call_graph_nodes[i].sym);
      }
      emit(&es_export, ".export %s\n", meta);
      emit(&es_export, "%s = 0\n", meta);
   }

   for (int i = 0; i < call_graph_edge_count; i++) {
      int from = call_graph_edges[i].from;
      int to = call_graph_edges[i].to;

      if (from < 0 || from >= call_graph_node_count || to < 0 || to >= call_graph_node_count) {
         continue;
      }
      if (!function_has_body(call_graph_nodes[from].fn)) {
         continue;
      }
      if (!symbol_backed_metadata_edge_name(meta, sizeof(meta), call_graph_nodes[from].sym, call_graph_nodes[to].sym)) {
         error_user("symbol-backed metadata edge name too long for '%s' -> '%s'", call_graph_nodes[from].sym, call_graph_nodes[to].sym);
      }
      emit(&es_export, ".export %s\n", meta);
      emit(&es_export, "%s = 0\n", meta);
   }
}

//! @brief Emit function parameter storage for compiler function lowering diagnostics or output files.
void emit_function_parameter_storage(const ASTNode *node, Context *ctx) {
   const ASTNode *declarator = node->children[1];
   const ASTNode *params = declarator_parameter_list(declarator);

   if (!params || is_empty(params)) {
      return;
   }

   for (int i = 0; i < params->count; i++) {
      const ASTNode *parameter = params->children[i];
      const ASTNode *type = parameter_type(parameter);
      const ASTNode *decl_specs = parameter_decl_specifiers(parameter);
      const ASTNode *modifiers = (decl_specs && decl_specs->count > 0) ? decl_specs->children[0] : NULL;
      const char *name = parameter_name(parameter, i);
      const ContextEntry *entry;
      char sym[256];

      if (!type || !function_parameter_uses_symbol_storage(node, parameter)) {
         continue;
      }

      emit_mem_region_metadata_for_modifiers(parameter, modifiers);

      entry = (const ContextEntry *) set_get(ctx->vars, name);
      if (!entry) {
         continue;
      }
      if (!entry_symbol_name(ctx, entry, sym, sizeof(sym))) {
         continue;
      }

      if (entry->is_zeropage) {
         char segbuf[256];
         build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "ZEROPAGE");
         emit(&es_zp, ".segment \"%s\"\n", segbuf);
         emit(&es_zp, "%s:\n", sym);
         emit(&es_zp, "\t.res %d\n", entry->size);
      }
      else {
         char segbuf[256];
         build_named_storage_segment(segbuf, sizeof(segbuf), modifiers, "BSS");
         emit(&es_bss, ".segment \"%s\"\n", segbuf);
         emit(&es_bss, "%s:\n", sym);
         emit(&es_bss, "\t.res %d\n", entry->size);
      }
   }
}

//! @brief Emit function parameter exports for compiler function lowering diagnostics or output files.
void emit_function_parameter_exports(const ASTNode *node) {
   const ASTNode *declarator = node->children[1];
   const ASTNode *params = declarator_parameter_list(declarator);

   if (!params || is_empty(params)) {
      return;
   }

   for (int i = 0; i < params->count; i++) {
      const ASTNode *parameter = params->children[i];
      char sym[256];
      bool is_zeropage = false;

      if (!function_parameter_uses_symbol_storage(node, parameter)) {
         continue;
      }
      if (!function_parameter_symbol_name(node, parameter, i, sym, sizeof(sym), &is_zeropage)) {
         continue;
      }
      emit(&es_export,
           is_zeropage ? ".zpexport %s\n" : ".export %s\n",
           sym);
   }
}
