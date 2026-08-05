//! @file compiler/compile_function_registry.c
//! @brief Implements one-name/one-signature direct function registration.
//! @ingroup compiler

#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast.h"
#include "builtin.h"
#include "compile_declarator.h"
#include "compile_expr_info.h"
#include "compile_function.h"
#include "compile_function_registry.h"
#include "compile_internal.h"
#include "compile_type.h"
#include "memname.h"
#include "messages.h"
#include "set.h"

extern Set *functions;

//! @brief Return the modifiers attached to a function declaration or definition.
const ASTNode *function_modifiers_node(const ASTNode *fn) {
   if (!fn) {
      return NULL;
   }
   if (fn->count == 3 && fn->children[0] && fn->children[0]->count > 0) {
      return fn->children[0]->children[0];
   }
   if (fn->count == 4) {
      return fn->children[0];
   }
   return NULL;
}

bool function_has_body(const ASTNode *fn) {
   return fn && fn->count == 3;
}

bool function_is_inline(const ASTNode *fn) {
   return has_modifier((ASTNode *)function_modifiers_node(fn), "inline");
}

//! @brief Collect the independently classified code and result regions of one function.
void function_region_spec_collect(const ASTNode *fn, FunctionRegionSpec *spec) {
   const ASTNode *modifiers = function_modifiers_node(fn);

   if (!spec) {
      return;
   }
   memset(spec, 0, sizeof(*spec));
   if (!modifiers || is_empty(modifiers)) {
      return;
   }

   spec->code_regions = calloc((size_t)modifiers->count, sizeof(*spec->code_regions));
   if (!spec->code_regions) {
      error_unreachable("out of memory collecting function memory regions");
   }

   for (int i = 0; i < modifiers->count; i++) {
      const ASTNode *modifier = modifiers->children[i];
      const char *name = (modifier && modifier->strval) ? modifier->strval : NULL;
      const ASTNode *mem_decl;
      bool is_ro;
      bool is_rw;

      if (!name || !memname_exists(name)) {
         continue;
      }
      mem_decl = get_memname_node(name);
      is_ro = mem_decl_is_readonly(mem_decl);
      is_rw = mem_decl_is_writable(mem_decl);
      if (is_ro && !is_rw) {
         spec->code_regions[spec->code_region_count++] = name;
      }
      else if (is_rw && !is_ro && !spec->result_region) {
         spec->result_region = name;
      }
   }
}

//! @brief Release temporary storage owned by one function region specification.
void function_region_spec_release(FunctionRegionSpec *spec) {
   if (!spec) {
      return;
   }
   free(spec->code_regions);
   memset(spec, 0, sizeof(*spec));
}

//! @brief Return the sole code-placement region selected by a function, if any.
const char *function_single_code_region_name(const ASTNode *fn) {
   FunctionRegionSpec spec;
   const char *ret = NULL;

   function_region_spec_collect(fn, &spec);
   if (spec.code_region_count == 1) {
      ret = spec.code_regions[0];
   }
   function_region_spec_release(&spec);
   return ret;
}

//! @brief Return the writable hidden-result region selected by a function, if any.
const char *function_result_region_name(const ASTNode *fn) {
   FunctionRegionSpec spec;
   const char *ret;

   function_region_spec_collect(fn, &spec);
   ret = spec.result_region;
   function_region_spec_release(&spec);
   return ret;
}

//! @brief Return the writable hidden-result region declaration selected by a function.
const ASTNode *function_result_region_node(const ASTNode *fn) {
   const char *name = function_result_region_name(fn);
   return name ? get_memname_node(name) : NULL;
}

//! @brief Return whether two source-order-insensitive function region contracts agree.
bool function_region_contract_matches(const ASTNode *a, const ASTNode *b) {
   FunctionRegionSpec aspec;
   FunctionRegionSpec bspec;
   bool equal = true;

   function_region_spec_collect(a, &aspec);
   function_region_spec_collect(b, &bspec);
   if ((aspec.result_region == NULL) != (bspec.result_region == NULL) ||
       (aspec.result_region && strcmp(aspec.result_region, bspec.result_region)) ||
       aspec.code_region_count != bspec.code_region_count) {
      equal = false;
   }
   for (size_t i = 0; equal && i < aspec.code_region_count; i++) {
      bool found = false;
      for (size_t j = 0; j < bspec.code_region_count; j++) {
         if (!strcmp(aspec.code_regions[i], bspec.code_regions[j])) {
            found = true;
            break;
         }
      }
      if (!found) {
         equal = false;
      }
   }
   function_region_spec_release(&aspec);
   function_region_spec_release(&bspec);
   return equal;
}

