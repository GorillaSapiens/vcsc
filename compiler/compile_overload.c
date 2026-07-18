//! @file compiler/compile_overload.c
//! @brief Implements ordinary function overload resolution for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdbool.h>
#include <limits.h>
#include <ctype.h>

#include "ast.h"
#include "compile_internal.h"
#include "compile_overload.h"
#include "compile_type.h"
#include "messages.h"
#include "set.h"

typedef struct OrdinaryFunction {
   const char *name;
   const ASTNode *node;
} OrdinaryFunction;

extern Set *functions;

static OrdinaryFunction *ordinary_functions = NULL;
static int ordinary_function_count = 0;

static bool function_same_signature(const ASTNode *a, const ASTNode *b);
static void append_type_declarator_text(char **buf, size_t *cap, size_t *len, const ASTNode *type, const ASTNode *declarator, bool is_ref);




//! @brief Return function modifiers node data used by compiler overload resolver; returned pointers alias existing storage unless explicitly allocated by the function name.
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

//! @brief Return whether function has body in compiler overload resolver.
bool function_has_body(const ASTNode *fn) {
   return fn && fn->count == 3;
}



//! @brief Handle function fixed param count logic for compiler overload resolver.
int function_fixed_param_count(const ASTNode *fn) {
   const ASTNode *declarator = function_declarator_node(fn);
   const ASTNode *params = declarator_parameter_list(declarator);
   int count = 0;

   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count; i++) {
         const ASTNode *parameter = params->children[i];
         if (!parameter || parameter_is_void(parameter)) {
            continue;
         }
         if (parameter_type(parameter)) {
            count++;
         }
      }
   }

   return count;
}


