//! @file compiler/compile_declarator.c
//! @brief Implements declarator analysis for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast.h"
#include "compile_declarator.h"
#include "compile_literal.h"
#include "compile_type.h"

//! @brief Return decl subitem declarator data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *decl_subitem_declarator(const ASTNode *node) {
   if (!node) {
      return NULL;
   }
   if (strcmp(node->name, "decl_subitem") || node->count <= 0) {
      return node;
   }
   return node->children[0];
}

//! @brief Handle declarator array signature matches from logic for compiler declarator handling.
bool declarator_array_signature_matches_from(const ASTNode *actual, const ASTNode *formal, int start_child) {
   int ai = start_child;
   int fi = start_child;

   while (1) {
      while (actual && ai < actual->count && (!actual->children[ai] || actual->children[ai]->kind != AST_INTEGER)) {
         ai++;
      }
      while (formal && fi < formal->count && (!formal->children[fi] || formal->children[fi]->kind != AST_INTEGER)) {
         fi++;
      }
      if ((!actual || ai >= actual->count) && (!formal || fi >= formal->count)) {
         return true;
      }
      if (!actual || ai >= actual->count || !formal || fi >= formal->count) {
         return false;
      }
      if (strcmp(actual->children[ai]->strval, formal->children[fi]->strval)) {
         return false;
      }
      ai++;
      fi++;
   }
}

//! @brief Handle declarator signature matches logic for compiler declarator handling.
bool declarator_signature_matches(const ASTNode *actual, const ASTNode *formal) {
   if (declarator_pointer_depth(actual) != declarator_pointer_depth(formal)) {
      return false;
   }
   if (declarator_array_count(actual) != declarator_array_count(formal)) {
      return false;
   }
   return declarator_array_signature_matches_from(actual, formal, 2);
}

//! @brief Return whether declarator is plain value in compiler declarator handling.
bool declarator_is_plain_value(const ASTNode *declarator) {
   return declarator_pointer_depth(declarator) == 0 && declarator_array_count(declarator) == 0;
}

//! @brief Create synthetic pointer declarator for compiler declarator handling. The returned storage is owned by the caller or the object that immediately records it.
static const ASTNode *make_synthetic_pointer_declarator(int ptr_depth) {
   ASTNode *decl;
   char depth_buf[32];

   if (ptr_depth < 0) {
      return NULL;
   }

   decl = make_node("declarator", NULL);
   if (!decl) {
      return NULL;
   }

   snprintf(depth_buf, sizeof(depth_buf), "%d", ptr_depth);
   decl = append_child(decl, make_integer_leaf(strdup(depth_buf)));
   decl->children[0]->name = "pointer";
   decl = append_child(decl, make_empty_leaf());
   return decl;
}

//! @brief Return decayed array declarator data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *decayed_array_declarator(const ASTNode *declarator) {
   const ASTNode *value_decl;
   int start;

   if (!declarator || declarator_pointer_depth(declarator) > 0 || declarator_array_count(declarator) <= 0) {
      return declarator;
   }

   value_decl = declarator_value_declarator(declarator);
   start = declarator_suffix_start_index(value_decl ? value_decl : declarator);
   return clone_declarator_variant(value_decl ? value_decl : declarator, 1, start + 1);
}

//! @brief Return call adjusted parameter declarator data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *call_adjusted_parameter_declarator(const ASTNode *declarator, bool is_ref) {
   if (!is_ref && declarator && declarator_pointer_depth(declarator) == 0 && declarator_array_count(declarator) > 0) {
      return decayed_array_declarator(declarator);
   }
   return declarator;
}

