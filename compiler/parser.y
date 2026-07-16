/* ---------- parser.y ---------- */
%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdbool.h>

#include "ast.h"
#include "coverage.h"
#include "enumname.h"
#include "lextern.h"
#include "memname.h"
#include "messages.h"
#include "typename.h"
#include "xform.h"
#include "xray.h"

// this flattens out fields in structs and unions.
// we need it here because append/prepend is problematic
// when we recursive descend at compile time.
// also makes compile easier.
ASTNode *append_decl_items(ASTNode *parent, ASTNode *fieldlist) {
   for (int i = 0; i < fieldlist->count; i++) {
      for (int j = 0; j < fieldlist->children[i]->count; j++) {
         parent = append_child(parent, fieldlist->children[i]->children[j]);
      }
   }
   return parent;
}

static ASTNode *append_decl_bitfield(ASTNode *declarator, ASTNode *bitfield) {
   if (!bitfield || is_empty(bitfield)) {
      return declarator;
   }
   return append_child(declarator, bitfield);
}

static ASTNode *make_decl_addr_term(char *tok) {
   if (!strcmp(tok, "none")) {
      return make_empty_leaf();
   }
   return make_identifier_leaf(tok);
}

static ASTNode *make_ellipsis_marker(void) {
   ASTNode *ret = make_empty_leaf();
   ret->name = "ellipsis";
   return ret;
}

%}

%union {
    char    *str;
    ASTNode *node;
}

%token <str> CHAR          /* string, because xform shenanigans */
%token <str> FLAG
%token <str> FLOAT         /* string, because value might be outside hosts abilities */
%token <str> IDENTIFIER
%token <str> INTEGER       /* string, because value might be outside hosts abilities */
%token <str> MEMNAME
%token <str> OPERATOR
%token <str> STRING
%token <str> ASM
%token <str> TYPENAME
%token <str> ENUMNAME
%token <str> XFORMNAME

%token ADD_ASSIGN
%token AND
%token AND_ASSIGN
%token ARROW
%token ASSIGN
%token BREAK
%token CASE
%token CONST
%token CONTINUE
%token DEC
%token DEFAULT
%token DIV_ASSIGN
%token DOLLAR_DOLLAR
%token DO
%token ELLIPSIS
%token ELSE
%token ENUM
%token EQ
%token EXTERN
%token FOR
%token GE
%token GOTO
%token IF
%token INC
%token INCLUDE
%token LE
%token LSHIFT
%token LSHIFT_ASSIGN
%token MEM
%token MOD_ASSIGN
%token MUL_ASSIGN
%token NE
%token OR
%token OR_ASSIGN
%token REF
%token RETURN
%token RSHIFT
%token RSHIFT_ASSIGN
%token STATIC
%token STRUCT
%token SIZEOF
%token SUB_ASSIGN
%token SWITCH
%token TO
%token TYPE
%token UNION
%token WHILE
%token XFORM
%token XOR_ASSIGN

%precedence LOWER_THAN_RPAREN
%precedence ')'


%type <node> additive_expr
%type <node> arg_list
%type <node> array_initializer
%type <node> asm_stmt
%type <node> assign_expr
%type <node> bitwise_and_expr
%type <node> bitwise_or_expr
%type <node> bitwise_xor_expr
%type <node> block
%type <node> break_stmt
%type <node> cast_type
%type <node> case_block
%type <node> case_choice
%type <node> case_additive_expr
%type <node> case_enum_primary_expr
%type <node> case_bitwise_and_expr
%type <node> case_bitwise_or_expr
%type <node> case_bitwise_xor_expr
%type <node> case_conditional_expr
%type <node> case_equality_expr
%type <node> case_logical_and_expr
%type <node> case_logical_or_expr
%type <node> case_multiplicative_expr
%type <node> case_num_primary_expr
%type <node> case_primary_expr
%type <node> case_relational_expr
%type <node> case_shift_expr
%type <node> case_term
%type <node> case_unary_expr
%type <node> case_section
%type <node> comma_expr
%type <node> conditional_expr
%type <node> continue_stmt
%type <node> decl
%type <node> decl_item
%type <node> decl_list
%type <node> decl_specifiers
%type <node> decl_subitem
%type <node> decl_addr_term
%type <node> declarator
%type <node> defdecl_stmt
%type <node> direct_declarator
%type <node> do_stmt
%type <node> enum_decl_stmt
%type <node> enum_names
%type <node> enum_value
%type <node> equality_expr
%type <node> expr
%type <node> expr_args
%type <node> expr_list
%type <node> expr_stmt
%type <node> field
%type <node> field_list
%type <node> flag
%type <node> flag_list
%type <node> for_stmt
%type <node> for_init
%type <node> goto_stmt
%type <node> if_stmt
%type <node> include_stmt
%type <node> initializer
%type <node> label_stmt
%type <node> logical_and_expr
%type <node> logical_or_expr
%type <node> lvalue
%type <node> lvalue_primary
%type <node> postfix_lvalue
%type <node> postfix_lvalue_core
%type <node> unary_lvalue
%type <node> mem_decl_stmt
%type <node> modifier
%type <node> modifier_list
%type <node> multiplicative_expr
%type <node> named_expr
%type <node> nonnum_primary_expr
%type <node> num_primary_expr
%type <node> opt_bitfield_width
%type <node> opt_expr
%type <node> opt_flags
%type <node> opt_identifier
%type <node> parameter
%type <node> parameter_list
%type <node> pointer
%type <node> postfix_expr
%type <node> primary_expr
%type <node> program
%type <node> program_item
%type <node> relational_expr
%type <node> return_stmt
%type <node> shift_expr
%type <node> statement
%type <node> statement_list
%type <node> struct_decl_stmt
%type <node> switch_stmt
%type <node> sizeof_operand
%type <node> type_decl_stmt
%type <node> unary_expr
%type <node> union_decl_stmt
%type <node> while_stmt
%type <node> xform_decl_stmt
%type <node> xform_item
%type <node> xform_list