//! @brief Validate named function regions after classifying them from mem properties.
void validate_function_region_modifiers(const ASTNode *fn) {
   const ASTNode *modifiers = function_modifiers_node(fn);
   const ASTNode *return_decl;
   const char *fname;
   const char *result_region = NULL;
   const char *first_code_region = NULL;
   size_t code_region_count = 0;

   if (!fn || !modifiers || is_empty(modifiers)) {
      return;
   }
   fname = declarator_name(function_declarator_node(fn));
   if (!fname || !*fname) {
      fname = "<unnamed>";
   }
   return_decl = function_return_declarator_from_callable(function_declarator_node(fn));

   for (int i = 0; i < modifiers->count; i++) {
      const ASTNode *modifier = modifiers->children[i];
      const char *name = (modifier && modifier->strval) ? modifier->strval : NULL;
      const ASTNode *mem_decl;
      bool is_ro;
      bool is_rw;

      if (!name || !memname_exists(name)) {
         continue;
      }
      for (int j = 0; j < i; j++) {
         const ASTNode *previous = modifiers->children[j];
         if (previous && previous->strval && !strcmp(previous->strval, name)) {
            error_user("[%s:%d.%d] function '%s' repeats mem region modifier '%s'",
                       fn->file, fn->line, fn->column, fname, name);
         }
      }

      mem_decl = get_memname_node(name);
      if (!mem_decl) {
         error_user("[%s:%d.%d] function '%s' uses unknown mem region modifier '%s'",
                    fn->file, fn->line, fn->column, fname, name);
      }
      is_ro = mem_decl_is_readonly(mem_decl);
      is_rw = mem_decl_is_writable(mem_decl);
      if (is_ro == is_rw) {
         error_user("[%s:%d.%d] mem region '%s' used by function '%s' must declare exactly one of $ro or $rw",
                    fn->file, fn->line, fn->column, name, fname);
      }
      if (is_ro) {
         if (mem_decl_split_addresses(mem_decl, NULL, NULL)) {
            error_user("[%s:%d.%d] read-only code region '%s' for function '%s' cannot use split read/write aliases",
                       fn->file, fn->line, fn->column, name, fname);
         }
         if (!first_code_region) {
            first_code_region = name;
         }
         code_region_count++;
      }
      else {
         if (result_region) {
            error_user("[%s:%d.%d] function '%s' selects multiple writable result regions '%s' and '%s'; at most one is allowed",
                       fn->file, fn->line, fn->column, fname, result_region, name);
         }
         result_region = name;
      }
   }

   if (result_region && return_type_is_void(function_return_type(fn), return_decl)) {
      error_user("[%s:%d.%d] void function '%s' cannot select writable result region '%s' because it has no return object",
                 fn->file, fn->line, fn->column, fname, result_region);
   }
   if (function_is_inline(fn) && (code_region_count > 0 || result_region)) {
      error_user("[%s:%d.%d] inline function '%s' cannot use mem region '%s' because inline expansion has no independently placeable linker layout",
                 fn->file, fn->line, fn->column, fname,
                 first_code_region ? first_code_region : result_region);
   }
   if (code_region_count > 1) {
      error_user("[%s:%d.%d] function '%s' requests %zu read-only code regions; multi-region code placement requires bankswitching roadmap item 21",
                 fn->file, fn->line, fn->column, fname, code_region_count);
   }
}

int function_fixed_param_count(const ASTNode *fn) {
   const ASTNode *declarator = function_declarator_node(fn);
   const ASTNode *params = declarator_parameter_list(declarator);
   int count = 0;

   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count; i++) {
         const ASTNode *parameter = params->children[i];
         if (parameter && !parameter_is_void(parameter) && parameter_type(parameter)) {
            count++;
         }
      }
   }
   return count;
}

