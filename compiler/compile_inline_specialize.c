//! @file compiler/compile_inline_specialize.c
//! @brief Plans and applies single-callsite parameter specialization.
//! @ingroup compiler

#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "ast.h"
#include "compile_declarator.h"
#include "compile_function.h"
#include "compile_function_registry.h"
#include "compile_init.h"
#include "compile_inline_specialize.h"
#include "compile_lvalue.h"
#include "compile_internal.h"
#include "compile_support.h"
#include "compile_type.h"
#include "messages.h"

typedef struct RefPlan {
   const ASTNode *fn;
   int parameter_index;
   char *read_expr;
   char *write_expr;
   int offset;
   bool is_zeropage;
   bool has_split_alias_delta;
   int split_alias_delta;
} RefPlan;

static RefPlan *plans;
static size_t plan_count;

static void reset_plans(void) {
   for (size_t i = 0; i < plan_count; i++) {
      free(plans[i].read_expr);
      free(plans[i].write_expr);
   }
   free(plans);
   plans = NULL;
   plan_count = 0;
}

static void add_plan(const ASTNode *fn, int parameter_index,
                     const char *read_expr, const char *write_expr,
                     int offset, bool is_zeropage,
                     bool has_split_alias_delta, int split_alias_delta) {
   RefPlan *grown = (RefPlan *)realloc(plans, sizeof(*plans) * (plan_count + 1));
   RefPlan *plan;
   if (!grown) {
      error_unreachable("out of memory recording ref specialization");
   }
   plans = grown;
   plan = &plans[plan_count++];
   memset(plan, 0, sizeof(*plan));
   plan->fn = fn;
   plan->parameter_index = parameter_index;
   plan->read_expr = read_expr ? strdup(read_expr) : NULL;
   plan->write_expr = write_expr ? strdup(write_expr) : NULL;
   plan->offset = offset;
   plan->is_zeropage = is_zeropage;
   plan->has_split_alias_delta = has_split_alias_delta;
   plan->split_alias_delta = split_alias_delta;
   if ((read_expr && !plan->read_expr) || (write_expr && !plan->write_expr)) {
      error_unreachable("out of memory recording ref specialization address");
   }
}

//! @brief Return whether an asm statement text contains one exact identifier token.
static bool asm_text_mentions(const char *text, const char *name) {
   size_t n;
   if (!text || !name || !*name) {
      return false;
   }
   n = strlen(name);
   for (const char *p = text; (p = strstr(p, name)) != NULL; p++) {
      unsigned char before = p == text ? 0 : (unsigned char)p[-1];
      unsigned char after = (unsigned char)p[n];
      bool before_id = before == '_' || before == '$' ||
                       (before >= '0' && before <= '9') ||
                       (before >= 'A' && before <= 'Z') ||
                       (before >= 'a' && before <= 'z');
      bool after_id = after == '_' || after == '$' ||
                      (after >= '0' && after <= '9') ||
                      (after >= 'A' && after <= 'Z') ||
                      (after >= 'a' && after <= 'z');
      if (!before_id && !after_id) {
         return true;
      }
   }
   return false;
}

//! @brief Return whether a subtree contains any inline assembly statement.
static bool subtree_contains_asm(const ASTNode *node) {
   if (!node) {
      return false;
   }
   if (!strcmp(node->name, "asm_stmt")) {
      return true;
   }
   for (int i = 0; i < node->count; i++) {
      if (subtree_contains_asm(node->children[i])) {
         return true;
      }
   }
   return false;
}

//! @brief Conservatively detect inline-assembly references to a function ABI symbol.
static bool subtree_asm_mentions(const ASTNode *node, const char *source_name,
                                 const char *asm_name) {
   if (!node) {
      return false;
   }
   if (!strcmp(node->name, "asm_stmt")) {
      for (int i = 0; i < node->count; i++) {
         const ASTNode *leaf = node->children[i];
         if (leaf && leaf->strval &&
             (asm_text_mentions(leaf->strval, source_name) ||
              asm_text_mentions(leaf->strval, asm_name))) {
            return true;
         }
      }
   }
   for (int i = 0; i < node->count; i++) {
      if (subtree_asm_mentions(node->children[i], source_name, asm_name)) {
         return true;
      }
   }
   return false;
}

//! @brief Return a local declaration item's optional absolute address specification.
static const ASTNode *local_decl_address_spec(const ASTNode *decl) {
   const ASTNode *sub;
   if (!decl || decl->count <= 2) {
      return NULL;
   }
   sub = decl->children[2];
   if (!sub || strcmp(sub->name, "decl_subitem") || sub->count <= 1) {
      return NULL;
   }
   return sub->children[1];
}