%locations
%define parse.error verbose
%define parse.lac full
%expect 0
/* %expect-rr 0 */

%%

program:
    program_item                             { COVER; root = $$ = MAKE_NODE($1); }
  | program program_item                     { COVER; root = $$ = append_child($1, $2); }
  ;

program_item:
    include_stmt                             { COVER; $$ = $1; }
  | xform_decl_stmt                          { COVER; $$ = $1; register_xform($$->children[0]->strval, $$->children[1]); }
  | mem_decl_stmt                            { COVER; $$ = $1; }
  | type_decl_stmt                           { COVER; $$ = $1; }
  | enum_decl_stmt                           { COVER; $$ = $1; }
  | struct_decl_stmt                         { COVER; $$ = $1; }
  | union_decl_stmt                          { COVER; $$ = $1; }
  | defdecl_stmt                             { COVER; $$ = $1; }
  ;

include_stmt:
    INCLUDE STRING                           {
                                                COVER;
                                                $$ = MAKE_NODE(make_string_leaf($2));
                                                if (push_file($2) != 0) {
                                                   yyerror("failed to include file: %s", $2);
                                                   YYABORT;
                                                }
                                             }
  ;

xform_decl_stmt:
    XFORM opt_identifier '{' xform_list ',' '}' ';' { COVER; $$ = MAKE_NODE($2, $4); }
  | XFORM opt_identifier '{' xform_list '}' ';'     { COVER; $$ = MAKE_NODE($2, $4); }
  ;

opt_identifier:
    IDENTIFIER  { $$ = make_identifier_leaf($1); }
  | %empty      { $$ = make_identifier_leaf(strdup("")); }
  ;

xform_list:
    xform_item                               { COVER; $$ = MAKE_NODE($1); }
  | xform_list ',' xform_item                { COVER; $$ = append_child($1, $3); }
  ;

xform_item:
    CHAR                                     { COVER; $$ = MAKE_NODE(make_string_leaf($1)); }
  | xform_item INTEGER                       { COVER; $$ = append_child($1, make_integer_leaf($2)); }
  ;

mem_decl_stmt:
    MEM IDENTIFIER '{' opt_flags '}' ';'     { COVER; if (register_memname($2) < 0) YYABORT; $$ = MAKE_NODE(make_identifier_leaf($2), $4); }
  ;

type_decl_stmt:
    TYPE IDENTIFIER '{' opt_flags '}' ';'    { COVER; if (register_typename($2) < 0) YYABORT; $$ = MAKE_NODE(make_identifier_leaf($2), $4); }
  | TYPE '*' '{' opt_flags '}' ';'           { COVER; if (register_typename("*") < 0) YYABORT; $$ = MAKE_NODE(make_identifier_leaf("*"), $4); }
  ;

enum_decl_stmt:
    ENUM IDENTIFIER '{' enum_names '}' ';'     { COVER; if (register_typename($2) < 0) YYABORT; $$ = MAKE_NODE(make_identifier_leaf($2), $4); register_enumnames($$); }
  | ENUM IDENTIFIER '{' enum_names ',' '}' ';' { COVER; if (register_typename($2) < 0) YYABORT; $$ = MAKE_NODE(make_identifier_leaf($2), $4); register_enumnames($$); }
  ;

enum_names:
    enum_value                               { COVER; $$ = MAKE_NODE($1); }
  | enum_names ',' enum_value                { COVER; $$ = append_child($1, $3); }
  ;

enum_value:
    IDENTIFIER                               { COVER; $$ = MAKE_NODE(make_identifier_leaf($1)); }
  | IDENTIFIER ASSIGN INTEGER                { COVER; $$ = MAKE_NODE(make_identifier_leaf($1), make_integer_leaf($3)); }
  ;