//! @brief Return whether integer type can represent type in compiler overload resolver.
static bool integer_type_can_represent_type(const ASTNode *formal_type, const ASTNode *actual_type) {
   int formal_size;
   int actual_size;
   bool formal_signed;
   bool actual_signed;

   if (!type_is_promotable_integer(formal_type) || !type_is_promotable_integer(actual_type)) {
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

   if (formal_signed && !actual_signed) {
      return formal_size >= actual_size + 1;
   }

   return false;
}

//! @brief Handle integer promotion conversion cost logic for compiler overload resolver.
static int integer_promotion_conversion_cost(const ASTNode *actual_type, const ASTNode *actual_decl,
                                             const ASTNode *formal_type, const ASTNode *formal_decl) {
   int cost = 0;
   int formal_size;
   int actual_size;

   if (!actual_type || !formal_type) {
      return -1;
   }
   if (actual_decl) {
      if (!declarator_signature_matches(actual_decl, formal_decl)) {
         return -1;
      }
      if (!declarator_is_plain_value(actual_decl)) {
         return -1;
      }
   }
   else if (!declarator_is_plain_value(formal_decl)) {
      return -1;
   }
   if (!declarator_is_plain_value(formal_decl)) {
      return -1;
   }
   if (!type_is_promotable_integer(actual_type) || !type_is_promotable_integer(formal_type)) {
      return -1;
   }
   if (!integer_type_can_represent_type(formal_type, actual_type)) {
      return -1;
   }

   formal_size = type_size_from_node(formal_type);
   actual_size = type_size_from_node(actual_type);
   if (formal_size < actual_size) {
      return -1;
   }

   cost += (formal_size - actual_size) * 16;
   if (type_is_signed_integer(formal_type) != type_is_signed_integer(actual_type)) {
      cost += 4;
   }

   return cost;
}

//! @brief Handle implicit object pointer to void pointer allowed logic for compiler overload resolver.
static bool implicit_object_pointer_to_void_pointer_allowed(const ASTNode *formal_type, const ASTNode *formal_decl,
                                                            const ASTNode *actual_type, const ASTNode *actual_decl) {
   const char *formal_name = type_name_from_node(formal_type);

   if (!formal_type || !formal_decl || !actual_type || !actual_decl) {
      return false;
   }
   if (!formal_name || !type_name_from_node(actual_type)) {
      return false;
   }
   if (strcmp(formal_name, "void")) {
      return false;
   }
   if (declarator_pointer_depth(formal_decl) != 1 || declarator_pointer_depth(actual_decl) != 1) {
      return false;
   }
   return true;
}

//! @brief Handle parameter argument conversion cost logic for compiler overload resolver.
static int parameter_argument_conversion_cost(const ASTNode *ptype, const ASTNode *pdecl, bool pref,
                                              const ASTNode *atype, const ASTNode *adecl, bool arg_lvalue, const ASTNode *arg_expr, Context *ctx) {
   const char *pname;
   const char *aname;
   bool decl_match = false;
   int promo_cost;

   (void) ctx;
   pdecl = call_adjusted_parameter_declarator(pdecl, pref);

   if (!ptype || !atype) {
      return -1;
   }

   pname = type_name_from_node(ptype);
   aname = type_name_from_node(atype);
   if (!pname || !aname) {
      return -1;
   }

   if (!pref && expr_is_untyped_integer_literal(arg_expr)) {
      if (pdecl && declarator_pointer_depth(pdecl) > 0 && integer_literal_is_zero_expr(arg_expr)) {
         return 8 + declarator_pointer_depth(pdecl) - 1;
      }
      if (integer_literal_fits_plain_integer_type(arg_expr, ptype, pdecl)) {
         int literal_cost = 16;
         int formal_size = type_size_from_node(ptype);

         if (formal_size > 1) {
            literal_cost += (formal_size - 1) * 4;
         }
         if (type_is_signed_integer(ptype)) {
            literal_cost += 1;
         }
         return literal_cost;
      }
   }

   if (adecl) {
      decl_match = declarator_signature_matches(adecl, pdecl);
   }
   else if (declarator_is_plain_value(pdecl)) {
      decl_match = true;
   }

   if (!strcmp(pname, aname) && decl_match) {
      if (pref) {
         return arg_lvalue ? 0 : -1;
      }
      return 1;
   }

   if (pref) {
      return -1;
   }

   if (implicit_object_pointer_to_void_pointer_allowed(ptype, pdecl, atype, adecl)) {
      return 12;
   }

   promo_cost = integer_promotion_conversion_cost(atype, adecl, ptype, pdecl);
   if (promo_cost >= 0) {
      return 32 + promo_cost;
   }

   if (!pref && type_is_promotable_integer(atype) && type_is_promotable_integer(ptype) &&
       type_size_from_node(atype) == type_size_from_node(ptype) && declarator_is_plain_value(pdecl) &&
       (!adecl || declarator_is_plain_value(adecl))) {
      int cost = 96;
      if (type_is_signed_integer(atype) != type_is_signed_integer(ptype)) {
         cost += 4;
      }
      return cost;
   }

   return -1;
}

//! @brief Handle function same declaration logic for compiler overload resolver.
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
   if (declarator_pointer_depth(adecl) != declarator_pointer_depth(bdecl)) {
      return false;
   }
   if (!declarator_array_signature_matches_from(adecl, bdecl, 3)) {
      return false;
   }
   if (has_modifier((ASTNode *) function_modifiers_node(a), "static") !=
       has_modifier((ASTNode *) function_modifiers_node(b), "static")) {
      return false;
   }

   return function_same_signature(a, b);
}

//! @brief Handle function signature match cost logic for compiler overload resolver.
static int function_signature_match_cost(const ASTNode *fn, int arg_count, const ASTNode **arg_types, const ASTNode **arg_decls, const bool *arg_lvalues, const ASTNode **arg_exprs, Context *ctx) {
   const ASTNode *declarator = function_declarator_node(fn);
   const ASTNode *params = declarator_parameter_list(declarator);
   int seen = 0;
   int cost = 0;

   if (!declarator) {
      return -1;
   }

   if (function_fixed_param_count(fn) != arg_count) {
      return -1;
   }

   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count; i++) {
         const ASTNode *parameter = params->children[i];
         const ASTNode *ptype;
         const ASTNode *pdecl;
         bool pref;
         int param_cost;

         if (!parameter || parameter_is_void(parameter)) {
            continue;
         }

         ptype = parameter_type(parameter);
         pdecl = parameter_declarator(parameter);
         pref = parameter_is_ref(parameter);
         if (!ptype || seen >= arg_count || !arg_types[seen]) {
            return -1;
         }

         param_cost = parameter_argument_conversion_cost(
               ptype, pdecl, pref,
               arg_types[seen], arg_decls[seen],
               arg_lvalues ? arg_lvalues[seen] : false,
               arg_exprs ? arg_exprs[seen] : NULL,
               ctx);
         if (param_cost < 0) {
            return -1;
         }
         cost += param_cost;
         seen++;
      }
   }


   return seen == arg_count ? cost : -1;
}