static const char *specialize_address_read_expr(const ASTNode *node) {
   if (!node || is_empty(node)) return NULL;
   if (!strcmp(node->name, "rw_addr_spec")) {
      return node->count > 0 && node->children[0] && !is_empty(node->children[0])
         ? node->children[0]->strval : NULL;
   }
   return node->strval;
}

static const char *specialize_address_write_expr(const ASTNode *node) {
   if (!node || is_empty(node)) return NULL;
   if (!strcmp(node->name, "rw_addr_spec")) {
      return node->count > 1 && node->children[1] && !is_empty(node->children[1])
         ? node->children[1]->strval : NULL;
   }
   return node->strval;
}

//! @brief Add local declaration facts to a silent caller context used only by planning.
static void analysis_add_local_decl(const ASTNode *decl, Context *ctx) {
   const ASTNode *modifiers;
   const ASTNode *type;
   const ASTNode *declarator;
   const ASTNode *addrspec;
   const char *name;
   ContextEntry *entry;
   int size;

   if (!decl || !ctx || decl->count < 3) return;
   modifiers = decl->children[0];
   type = decl->children[1];
   declarator = decl_node_declarator(decl);
   addrspec = local_decl_address_spec(decl);
   name = declarator ? declarator_name(declarator) : NULL;
   if (!type || !declarator || !name || !*name || set_get(ctx->vars, name)) return;
   size = declarator_storage_size(type, declarator);

   if (addrspec && !is_empty(addrspec)) {
      entry = (ContextEntry *)calloc(1, sizeof(*entry));
      if (!entry) error_unreachable("out of memory planning local ref specialization");
      entry->name = strdup(name);
      if (!entry->name) error_unreachable("out of memory planning local ref specialization name");
      entry->type = type;
      entry->declarator = declarator;
      entry->is_absolute_ref = true;
      entry->read_expr = specialize_address_read_expr(addrspec);
      entry->write_expr = specialize_address_write_expr(addrspec);
      entry->object_is_const = declaration_const_applies_to_object(modifiers, declarator);
      entry->pointer_access = declaration_pointer_access(modifiers, declarator);
      entry->size = size;
      set_add(ctx->vars, strdup(name), entry);
      return;
   }

   if (modifiers_imply_zeropage(modifiers)) ctx_zeropage(ctx, type, name);
   else ctx_static(ctx, type, name);
   entry = (ContextEntry *)set_get(ctx->vars, name);
   if (!entry) return;
   entry->declarator = declarator;
   entry->size = size;
   entry->object_is_const = declaration_const_applies_to_object(modifiers, declarator);
   entry->pointer_access = declaration_pointer_access(modifiers, declarator);
   if (modifiers_imply_split_address(modifiers)) {
      char symbol[256];
      if (entry_symbol_name(ctx, entry, symbol, sizeof(symbol))) {
         init_split_mem_entry_addresses_for_symbol(entry, symbol, modifiers);
      }
   }
}

//! @brief Recursively collect caller locals without emitting storage or metadata.
static void analysis_collect_locals(const ASTNode *node, Context *ctx) {
   if (!node || !ctx) return;
   if (!strcmp(node->name, "defdecl_stmt") && node->count > 0) {
      const ASTNode *list = node->children[0];
      if (list) {
         for (int i = 0; i < list->count; i++) analysis_add_local_decl(list->children[i], ctx);
      }
      return;
   }
   for (int i = 0; i < node->count; i++) analysis_collect_locals(node->children[i], ctx);
}

//! @brief Build enough of the unique caller context to resolve fixed lvalue addresses.
static bool build_analysis_caller_context(const ASTNode *caller, Context *ctx) {
   char caller_sym[256];
   const char *name;
   if (!caller || !ctx || !function_has_body(caller)) return false;
   name = declarator_name(function_declarator_node(caller));
   if (!name || !function_symbol_name(caller, name, caller_sym, sizeof(caller_sym))) return false;
   memset(ctx, 0, sizeof(*ctx));
   ctx->name = strdup(caller_sym);
   if (!ctx->name) error_unreachable("out of memory naming specialization caller context");
   ctx->activation_owner = ctx->name;
   ctx->vars = new_set();
   build_function_context(caller, ctx);
   /* Plans found for the caller on an earlier fixed-point iteration turn its
      specialized ref formals into fixed absolute bindings here.  That lets a
      known address propagate through chains such as main -> middle(ref) ->
      leaf(ref), regardless of source definition order. */
   apply_optimizer_ref_specializations(caller, ctx);
   apply_optimizer_value_specializations(caller, ctx);
   analysis_collect_locals(caller->children[2], ctx);
   return true;
}