struct_decl_stmt:
    STRUCT IDENTIFIER ';'                    { COVER; if (register_typename($2) < 0) YYABORT; $$ = make_empty_leaf(); $$->strval = strdup($2); } // Add early to type table
  | STRUCT TYPENAME '{' field_list '}' ';'   { COVER; $$ = append_decl_items(MAKE_NODE(make_identifier_leaf($2)), $4); }
  | STRUCT IDENTIFIER '{'                    {
                                                COVER;
                                                if (register_typename($2) < 0) YYABORT;  // Add early to type table
                                             }
    field_list '}' ';'                       {
                                                COVER;
                                                $$ = append_decl_items(MAKE_NODE(make_identifier_leaf($2)), $5);
                                             }
  ;

union_decl_stmt:
    UNION IDENTIFIER ';'                     { COVER; if (register_typename($2) < 0) YYABORT; $$ = make_empty_leaf(); $$->strval = strdup($2); } // Add early to type table
  | UNION TYPENAME '{' field_list '}' ';'    { COVER; $$ = append_decl_items(MAKE_NODE(make_identifier_leaf($2)), $4); }
  | UNION IDENTIFIER '{'                     {
                                                COVER;
                                                if (register_typename($2) < 0) YYABORT;  // Add early to type table
                                             }
    field_list '}' ';'                       {
                                                COVER;
                                                $$ = append_decl_items(MAKE_NODE(make_identifier_leaf($2)), $5);
                                             }
  ;

defdecl_stmt:
    decl ';'                                 { COVER; $$ = MAKE_NODE($1); }
  | decl_specifiers declarator block         { COVER; $$ = MAKE_NODE($1, $2, $3); }
  ;

field_list:
    field                                    { COVER; $$ = MAKE_NODE($1); }
  | field_list field                         { COVER; $$ = append_child($1, $2); }
  ;

field:
    decl ';'                                 { COVER; $$ = $1; }
  ;

modifier_list:
    modifier_list modifier                   { COVER; $$ = append_child($1, $2); }
  | modifier                                 { COVER; $$ = MAKE_NODE($1); }
  ;

modifier:
    CONST                                    { COVER; $$ = make_identifier_leaf("const"); }
  | EXTERN                                   { COVER; $$ = make_identifier_leaf("extern"); }
  | REF                                      { COVER; $$ = make_identifier_leaf("ref"); }
  | STATIC                                   { COVER; $$ = make_identifier_leaf("static"); }
  | MEMNAME                                  { COVER; $$ = make_identifier_leaf($1); }
  ;

decl:
    decl_specifiers decl_list                {
                                                COVER;
                                                for (int i = 0; i < $2->count; i++) {
                                                   $2->children[i] = prepend_children_from($2->children[i], $1);
                                                }
                                                $$ = $2;
                                             }
  ;

decl_list:
    decl_item                                { COVER; $$ = MAKE_NODE($1); }
  | decl_list ',' decl_item                  { COVER; $$ = append_child($1, $3); }
  ;

decl_item:
    decl_subitem                                     { COVER; $$ = MAKE_NODE($1, make_empty_leaf()); }
  | decl_subitem ASSIGN initializer                  { COVER; $$ = MAKE_NODE($1, $3); }
  ;

opt_bitfield_width:
    %empty                                   { COVER; $$ = make_empty_leaf(); }
  | ':' INTEGER                              { COVER; $$ = MAKE_NAMED_NODE("bitfield_width", make_integer_leaf($2)); }
  ;

decl_subitem:
    declarator opt_bitfield_width            { COVER; $$ = append_decl_bitfield($1, $2); }
  | declarator opt_bitfield_width '@' INTEGER
                                             { COVER; $$ = MAKE_NODE(append_decl_bitfield($1, $2), MAKE_NAMED_NODE("rw_addr_spec", make_integer_leaf($4), make_integer_leaf($4))); }
  | declarator opt_bitfield_width '@' IDENTIFIER
                                             { COVER; $$ = MAKE_NODE(append_decl_bitfield($1, $2), MAKE_NAMED_NODE("rw_addr_spec", make_identifier_leaf($4), make_identifier_leaf($4))); }
  | declarator opt_bitfield_width '@' '[' decl_addr_term '/' decl_addr_term ']'
                                             { COVER; $$ = MAKE_NODE(append_decl_bitfield($1, $2), MAKE_NAMED_NODE("rw_addr_spec", $5, $7)); }
  ;


decl_addr_term:
    INTEGER                                  { COVER; $$ = make_integer_leaf($1); }
  | IDENTIFIER                               { COVER; $$ = make_decl_addr_term($1); }
  ;

decl_specifiers:
    TYPENAME                                 { COVER; $$ = MAKE_NODE(make_empty_leaf(), make_typename_leaf($1)); }
  | modifier_list TYPENAME                   { COVER; $$ = MAKE_NODE($1, make_typename_leaf($2)); }
  ;

