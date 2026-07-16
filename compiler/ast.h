//! @file compiler/ast.h
//! @brief Declares abstract syntax tree support for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_AST_H_
#define _INCLUDE_AST_H_

#include <stdbool.h>

//! Kinds of leaves and parser-created AST nodes tracked by the compiler.
enum ASTKind {
    AST_GENERIC = 0,
    AST_IDENTIFIER,
    AST_TYPENAME,
    AST_INTEGER,
    AST_FLOAT,
    AST_STRING,
    AST_ASM,
    AST_EMPTY
};

//! Variable-width AST node; child pointers are stored inline after the fixed header.
typedef struct ASTNode {
   const char *name;
   const char *file;
   int line, column;
   bool handled;
   enum ASTKind kind;

   union {
      const char *strval;
   };

   int count;
   struct ASTNode *children[];
} ASTNode;

//! True when an AST node is the explicit empty placeholder used by the grammar.
#define is_empty(x) ((x)->kind == AST_EMPTY)

ASTNode *make_node(const char *name, ...);

ASTNode *append_child(ASTNode *parent, ASTNode *child);
ASTNode *append_children_from(ASTNode *parent, ASTNode *other);

ASTNode *prepend_child(ASTNode *parent, ASTNode *child);
ASTNode *prepend_children_from(ASTNode *parent, ASTNode *other);

ASTNode *make_integer_leaf(const char *intval);
ASTNode *make_integer_leaf_with_type(const char *intval, ASTNode *typename);
ASTNode *increment_integer_leaf(ASTNode *node);
ASTNode *make_string_leaf(const char *strval);
ASTNode *make_asm_leaf(const char *strval);
ASTNode *make_identifier_leaf(const char *strval);
ASTNode *make_typename_leaf(const char *strval);
ASTNode *make_float_leaf(const char *dval);
ASTNode *make_float_leaf_with_type(const char *dval, ASTNode *typename);
ASTNode *make_empty_leaf(void);
char *make_negative(const char *p);

void dump_ast_flat(const ASTNode *node,
                   const char *prefix,
                   int is_last,
                   const char *parent_name);

void parse_dump(void);
void parse_dump_node(const ASTNode *node);

//! Parser-owned root node for the most recently parsed translation unit.
extern ASTNode *root;

#define MAKE_NODE(...)              make_node(yysymbol_name(yyr1[yyn]), __VA_ARGS__, NULL)
#define MAKE_NAMED_NODE(name, ...)  make_node(name, __VA_ARGS__, NULL)

#endif // _INCLUDE_AST_H_