//! @brief Resolve one actual to fixed read/write base expressions plus byte offset.
static bool fixed_caller_actual(ASTNode *actual, const ASTNode *caller,
                                ContextEntry *actual_entry,
                                char *read_buf, size_t read_size,
                                char *write_buf, size_t write_size,
                                int *offset_out) {
   Context caller_ctx;
   LValueRef lv;
   char symbol[256];

   if (!build_analysis_caller_context(caller, &caller_ctx) ||
       !resolve_ref_argument_lvalue(&caller_ctx, actual, &lv) ||
       lv.is_bitfield || lv.indirect || lv.needs_runtime_address ||
       (lv.is_ref && !lv.is_absolute_ref)) {
      return false;
   }

   memset(actual_entry, 0, sizeof(*actual_entry));
   actual_entry->name = lv.name;
   actual_entry->type = lv.type;
   actual_entry->declarator = lv.declarator;
   actual_entry->is_static = lv.is_static;
   actual_entry->is_zeropage = lv.is_zeropage;
   actual_entry->is_global = lv.is_global;
   actual_entry->is_absolute_ref = lv.is_absolute_ref;
   actual_entry->read_expr = lv.read_expr;
   actual_entry->write_expr = lv.write_expr;
   actual_entry->has_split_alias_delta = lv.has_split_alias_delta;
   actual_entry->split_alias_delta = lv.split_alias_delta;
   actual_entry->object_is_const = lv.object_is_const;
   actual_entry->pointer_access = lv.pointer_access;
   actual_entry->size = lv.size;

   read_buf[0] = '\0';
   write_buf[0] = '\0';
   if (lv.is_absolute_ref) {
      if (lv.read_expr) snprintf(read_buf, read_size, "%s", lv.read_expr);
      if (lv.write_expr) snprintf(write_buf, write_size, "%s", lv.write_expr);
   }
   else {
      if (!lvalue_fixed_symbol_name(&caller_ctx, &lv, symbol, sizeof(symbol))) return false;
      snprintf(read_buf, read_size, "%s", symbol);
      snprintf(write_buf, write_size, "%s", symbol);
   }
   if (offset_out) *offset_out = lv.offset;
   return true;
}

//! @brief Return whether an actual's fixed address capabilities satisfy one ref formal.
static bool fixed_actual_supports_formal(const ContextEntry *actual,
                                         const char *read_expr,
                                         const char *write_expr,
                                         PointerAccessQualifier access) {
   switch (access) {
      case POINTER_ACCESS_READONLY:
         return read_expr && *read_expr;
      case POINTER_ACCESS_WRITEONLY:
         return !actual->object_is_const && write_expr && *write_expr;
      case POINTER_ACCESS_READWRITE:
      default:
         /* Unlike the ordinary one-address ref ABI, specialization can bake a
            distinct read and write address directly into the callee body. */
         return !actual->object_is_const && read_expr && *read_expr &&
                write_expr && *write_expr;
   }
}

//! @brief Plan currently provable ref specializations for all single-callsite functions.
void analyze_optimizer_ref_specializations(ASTNode *program) {
   size_t previous_count;

   reset_plans();
   if (!program) {
      return;
   }

   /* Specializing one ref formal can make that formal a fixed-address actual
      at its own unique downstream call site.  Iterate to a fixed point so
      addresses propagate through nonrecursive single-callsite chains and the
      result does not depend on source definition order. */
   do {
      previous_count = plan_count;
      for (int p = 0; p < program->count; p++) {
         ASTNode *fn = program->children[p];
         const ASTNode *callsite;
         const ASTNode *caller;
         const ASTNode *declarator;
         const ASTNode *params;
         ASTNode *args;
         int actual_index = 0;
         char fn_sym[256];
         const char *fn_name;

         if (!fn || strcmp(fn->name, "defdecl_stmt") || !function_has_body(fn) ||
             !function_is_single_direct_callsite_candidate(fn)) {
            continue;
         }
         callsite = function_single_direct_callsite(fn);
         caller = function_single_direct_caller(fn);
         if (!callsite || strcmp(callsite->name, "()") || callsite->count < 2) {
            continue;
         }
         args = callsite->children[1];
         declarator = function_declarator_node(fn);
         params = declarator_parameter_list(declarator);
         fn_name = declarator_name(declarator);
         if (!fn_name || !function_symbol_name(fn, fn_name, fn_sym, sizeof(fn_sym))) {
            continue;
         }

         /* Subsection 6 will grow a complete assembly-escape proof. Until then,
            keep ABI-changing parameter storage elimination away from any callee
            containing inline assembly, and from any function whose callable symbol
            is named by inline assembly elsewhere in the translation unit. */
         if (subtree_contains_asm(fn) || subtree_asm_mentions(program, fn_name, fn_sym)) {
            continue;
         }

         if (!params || is_empty(params) || !args || is_empty(args)) {
            continue;
         }
         for (int i = 0; i < params->count && actual_index < args->count; i++) {
            const ASTNode *parameter = params->children[i];
            ContextEntry actual_entry;
            int actual_offset = 0;
            char read_expr[320];
            char write_expr[320];
            PointerAccessQualifier access;

            if (!parameter_type(parameter) || parameter_is_void(parameter)) {
               continue;
            }
            if (!parameter_is_ref(parameter)) {
               actual_index++;
               continue;
            }
            if (optimizer_ref_parameter_specialization(fn, i, NULL)) {
               actual_index++;
               continue;
            }
            memset(&actual_entry, 0, sizeof(actual_entry));
            read_expr[0] = '\0';
            write_expr[0] = '\0';
            if (!fixed_caller_actual(args->children[actual_index], caller, &actual_entry,
                                     read_expr, sizeof(read_expr),
                                     write_expr, sizeof(write_expr), &actual_offset)) {
               actual_index++;
               continue;
            }
            access = parameter_access_qualifier(parameter);
            if (fixed_actual_supports_formal(&actual_entry, read_expr, write_expr, access)) {
               add_plan(fn, i,
                        *read_expr ? read_expr : NULL,
                        *write_expr ? write_expr : NULL,
                        actual_offset, actual_entry.is_zeropage,
                        actual_entry.has_split_alias_delta,
                        actual_entry.split_alias_delta);
            }
            actual_index++;
         }
      }
   } while (plan_count != previous_count);
}