declarator:
    pointer direct_declarator                { COVER; $$ = MAKE_NODE($1); $$ = append_children_from($$, $2); }
  | direct_declarator                        { COVER; $$ = MAKE_NODE(make_integer_leaf(strdup("0"))); $$->children[0]->name = "pointer"; $$ = append_children_from($$, $1); }
  | pointer                                  { COVER; $$ = MAKE_NODE($1, make_empty_leaf()); }
  | %empty                                   { COVER; $$ = MAKE_NODE(make_integer_leaf(strdup("0")), make_empty_leaf()); $$->children[0]->name = "pointer"; }
  ;

pointer:
    '*'                                      { COVER; $$ = make_integer_leaf(strdup("1")); $$->name = "pointer"; }
  | '*' pointer                              { COVER; $$ = $2; increment_integer_leaf($$); }
  ;

direct_declarator:
    IDENTIFIER                               { COVER; $$ = MAKE_NODE(make_identifier_leaf($1)); }
  | DOLLAR_DOLLAR                            { COVER; $$ = MAKE_NODE(make_identifier_leaf(strdup("$$"))); }
  | OPERATOR                                 { COVER; $$ = MAKE_NODE(make_identifier_leaf($1)); }
  | '(' declarator ')'                       { COVER; $$ = MAKE_NODE($2); }
  | direct_declarator '[' INTEGER ']'        { COVER; $$ = append_child($1, make_integer_leaf($3)); }
  | direct_declarator '(' parameter_list ')' { COVER; $$ = append_child($1, $3); }
  | direct_declarator '(' ')'                { COVER; $$ = append_child($1, MAKE_NAMED_NODE("parameter_list", NULL)); }
  ;

parameter_list:
    parameter_list ',' parameter             { COVER; $$ = append_child($1, $3); }
  | parameter_list ',' ELLIPSIS              { COVER; $$ = append_child($1, make_ellipsis_marker()); }
  | parameter                                { COVER; $$ = MAKE_NODE($1); }
  ;

parameter:
    decl_specifiers decl_item                { COVER; $$ = MAKE_NODE($1, $2); }
  ;

cast_type:
    decl_specifiers declarator               { COVER; $$ = MAKE_NAMED_NODE("cast_type", $1, $2); }
  ;

block:
    '{' statement_list '}'                   { COVER; $$ = $2; }
  ;

statement_list:
    %empty                                   { COVER; $$ = MAKE_NODE(NULL); }
  | statement statement_list                 { COVER; $$ = prepend_child($2, $1); }
  ;

statement:
    block                                    { COVER; $$ = $1; }
  | expr_stmt                                { COVER; $$ = $1; }
  | defdecl_stmt                             { COVER; $$ = $1; }
  | return_stmt                              { COVER; $$ = $1; }
  | goto_stmt                                { COVER; $$ = $1; }
  | break_stmt                               { COVER; $$ = $1; }
  | continue_stmt                            { COVER; $$ = $1; }
  | switch_stmt                              { COVER; $$ = $1; }
  | if_stmt                                  { COVER; $$ = $1; }
  | while_stmt                               { COVER; $$ = $1; }
  | for_stmt                                 { COVER; $$ = $1; }
  | do_stmt                                  { COVER; $$ = $1; }
  | label_stmt                               { COVER; $$ = $1; }
  | asm_stmt                                 { COVER; $$ = $1; }
  ;

asm_stmt:
    ASM                                      { COVER; $$ = MAKE_NODE(make_asm_leaf($1)); }
  ;

return_stmt:
    RETURN opt_expr ';'                      { COVER; $$ = MAKE_NODE($2); }
  ;

goto_stmt:
    GOTO IDENTIFIER ';'                      { COVER; $$ = MAKE_NODE(make_identifier_leaf($2)); }
  ;

break_stmt:
    BREAK ';'                                { COVER; $$ = MAKE_NODE(make_empty_leaf()); }
  | BREAK IDENTIFIER ';'                     { COVER; $$ = MAKE_NODE(make_identifier_leaf($2)); }
  ;

continue_stmt:
    CONTINUE ';'                             { COVER; $$ = MAKE_NODE(make_empty_leaf()); }
  | CONTINUE IDENTIFIER ';'                  { COVER; $$ = MAKE_NODE(make_identifier_leaf($2)); }
  ;

switch_stmt:
    SWITCH '(' expr ')' '{' case_section '}' { COVER; $$ = MAKE_NODE($3,$6); }
  ;

if_stmt:
    IF '(' expr ')' block ELSE block         { COVER; $$ = MAKE_NODE($3, $5, $7); }
  | IF '(' expr ')' block                    { COVER; $$ = MAKE_NODE($3, $5); }
  ;

while_stmt:
    WHILE '(' expr ')' block                 { COVER; $$ = MAKE_NODE($3, $5); }
  ;

for_init:
    %empty                                   { COVER; $$ = make_empty_leaf(); }
  | expr                                     { COVER; $$ = $1; }
  | decl                                     { COVER; $$ = MAKE_NAMED_NODE("defdecl_stmt", $1); }
  ;