//! @brief Handle function same signature logic for compiler overload resolver.
static bool function_same_signature(const ASTNode *a, const ASTNode *b) {
   if (!a || !b) {
      return false;
   }
   if (function_fixed_param_count(a) != function_fixed_param_count(b)) {
      return false;
   }

   {
      const ASTNode *adecl = function_declarator_node(a);
      const ASTNode *bdecl = function_declarator_node(b);
      const ASTNode *aparams = declarator_parameter_list(adecl);
      const ASTNode *bparams = declarator_parameter_list(bdecl);
      int ai = 0;
      int bi = 0;

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
         if (!aparam && !bparam) {
            break;
         }
         if (!aparam || !bparam) {
            return false;
         }
         if (strcmp(type_name_from_node(parameter_type(aparam)), type_name_from_node(parameter_type(bparam)))) {
            return false;
         }
         if (parameter_is_ref(aparam) != parameter_is_ref(bparam)) {
            return false;
         }
         if (!declarator_signature_matches(parameter_declarator(aparam), parameter_declarator(bparam))) {
            return false;
         }
      }
   }

   return true;
}


//! @brief Add mangled text to compiler overload resolver state, growing storage or preserving uniqueness as needed.
void append_mangled_text(char *buf, size_t bufsize, const char *text) {
   size_t len = strlen(buf);
   if (!text) {
      return;
   }
   for (size_t i = 0; text[i] && len + 1 < bufsize; i++) {
      unsigned char c = (unsigned char) text[i];
      if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
          (c >= '0' && c <= '9') || c == '_' || c == '?' || c == '@' || c == '$') {
         buf[len++] = (char) c;
      }
      else if (len + 3 < bufsize) {
         sprintf(buf + len, "x%02X", c);
         len += 3;
      }
      else {
         break;
      }
   }
   buf[len] = 0;
}

//! @brief Add callable signature mangle to compiler overload resolver state, growing storage or preserving uniqueness as needed.
static void append_callable_signature_mangle(char *buf, size_t bufsize, const ASTNode *declarator) {
   const ASTNode *params = declarator_parameter_list(declarator);
   bool saw_param = false;

   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count; i++) {
         const ASTNode *parameter = params->children[i];
         const ASTNode *ptype;
         const ASTNode *pdecl;
         char tmp[64];
         if (!parameter || parameter_is_void(parameter)) {
            continue;
         }
         saw_param = true;
         ptype = parameter_type(parameter);
         pdecl = parameter_declarator(parameter);
         strncat(buf, "@", bufsize - strlen(buf) - 1);
         append_mangled_text(buf, bufsize, type_name_from_node(ptype));
         if (parameter_is_ref(parameter)) {
            strncat(buf, "_r1", bufsize - strlen(buf) - 1);
         }
         snprintf(tmp, sizeof(tmp), "_p%d_a%d", declarator_pointer_depth(pdecl), declarator_array_count(pdecl));
         strncat(buf, tmp, bufsize - strlen(buf) - 1);
      }
   }
   if (!saw_param) {
      strncat(buf, "@void", bufsize - strlen(buf) - 1);
   }
}




//! @brief Handle assembler user symbol needs escape logic for compiler overload resolver.
static bool assembler_user_symbol_needs_escape(const char *name) {
   static const char *const reserved[] = {
      "a", "x", "y",
      "adc", "and", "asl", "bcc", "bcs", "beq", "bit", "bmi", "bne", "bpl", "brk", "bvc", "bvs",
      "clc", "cld", "cli", "clv", "cmp", "cpx", "cpy", "dec", "dex", "dey", "eor", "inc", "inx", "iny",
      "jmp", "jsr", "lda", "ldx", "ldy", "lsr", "nop", "ora", "pha", "php", "pla", "plp", "rol", "ror",
      "rti", "rts", "sbc", "sec", "sed", "sei", "sta", "stx", "sty", "tax", "tay", "tsx", "txa", "txs", "tya",
      "fp", "arg0", "arg1", "ptr0", "ptr1", "ptr2", "ptr3", "tmp0", "tmp1", "tmp2", "tmp3", "tmp4", "tmp5"
   };
   char lower[256];
   size_t n;
   if (!name || !*name) return false;
   if (strchr(name, '$') || strchr(name, '?')) return false;
   n = strlen(name);
   if (n >= sizeof(lower)) return false;
   for (size_t i = 0; i < n; i++) lower[i] = (char)tolower((unsigned char)name[i]);
   lower[n] = 0;
   for (size_t i = 0; i < sizeof(reserved) / sizeof(reserved[0]); i++) {
      if (!strcmp(lower, reserved[i])) return true;
   }
   return false;
}