//! @brief Query one planned ref specialization by source parameter-list index.
bool optimizer_ref_parameter_specialization(const ASTNode *fn, int parameter_index,
                                            InlineRefSpecialization *out) {
   for (size_t i = 0; i < plan_count; i++) {
      if (plans[i].fn == fn && plans[i].parameter_index == parameter_index) {
         if (out) {
            out->read_expr = plans[i].read_expr;
            out->write_expr = plans[i].write_expr;
            out->offset = plans[i].offset;
            out->is_zeropage = plans[i].is_zeropage;
            out->has_split_alias_delta = plans[i].has_split_alias_delta;
            out->split_alias_delta = plans[i].split_alias_delta;
         }
         return true;
      }
   }
   return false;
}

//! @brief Rebind specialized ref formals to fixed caller addresses in a callee context.
void apply_optimizer_ref_specializations(const ASTNode *fn, Context *ctx) {
   const ASTNode *declarator;
   const ASTNode *params;

   if (!fn || !ctx) {
      return;
   }
   declarator = function_declarator_node(fn);
   params = declarator_parameter_list(declarator);
   if (!params || is_empty(params)) {
      return;
   }
   for (int i = 0; i < params->count; i++) {
      const ASTNode *parameter = params->children[i];
      InlineRefSpecialization spec;
      ContextEntry *entry;
      const char *name;
      if (!parameter || !parameter_is_ref(parameter) ||
          !optimizer_ref_parameter_specialization(fn, i, &spec)) {
         continue;
      }
      name = parameter_name(parameter, i);
      entry = name ? (ContextEntry *)set_get(ctx->vars, name) : NULL;
      if (!entry) {
         error_unreachable("missing context entry for specialized ref parameter '%s'",
                           name ? name : "<unnamed>");
      }
      entry->is_ref = true;
      entry->is_absolute_ref = true;
      entry->read_expr = spec.read_expr;
      entry->write_expr = spec.write_expr;
      entry->has_split_alias_delta = spec.has_split_alias_delta;
      entry->split_alias_delta = spec.split_alias_delta;
      entry->is_static = false;
      entry->is_global = false;
      entry->is_zeropage = spec.is_zeropage;
      entry->offset = spec.offset;
      /* A specialized ref no longer stores an address. Its context entry now
         denotes the referenced object directly, so expression lowering must
         use the referent size rather than the two-byte ref ABI slot size. */
      entry->size = declarator_storage_size(entry->type, entry->declarator);
   }
}

/* ------------------------------------------------------------------------- */
/* Readonly by-value single-callsite specialization (inline roadmap item 2). */

typedef struct ValuePlan {
   const ASTNode *fn;
   int parameter_index;
   InlineValueSpecializationKind kind;
   char *read_expr;
   int offset;
   bool is_zeropage;
   long long constant_value;
} ValuePlan;

static ValuePlan *value_plans;
static size_t value_plan_count;
static size_t value_plan_revision;
static const ASTNode *value_plan_program;

static void reset_value_plans(void) {
   for (size_t i = 0; i < value_plan_count; i++) {
      free(value_plans[i].read_expr);
   }
   free(value_plans);
   value_plans = NULL;
   value_plan_count = 0;
   value_plan_revision = 0;
}