//! @brief Return whether one integer type can represent every value of another.
static bool integer_type_can_represent_type(const ASTNode *formal_type, const ASTNode *actual_type) {
   int formal_size;
   int actual_size;
   bool formal_signed;
   bool actual_signed;

   if (!type_is_promotable_integer(formal_type) || !type_is_promotable_integer(actual_type)) {
      return false;
   }
   if (type_is_bcd_integer(formal_type) != type_is_bcd_integer(actual_type)) {
      return false;
   }

   formal_size = type_size_from_node(formal_type);
   actual_size = type_size_from_node(actual_type);
   formal_signed = type_is_signed_integer(formal_type);
   actual_signed = type_is_signed_integer(actual_type);
   if (formal_size <= 0 || actual_size <= 0) {
      return false;
   }
   if (formal_signed == actual_signed) {
      return formal_size >= actual_size;
   }
   return formal_signed && !actual_signed && formal_size >= actual_size + 1;
}

//! @brief Return whether an ordinary integer promotion is permitted for a call argument.
static bool integer_promotion_allowed(const ASTNode *actual_type, const ASTNode *actual_decl,
                                      const ASTNode *formal_type, const ASTNode *formal_decl) {
   if (!actual_type || !formal_type) {
      return false;
   }
   if (actual_decl) {
      if (!declarator_signature_matches(actual_decl, formal_decl) ||
          !declarator_is_plain_value(actual_decl)) {
         return false;
      }
   }
   else if (!declarator_is_plain_value(formal_decl)) {
      return false;
   }
   return declarator_is_plain_value(formal_decl) &&
          integer_type_can_represent_type(formal_type, actual_type);
}

//! @brief Return whether an object pointer may be passed to a void pointer parameter.
static bool object_pointer_to_void_pointer_allowed(const ASTNode *formal_type, const ASTNode *formal_decl,
                                                   const ASTNode *actual_type, const ASTNode *actual_decl) {
   const char *formal_name;
   if (!formal_type || !formal_decl || !actual_type || !actual_decl) {
      return false;
   }
   formal_name = type_name_from_node(formal_type);
   if (!formal_name || strcmp(formal_name, "void") || !type_name_from_node(actual_type)) {
      return false;
   }
   return declarator_pointer_depth(formal_decl) == 1 &&
          declarator_pointer_depth(actual_decl) == 1;
}

//! @brief Return whether one call argument is accepted by one fixed parameter.
static bool parameter_accepts_argument(const ASTNode *parameter,
                                       const ASTNode *actual_type,
                                       const ASTNode *actual_decl,
                                       bool actual_lvalue,
                                       const ASTNode *actual_expr,
                                       Context *ctx) {
   const ASTNode *formal_type = parameter_type(parameter);
   const ASTNode *formal_decl = call_adjusted_parameter_declarator(
         parameter_declarator(parameter), parameter_is_ref(parameter));
   const char *formal_name;
   const char *actual_name;
   const ASTNode *decl_specs = parameter_decl_specifiers(parameter);
   const ASTNode *modifiers = (decl_specs && decl_specs->count > 0) ? decl_specs->children[0] : NULL;
   PointerAccessQualifier formal_access = declaration_pointer_access(modifiers, formal_decl);
   bool decl_match;

   if (!formal_type || !actual_type) {
      return false;
   }
   formal_name = type_name_from_node(formal_type);
   actual_name = type_name_from_node(actual_type);
   if (!formal_name || !actual_name) {
      return false;
   }

   if (parameter_is_ref(parameter)) {
      return actual_lvalue && !strcmp(formal_name, actual_name) &&
             declarator_signature_matches(actual_decl, formal_decl);
   }

   if (expr_is_untyped_integer_literal(actual_expr)) {
      if (formal_decl && declarator_pointer_depth(formal_decl) > 0 &&
          integer_literal_is_zero_expr(actual_expr)) {
         return true;
      }
      if (integer_literal_fits_plain_integer_type(actual_expr, formal_type, formal_decl)) {
         return true;
      }
   }

   decl_match = actual_decl ? declarator_signature_matches(actual_decl, formal_decl)
                            : declarator_is_plain_value(formal_decl);
   if (!strcmp(formal_name, actual_name) && decl_match) {
      if (formal_decl && actual_decl && declarator_pointer_depth(formal_decl) > 0 &&
          declarator_pointer_depth(actual_decl) > 0 &&
          !pointer_access_implicit_conversion_allowed(formal_access,
                                                       expr_pointer_access((ASTNode *)actual_expr, ctx))) {
         return false;
      }
      return true;
   }
   if (object_pointer_to_void_pointer_allowed(formal_type, formal_decl, actual_type, actual_decl)) {
      return pointer_access_implicit_conversion_allowed(formal_access,
                 expr_pointer_access((ASTNode *)actual_expr, ctx));
   }
   if (integer_promotion_allowed(actual_type, actual_decl, formal_type, formal_decl)) {
      return true;
   }
   return type_is_promotable_integer(actual_type) &&
          type_is_promotable_integer(formal_type) &&
          type_is_bcd_integer(actual_type) == type_is_bcd_integer(formal_type) &&
          type_size_from_node(actual_type) == type_size_from_node(formal_type) &&
          declarator_is_plain_value(formal_decl) &&
          (!actual_decl || declarator_is_plain_value(actual_decl));
}