//! @brief Handle expr match signature logic for compiler declarator handling.
void expr_match_signature(ASTNode *expr, Context *ctx, const ASTNode **type_out, const ASTNode **decl_out) {
   const ASTNode *type;
   const ASTNode *decl;

   expr = (ASTNode *) unwrap_expr_node(expr);
   if (!expr || is_empty(expr)) {
      if (type_out) *type_out = NULL;
      if (decl_out) *decl_out = NULL;
      return;
   }

   type = expr_value_type(expr, ctx);
   decl = expr_value_declarator(expr, ctx);

   if (expr->kind == AST_STRING && !string_literal_is_char_constant(expr->strval)) {
      type = required_typename_node("char");
      decl = make_synthetic_pointer_declarator(1);
   }
   else if (decl && declarator_pointer_depth(decl) == 0 && declarator_array_count(decl) > 0) {
      decl = decayed_array_declarator(decl);
   }
   else if (expr->count == 2 && (!strcmp(expr->name, "+") || !strcmp(expr->name, "-"))) {
      const ASTNode *lhs_type = NULL;
      const ASTNode *lhs_decl = NULL;
      const ASTNode *rhs_type = NULL;
      const ASTNode *rhs_decl = NULL;

      expr_match_signature(expr->children[0], ctx, &lhs_type, &lhs_decl);
      expr_match_signature(expr->children[1], ctx, &rhs_type, &rhs_decl);

      if (lhs_decl && declarator_pointer_depth(lhs_decl) > 0 && !(rhs_decl && declarator_pointer_depth(rhs_decl) > 0)) {
         type = lhs_type;
         decl = lhs_decl;
      }
      else if (!strcmp(expr->name, "+") && rhs_decl && declarator_pointer_depth(rhs_decl) > 0 && !(lhs_decl && declarator_pointer_depth(lhs_decl) > 0)) {
         type = rhs_type;
         decl = rhs_decl;
      }
   }

   if (type_out) *type_out = type;
   if (decl_out) *decl_out = decl;
}

//! @brief Return missing argname data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *missing_argname(int i) {
   static char ret[16];
   sprintf(ret, "$%d", i);
   return ret;
}

//! @brief Create named pointer declarator for compiler declarator handling. The returned storage is owned by the caller or the object that immediately records it.
ASTNode *make_named_pointer_declarator(const char *name) {
   ASTNode *ret;

   ret = make_node("declarator", NULL);
   ret = append_child(ret, make_integer_leaf(strdup("1")));
   ret->children[0]->name = "pointer";
   ret = append_child(ret, name ? make_identifier_leaf(strdup(name)) : make_empty_leaf());
   return ret;
}

//! @brief Return parameter decl specifiers data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *parameter_decl_specifiers(const ASTNode *parameter) {
   return parameter->count > 0 ? parameter->children[0] : NULL;
}

//! @brief Return parameter decl item data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *parameter_decl_item(const ASTNode *parameter) {
   return parameter->count > 1 ? parameter->children[1] : NULL;
}

//! @brief Return parameter type data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *parameter_type(const ASTNode *parameter) {
   const ASTNode *decl_specs = parameter_decl_specifiers(parameter);
   return (decl_specs && decl_specs->count > 1) ? decl_specs->children[1] : NULL;
}

//! @brief Return parameter declarator data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *parameter_declarator(const ASTNode *parameter) {
   const ASTNode *decl_item = parameter_decl_item(parameter);
   return (decl_item && decl_item->count > 0) ? decl_subitem_declarator(decl_item->children[0]) : NULL;
}

//! @brief Return whether parameter is ref in compiler declarator handling.
bool parameter_is_ref(const ASTNode *parameter) {
   const ASTNode *decl_specs = parameter_decl_specifiers(parameter);
   const ASTNode *modifiers = (decl_specs && decl_specs->count > 0) ? decl_specs->children[0] : NULL;
   return has_modifier((ASTNode *) modifiers, "ref");
}

//! @brief Return whether parameter has symbol storage in compiler declarator handling.
bool parameter_has_symbol_storage(const ASTNode *parameter) {
   const ASTNode *decl_specs = parameter_decl_specifiers(parameter);
   const ASTNode *modifiers = (decl_specs && decl_specs->count > 0) ? decl_specs->children[0] : NULL;
   return has_modifier((ASTNode *) modifiers, "static") || modifiers_imply_mem_storage(modifiers);
}