static void add_value_plan(const ASTNode *fn, int parameter_index,
                           InlineValueSpecializationKind kind,
                           const char *read_expr, int offset,
                           bool is_zeropage, long long constant_value) {
   ValuePlan *plan = NULL;

   for (size_t i = 0; i < value_plan_count; i++) {
      if (value_plans[i].fn == fn &&
          value_plans[i].parameter_index == parameter_index) {
         plan = &value_plans[i];
         break;
      }
   }

   /* A later fixed-point iteration may learn that an address-backed caller
      formal is itself a constant.  Constant is strictly stronger than address:
      upgrade the existing plan so no dead caller ABI symbol leaks downstream. */
   if (plan) {
      if (plan->kind == INLINE_VALUE_INTEGER_CONSTANT ||
          kind != INLINE_VALUE_INTEGER_CONSTANT) {
         return;
      }
      free(plan->read_expr);
      plan->read_expr = NULL;
      plan->kind = kind;
      plan->offset = 0;
      plan->is_zeropage = false;
      plan->constant_value = constant_value;
      value_plan_revision++;
      return;
   }

   {
      ValuePlan *grown = (ValuePlan *)realloc(value_plans,
         sizeof(*value_plans) * (value_plan_count + 1));
      if (!grown) {
         error_unreachable("out of memory recording value specialization");
      }
      value_plans = grown;
      plan = &value_plans[value_plan_count++];
   }
   memset(plan, 0, sizeof(*plan));
   plan->fn = fn;
   plan->parameter_index = parameter_index;
   plan->kind = kind;
   plan->read_expr = read_expr ? strdup(read_expr) : NULL;
   plan->offset = offset;
   plan->is_zeropage = is_zeropage;
   plan->constant_value = constant_value;
   if (read_expr && !plan->read_expr) {
      error_unreachable("out of memory recording value specialization address");
   }
   value_plan_revision++;
}

bool optimizer_value_parameter_specialization(const ASTNode *fn, int parameter_index,
                                              InlineValueSpecialization *out) {
   for (size_t i = 0; i < value_plan_count; i++) {
      if (value_plans[i].fn == fn && value_plans[i].parameter_index == parameter_index) {
         if (out) {
            out->kind = value_plans[i].kind;
            out->read_expr = value_plans[i].read_expr;
            out->offset = value_plans[i].offset;
            out->is_zeropage = value_plans[i].is_zeropage;
            out->constant_value = value_plans[i].constant_value;
         }
         return true;
      }
   }
   return false;
}

static bool specialize_ast_contains_identifier(const ASTNode *node, const char *name) {
   if (!node || !name || !*name) return false;
   if (node->kind == AST_IDENTIFIER && node->strval && !strcmp(node->strval, name)) {
      return true;
   }
   for (int i = 0; i < node->count; i++) {
      if (specialize_ast_contains_identifier(node->children[i], name)) return true;
   }
   return false;
}

/* A by-value formal may alias caller storage only when its private storage
   identity is unobservable.  Writing the formal obviously forbids aliasing,
   but so does taking its address or binding it to any ref parameter: even a
   const ref can observe/return the address of what would otherwise be the
   callee-owned copy. */
static bool value_formal_storage_is_readonly_unobserved(const ASTNode *node,
                                                        const char *name) {
   if (!node || !name || !*name) return true;

   if (!strcmp(node->name, "assign_expr") && node->count >= 2 &&
       specialize_ast_contains_identifier(node->children[1], name)) {
      return false;
   }
   if (!strcmp(node->name, "lvalue") && node->count > 2) {
      const ASTNode *suffix = node->children[node->count - 1];
      const char *op = suffix ? suffix->strval : NULL;
      if (op && (!strcmp(op, "pre++") || !strcmp(op, "post++") ||
                 !strcmp(op, "pre--") || !strcmp(op, "post--")) &&
          specialize_ast_contains_identifier(node, name)) {
         return false;
      }
   }
   if ((!strcmp(node->name, "&") || !strcmp(node->name, "&<") ||
        !strcmp(node->name, "&>")) && specialize_ast_contains_identifier(node, name)) {
      return false;
   }
   if (!strcmp(node->name, "()") && node->count > 1) {
      const ASTNode *callee_expr = unwrap_expr_node(node->children[0]);
      const char *callee_name = expr_bare_identifier_name((ASTNode *)callee_expr);
      const ASTNode *callee_fn = callee_name
         ? resolve_function_designator_target(callee_name) : NULL;
      const ASTNode *params = callee_fn
         ? declarator_parameter_list(function_declarator_node(callee_fn)) : NULL;
      const ASTNode *args = node->children[1];
      int actual_index = 0;

      if (args && !is_empty(args) && specialize_ast_contains_identifier(args, name)) {
         if (!callee_fn || !params || is_empty(params)) {
            return false;
         }
         for (int i = 0; i < params->count && actual_index < args->count; i++) {
            const ASTNode *parameter = params->children[i];
            if (!parameter || parameter_is_void(parameter) || !parameter_type(parameter)) {
               continue;
            }
            if (specialize_ast_contains_identifier(args->children[actual_index], name) &&
                parameter_is_ref(parameter)) {
               return false;
            }
            actual_index++;
         }
      }
   }

   for (int i = 0; i < node->count; i++) {
      if (!value_formal_storage_is_readonly_unobserved(node->children[i], name)) {
         return false;
      }
   }
   return true;
}

