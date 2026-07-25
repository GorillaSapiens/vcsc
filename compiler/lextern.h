//! @file compiler/lextern.h
//! @brief Declares lexer/parser external declarations for the VCSC compiler.
//! @ingroup compiler

#ifndef _INCLUDE_LEXTERN_H_
#define _INCLUDE_LEXTERN_H_

#include <stdbool.h>

// called when an "include" directive is found
int push_file(const char *filename);

// called when a repeatable template directive is found
int push_template_file(const char *filename, const char *instance,
                       const char *invoke_file, int invoke_line, int invoke_column);

// Return the active template instance and its invocation location, or NULL.
const char *lexer_current_template_instance(void);
const char *lexer_current_template_invoke_file(void);
int lexer_current_template_invoke_line(void);
int lexer_current_template_invoke_column(void);

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
int lexer_lookup_token_location(const char *token, const char **filename, int *line, int *column,
                                const char **template_instance,
                                const char **template_invoke_file,
                                int *template_invoke_line,
                                int *template_invoke_column);

// Return the final source spelling associated with one identifier token.
const char *lexer_token_source_spelling(const char *token);
// Return the spelling before template identifier rewriting.
const char *lexer_token_original_spelling(const char *token);
bool lexer_token_is_direct_template_source(const char *token);

#endif