for_stmt:
    FOR '(' for_init ';' opt_expr ';' opt_expr ')' block { COVER; $$ = MAKE_NODE($3, $5, $7, $9); }
  ;

do_stmt:
    DO block WHILE '(' expr ')' ';'          { COVER; $$ = MAKE_NODE($2, $5); }
  ;

label_stmt:
    IDENTIFIER ':' statement                 { COVER; $$ = MAKE_NODE(make_identifier_leaf($1), $3); }
  ;

initializer:
    assign_expr                              { COVER; $$ = $1; }
  | array_initializer                        { COVER; $$ = $1; }
  ;

array_initializer:
    '{' expr_list ',' '}'                    { COVER; $$ = $2; }
  | '{' expr_list '}'                        { COVER; $$ = $2; }
  ;

expr_list:
    named_expr                               { COVER; $$ = $1; }
  | expr_list ',' named_expr                 { COVER; $$ = MAKE_NODE($1, $3); }
;

named_expr:
    initializer                              { COVER; $$ = MAKE_NODE(make_empty_leaf(), $1); }
  | '.' IDENTIFIER ASSIGN initializer        { COVER; $$ = MAKE_NODE(make_identifier_leaf($2), $4); }
  ;

expr_stmt:
    expr ';'                                 { COVER; $$ = $1; }
  | ';'                                      { COVER; $$ = make_empty_leaf(); }
  ;

opt_expr:
    %empty                                   { COVER; $$ = make_empty_leaf(); }
  | expr                                     { COVER; $$ = $1; }
  ;

expr:
    comma_expr                               { COVER; $$ = $1; }
  ;

comma_expr:
    assign_expr                              { COVER; $$ = $1; }
  | comma_expr ',' assign_expr               { COVER; if (!strcmp($1->name, "comma_expr")) { $$ = append_child($1, $3); } else { $$ = MAKE_NAMED_NODE("comma_expr", $1, $3); } }
  ;

conditional_expr:
    logical_or_expr                             { COVER; $$ = $1; }
  | logical_or_expr '?' expr ':' conditional_expr  { COVER; $$ = MAKE_NODE(make_identifier_leaf("?:"), $1, $3, $5); }
  ;

assign_expr:
    conditional_expr                              { COVER; $$ = MAKE_NODE($1); }
  | lvalue ASSIGN initializer                     { COVER; $$ = MAKE_NODE(make_identifier_leaf(":="), $1, $3); }
  | lvalue ADD_ASSIGN assign_expr                 { COVER; $$ = MAKE_NODE(make_identifier_leaf("+="), $1, $3); }
  | lvalue SUB_ASSIGN assign_expr                 { COVER; $$ = MAKE_NODE(make_identifier_leaf("-="), $1, $3); }
  | lvalue MUL_ASSIGN assign_expr                 { COVER; $$ = MAKE_NODE(make_identifier_leaf("*="), $1, $3); }
  | lvalue DIV_ASSIGN assign_expr                 { COVER; $$ = MAKE_NODE(make_identifier_leaf("/="), $1, $3); }
  | lvalue MOD_ASSIGN assign_expr                 { COVER; $$ = MAKE_NODE(make_identifier_leaf("%="), $1, $3); }
  | lvalue AND_ASSIGN assign_expr                 { COVER; $$ = MAKE_NODE(make_identifier_leaf("&="), $1, $3); }
  | lvalue OR_ASSIGN assign_expr                  { COVER; $$ = MAKE_NODE(make_identifier_leaf("|="), $1, $3); }
  | lvalue XOR_ASSIGN assign_expr                 { COVER; $$ = MAKE_NODE(make_identifier_leaf("^="), $1, $3); }
  | lvalue LSHIFT_ASSIGN assign_expr              { COVER; $$ = MAKE_NODE(make_identifier_leaf("<<="), $1, $3); }
  | lvalue RSHIFT_ASSIGN assign_expr              { COVER; $$ = MAKE_NODE(make_identifier_leaf(">>="), $1, $3); }
  ;

logical_or_expr:
    logical_and_expr                         { COVER; $$ = $1; }
  | logical_or_expr OR logical_and_expr      { COVER; $$ = MAKE_NAMED_NODE("||", $1, $3); }
  ;

logical_and_expr:
    bitwise_or_expr                          { COVER; $$ = $1; }
  | logical_and_expr AND bitwise_or_expr     { COVER; $$ = MAKE_NAMED_NODE("&&", $1, $3); }
  ;

bitwise_or_expr:
    bitwise_xor_expr                         { COVER; $$ = $1; }
  | bitwise_or_expr '|' bitwise_xor_expr     { COVER; $$ = MAKE_NAMED_NODE("|", $1, $3); }
  ;

bitwise_xor_expr:
    bitwise_and_expr                         { COVER; $$ = $1; }
  | bitwise_xor_expr '^' bitwise_and_expr    { COVER; $$ = MAKE_NAMED_NODE("^", $1, $3); }
  ;