//! @brief Return whether two function declarations have the same parameter signature.
static bool function_same_signature(const ASTNode *a, const ASTNode *b) {
   const ASTNode *adecl;
   const ASTNode *bdecl;
   const ASTNode *aparams;
   const ASTNode *bparams;
   int ai = 0;
   int bi = 0;

   if (!a || !b || function_fixed_param_count(a) != function_fixed_param_count(b)) {
      return false;
   }
   adecl = function_declarator_node(a);
   bdecl = function_declarator_node(b);
   aparams = declarator_parameter_list(adecl);
   bparams = declarator_parameter_list(bdecl);

   while ((aparams && !is_empty(aparams) && ai < aparams->count) ||
          (bparams && !is_empty(bparams) && bi < bparams->count)) {
      const ASTNode *aparam = NULL;
      const ASTNode *bparam = NULL;
      while (aparams && !is_empty(aparams) && ai < aparams->count) {
         aparam = aparams->children[ai++];
         if (aparam && !parameter_is_void(aparam) && parameter_type(aparam)) {
            break;
         }
         aparam = NULL;
      }
      while (bparams && !is_empty(bparams) && bi < bparams->count) {
         bparam = bparams->children[bi++];
         if (bparam && !parameter_is_void(bparam) && parameter_type(bparam)) {
            break;
         }
         bparam = NULL;
      }
      if (!aparam || !bparam) {
         return aparam == bparam;
      }
      {
         const ASTNode *aspecs = parameter_decl_specifiers(aparam);
         const ASTNode *bspecs = parameter_decl_specifiers(bparam);
         const ASTNode *amods = (aspecs && aspecs->count > 0) ? aspecs->children[0] : NULL;
         const ASTNode *bmods = (bspecs && bspecs->count > 0) ? bspecs->children[0] : NULL;
         const char *amem = find_mem_modifier_name(amods);
         const char *bmem = find_mem_modifier_name(bmods);

         if (strcmp(type_name_from_node(parameter_type(aparam)),
                    type_name_from_node(parameter_type(bparam))) ||
             parameter_is_ref(aparam) != parameter_is_ref(bparam) ||
             !declarator_signature_matches(parameter_declarator(aparam),
                                           parameter_declarator(bparam)) ||
             parameter_access_qualifier(aparam) !=
             parameter_access_qualifier(bparam) ||
             ((amem || bmem) && (!amem || !bmem || strcmp(amem, bmem)))) {
            return false;
         }
      }
   }
   return true;
}

//! @brief Return whether two declarations describe the same function ABI.
static bool function_same_declaration(const ASTNode *a, const ASTNode *b) {
   const ASTNode *atype;
   const ASTNode *btype;
   const ASTNode *adecl;
   const ASTNode *bdecl;
   const char *aname;
   const char *bname;

   if (!a || !b) {
      return false;
   }
   atype = function_return_type(a);
   btype = function_return_type(b);
   aname = type_name_from_node(atype);
   bname = type_name_from_node(btype);
   if ((!aname || !bname) && aname != bname) {
      return false;
   }
   if (aname && bname && strcmp(aname, bname)) {
      return false;
   }
   adecl = function_declarator_node(a);
   bdecl = function_declarator_node(b);
   {
      const ASTNode *amod = function_modifiers_node(a);
      const ASTNode *bmod = function_modifiers_node(b);

      if (declarator_pointer_depth(adecl) != declarator_pointer_depth(bdecl) ||
          !declarator_array_signature_matches_from(adecl, bdecl, 3) ||
          has_modifier((ASTNode *)amod, "static") !=
          has_modifier((ASTNode *)bmod, "static") ||
          function_is_inline(a) != function_is_inline(b) ||
          declaration_pointer_access(amod, function_return_declarator_from_callable(adecl)) !=
          declaration_pointer_access(bmod, function_return_declarator_from_callable(bdecl)) ||
          !function_region_contract_matches(a, b)) {
         return false;
      }
   }
   return function_same_signature(a, b);
}