//! @brief Handle parameter storage size logic for compiler declarator handling.
int parameter_storage_size(const ASTNode *parameter) {
   const ASTNode *ptype = parameter_type(parameter);
   const ASTNode *pdecl = call_adjusted_parameter_declarator(parameter_declarator(parameter), parameter_is_ref(parameter));
   if (parameter_is_ref(parameter)) {
      return get_size("*");
   }
   return declarator_storage_size(ptype, pdecl);
}

//! @brief Return parameter name data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *parameter_name(const ASTNode *parameter, int i) {
   const ASTNode *declarator = parameter_declarator(parameter);
   if (!declarator || !declarator_name(declarator)) {
      return missing_argname(i);
   }
   return declarator_name(declarator);
}

//! @brief Return whether parameter is void in compiler declarator handling.
bool parameter_is_void(const ASTNode *parameter) {
   const ASTNode *type = parameter_type(parameter);
   const ASTNode *declarator = parameter_declarator(parameter);

   if (!type || strcmp(type->strval, "void")) {
      return false;
   }

   if (declarator && declarator_name(declarator)) {
      return false;
   }

   if (declarator && !declarator_is_plain_value(declarator)) {
      return false;
   }

   return true;
}

//! @brief Return unwrap expression node data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *unwrap_expr_node(const ASTNode *expr) {
   while (expr && expr->count == 1 &&
          (!strcmp(expr->name, "expr") ||
           !strcmp(expr->name, "assign_expr") ||
           !strcmp(expr->name, "conditional_expr") ||
           !strcmp(expr->name, "case_conditional_expr") ||
           !strcmp(expr->name, "initializer") ||
           !strcmp(expr->name, "opt_expr") ||
           !strcmp(expr->name, "case_choice") ||
           !strcmp(expr->name, "case_term"))) {
      expr = expr->children[0];
   }
   return expr;
}

//! @brief Handle declarator pointer node count logic for compiler declarator handling.
int declarator_pointer_node_count(const ASTNode *declarator) {
   int count = 0;

   if (!declarator) {
      return 0;
   }

   while (count < declarator->count && declarator->children[count] &&
          !strcmp(declarator->children[count]->name, "pointer")) {
      count++;
   }

   return count;
}

//! @brief Return declarator nested data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
static const ASTNode *declarator_nested(const ASTNode *declarator) {
   int pcount = declarator_pointer_node_count(declarator);

   if (!declarator || pcount >= declarator->count) {
      return NULL;
   }

   if (declarator->children[pcount] && !strcmp(declarator->children[pcount]->name, "declarator")) {
      return declarator->children[pcount];
   }

   return NULL;
}

//! @brief Return declarator value declarator data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *declarator_value_declarator(const ASTNode *declarator) {
   const ASTNode *nested = declarator_nested(declarator);

   if (nested && declarator_parameter_list(declarator)) {
      return nested;
   }

   return declarator;
}

//! @brief Return declarator name node data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *declarator_name_node(const ASTNode *declarator) {
   const ASTNode *nested = declarator_nested(declarator);
   int pcount = declarator_pointer_node_count(declarator);
   const ASTNode *fallback = NULL;

   if (!declarator) {
      return NULL;
   }

   if (nested) {
      return declarator_name_node(nested);
   }

   for (int i = pcount; i < declarator->count; i++) {
      const ASTNode *child = declarator->children[i];
      if (!child) {
         continue;
      }
      if (child->kind == AST_IDENTIFIER) {
         return child;
      }
      if (!fallback && child->kind == AST_EMPTY) {
         fallback = child;
      }
   }

   return fallback;
}

