%code requires {
#include "addr_mode.h"
#include "expr.h"
#include "directive.h"
#include "ir.h"

typedef struct operand_info {
   addr_mode_t mode;
   expr_t *expr;
} operand_info_t;

typedef struct YYLTYPE {
   int first_line;
   int first_column;
   int last_line;
   int last_column;
   const char *filename;
} YYLTYPE;
#define YYLTYPE_IS_DECLARED 1

#define YYLLOC_DEFAULT(Current, Rhs, N)                                \
   do {                                                                \
      if ((N) > 0) {                                                   \
         (Current).first_line   = YYRHSLOC((Rhs), 1).first_line;       \
         (Current).first_column = YYRHSLOC((Rhs), 1).first_column;     \
         (Current).last_line    = YYRHSLOC((Rhs), (N)).last_line;      \
         (Current).last_column  = YYRHSLOC((Rhs), (N)).last_column;    \
         (Current).filename     = YYRHSLOC((Rhs), 1).filename;         \
      } else {                                                         \
         (Current).first_line   = (Current).last_line =                \
            YYRHSLOC((Rhs), 0).last_line;                              \
         (Current).first_column = (Current).last_column =              \
            YYRHSLOC((Rhs), 0).last_column;                            \
         (Current).filename     = YYRHSLOC((Rhs), 0).filename;         \
      }                                                                \
   } while (0)
}

%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "addr_mode.h"
#include "expr.h"
#include "directive.h"
#include "ir.h"

int yylex(void);
void yyerror(const char *s);

program_ir_t g_program;

static void free_if(char *s)
{
   if (s)
      free(s);
}
%}

%locations

%union {
   char *str;
   expr_t *expr;
   operand_info_t operand;
   expr_list_node_t *expr_list;
   directive_info_t *directive;
   stmt_t *stmt;
}

%token <str> OPCODE
%token <str> OPCODE_EXPR_SUFFIX
%token <str> DIRECTIVE
%token <str> IDENT
%token <str> LABEL_DEF
%token <str> NUMBER
%token <str> STRING
%token <str> CHARCONST

%token REG_A REG_X REG_Y
%token DEFAULT_ASSIGN
%token SET_DIRECTIVE
%token SHL SHR LE GE EQ NE LOG_AND LOG_OR
%token EOL

%type <expr> expr logical_or_expr logical_and_expr bit_or_expr bit_xor_expr bit_and_expr equality_expr relational_expr shift_expr add_expr mul_expr unary_expr primary
%type <operand> operand_expr
%type <expr_list> expr_list
%type <directive> directive_stmt
%type <stmt> instruction_stmt
%type <stmt> const_stmt

%start program

%%

program
   : lines
   ;

lines
   : %empty
   | lines line
   ;

line
   : EOL
   | statement EOL
   ;

statement
   : LABEL_DEF
     {
        program_ir_append(&g_program, stmt_make_label(@1.filename, @1.first_line, $1));
        free_if($1);
     }
   | LABEL_DEF directive_stmt
     {
        program_ir_append(&g_program, stmt_make_dir(@2.filename, @2.first_line, $1, $2));
        free_if($1);
     }
   | LABEL_DEF instruction_stmt
     {
        $2->label = strdup($1);
        program_ir_append(&g_program, $2);
        free_if($1);
     }
   | directive_stmt
     {
        program_ir_append(&g_program, stmt_make_dir(@1.filename, @1.first_line, NULL, $1));
     }
   | instruction_stmt
     {
        program_ir_append(&g_program, $1);
     }
   | const_stmt
     {
        program_ir_append(&g_program, $1);
     }
   ;

const_stmt
   : IDENT '=' expr
     {
        $$ = stmt_make_const(@1.filename, @1.first_line, $1, $3);
        free_if($1);
     }
   | IDENT DEFAULT_ASSIGN expr
     {
        $$ = stmt_make_const_default(@1.filename, @1.first_line, $1, $3);
        free_if($1);
     }
   | SET_DIRECTIVE IDENT '=' expr
     {
        $$ = stmt_make_const_set(@1.filename, @1.first_line, $2, $4);
        free_if($2);
     }
   ;