//! @brief Handle format user asm symbol logic for compiler overload resolver.
bool format_user_asm_symbol(const char *name, char *buf, size_t bufsize) {
   if (!name || !buf || bufsize == 0) return false;
   if (assembler_user_symbol_needs_escape(name)) {
      snprintf(buf, bufsize, "%s?", name);
   }
   else {
      snprintf(buf, bufsize, "%s", name);
   }
   return true;
}

//! @brief Handle function symbol name logic for compiler overload resolver.
bool function_symbol_name(const ASTNode *fn, const char *fallback_name, char *buf, size_t bufsize) {
   const ASTNode *declarator = function_declarator_node(fn);
   const char *name = fallback_name;

   if (!buf || bufsize == 0) {
      return false;
   }
   buf[0] = 0;

   if (!name && declarator) {
      name = declarator_name(declarator);
   }
   if (!name) {
      return false;
   }

   if (!ordinary_function_name_is_overloaded(name)) {
      return format_user_asm_symbol(name, buf, bufsize);
   }

   append_mangled_text(buf, bufsize, name);
   if (!fn) {
      return true;
   }

   append_callable_signature_mangle(buf, bufsize, declarator);
   {
      char raw[256];
      snprintf(raw, sizeof(raw), "%s", buf);
      return format_user_asm_symbol(raw, buf, bufsize);
   }
}


//! @brief Return whether ordinary function name is overloaded in compiler overload resolver.
bool ordinary_function_name_is_overloaded(const char *name) {
   int count = 0;

   if (!name) {
      return false;
   }

   for (int i = 0; i < ordinary_function_count; i++) {
      if (strcmp(ordinary_functions[i].name, name)) {
         continue;
      }
      count++;
      if (count > 1) {
         return true;
      }
   }

   return false;
}


//! @brief Add format text to compiler overload resolver state, growing storage or preserving uniqueness as needed.
static void append_format_text(char **buf, size_t *cap, size_t *len, const char *fmt, ...) {
   va_list args;
   va_list args_copy;
   int needed;

   if (!buf || !cap || !len || !fmt) {
      return;
   }

   if (!*buf || *cap == 0) {
      *cap = 128;
      *len = 0;
      *buf = (char *) malloc(*cap);
      if (!*buf) {
         error_unreachable("out of memory");
      }
      (*buf)[0] = 0;
   }

   while (1) {
      size_t avail = (*cap > *len) ? (*cap - *len) : 0;
      va_start(args, fmt);
      va_copy(args_copy, args);
      needed = vsnprintf(*buf + *len, avail, fmt, args_copy);
      va_end(args_copy);
      va_end(args);
      if (needed < 0) {
         error_unreachable("vsnprintf failed");
      }
      if ((size_t) needed < avail) {
         *len += (size_t) needed;
         return;
      }
      *cap = (*cap * 2 > *len + (size_t) needed + 1) ? *cap * 2 : *len + (size_t) needed + 1;
      *buf = (char *) realloc(*buf, *cap);
      if (!*buf) {
         error_unreachable("out of memory");
      }
   }
}

//! @brief Add array suffix text to compiler overload resolver state, growing storage or preserving uniqueness as needed.
static void append_array_suffix_text(char **buf, size_t *cap, size_t *len, const ASTNode *declarator) {
   const ASTNode *value_decl = declarator_value_declarator(declarator);
   int start;

   if (!value_decl || declarator_is_function(declarator)) {
      return;
   }

   start = declarator_suffix_start_index(value_decl);
   for (int i = start; i < value_decl->count; i++) {
      const ASTNode *child = value_decl->children[i];
      if (child && child->kind == AST_INTEGER && child->strval) {
         append_format_text(buf, cap, len, "[%s]", child->strval);
      }
   }
}