bitwise_and_expr:
    equality_expr                            { COVER; $$ = $1; }
  | bitwise_and_expr '&' equality_expr       { COVER; $$ = MAKE_NAMED_NODE("&", $1, $3); }
  ;

equality_expr:
    relational_expr                          { COVER; $$ = $1; }
  | equality_expr EQ relational_expr         { COVER; $$ = MAKE_NAMED_NODE("==", $1, $3); }
  | equality_expr NE relational_expr         { COVER; $$ = MAKE_NAMED_NODE("!=", $1, $3); }
  ;

relational_expr:
    shift_expr                               { COVER; $$ = $1; }
  | relational_expr '<' shift_expr           { COVER; $$ = MAKE_NAMED_NODE("<", $1, $3); }
  | relational_expr '>' shift_expr           { COVER; $$ = MAKE_NAMED_NODE(">", $1, $3); }
  | relational_expr LE shift_expr            { COVER; $$ = MAKE_NAMED_NODE("<=", $1, $3); }
  | relational_expr GE shift_expr            { COVER; $$ = MAKE_NAMED_NODE(">=", $1, $3); }
  ;

shift_expr:
    additive_expr                            { COVER; $$ = $1; }
  | shift_expr LSHIFT additive_expr          { COVER; $$ = MAKE_NAMED_NODE("<<", $1, $3); }
  | shift_expr RSHIFT additive_expr          { COVER; $$ = MAKE_NAMED_NODE(">>", $1, $3); }
  ;

additive_expr:
    multiplicative_expr                      { COVER; $$ = $1; }
  | additive_expr '+' multiplicative_expr    { COVER; $$ = MAKE_NAMED_NODE("+", $1, $3); }
  | additive_expr '-' multiplicative_expr    { COVER; $$ = MAKE_NAMED_NODE("-", $1, $3); }
  ;

multiplicative_expr:
    unary_expr                               { COVER; $$ = $1; }
  | multiplicative_expr '*' unary_expr       { COVER; $$ = MAKE_NAMED_NODE("*", $1, $3); }
  | multiplicative_expr '/' unary_expr       { COVER; $$ = MAKE_NAMED_NODE("/", $1, $3); }
  | multiplicative_expr '%' unary_expr       { COVER; $$ = MAKE_NAMED_NODE("%", $1, $3); }
  ;

lvalue:
    unary_lvalue                            { COVER; $$ = $1; }
  ;

unary_lvalue:
    postfix_lvalue                          { COVER; $$ = $1; }
  | INC unary_lvalue                        { COVER; $$ = append_child($2, make_identifier_leaf("pre++")); }
  | DEC unary_lvalue                        { COVER; $$ = append_child($2, make_identifier_leaf("pre--")); }
  | '*' unary_lvalue                        { COVER; $$ = MAKE_NAMED_NODE("lvalue", MAKE_NAMED_NODE("*", $2), make_empty_leaf()); }
  ;

postfix_lvalue:
    postfix_lvalue_core                     { COVER; $$ = $1; }
  | postfix_lvalue_core INC                 { COVER; $$ = append_child($1, make_identifier_leaf("post++")); }
  | postfix_lvalue_core DEC                 { COVER; $$ = append_child($1, make_identifier_leaf("post--")); }
  ;

postfix_lvalue_core:
    lvalue_primary                          { COVER; $$ = $1; }
  | postfix_lvalue_core '[' expr ']'        { COVER; $1->children[1] = MAKE_NAMED_NODE("[", $1->children[1], $3); $$ = $1; }
  | postfix_lvalue_core '.' IDENTIFIER      { COVER; $1->children[1] = MAKE_NAMED_NODE(".", $1->children[1], make_identifier_leaf($3)); $$ = $1; }
  | postfix_lvalue_core ARROW IDENTIFIER    { COVER; $1->children[1] = MAKE_NAMED_NODE("->", $1->children[1], make_identifier_leaf($3)); $$ = $1; }
  ;

lvalue_primary:
    IDENTIFIER                              { COVER; $$ = MAKE_NAMED_NODE("lvalue", MAKE_NAMED_NODE("lvalue_base", make_identifier_leaf($1)), make_empty_leaf()); }
  | DOLLAR_DOLLAR                           { COVER; $$ = MAKE_NAMED_NODE("lvalue", MAKE_NAMED_NODE("lvalue_base", make_identifier_leaf(strdup("$$"))), make_empty_leaf()); }
  | '(' lvalue ')'                          { COVER; $$ = $2; }
  ;