static bool value_parameter_explicit_const(const ASTNode *parameter) {
   const ASTNode *specs = parameter_decl_specifiers(parameter);
   const ASTNode *mods = (specs && specs->count > 0) ? specs->children[0] : NULL;
   const ASTNode *decl = call_adjusted_parameter_declarator(
      parameter_declarator(parameter), false);
   return mods && decl && declaration_const_applies_to_object(mods, decl);
}

static bool value_parameter_readonly_candidate(const ASTNode *fn,
                                               const ASTNode *parameter,
                                               int parameter_index) {
   const char *name;
   const ASTNode *body;
   bool explicit_const;
   if (!fn || !parameter || parameter_is_ref(parameter) || parameter_is_void(parameter)) {
      return false;
   }
   name = parameter_name(parameter, parameter_index);
   body = function_has_body(fn) && fn->count > 2 ? fn->children[2] : NULL;
   if (!name || !*name || !body) return false;

   /* Explicit const and inferred readonly formals deliberately share the same
      storage-identity proof.  Explicit const proves there are no legal direct
      writes, but its private by-value address may still be observed through a
      const ref, so both forms must pass the complete scan. */
   explicit_const = value_parameter_explicit_const(parameter);
   if (explicit_const) {
      return value_formal_storage_is_readonly_unobserved(body, name);
   }
   return value_formal_storage_is_readonly_unobserved(body, name);
}

/* Return false if the caller has ever exposed one ordinary local/parameter's
   address.  Caller execution is suspended during the direct call, so ordinary
   assignments before/after the call do not threaten stability; only an alias
   that the callee could use while the caller is suspended matters. */
static bool caller_storage_address_unexposed(const ASTNode *node, const char *name) {
   if (!node || !name || !*name) return true;
   if ((!strcmp(node->name, "&") || !strcmp(node->name, "&<") ||
        !strcmp(node->name, "&>")) && specialize_ast_contains_identifier(node, name)) {
      return false;
   }
   if (!strcmp(node->name, "()") && node->count > 1) {
      const ASTNode *callee_expr = unwrap_expr_node(node->children[0]);
      const char *callee_name = expr_bare_identifier_name((ASTNode *)callee_expr);
      const ASTNode *callee_fn = callee_name
         ? resolve_function_designator_target(callee_name) : NULL;
      const ASTNode *params = callee_fn
         ? declarator_parameter_list(function_declarator_node(callee_fn)) : NULL;
      const ASTNode *args = node->children[1];
      int actual_index = 0;
      if (args && !is_empty(args) && specialize_ast_contains_identifier(args, name)) {
         if (!callee_fn || !params || is_empty(params)) return false;
         for (int i = 0; i < params->count && actual_index < args->count; i++) {
            const ASTNode *parameter = params->children[i];
            if (!parameter || parameter_is_void(parameter) || !parameter_type(parameter)) {
               continue;
            }
            if (parameter_is_ref(parameter) &&
                specialize_ast_contains_identifier(args->children[actual_index], name)) {
               return false;
            }
            actual_index++;
         }
      }
   }
   for (int i = 0; i < node->count; i++) {
      if (!caller_storage_address_unexposed(node->children[i], name)) return false;
   }
   return true;
}

static bool value_parameter_signature_matches_actual(const ASTNode *parameter,
                                                     const ContextEntry *actual) {
   const ASTNode *ptype = parameter_type(parameter);
   const ASTNode *pdecl = call_adjusted_parameter_declarator(
      parameter_declarator(parameter), false);
   const char *ptname = ptype ? type_name_from_node(ptype) : NULL;
   const char *atname = actual && actual->type ? type_name_from_node(actual->type) : NULL;
   if (!ptype || !pdecl || !actual || !actual->type || !actual->declarator ||
       !ptname || !atname || strcmp(ptname, atname)) {
      return false;
   }
   return declarator_signature_matches(actual->declarator, pdecl) &&
      declarator_storage_size(ptype, pdecl) == actual->size;
}