//! @brief Return declarator name data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *declarator_name(const ASTNode *declarator) {
   const ASTNode *name = declarator_name_node(declarator);

   if (!name || is_empty(name) || !name->strval) {
      return NULL;
   }

   return name->strval;
}

//! @brief Return declarator bitfield node data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *declarator_bitfield_node(const ASTNode *declarator) {
   const ASTNode *value_decl = declarator_value_declarator(declarator);
   int start;

   if (!value_decl) {
      return NULL;
   }

   start = declarator_suffix_start_index(value_decl);
   for (int i = start; i < value_decl->count; i++) {
      const ASTNode *child = value_decl->children[i];
      if (child && !strcmp(child->name, "bitfield_width")) {
         return child;
      }
   }

   return NULL;
}

//! @brief Handle declarator bitfield width logic for compiler declarator handling.
int declarator_bitfield_width(const ASTNode *declarator) {
   const ASTNode *node = declarator_bitfield_node(declarator);

   if (!node || node->count <= 0 || !node->children[0] || !node->children[0]->strval) {
      return 0;
   }

   return atoi(node->children[0]->strval);
}

//! @brief Handle declarator suffix start index logic for compiler declarator handling.
int declarator_suffix_start_index(const ASTNode *declarator) {
   const ASTNode *nested = declarator_nested(declarator);
   const ASTNode *name = declarator_name_node(declarator);

   if (!declarator) {
      return 0;
   }

   if (nested) {
      return declarator->count;
   }

   for (int i = 0; i < declarator->count; i++) {
      if (declarator->children[i] == name) {
         return i + 1;
      }
   }

   return declarator_pointer_node_count(declarator);
}

//! @brief Return declarator parameter list data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *declarator_parameter_list(const ASTNode *declarator) {
   int start = declarator_pointer_node_count(declarator) + 1;

   if (!declarator) {
      return NULL;
   }

   for (int i = start; i < declarator->count; i++) {
      if (declarator->children[i] && !strcmp(declarator->children[i]->name, "parameter_list")) {
         return declarator->children[i];
      }
   }

   return NULL;
}

//! @brief Return whether declarator has parameter list in compiler declarator handling.
bool declarator_has_parameter_list(const ASTNode *declarator) {
   return declarator_parameter_list(declarator) != NULL;
}

//! @brief Handle declarator pointer depth logic for compiler declarator handling.
int declarator_pointer_depth(const ASTNode *declarator) {
   const ASTNode *value_decl = declarator_value_declarator(declarator);
   int pcount = declarator_pointer_node_count(value_decl);

   if (!value_decl || pcount == 0) {
      return 0;
   }

   return value_decl->children[0] && value_decl->children[0]->strval ? atoi(value_decl->children[0]->strval) : 0;
}

//! @brief Handle declarator function pointer depth logic for compiler declarator handling.
int declarator_function_pointer_depth(const ASTNode *declarator) {
   const ASTNode *nested = declarator_nested(declarator);

   if (!declarator_has_parameter_list(declarator) || !nested) {
      return 0;
   }

   return declarator_pointer_depth(nested);
}

//! @brief Handle declarator array multiplier from logic for compiler declarator handling.
int declarator_array_multiplier_from(const ASTNode *declarator, int start_child) {
   int mult = 1;
   const ASTNode *value_decl = declarator_value_declarator(declarator);

   if (!value_decl || declarator_is_function(declarator)) {
      return 1;
   }

   for (int i = start_child; i < value_decl->count; i++) {
      if (value_decl->children[i] && value_decl->children[i]->kind == AST_INTEGER) {
         mult *= atoi(value_decl->children[i]->strval);
      }
   }

   return mult;
}