directive_stmt
   : DIRECTIVE
     {
        $$ = directive_make_empty($1);
        free_if($1);
     }
   | DIRECTIVE expr_list
     {
        $$ = directive_make_exprs($1, $2);
        free_if($1);
     }
   | DIRECTIVE STRING
     {
        $$ = directive_make_string($1, $2);
        free_if($1);
        free_if($2);
     }
   | DIRECTIVE STRING ',' expr_list
     {
        $$ = directive_make_string_exprs($1, $2, $4);
        free_if($1);
        free_if($2);
     }
   ;

expr_list
   : expr
     {
        $$ = expr_list_node_make($1);
     }
   | expr_list ',' expr
     {
        $$ = expr_list_append($1, $3);
     }
   ;

instruction_stmt
   : OPCODE
     {
        $$ = stmt_make_insn(@1.filename, @1.first_line, NULL, $1, AM_IMPLIED, NULL, 0);
        free_if($1);
     }
   | OPCODE operand_expr
     {
        $$ = stmt_make_insn(@1.filename, @1.first_line, NULL, $1, $2.mode, $2.expr, 1);
        free_if($1);
     }
   | OPCODE_EXPR_SUFFIX
     {
        $$ = stmt_make_insn(@1.filename, @1.first_line, NULL, $1, AM_IMPLIED, NULL, 0);
        free_if($1);
     }
   | OPCODE_EXPR_SUFFIX expr
     {
        $$ = stmt_make_insn(@1.filename, @1.first_line, NULL, $1, AM_ZP_OR_ABS, $2, 1);
        free_if($1);
     }
   | OPCODE_EXPR_SUFFIX expr ',' REG_X
     {
        $$ = stmt_make_insn(@1.filename, @1.first_line, NULL, $1, AM_ZPX_OR_ABSX, $2, 1);
        free_if($1);
     }
   | OPCODE_EXPR_SUFFIX expr ',' REG_Y
     {
        $$ = stmt_make_insn(@1.filename, @1.first_line, NULL, $1, AM_ZPY_OR_ABSY, $2, 1);
        free_if($1);
     }
   ;

operand_expr
   : REG_A
     {
        $$.mode = AM_ACCUMULATOR;
        $$.expr = NULL;
     }
   | '#' expr
     {
        $$.mode = AM_IMMEDIATE;
        $$.expr = $2;
     }
   | expr
     {
        $$.mode = AM_ZP_OR_ABS;
        $$.expr = $1;
     }
   | expr ',' REG_X
     {
        $$.mode = AM_ZPX_OR_ABSX;
        $$.expr = $1;
     }
   | expr ',' REG_Y
     {
        $$.mode = AM_ZPY_OR_ABSY;
        $$.expr = $1;
     }
   | '(' expr ')'
     {
        $$.mode = AM_INDIRECT;
        $$.expr = $2;
     }
   | '(' expr ',' REG_X ')'
     {
        $$.mode = AM_INDEXED_INDIRECT;
        $$.expr = $2;
     }
   | '(' expr ')' ',' REG_Y
     {
        $$.mode = AM_INDIRECT_INDEXED;
        $$.expr = $2;
     }
   ;

expr
   : logical_or_expr
     {
        $$ = $1;
     }
   ;

logical_or_expr
   : logical_and_expr
     {
        $$ = $1;
     }
   | logical_or_expr LOG_OR logical_and_expr
     {
        $$ = expr_make_binary(EXPR_BOP_LOG_OR, $1, $3);
     }
   ;

logical_and_expr
   : bit_or_expr
     {
        $$ = $1;
     }
   | logical_and_expr LOG_AND bit_or_expr
     {
        $$ = expr_make_binary(EXPR_BOP_LOG_AND, $1, $3);
     }
   ;

bit_or_expr
   : bit_xor_expr
     {
        $$ = $1;
     }
   | bit_or_expr '|' bit_xor_expr
     {
        $$ = expr_make_binary(EXPR_BOP_BIT_OR, $1, $3);
     }
   ;