static bool integer_value_parameter(const ASTNode *parameter) {
   const ASTNode *type = parameter_type(parameter);
   const ASTNode *decl = call_adjusted_parameter_declarator(
      parameter_declarator(parameter), false);
   return type && decl && declarator_pointer_depth(decl) == 0 &&
      (type_is_signed_integer(type) || type_is_unsigned_integer(type) ||
       type_is_bcd_integer(type));
}

static bool normalize_value_constant_for_parameter(const ASTNode *parameter,
                                                   long long raw,
                                                   long long *normalized_out) {
   const ASTNode *type;
   int size;
   unsigned char bytes[8] = {0};
   unsigned long long bits = 0;

   if (!parameter || !normalized_out) return false;
   type = parameter_type(parameter);
   size = parameter_storage_size(parameter);
   if (!type || size <= 0 || size > (int)sizeof(bytes)) return false;
   if (!encode_integer_initializer_value(raw, bytes, size, type)) return false;

   /* Packed BCD is represented as a decimal value by const_value; its encoder
      already range-checks the formal width, so no two's-complement recovery is
      appropriate here. */
   if (type_is_bcd_integer(type)) {
      *normalized_out = raw;
      return true;
   }

   for (int i = size - 1; i >= 0; i--) {
      bits = (bits << 8) | bytes[i];
   }
   if (type_is_signed_integer(type) && size < (int)sizeof(bits) &&
       (bytes[size - 1] & 0x80u)) {
      bits |= (~0ULL) << (size * 8);
   }
   *normalized_out = (long long)bits;
   return true;
}

static bool plan_one_value_parameter(const ASTNode *program, const ASTNode *fn,
                                     const ASTNode *caller, const ASTNode *parameter,
                                     int parameter_index, ASTNode *actual) {
   long long constant_value = 0;
   const char *actual_name;
   ContextEntry actual_entry;
   int actual_offset = 0;
   char read_expr[320];
   char write_expr[320];
   char actual_symbol[256];

   if (!value_parameter_readonly_candidate(fn, parameter, parameter_index)) return false;

   /* Integer constant expressions have no storage identity at all. */
   if (integer_value_parameter(parameter) &&
       expr_is_integer_constant_expr(actual, &constant_value) &&
       normalize_value_constant_for_parameter(parameter, constant_value,
                                              &constant_value)) {
      add_value_plan(fn, parameter_index, INLINE_VALUE_INTEGER_CONSTANT,
                     NULL, 0, false, constant_value);
      return true;
   }

   /* Storage aliasing is deliberately narrower than ref specialization.  Only
      a bare object name is accepted here: compound lvalues can be added later
      once the stability proof is subobject-aware. */
   actual_name = expr_bare_identifier_name(actual);
   if (!actual_name || !*actual_name) return false;

   /* The caller formal may itself have disappeared because an earlier
      fixed-point iteration specialized it to a constant.  Propagate that
      binding instead of recording the caller formal's now-nonexistent ABI
      symbol as this callee's backing storage.  This is what makes readonly
      chains such as main -> middle(4) -> leaf(x) independent of definition
      order. */
   {
      Context caller_ctx;
      ContextEntry *caller_entry = NULL;
      if (build_analysis_caller_context(caller, &caller_ctx)) {
         caller_entry = (ContextEntry *)set_get(caller_ctx.vars, actual_name);
      }
      if (caller_entry && caller_entry->has_const_value &&
          value_parameter_signature_matches_actual(parameter, caller_entry) &&
          normalize_value_constant_for_parameter(parameter,
                                                 caller_entry->const_value,
                                                 &constant_value)) {
         add_value_plan(fn, parameter_index, INLINE_VALUE_INTEGER_CONSTANT,
                        NULL, 0, false, constant_value);
         return true;
      }
   }

   memset(&actual_entry, 0, sizeof(actual_entry));
   if (!fixed_caller_actual(actual, caller, &actual_entry,
                            read_expr, sizeof(read_expr),
                            write_expr, sizeof(write_expr), &actual_offset) ||
       !*read_expr || actual_entry.is_ref ||
       !value_parameter_signature_matches_actual(parameter, &actual_entry)) {
      return false;
   }

   /* A language-const object is intrinsically stable.  A mutable ordinary
      caller local/parameter is also stable while the caller is suspended when
      its address never escapes.  Mutable globals and absolute/hardware-backed
      objects remain conservative fallbacks because the callee may name/change
      them independently. */
   if (!actual_entry.object_is_const) {
      if (actual_entry.is_global || actual_entry.is_absolute_ref ||
          !caller_storage_address_unexposed(caller->children[2], actual_name)) {
         return false;
      }
   }
   else if (actual_entry.is_absolute_ref) {
      return false;
   }

   /* Inline assembly can bypass the typed alias proof by naming the caller
      object directly.  Reject only an asm mention of this specific source or
      assembler symbol rather than vetoing unrelated assembly globally. */
   actual_symbol[0] = '\0';
   {
      Context caller_ctx;
      LValueRef lv;
      if (build_analysis_caller_context(caller, &caller_ctx) &&
          resolve_ref_argument_lvalue(&caller_ctx, actual, &lv) &&
          lvalue_fixed_symbol_name(&caller_ctx, &lv, actual_symbol, sizeof(actual_symbol)) &&
          subtree_asm_mentions(program, actual_name, actual_symbol)) {
         return false;
      }
   }

   add_value_plan(fn, parameter_index, INLINE_VALUE_ADDRESS,
                  read_expr, actual_offset, actual_entry.is_zeropage, 0);
   return true;
}

