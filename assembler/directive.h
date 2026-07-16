//! @file assembler/directive.h
//! @brief Declares assembler directive handling for the n65 assembler.
//! @ingroup assembler

#ifndef DIRECTIVE_H
#define DIRECTIVE_H

#include "expr.h"

typedef struct expr_list_node expr_list_node_t;

//! Singly-linked list of directive expression operands.
struct expr_list_node {
   expr_t *expr;
   expr_list_node_t *next;
};

//! Shape of the argument payload carried by a parsed directive.
typedef enum directive_arg_kind {
   DIRARG_NONE = 0,
   DIRARG_EXPR_LIST,
   DIRARG_STRING,
   DIRARG_STRING_AND_EXPR_LIST
} directive_arg_kind_t;

//! Parsed assembler directive and its owned argument data.
typedef struct directive_info {
   char *name;
   directive_arg_kind_t kind;
   char *string;
   expr_list_node_t *exprs;
} directive_info_t;

directive_info_t *directive_make_empty(char *name);
directive_info_t *directive_make_exprs(char *name, expr_list_node_t *exprs);
directive_info_t *directive_make_string(char *name, char *string);
directive_info_t *directive_make_string_exprs(char *name, char *string, expr_list_node_t *exprs);

expr_list_node_t *expr_list_node_make(expr_t *expr);
expr_list_node_t *expr_list_append(expr_list_node_t *list, expr_t *expr);

void directive_free(directive_info_t *dir);
void directive_print(const directive_info_t *dir);

#endif