unary_expr:
    postfix_expr                             { COVER; $$ = $1; }
  | SIZEOF sizeof_operand                    { COVER; $$ = MAKE_NAMED_NODE("sizeof", $2); }
  | '!' unary_expr                           { COVER; $$ = MAKE_NAMED_NODE("!", $2); }
  | '~' unary_expr                           { COVER; $$ = MAKE_NAMED_NODE("~", $2); }
  | '-' unary_expr                           { COVER; $$ = MAKE_NAMED_NODE("-", $2); }
  | '+' unary_expr                           { COVER; $$ = MAKE_NAMED_NODE("+", $2); }
  | '&' unary_expr                           { COVER; $$ = MAKE_NAMED_NODE("&", $2); }
  | '(' FLAG ')' unary_expr                  { COVER; $$ = MAKE_NAMED_NODE("flag_cast", make_identifier_leaf($2), $4); }
  | '(' cast_type ')' unary_expr             { COVER; $$ = MAKE_NAMED_NODE("cast", $2, $4); }
  ;


sizeof_operand:
    '(' expr ')'                             { COVER; $$ = MAKE_NAMED_NODE("sizeof_expr", $2); }
  | '(' cast_type ')'                        { COVER; $$ = MAKE_NAMED_NODE("sizeof_type", $2); }
  ;

postfix_expr:
    primary_expr                             { COVER; $$ = $1; }
  | postfix_expr '(' arg_list ')'            { COVER; $$ = MAKE_NAMED_NODE("()", $1, $3); }
  ;

primary_expr:
    num_primary_expr                         { COVER; $$ = $1; }
  | nonnum_primary_expr                      { COVER; $$ = $1; }
  ;

num_primary_expr:
    INTEGER                                  { COVER; $$ = make_integer_leaf($1); }
  | INTEGER '`' TYPENAME                     { COVER; $$ = make_integer_leaf_with_type($1, make_typename_leaf($3)); }
  | ENUMNAME                                 { COVER; $$ = make_enumname_expr($1); }
  | ENUMNAME '`' TYPENAME                    { COVER; $$ = make_enumname_expr_with_type($1, make_typename_leaf($3)); }
  | FLOAT                                    { COVER; $$ = make_float_leaf($1); }
  | FLOAT '`' TYPENAME                       { COVER; $$ = make_float_leaf_with_type($1, make_typename_leaf($3)); }
  | CHAR                                     { COVER; $$ = do_xform(make_string_leaf($1), NULL); }
  | CHAR '`' XFORMNAME                       { COVER; $$ = do_xform(make_string_leaf($1), $3); }
  ;

nonnum_primary_expr:
    STRING                                   { COVER; $$ = do_xform(make_string_leaf($1), NULL); }
  | STRING '`' XFORMNAME                     { COVER; $$ = do_xform(make_string_leaf($1), $3); }
  | lvalue %prec LOWER_THAN_RPAREN           { COVER; $$ = $1; }
  | '(' expr ')'                             { COVER; $$ = $2; }
  ;

arg_list:
    %empty                                   { COVER; $$ = MAKE_NAMED_NODE("expr_args", NULL); }
  | expr_args                                { COVER; $$ = $1; }
  ;

expr_args:
    assign_expr                              { COVER; $$ = MAKE_NODE($1); }
  | expr_args ',' assign_expr                { COVER; $$ = append_child($1, $3); }
  ;


case_section:
    case_section case_block                  { COVER; $$ = append_child($1, $2); }
  | case_block                               { COVER; $$ = MAKE_NODE($1); }
  ;

case_block:
    CASE case_choice ':' statement_list      { COVER; $$ = MAKE_NODE($2, $4); }
  | DEFAULT ':' statement_list               { COVER; $$ = MAKE_NODE(make_empty_leaf(), $3); }
  ;

case_choice:
    case_term                                { COVER; $$ = MAKE_NODE($1); }
  | case_term TO case_term                   { COVER; $$ = MAKE_NODE($1, $3); }
  ;

case_term:
    case_conditional_expr                    { COVER; $$ = $1; }
  | case_enum_primary_expr                   { COVER; $$ = $1; }
  ;

case_enum_primary_expr:
    ENUMNAME                                 { COVER; $$ = make_enumname_expr($1); }
  | ENUMNAME '`' TYPENAME                    { COVER; $$ = make_enumname_expr_with_type($1, make_typename_leaf($3)); }
  ;

case_conditional_expr:
    case_logical_or_expr                     { COVER; $$ = $1; }
  | case_logical_or_expr '?' case_conditional_expr ':' case_conditional_expr
                                             { COVER; $$ = MAKE_NODE(make_identifier_leaf("?:"), $1, $3, $5); }
  ;

case_logical_or_expr:
    case_logical_and_expr                                  { COVER; $$ = $1; }
  | case_logical_or_expr OR case_logical_and_expr          { COVER; $$ = MAKE_NAMED_NODE("||", $1, $3); }
  ;

case_logical_and_expr:
    case_bitwise_or_expr                                   { COVER; $$ = $1; }
  | case_logical_and_expr AND case_bitwise_or_expr         { COVER; $$ = MAKE_NAMED_NODE("&&", $1, $3); }
  ;