void analyze_optimizer_value_specializations(ASTNode *program) {
   size_t previous_revision;
   reset_value_plans();
   value_plan_program = program;
   if (!program) return;

   /* Value aliases can themselves become stable actuals farther down a
      single-callsite chain.  Iterate so definition order does not decide the
      result, matching the ref-specialization planner. */
   do {
      previous_revision = value_plan_revision;
      for (int p = 0; p < program->count; p++) {
         ASTNode *fn = program->children[p];
         const ASTNode *callsite;
         const ASTNode *caller;
         const ASTNode *params;
         ASTNode *args;
         int actual_index = 0;
         char fn_sym[256];
         const char *fn_name;

         if (!fn || strcmp(fn->name, "defdecl_stmt") || !function_has_body(fn) ||
             !function_is_single_direct_callsite_candidate(fn)) continue;
         callsite = function_single_direct_callsite(fn);
         caller = function_single_direct_caller(fn);
         if (!callsite || !caller || strcmp(callsite->name, "()") || callsite->count < 2) continue;
         args = callsite->children[1];
         params = declarator_parameter_list(function_declarator_node(fn));
         fn_name = declarator_name(function_declarator_node(fn));
         if (!fn_name || !function_symbol_name(fn, fn_name, fn_sym, sizeof(fn_sym))) continue;
         if (subtree_contains_asm(fn) || subtree_asm_mentions(program, fn_name, fn_sym)) continue;
         if (!params || is_empty(params) || !args || is_empty(args)) continue;

         for (int i = 0; i < params->count && actual_index < args->count; i++) {
            const ASTNode *parameter = params->children[i];
            if (!parameter || parameter_is_void(parameter) || !parameter_type(parameter)) continue;
            if (!parameter_is_ref(parameter)) {
               InlineValueSpecialization existing;
               bool have_existing = optimizer_value_parameter_specialization(fn, i,
                                                                               &existing);
               if (!have_existing || existing.kind == INLINE_VALUE_ADDRESS) {
                  (void)plan_one_value_parameter(program, fn, caller, parameter, i,
                                                 args->children[actual_index]);
               }
            }
            actual_index++;
         }
      }
   } while (value_plan_revision != previous_revision);
   (void)value_plan_program;
}

void apply_optimizer_value_specializations(const ASTNode *fn, Context *ctx) {
   const ASTNode *params;
   if (!fn || !ctx) return;
   params = declarator_parameter_list(function_declarator_node(fn));
   if (!params || is_empty(params)) return;

   for (int i = 0; i < params->count; i++) {
      const ASTNode *parameter = params->children[i];
      InlineValueSpecialization spec;
      ContextEntry *entry;
      const char *name;
      if (!parameter || parameter_is_ref(parameter) ||
          !optimizer_value_parameter_specialization(fn, i, &spec)) continue;
      name = parameter_name(parameter, i);
      entry = name ? (ContextEntry *)set_get(ctx->vars, name) : NULL;
      if (!entry) {
         error_unreachable("missing context entry for specialized value parameter '%s'",
                           name ? name : "<unnamed>");
      }
      entry->object_is_const = true;
      entry->is_ref = false;
      entry->is_global = false;
      entry->size = declarator_storage_size(entry->type, entry->declarator);
      if (spec.kind == INLINE_VALUE_INTEGER_CONSTANT) {
         entry->is_static = false;
         entry->is_zeropage = false;
         entry->is_absolute_ref = false;
         entry->read_expr = NULL;
         entry->write_expr = NULL;
         entry->offset = 0;
         entry->has_const_value = true;
         entry->const_value = spec.constant_value;
      }
      else if (spec.kind == INLINE_VALUE_ADDRESS) {
         entry->is_static = false;
         entry->is_zeropage = spec.is_zeropage;
         entry->is_absolute_ref = true;
         entry->read_expr = spec.read_expr;
         entry->write_expr = NULL;
         entry->offset = spec.offset;
         entry->has_const_value = false;
      }
   }
}