//! @brief Return whether a user symbol must be escaped for the assembler.
static bool assembler_user_symbol_needs_escape(const char *name) {
   static const char *const reserved[] = {
      "a", "x", "y",
      "adc", "and", "asl", "bcc", "bcs", "beq", "bit", "bmi", "bne", "bpl", "brk", "bvc", "bvs",
      "clc", "cld", "cli", "clv", "cmp", "cpx", "cpy", "dec", "dex", "dey", "eor", "inc", "inx", "iny",
      "jmp", "jsr", "lda", "ldx", "ldy", "lsr", "nop", "ora", "pha", "php", "pla", "plp", "rol", "ror",
      "rti", "rts", "sbc", "sec", "sed", "sei", "sta", "stx", "sty", "tax", "tay", "tsx", "txa", "txs", "tya",
      "arg0", "arg1", "ptr0", "ptr1", "ptr2"
   };
   char lower[256];
   size_t n;

   if (!name || !*name || strchr(name, '$') || strchr(name, '?')) {
      return false;
   }
   n = strlen(name);
   if (n >= sizeof(lower)) {
      return false;
   }
   for (size_t i = 0; i < n; i++) {
      lower[i] = (char)tolower((unsigned char)name[i]);
   }
   lower[n] = 0;
   for (size_t i = 0; i < sizeof(reserved) / sizeof(reserved[0]); i++) {
      if (!strcmp(lower, reserved[i])) {
         return true;
      }
   }
   return false;
}

bool format_user_asm_symbol(const char *name, char *buf, size_t bufsize) {
   if (!name || !buf || bufsize == 0) {
      return false;
   }
   if (assembler_user_symbol_needs_escape(name)) {
      return (size_t)snprintf(buf, bufsize, "%s?", name) < bufsize;
   }
   return (size_t)snprintf(buf, bufsize, "%s", name) < bufsize;
}

bool function_symbol_name(const ASTNode *fn, const char *fallback_name, char *buf, size_t bufsize) {
   const ASTNode *declarator = function_declarator_node(fn);
   const char *name = fallback_name;
   if (!name && declarator) {
      name = declarator_name(declarator);
   }
   return format_user_asm_symbol(name, buf, bufsize);
}

const ASTNode *resolve_function_designator_target(const char *name) {
   return (name && functions) ? (const ASTNode *)set_get(functions, name) : NULL;
}

//! @brief Point the next diagnostic at the call's source-level function name.
static void set_call_location(const char *name, const ASTNode *call_expr) {
   const ASTNode *loc = call_expr;
   const ASTNode *callee = NULL;
   if (call_expr && call_expr->count > 0) {
      callee = call_expr->children[0];
   }
   if (callee && callee->file && callee->line > 0) {
      loc = callee;
   }
   if (loc && loc->file && loc->line > 0) {
      message_set_location(loc->file, loc->line, loc->column, name);
   }
}