case_bitwise_or_expr:
    case_bitwise_xor_expr                                  { COVER; $$ = $1; }
  | case_bitwise_or_expr '|' case_bitwise_xor_expr         { COVER; $$ = MAKE_NAMED_NODE("|", $1, $3); }
  ;

case_bitwise_xor_expr:
    case_bitwise_and_expr                                  { COVER; $$ = $1; }
  | case_bitwise_xor_expr '^' case_bitwise_and_expr        { COVER; $$ = MAKE_NAMED_NODE("^", $1, $3); }
  ;

case_bitwise_and_expr:
    case_equality_expr                                     { COVER; $$ = $1; }
  | case_bitwise_and_expr '&' case_equality_expr           { COVER; $$ = MAKE_NAMED_NODE("&", $1, $3); }
  ;

case_equality_expr:
    case_relational_expr                                   { COVER; $$ = $1; }
  | case_equality_expr EQ case_relational_expr             { COVER; $$ = MAKE_NAMED_NODE("==", $1, $3); }
  | case_equality_expr NE case_relational_expr             { COVER; $$ = MAKE_NAMED_NODE("!=", $1, $3); }
  ;

case_relational_expr:
    case_shift_expr                                        { COVER; $$ = $1; }
  | case_relational_expr '<' case_shift_expr               { COVER; $$ = MAKE_NAMED_NODE("<", $1, $3); }
  | case_relational_expr '>' case_shift_expr               { COVER; $$ = MAKE_NAMED_NODE(">", $1, $3); }
  | case_relational_expr LE case_shift_expr                { COVER; $$ = MAKE_NAMED_NODE("<=", $1, $3); }
  | case_relational_expr GE case_shift_expr                { COVER; $$ = MAKE_NAMED_NODE(">=", $1, $3); }
  ;

case_shift_expr:
    case_additive_expr                                     { COVER; $$ = $1; }
  | case_shift_expr LSHIFT case_additive_expr              { COVER; $$ = MAKE_NAMED_NODE("<<", $1, $3); }
  | case_shift_expr RSHIFT case_additive_expr              { COVER; $$ = MAKE_NAMED_NODE(">>", $1, $3); }
  ;

case_additive_expr:
    case_multiplicative_expr                               { COVER; $$ = $1; }
  | case_additive_expr '+' case_multiplicative_expr        { COVER; $$ = MAKE_NAMED_NODE("+", $1, $3); }
  | case_additive_expr '-' case_multiplicative_expr        { COVER; $$ = MAKE_NAMED_NODE("-", $1, $3); }
  ;

case_multiplicative_expr:
    case_unary_expr                                        { COVER; $$ = $1; }
  | case_multiplicative_expr '*' case_unary_expr           { COVER; $$ = MAKE_NAMED_NODE("*", $1, $3); }
  | case_multiplicative_expr '/' case_unary_expr           { COVER; $$ = MAKE_NAMED_NODE("/", $1, $3); }
  | case_multiplicative_expr '%' case_unary_expr           { COVER; $$ = MAKE_NAMED_NODE("%", $1, $3); }
  ;

case_unary_expr:
    case_primary_expr                                      { COVER; $$ = $1; }
  | '!' case_unary_expr                                    { COVER; $$ = MAKE_NAMED_NODE("!", $2); }
  | '~' case_unary_expr                                    { COVER; $$ = MAKE_NAMED_NODE("~", $2); }
  | '-' case_unary_expr                                    { COVER; $$ = MAKE_NAMED_NODE("-", $2); }
  | '+' case_unary_expr                                    { COVER; $$ = MAKE_NAMED_NODE("+", $2); }
  ;

case_primary_expr:
    case_num_primary_expr                                  { COVER; $$ = $1; }
  | '(' case_conditional_expr ')'                          { COVER; $$ = $2; }
  ;

case_num_primary_expr:
    INTEGER                                                { COVER; $$ = make_integer_leaf($1); }
  | INTEGER '`' TYPENAME                                   { COVER; $$ = make_integer_leaf_with_type($1, make_typename_leaf($3)); }
  | FLOAT                                                  { COVER; $$ = make_float_leaf($1); }
  | FLOAT '`' TYPENAME                                     { COVER; $$ = make_float_leaf_with_type($1, make_typename_leaf($3)); }
  | CHAR                                                   { COVER; $$ = do_xform(make_string_leaf($1), NULL); }
  | CHAR '`' XFORMNAME                                     { COVER; $$ = do_xform(make_string_leaf($1), $3); }
  ;

opt_flags:
    flag_list                                { COVER; $$ = $1; }
  | %empty                                   { COVER; $$ = make_empty_leaf(); }
  ;

flag_list:
    flag_list flag                           { COVER; $$ = append_child($1, $2); }
  | flag                                     { COVER; $$ = MAKE_NODE($1); }
  ;

flag:
    FLAG                                     { COVER; $$ = make_identifier_leaf($1); }
  ;

%%

/* vim: set expandtab nu nowrap tabstop=3 shiftwidth=3 softtabstop=3: */