bit_xor_expr
   : bit_and_expr
     {
        $$ = $1;
     }
   | bit_xor_expr '^' bit_and_expr
     {
        $$ = expr_make_binary(EXPR_BOP_BIT_XOR, $1, $3);
     }
   ;

bit_and_expr
   : equality_expr
     {
        $$ = $1;
     }
   | bit_and_expr '&' equality_expr
     {
        $$ = expr_make_binary(EXPR_BOP_BIT_AND, $1, $3);
     }
   ;

equality_expr
   : relational_expr
     {
        $$ = $1;
     }
   | equality_expr EQ relational_expr
     {
        $$ = expr_make_binary(EXPR_BOP_EQ, $1, $3);
     }
   | equality_expr NE relational_expr
     {
        $$ = expr_make_binary(EXPR_BOP_NE, $1, $3);
     }
   ;

relational_expr
   : shift_expr
     {
        $$ = $1;
     }
   | relational_expr '<' shift_expr
     {
        $$ = expr_make_binary(EXPR_BOP_LT, $1, $3);
     }
   | relational_expr LE shift_expr
     {
        $$ = expr_make_binary(EXPR_BOP_LE, $1, $3);
     }
   | relational_expr '>' shift_expr
     {
        $$ = expr_make_binary(EXPR_BOP_GT, $1, $3);
     }
   | relational_expr GE shift_expr
     {
        $$ = expr_make_binary(EXPR_BOP_GE, $1, $3);
     }
   ;

shift_expr
   : add_expr
     {
        $$ = $1;
     }
   | shift_expr SHL add_expr
     {
        $$ = expr_make_binary(EXPR_BOP_SHL, $1, $3);
     }
   | shift_expr SHR add_expr
     {
        $$ = expr_make_binary(EXPR_BOP_SHR, $1, $3);
     }
   ;

add_expr
   : mul_expr
     {
        $$ = $1;
     }
   | add_expr '+' mul_expr
     {
        $$ = expr_make_binary(EXPR_BOP_ADD, $1, $3);
     }
   | add_expr '-' mul_expr
     {
        $$ = expr_make_binary(EXPR_BOP_SUB, $1, $3);
     }
   ;

mul_expr
   : unary_expr
     {
        $$ = $1;
     }
   | mul_expr '*' unary_expr
     {
        $$ = expr_make_binary(EXPR_BOP_MUL, $1, $3);
     }
   | mul_expr '/' unary_expr
     {
        $$ = expr_make_binary(EXPR_BOP_DIV, $1, $3);
     }
   | mul_expr '%' unary_expr
     {
        $$ = expr_make_binary(EXPR_BOP_MOD, $1, $3);
     }
   ;

unary_expr
   : primary
     {
        $$ = $1;
     }
   | '+' unary_expr
     {
        $$ = expr_make_unary(EXPR_UOP_POS, $2);
     }
   | '-' unary_expr
     {
        $$ = expr_make_unary(EXPR_UOP_NEG, $2);
     }
   | '!' unary_expr
     {
        $$ = expr_make_unary(EXPR_UOP_LOG_NOT, $2);
     }
   | '~' unary_expr
     {
        $$ = expr_make_unary(EXPR_UOP_BIT_NOT, $2);
     }
   | '<' unary_expr
     {
        $$ = expr_make_unary(EXPR_UOP_LO, $2);
     }
   | '>' unary_expr
     {
        $$ = expr_make_unary(EXPR_UOP_HI, $2);
     }
   ;

primary
   : NUMBER
     {
        $$ = expr_make_number(parse_number_token($1));
        free_if($1);
     }
   | IDENT
     {
        $$ = expr_make_ident($1);
        free_if($1);
     }
   | CHARCONST
     {
        $$ = expr_make_char(parse_charconst_token($1));
        free_if($1);
     }
   | '*'
     {
        $$ = expr_make_pc();
     }
   | '{' expr '}'
     {
        $$ = $2;
     }
   ;

%%

void yyerror(const char *s)
{
   if (yylloc.filename)
      fprintf(stderr, "%s:%d: parse error: %s\n", yylloc.filename, yylloc.first_line, s);
   else
      fprintf(stderr, "line %d: parse error: %s\n", yylloc.first_line, s);
}