//! @brief Handle declarator array count logic for compiler declarator handling.
int declarator_array_count(const ASTNode *declarator) {
   int count = 0;
   const ASTNode *value_decl = declarator_value_declarator(declarator);
   int start = declarator_suffix_start_index(value_decl);

   if (!value_decl || declarator_is_function(declarator)) {
      return 0;
   }

   for (int i = start; i < value_decl->count; i++) {
      if (value_decl->children[i] && value_decl->children[i]->kind == AST_INTEGER) {
         count++;
      }
   }

   return count;
}

//! @brief Handle declarator first element size logic for compiler declarator handling.
int declarator_first_element_size(const ASTNode *type, const ASTNode *declarator) {
   const ASTNode *value_decl = declarator_value_declarator(declarator);

   if (declarator_pointer_depth(declarator) > 0) {
      return get_size(type_name_from_node(type));
   }
   return get_size(type_name_from_node(type)) * declarator_array_multiplier_from(value_decl, declarator_suffix_start_index(value_decl) + 1);
}

//! @brief Return clone declarator variant data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *clone_declarator_variant(const ASTNode *declarator, int new_ptr_depth, int first_array_child) {
   ASTNode *copy;
   char depth_buf[32];
   const ASTNode *name = declarator_name_node(declarator);

   if (!declarator) {
      return NULL;
   }

   snprintf(depth_buf, sizeof(depth_buf), "%d", new_ptr_depth);
   copy = make_node(declarator->name, NULL);
   copy->file = declarator->file;
   copy->line = declarator->line;
   copy->column = declarator->column;
   copy->handled = declarator->handled;
   copy->kind = declarator->kind;

   copy = append_child(copy, make_integer_leaf(strdup(depth_buf)));
   copy->children[0]->name = "pointer";
   if (name) {
      copy = append_child(copy, (ASTNode *) name);
   }
   else {
      copy = append_child(copy, make_empty_leaf());
   }
   for (int i = first_array_child; i < declarator->count; i++) {
      if (declarator->children[i] && strcmp(declarator->children[i]->name, "parameter_list")) {
         copy = append_child(copy, (ASTNode *) declarator->children[i]);
      }
   }
   return copy;
}

//! @brief Extract function pointer declarator from callable for compiler declarator handling.
const ASTNode *function_pointer_declarator_from_callable(const ASTNode *declarator) {
   ASTNode *copy;
   ASTNode *nested;
   char depth_buf[32];
   int outer_depth = 0;
   int param_index = -1;

   if (!declarator || !declarator_has_parameter_list(declarator)) {
      return NULL;
   }

   if (declarator_function_pointer_depth(declarator) > 0) {
      return declarator;
   }

   if (declarator->children[0] && declarator->children[0]->strval) {
      outer_depth = atoi(declarator->children[0]->strval);
   }

   copy = make_node(declarator->name, NULL);
   copy->file = declarator->file;
   copy->line = declarator->line;
   copy->column = declarator->column;
   copy->handled = declarator->handled;
   copy->kind = declarator->kind;

   snprintf(depth_buf, sizeof(depth_buf), "%d", outer_depth);
   copy = append_child(copy, make_integer_leaf(strdup(depth_buf)));
   copy->children[0]->name = "pointer";
   nested = make_node("declarator", NULL);
   nested = append_child(nested, make_integer_leaf(strdup("1")));
   nested->children[0]->name = "pointer";
   nested = append_child(nested, make_empty_leaf());
   copy = append_child(copy, nested);
   for (int i = 0; i < declarator->count; i++) {
      if (declarator->children[i] && !strcmp(declarator->children[i]->name, "parameter_list")) {
         param_index = i;
         break;
      }
   }
   for (int i = param_index; param_index >= 0 && i < declarator->count; i++) {
      append_child(copy, (ASTNode *) declarator->children[i]);
   }

   return copy;
}

