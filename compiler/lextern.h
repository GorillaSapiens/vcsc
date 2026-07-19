//! @file compiler/lextern.h
//! @brief Declares lexer/parser external declarations for the VCSC compiler.
//! @ingroup compiler

#ifndef _INCLUDE_LEXTERN_H_
#define _INCLUDE_LEXTERN_H_

// called when an "include" directive is found
int push_file(const char *filename);

// extern stuff created by lex/flex
int yylex();
extern FILE *yyin;
extern char *root_filename;
extern char *current_filename;
extern int yylineno;
extern int yycolumn;
extern char* yytext;
extern char *yyfilename;

// Install an object-like alias from a -D command-line definition before parsing.
void lexer_define_alias_from_command_line(const char *spec);

// Lookup token start location captured by the lexer for parser-created AST leaves.
// The key is the exact semantic string pointer returned in yylval.
int lexer_lookup_token_location(const char *token, const char **filename, int *line, int *column);

#endif
