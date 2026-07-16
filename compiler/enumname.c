//! @file compiler/enumname.c
//! @brief Implements enum declaration support for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast.h"
#include "lextern.h"
#include "memname.h"
#include "integer.h"
#include "messages.h"
#include "pair.h"
#include "typename.h"
#include "enumname.h"
#include "xform.h"
#include "xray.h"

static Pair *enums = NULL;

//! @brief Handle enumname exists logic for enumname.
bool enumname_exists(const char* name) {
   if (!enums) {
      enums = pair_create();
   }

   return pair_exists(enums, name);
}

//! @brief Return clone enum value literal data used by enumname; returned pointers alias existing storage unless explicitly allocated by the function name.
static ASTNode *clone_enum_value_literal(const ASTNode *enum_value, ASTNode *type_override) {
   const ASTNode *value;
   ASTNode *type = type_override;

   if (!enum_value || enum_value->count < 2 || !enum_value->children[1] || enum_value->children[1]->kind != AST_INTEGER) {
      yyerror("internal invalid enum value node");
      return make_integer_leaf(strdup("0"));
   }

   value = enum_value->children[1];
   if (!type) {
      if (value->count > 0 && value->children[0]) {
         type = make_typename_leaf(value->children[0]->strval);
      }
      else {
         type = make_typename_leaf("int");
      }
   }

   return make_integer_leaf_with_type(strdup(value->strval), type);
}

//! @brief Add enumnames to enumname state, growing storage or preserving uniqueness as needed.
int register_enumnames(ASTNode *ast) {
   long long next_value = 0;
   bool have_range = false;
   const char *enum_type;

   if (!enums) {
      enums = pair_create();
   }

   if (!ast || ast->count < 2 || !ast->children[0] || !ast->children[1]) {
      yyerror("internal invalid enum declaration");
      return -1;
   }

   enum_type = ast->children[0]->strval;

   // register all the enum names for this enum type.
   for (int i = 0; i < ast->children[1]->count; i++) {
      ASTNode *entry = ast->children[1]->children[i];
      const char *name;
      long long value;
      char buf[64];
      ASTNode *typed_value;

      if (!entry || entry->count < 1 || !entry->children[0]) {
         yyerror("internal invalid enum entry");
         return -1;
      }

      name = entry->children[0]->strval;

      if (xform_exists(name)) {
         ASTNode *previous = get_xform_node(name);
         yyerror ("enumname at %s:%d.%d cannot be the same as existing xform at %s:%d.%d",
               current_filename, yylineno, yycolumn,
               previous->file, previous->line, previous->column);
         return -1;
      }

      if (memname_exists(name)) {
         ASTNode *previous = get_memname_node(name);
         yyerror ("enumname at %s:%d.%d cannot be the same as existing memname at %s:%d.%d",
               current_filename, yylineno, yycolumn,
               previous->file, previous->line, previous->column);
         return -1;
      }

      if (typename_exists(name)) {
         ASTNode *previous = get_typename_node(name);
         yyerror ("enumname at %s:%d.%d cannot be the same as existing typename at %s:%d.%d",
               current_filename, yylineno, yycolumn,
               previous->file, previous->line, previous->column);
         return -1;
      }

      if (enumname_exists(name)) {
         ASTNode *previous = get_enumname_node(name);
         yyerror ("enumname at %s:%d.%d already exists at %s:%d.%d",
               current_filename, yylineno, yycolumn,
               previous->file, previous->line, previous->column);
         return -1;
      }

      if (entry->count >= 2 && entry->children[1] && entry->children[1]->kind == AST_INTEGER) {
         value = parse_int(entry->children[1]->strval);
      }
      else {
         value = next_value;
      }

      snprintf(buf, sizeof(buf), "%lld", value);
      typed_value = make_integer_leaf_with_type(strdup(buf), make_typename_leaf(enum_type));
      if (entry->count >= 2) {
         entry->children[1] = typed_value;
      }
      else {
         entry = append_child(entry, typed_value);
         ast->children[1]->children[i] = entry;
      }

      pair_insert(enums, name, entry);
      next_value = value + 1;
      have_range = true;
   }

   (void) have_range;
   return 0;
}

//! @brief Return get enumname node data used by enumname; returned pointers alias existing storage unless explicitly allocated by the function name.
ASTNode *get_enumname_node(const char *name) {
   if (!enums) {
      enums = pair_create();
   }

   return pair_get(enums, name);
}

//! @brief Create enumname expr for enumname. The returned storage is owned by the caller or the object that immediately records it.
ASTNode *make_enumname_expr(const char *name) {
   ASTNode *node = get_enumname_node(name);
   return clone_enum_value_literal(node, NULL);
}

//! @brief Create enumname expression with type for enumname. The returned storage is owned by the caller or the object that immediately records it.
ASTNode *make_enumname_expr_with_type(const char *name, ASTNode *type) {
   ASTNode *node = get_enumname_node(name);
   return clone_enum_value_literal(node, type);
}

//! @brief Return enumname find null data used by enumname; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *enumname_find_null(void) {
   if (!enums) {
      enums = pair_create();
   }

   return pair_null_value(enums);
}