//! @brief Add parameter list text to compiler overload resolver state, growing storage or preserving uniqueness as needed.
static void append_parameter_list_text(char **buf, size_t *cap, size_t *len, const ASTNode *params) {
   bool saw_any = false;

   if (params && !is_empty(params)) {
      for (int i = 0; i < params->count; i++) {
         const ASTNode *parameter = params->children[i];
         if (!parameter) {
            continue;
         }
         if (parameter_is_void(parameter)) {
            continue;
         }
         append_format_text(buf, cap, len, "%s", saw_any ? ", " : "");
         append_type_declarator_text(buf, cap, len,
               parameter_type(parameter),
               parameter_declarator(parameter),
               parameter_is_ref(parameter));
         saw_any = true;
      }
   }

   if (!saw_any) {
      append_format_text(buf, cap, len, "void");
   }
}

//! @brief Add type declarator text to compiler overload resolver state, growing storage or preserving uniqueness as needed.
static void append_type_declarator_text(char **buf, size_t *cap, size_t *len, const ASTNode *type, const ASTNode *declarator, bool is_ref) {
   const char *type_name = type_name_from_node(type);

   if (is_ref) {
      append_format_text(buf, cap, len, "ref ");
   }

   append_format_text(buf, cap, len, "%s", type_name ? type_name : "?");

   if (!declarator) {
      return;
   }

   if (declarator_has_parameter_list(declarator)) {
      const ASTNode *ret_decl = function_return_declarator_from_callable(declarator);
      const ASTNode *params = declarator_parameter_list(declarator);
      int ret_ptr_depth = declarator_pointer_depth(ret_decl);

      for (int i = 0; i < ret_ptr_depth; i++) {
         append_format_text(buf, cap, len, "*");
      }
      append_array_suffix_text(buf, cap, len, ret_decl);
      append_format_text(buf, cap, len, "(");
      append_parameter_list_text(buf, cap, len, params);
      append_format_text(buf, cap, len, ")");
      return;
   }

   for (int i = 0; i < declarator_pointer_depth(declarator); i++) {
      append_format_text(buf, cap, len, "*");
   }
   append_array_suffix_text(buf, cap, len, declarator);
}

//! @brief Return describe call argument list data used by compiler overload resolver; returned pointers alias existing storage unless explicitly allocated by the function name.
static char *describe_call_argument_list(int arg_count, const ASTNode **arg_types, const ASTNode **arg_decls) {
   char *buf = NULL;
   size_t cap = 0;
   size_t len = 0;

   append_format_text(&buf, &cap, &len, "(");
   if (arg_count <= 0) {
      append_format_text(&buf, &cap, &len, "void");
   }
   else {
      for (int i = 0; i < arg_count; i++) {
         if (i > 0) {
            append_format_text(&buf, &cap, &len, ", ");
         }
         append_type_declarator_text(&buf, &cap, &len,
               arg_types ? arg_types[i] : NULL,
               arg_decls ? arg_decls[i] : NULL,
               false);
      }
   }
   append_format_text(&buf, &cap, &len, ")");
   return buf;
}

//! @brief Return describe same name overloads data used by compiler overload resolver; returned pointers alias existing storage unless explicitly allocated by the function name.
static char *describe_same_name_overloads(const char *name) {
   char *buf = NULL;
   size_t cap = 0;
   size_t len = 0;

   for (int i = 0; i < ordinary_function_count; i++) {
      const ASTNode *fn;
      const ASTNode *decl;
      const ASTNode *params;
      const char *file;
      int line;
      int column;

      if (!name || strcmp(ordinary_functions[i].name, name)) {
         continue;
      }

      fn = ordinary_functions[i].node;
      decl = function_declarator_node(fn);
      params = declarator_parameter_list(decl);
      {
         const ASTNode *name_node = declarator_name_node(decl);
         file = (name_node && name_node->file) ? name_node->file : ((fn && fn->file) ? fn->file : "?");
         line = (name_node && name_node->line > 0) ? name_node->line : (fn ? fn->line : 0);
         column = (name_node && name_node->line > 0) ? name_node->column : (fn ? fn->column : 0);
      }

      append_format_text(&buf, &cap, &len, "      %s:%d.%d   %s(", file, line, column, name);
      append_parameter_list_text(&buf, &cap, &len, params);
      append_format_text(&buf, &cap, &len, ")\n");
   }

   if (!buf) {
      append_format_text(&buf, &cap, &len, "      <none>");
   }
   else if (len > 0 && buf[len - 1] == '\n') {
      buf[len - 1] = 0;
   }

   return buf;
}