//! @brief Extract function return declarator from callable for compiler declarator handling.
const ASTNode *function_return_declarator_from_callable(const ASTNode *declarator) {
   ASTNode *copy;
   char depth_buf[32];
   int outer_depth = 0;
   int param_index = -1;

   if (!declarator || !declarator_has_parameter_list(declarator)) {
      return NULL;
   }

   if (declarator->children[0] && declarator->children[0]->strval) {
      outer_depth = atoi(declarator->children[0]->strval);
   }

   copy = make_node(declarator->name, NULL);
   copy->file = declarator->file;
   copy->line = declarator->line;
   copy->column = declarator->column;
   copy->handled = declarator->handled;
   copy->kind = declarator->kind;

   snprintf(depth_buf, sizeof(depth_buf), "%d", outer_depth);
   copy = append_child(copy, make_integer_leaf(strdup(depth_buf)));
   copy->children[0]->name = "pointer";
   copy = append_child(copy, make_empty_leaf());

   for (int i = 0; i < declarator->count; i++) {
      if (declarator->children[i] && !strcmp(declarator->children[i]->name, "parameter_list")) {
         param_index = i;
         break;
      }
   }
   for (int i = param_index + 1; param_index >= 0 && i < declarator->count; i++) {
      if (declarator->children[i] && declarator->children[i]->kind == AST_INTEGER) {
         copy = append_child(copy, (ASTNode *) declarator->children[i]);
      }
   }

   return copy;
}

//! @brief Return declarator after subscript data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *declarator_after_subscript(const ASTNode *declarator) {
   int ptr_depth = declarator_pointer_depth(declarator);
   const ASTNode *value_decl = declarator_value_declarator(declarator);

   if (!value_decl) {
      return NULL;
   }
   if (ptr_depth > 0) {
      return clone_declarator_variant(value_decl, ptr_depth - 1, declarator_suffix_start_index(value_decl));
   }
   if (declarator_array_count(value_decl) > 0) {
      return clone_declarator_variant(value_decl, ptr_depth, declarator_suffix_start_index(value_decl) + 1);
   }
   return NULL;
}

//! @brief Return declarator after deref data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *declarator_after_deref(const ASTNode *declarator) {
   int ptr_depth = declarator_pointer_depth(declarator);
   const ASTNode *value_decl = declarator_value_declarator(declarator);

   if (ptr_depth <= 0 || !value_decl) {
      return NULL;
   }
   return clone_declarator_variant(value_decl, ptr_depth - 1, declarator_suffix_start_index(value_decl));
}

//! @brief Return function return type data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *function_return_type(const ASTNode *fn) {
   if (!fn) {
      return NULL;
   }
   if (fn->count == 3) {
      return fn->children[0]->children[1];
   }
   if (fn->count == 4) {
      return fn->children[1];
   }
   return NULL;
}

//! @brief Return function declarator node data used by compiler declarator handling; returned pointers alias existing storage unless explicitly allocated by the function name.
const ASTNode *function_declarator_node(const ASTNode *fn) {
   if (!fn) {
      return NULL;
   }
   if (fn->count == 3) {
      return fn->children[1];
   }
   if (fn->count == 4) {
      return fn->children[2];
   }
   return NULL;
}


//! @brief Return whether declarator is function in compiler declarator handling.
bool declarator_is_function(const ASTNode *declarator) {
   return declarator && declarator_has_parameter_list(declarator) && !declarator_nested(declarator);
}

//! @brief Handle declarator array multiplier logic for compiler declarator handling.
int declarator_array_multiplier(const ASTNode *declarator) {
   if (!declarator || declarator_is_function(declarator)) {
      return 1;
   }

   return declarator_array_multiplier_from(declarator, declarator_suffix_start_index(declarator));
}

//! @brief Handle declarator storage size logic for compiler declarator handling.
int declarator_storage_size(const ASTNode *type, const ASTNode *declarator) {
   int size;

   if (declarator_pointer_depth(declarator) > 0 || declarator_function_pointer_depth(declarator) > 0) {
      size = get_size("*");
   }
   else {
      size = get_size(type_name_from_node(type));
   }

   return size * declarator_array_multiplier(declarator);
}
