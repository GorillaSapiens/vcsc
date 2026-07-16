//! @file compiler/typename.c
//! @brief Implements type-name registry for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast.h"
#include "enumname.h"
#include "lextern.h"
#include "memname.h"
#include "messages.h"
#include "pair.h"
#include "typename.h"
#include "xform.h"
#include "xray.h"

static Pair *types = NULL;

//! @brief Handle typename exists logic for typename.
bool typename_exists(const char* name) {
   if (!types) {
      types = pair_create();
   }

   return pair_exists(types, name);
}

//! @brief Add typename to typename state, growing storage or preserving uniqueness as needed.
int register_typename(const char* name) {
   if (!types) {
      types = pair_create();
   }

   if (xform_exists(name)) {
      ASTNode *previous = get_xform_node(name);
      yyerror ("typename at %s:%d.%d cannot be the same as existing xform at %s:%d.%d",
         current_filename, yylineno, yycolumn,
         previous->file, previous->line, previous->column);
      return -1;
   }

   if (memname_exists(name)) {
      ASTNode *previous = get_memname_node(name);
      yyerror ("typename at %s:%d.%d cannot be the same as existing memname at %s:%d.%d",
         current_filename, yylineno, yycolumn,
         previous->file, previous->line, previous->column);
      return -1;
   }

   if (enumname_exists(name)) {
      ASTNode *previous = get_enumname_node(name);
      yyerror ("typename at %s:%d.%d cannot be the same as existing enum name at %s:%d.%d",
         current_filename, yylineno, yycolumn,
         previous->file, previous->line, previous->column);
      return -1;
   }

   if (typename_exists(name)) {
      ASTNode *previous = get_typename_node(name);
      yyerror ("typename at %s:%d.%d already exists at %s:%d.%d",
         current_filename, yylineno, yycolumn,
         previous->file, previous->line, previous->column);
      return -1;
   }

   pair_insert(types, name, NULL);
   return 0;
}

//! @brief Handle attach typename logic for typename.
void attach_typename(const char *name, ASTNode *node) {
   if (!types) {
      types = pair_create();
   }

   pair_insert(types, name, node);
}

//! @brief Return get typename node data used by typename; returned pointers alias existing storage unless explicitly allocated by the function name.
ASTNode *get_typename_node(const char *name) {
   if (!types) {
      types = pair_create();
   }

   return pair_get(types, name);
}

//! @brief Return typename find null data used by typename; returned pointers alias existing storage unless explicitly allocated by the function name.
const char *typename_find_null(void) {
   if (!types) {
      types = pair_create();
   }

   return pair_null_value(types);
}