//! @brief Report the first exact ref-parameter candidate rejected only because the argument is not an lvalue.
static void maybe_report_ref_non_lvalue_argument(const char *name, int arg_count,
                                                 const ASTNode **arg_types,
                                                 const ASTNode **arg_decls,
                                                 const bool *arg_lvalues,
                                                 const ASTNode **arg_exprs) {
   if (!name || !arg_types || !arg_lvalues) {
      return;
   }

   for (int i = 0; i < ordinary_function_count; i++) {
      const ASTNode *fn;
      const ASTNode *declarator;
      const ASTNode *params;
      int seen = 0;

      if (strcmp(ordinary_functions[i].name, name)) {
         continue;
      }

      fn = ordinary_functions[i].node;
      declarator = function_declarator_node(fn);
      params = declarator_parameter_list(declarator);
      if (function_fixed_param_count(fn) != arg_count) {
         continue;
      }

      if (!params || is_empty(params)) {
         continue;
      }

      for (int pi = 0; pi < params->count; pi++) {
         const ASTNode *parameter = params->children[pi];
         const ASTNode *ptype;
         const ASTNode *pdecl;
         const char *pname;
         const char *aname;
         const ASTNode *loc;

         if (!parameter || parameter_is_void(parameter)) {
            continue;
         }
         if (seen >= arg_count) {
            break;
         }
         if (!parameter_is_ref(parameter)) {
            seen++;
            continue;
         }
         if (arg_lvalues[seen]) {
            seen++;
            continue;
         }

         ptype = parameter_type(parameter);
         pdecl = parameter_declarator(parameter);
         pname = type_name_from_node(ptype);
         aname = type_name_from_node(arg_types[seen]);
         if (!pname || !aname || strcmp(pname, aname)) {
            seen++;
            continue;
         }
         if (!declarator_signature_matches(arg_decls ? arg_decls[seen] : NULL, pdecl)) {
            seen++;
            continue;
         }

         loc = (arg_exprs && arg_exprs[seen]) ? arg_exprs[seen] : NULL;
         if (loc && loc->file && loc->line > 0) {
            message_set_location(loc->file, loc->line, loc->column, loc->name ? loc->name : NULL);
         }
         error_user("argument %d passed to ref parameter of function '%s' must be an lvalue", seen + 1, name);
      }
   }
}

//! @brief Find ordinary function overload in compiler overload resolver tables without transferring ownership.
static const ASTNode *lookup_ordinary_function_overload(const char *name, const ASTNode *call_expr, int arg_count, const ASTNode **arg_types, const ASTNode **arg_decls, const bool *arg_lvalues, const ASTNode **arg_exprs, Context *ctx) {
   const ASTNode *best = NULL;
   int best_cost = INT_MAX;
   bool ambiguous = false;
   bool saw_name = false;

   for (int i = 0; i < ordinary_function_count; i++) {
      int cost;

      if (strcmp(ordinary_functions[i].name, name)) {
         continue;
      }
      saw_name = true;
      cost = function_signature_match_cost(ordinary_functions[i].node, arg_count, arg_types, arg_decls, arg_lvalues, arg_exprs, ctx);
      if (cost < 0) {
         continue;
      }
      if (!best || cost < best_cost) {
         best = ordinary_functions[i].node;
         best_cost = cost;
         ambiguous = false;
      }
      else if (cost == best_cost) {
         ambiguous = true;
      }
   }

   if (!best && saw_name) {
      maybe_report_ref_non_lvalue_argument(name, arg_count, arg_types, arg_decls, arg_lvalues, arg_exprs);
   }

   if ((ambiguous && best) || (!best && saw_name)) {
      const char *near = name;
      char *call_args = describe_call_argument_list(arg_count, arg_types, arg_decls);
      char *overloads = describe_same_name_overloads(name);
      const ASTNode *callee = NULL;
      const ASTNode *loc = call_expr;

      if (call_expr && call_expr->count > 0) {
         callee = call_expr->children[0];
      }
      if (callee && callee->file && callee->line > 0) {
         loc = callee;
      }
      if (loc && loc->file && loc->line > 0) {
         const char *callee_name = callee ? expr_bare_identifier_name((ASTNode *) callee) : NULL;
         message_set_location(loc->file, loc->line, loc->column, callee_name ? callee_name : near);
      }
      error_user(ambiguous ? "ambiguous call to overloaded function '%s'\n   call arguments: %s\n\n   candidates:\n%s"
                           : "no viable overload for function '%s'\n   call arguments: %s\n\n   candidates:\n%s",
            name,
            call_args ? call_args : "(?)",
            overloads ? overloads : "      <none>");
   }

   return best;
}

