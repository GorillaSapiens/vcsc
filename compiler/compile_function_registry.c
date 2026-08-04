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
#include "compile_function_registry.h"
#include "compile_internal.h"
#include "compile_type.h"
#include "messages.h"
#include "set.h"

extern Set *functions;

//! @brief Return the modifiers attached to a function declaration or definition.
static const ASTNode *function_modifiers_node(const ASTNode *fn) {
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
                                       const ASTNode *actual_expr) {
   const ASTNode *formal_type = parameter_type(parameter);
   const ASTNode *formal_decl = call_adjusted_parameter_declarator(
         parameter_declarator(parameter), parameter_is_ref(parameter));
   const char *formal_name;
   const char *actual_name;
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
      return true;
   }
   if (object_pointer_to_void_pointer_allowed(formal_type, formal_decl, actual_type, actual_decl)) {
      return true;
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
      const char *amem = find_mem_modifier_name(amod);
      const char *bmem = find_mem_modifier_name(bmod);

      if (declarator_pointer_depth(adecl) != declarator_pointer_depth(bdecl) ||
          !declarator_array_signature_matches_from(adecl, bdecl, 3) ||
          has_modifier((ASTNode *)amod, "static") !=
          has_modifier((ASTNode *)bmod, "static") ||
          function_is_inline(a) != function_is_inline(b) ||
          ((amem || bmem) && (!amem || !bmem || strcmp(amem, bmem)))) {
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

         if (!parameter || parameter_is_void(parameter) || !parameter_type(parameter)) {
            continue;
         }
         actual_expr = unwrap_expr_node(args->children[actual_index]);
         expr_match_signature(args->children[actual_index], ctx, &actual_type, &actual_decl);
         actual_lvalue = resolve_ref_argument_lvalue(ctx, args->children[actual_index], NULL);
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
                                         actual_lvalue, actual_expr)) {
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
   {
      const char *memname = find_mem_modifier_name(modifiers);
      if (function_is_inline(node) && memname) {
         error_user("[%s:%d.%d] inline function '%s' cannot use mem region '%s' because inline expansion has no independently placeable linker layout",
                    node->file, node->line, node->column, name, memname);
      }
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