const ASTNode *resolve_function_call_target(const char *name, ASTNode *call_expr,
                                            ASTNode *args, Context *ctx) {
   const ASTNode *fn = resolve_function_designator_target(name);
   const ASTNode *params;
   int arg_count = (args && !is_empty(args)) ? args->count : 0;
   int expected;
   int actual_index = 0;

   if (!fn) {
      return NULL;
   }
   expected = function_fixed_param_count(fn);
   if (expected != arg_count) {
      set_call_location(name, call_expr);
      error_user("function '%s' expects %d argument%s, got %d",
                 name, expected, expected == 1 ? "" : "s", arg_count);
   }

   params = declarator_parameter_list(function_declarator_node(fn));
   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count; i++) {
         const ASTNode *parameter = params->children[i];
         const ASTNode *actual_type = NULL;
         const ASTNode *actual_decl = NULL;
         const ASTNode *actual_expr;
         bool actual_lvalue;
         LValueRef actual_lv;

         if (!parameter || parameter_is_void(parameter) || !parameter_type(parameter)) {
            continue;
         }
         actual_expr = unwrap_expr_node(args->children[actual_index]);
         actual_lvalue = resolve_ref_argument_lvalue(ctx, args->children[actual_index],
                                                     parameter_is_ref(parameter) ? &actual_lv : NULL);
         if (parameter_is_ref(parameter) && actual_lvalue) {
            actual_type = actual_lv.type;
            actual_decl = actual_lv.declarator;
         }
         else {
            expr_match_signature(args->children[actual_index], ctx, &actual_type, &actual_decl);
         }
         if (parameter_is_ref(parameter) && !actual_lvalue) {
            if (actual_expr && actual_expr->file && actual_expr->line > 0) {
               message_set_location(actual_expr->file, actual_expr->line,
                                    actual_expr->column,
                                    actual_expr->name ? actual_expr->name : NULL);
            }
            error_user("argument %d passed to ref parameter of function '%s' must be an lvalue",
                       actual_index + 1, name);
         }
         if (!parameter_accepts_argument(parameter, actual_type, actual_decl,
                                         actual_lvalue, actual_expr, ctx)) {
            long long constant_value = 0;
            const ASTNode *param_type = parameter_type(parameter);
            if (type_is_bcd_integer(param_type) &&
                expr_is_integer_constant_expr(actual_expr, &constant_value) &&
                !integer_value_fits_type(constant_value, param_type)) {
               int param_size = type_size_from_node(param_type);
               error_user("packed-BCD value %lld is outside the range 0..%llu for parameter %d of function '%s'",
                          constant_value, bcd_max_value_for_size(param_size),
                          actual_index + 1, name);
            }
            set_call_location(name, call_expr);
            error_user("argument %d is incompatible with parameter %d of function '%s'",
                       actual_index + 1, actual_index + 1, name);
         }
         actual_index++;
      }
   }
   return fn;
}

void remember_function(const ASTNode *node, const char *name) {
   const ASTNode *previous;
   const ASTNode *modifiers = function_modifiers_node(node);

   validate_function_nonreserved_implementation_names(node);
   validate_function_parameter_storage_modifiers(node);
   validate_function_region_modifiers(node);
   validate_declaration_access_qualifiers(node, modifiers,
      function_return_declarator_from_callable(function_declarator_node(node)),
      "function return declaration");
   if (!name) {
      error_user("[%s:%d.%d] unnamed function declaration is not supported here",
                 node->file, node->line, node->column);
   }
   if (builtin_name_is_registered(name)) {
      error_user("[%s:%d.%d] '%s' is a reserved compiler builtin name",
                 node->file, node->line, node->column, name);
   }
   if (has_modifier((ASTNode *)modifiers, "page") && !function_has_body(node)) {
      error_user("[%s:%d.%d] 'page' on a function requires its definition so the complete function size is known",
                 node->file, node->line, node->column);
   }
   if (function_is_inline(node) && has_modifier((ASTNode *)modifiers, "extern")) {
      error_user("[%s:%d.%d] inline function '%s' cannot be extern; its body must be available for source-level expansion",
                 node->file, node->line, node->column, name);
   }
   if (function_is_inline(node) && !strcmp(name, "main")) {
      error_user("[%s:%d.%d] entry function 'main' cannot be inline because startup requires a linker-visible symbol",
                 node->file, node->line, node->column);
   }
   if (!functions) {
      functions = new_set();
   }
   previous = (const ASTNode *)set_get(functions, name);
   if (!previous) {
      remember_declaration_use_contract(DECL_CONTRACT_FUNCTION, name, modifiers);
      set_add(functions, strdup(name), (void *)node);
      return;
   }
   if (previous == node) {
      return;
   }
   if (!function_same_declaration(previous, node)) {
      error_user("[%s:%d.%d] vs [%s:%d.%d] conflicting declarations for function '%s'; function overloading is not supported",
                 node->file, node->line, node->column,
                 previous->file, previous->line, previous->column,
                 name);
   }
   if (function_has_body(previous) && function_has_body(node)) {
      error_user("[%s:%d.%d] vs [%s:%d.%d] multiple definitions for '%s'",
                 node->file, node->line, node->column,
                 previous->file, previous->line, previous->column,
                 name);
   }
   remember_declaration_use_contract(DECL_CONTRACT_FUNCTION, name, modifiers);
   if (!function_has_body(previous) && function_has_body(node)) {
      set_rm(functions, name);
      set_add(functions, strdup(name), (void *)node);
   }
}