//! @brief Return any visible function with this name for unsupported-function-pointer diagnostics.
const ASTNode *resolve_function_designator_target(const char *name) {
   if (!name) {
      return NULL;
   }

   for (int i = 0; i < ordinary_function_count; i++) {
      if (!strcmp(ordinary_functions[i].name, name)) {
         return ordinary_functions[i].node;
      }
   }
   return NULL;
}

//! @brief Compute function call target and update compiler overload resolver state once prerequisite pass data is available.
const ASTNode *resolve_function_call_target(const char *name, ASTNode *call_expr, ASTNode *args, Context *ctx) {
   int arg_count = (args && !is_empty(args)) ? args->count : 0;
   const ASTNode **arg_types = NULL;
   const ASTNode **arg_decls = NULL;
   const ASTNode **arg_exprs = NULL;
   bool *arg_lvalues = NULL;
   const ASTNode *ret = NULL;

   if (arg_count > 0) {
      arg_types = calloc((size_t) arg_count, sizeof(*arg_types));
      arg_decls = calloc((size_t) arg_count, sizeof(*arg_decls));
      arg_exprs = calloc((size_t) arg_count, sizeof(*arg_exprs));
      arg_lvalues = calloc((size_t) arg_count, sizeof(*arg_lvalues));
      if (!arg_types || !arg_decls || !arg_exprs || !arg_lvalues) {
         free((void *) arg_types);
         free((void *) arg_decls);
         free((void *) arg_exprs);
         free(arg_lvalues);
         return NULL;
      }
   }

   for (int i = 0; i < arg_count; i++) {
      arg_exprs[i] = unwrap_expr_node(args->children[i]);
      expr_match_signature(args->children[i], ctx, &arg_types[i], &arg_decls[i]);
      arg_lvalues[i] = resolve_ref_argument_lvalue(ctx, args->children[i], NULL);
   }

   ret = lookup_ordinary_function_overload(name, call_expr, arg_count, arg_types, arg_decls, arg_lvalues, arg_exprs, ctx);

   free((void *) arg_types);
   free((void *) arg_decls);
   free((void *) arg_exprs);
   free(arg_lvalues);
   return ret;
}




//! @brief Add function to compiler overload resolver state, growing storage or preserving uniqueness as needed.
void remember_function(const ASTNode *node, const char *name) {
   bool name_present = false;

   validate_function_nonreserved_implementation_names(node);
   validate_function_parameter_storage_modifiers(node);

   if (!name) {
      error_user("[%s:%d.%d] unnamed function declaration is not supported here", node->file, node->line, node->column);
   }

   if (!functions) {
      functions = new_set();
   }

   for (int i = 0; i < ordinary_function_count; i++) {
      const ASTNode *value;

      if (strcmp(ordinary_functions[i].name, name)) {
         continue;
      }
      name_present = true;
      value = ordinary_functions[i].node;
      if (value == node) {
         return;
      }
      if (function_same_signature(value, node)) {
         if (!function_same_declaration(value, node)) {
            error_user("[%s:%d.%d] vs [%s:%d.%d] conflicting declarations for overloaded '%s'",
                  node->file, node->line, node->column,
                  value->file, value->line, value->column,
                  name);
         }
         if (function_has_body(value) && function_has_body(node)) {
            error_user("[%s:%d.%d] vs [%s:%d.%d] multiple definitions for '%s'",
                  node->file, node->line, node->column,
                  value->file, value->line, value->column,
                  name);
         }
         if (!function_has_body(value) && function_has_body(node)) {
            ordinary_functions[i].node = node;
            if (set_get(functions, name) == value) {
               set_rm(functions, name);
               set_add(functions, strdup(name), (void *) node);
            }
         }
         return;
      }
   }

   ordinary_functions = (OrdinaryFunction *) realloc(ordinary_functions,
         sizeof(*ordinary_functions) * (ordinary_function_count + 1));
   if (!ordinary_functions) {
      error_unreachable("out of memory");
   }
   ordinary_functions[ordinary_function_count].name = strdup(name);
   ordinary_functions[ordinary_function_count].node = node;
   ordinary_function_count++;

   if (!name_present && !set_get(functions, name)) {
      set_add(functions, strdup(name), (void *) node);
   }
}
