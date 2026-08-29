%option noyywrap nounput noinput case-insensitive

%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "util.h"
#include "addr_mode.h"
#include "opcode.h"
#include "parser.tab.h"

static char g_source_file[4096] = "<input>";
static long g_source_line = 1;
static char g_origin_file[4096] = "";
static long g_origin_line = 0;
static int g_origin_active = 0;

static void parse_file_marker(const char *text)
{
   const char *p;
   char *end;
   long line_no;

   p = text;

   if (strncmp(p, "@@FILE ", 7) != 0)
      return;

   p += 7;
   line_no = strtol(p, &end, 10);
   if (end == p)
      return;

   while (*end == ' ' || *end == '\t')
      end++;

   strncpy(g_source_file, end, sizeof(g_source_file) - 1);
   g_source_file[sizeof(g_source_file) - 1] = '\0';

   {
      size_t n = strlen(g_source_file);
      while (n > 0 &&
             (g_source_file[n - 1] == '\n' || g_source_file[n - 1] == '\r')) {
         g_source_file[n - 1] = '\0';
         n--;
      }
   }

   g_source_line = line_no;
}



static void parse_source_marker(const char *text)
{
   const char *p = text;
   char *end;
   long line_no;

   while (*p == ' ' || *p == '\t')
      p++;
   if (strncmp(p, ";@@SOURCE ", 10) != 0)
      return;
   p += 10;
   line_no = strtol(p, &end, 10);
   if (end == p || line_no < 0)
      return;
   if (line_no == 0) {
      strcpy(g_origin_file, "<compiler-generated>");
      g_origin_line = 0;
      g_origin_active = 1;
      return;
   }
   while (*end == ' ' || *end == '\t')
      end++;
   strncpy(g_origin_file, end, sizeof(g_origin_file) - 1);
   g_origin_file[sizeof(g_origin_file) - 1] = '\0';
   {
      size_t n = strlen(g_origin_file);
      while (n > 0 && (g_origin_file[n - 1] == '\n' || g_origin_file[n - 1] == '\r'))
         g_origin_file[--n] = '\0';
   }
   g_origin_line = line_no;
   g_origin_active = 1;
}

static int ascii_lower(int ch)
{
   if (ch >= 'A' && ch <= 'Z')
      return ch - 'A' + 'a';
   return ch;
}

static int suffix_is_plain_expression_mode(const char *text)
{
   const char *dot;
   char suffix[4];
   size_t i;
   size_t n;

   if (!text)
      return 0;

   dot = strchr(text, '.');
   if (!dot)
      return 0;

   n = strlen(dot);
   if (n >= sizeof(suffix))
      return 0;

   for (i = 0; i < n; i++)
      suffix[i] = (char)ascii_lower((unsigned char)dot[i]);
   suffix[n] = '\0';

   return !strcmp(suffix, ".z") ||
          !strcmp(suffix, ".zx") ||
          !strcmp(suffix, ".zy") ||
          !strcmp(suffix, ".a") ||
          !strcmp(suffix, ".ax") ||
          !strcmp(suffix, ".ay");
}

int lexer_listing_origin_active(void) { return g_origin_active; }
const char *lexer_listing_origin_file(void) { return g_origin_file; }
int lexer_listing_origin_line(void) { return (int)g_origin_line; }

#define YY_USER_ACTION                        \
   do {                                       \
      yylloc.first_line = (int)g_source_line; \
      yylloc.last_line = yylloc.first_line;   \
      yylloc.first_column = 1;                \
      yylloc.last_column = 1;                 \
      yylloc.filename = g_source_file;        \
   } while (0);
%}

WS           [ \t\r]+
HEX          \$[0-9A-Fa-f]+
BIN          %[01]+
DEC          [0-9]+
CHARBODY     ([^\\\n']|\\[0nrt'"\\])
CHARCONST    \'{CHARBODY}\'?
STRING       \"([^\\\n]|\\.)*\"
IDSTART      [A-Za-z_@?]
IDCHAR       [A-Za-z0-9_@?$]
IDENT        {IDSTART}{IDCHAR}*
DIRECTIVE    \.[A-Za-z_][A-Za-z0-9_]*
MODE_SUFFIX  \.(z|zx|zy|a|ax|ay|i|ix|iy|flex|same|cross)
OPCODETOK    {IDENT}{MODE_SUFFIX}?

%%

^@@FILE[^\n]*\n             { parse_file_marker(yytext); }
^[ \t]*";@@SOURCE "[^\n]*\n     { parse_source_marker(yytext); }

";"[^\n]*                  { }
{WS}                       { }
\n                         { g_source_line++; return EOL; }

".set"                     { return SET_DIRECTIVE; }
{DIRECTIVE}                { yylval.str = xstrdup(yytext); return DIRECTIVE; }

","                        { return ','; }
":"                        { return ':'; }
"#"                        { return '#'; }
"("                        { return '('; }
")"                        { return ')'; }
"{"                        { return '{'; }
"}"                        { return '}'; }
"<<"                       { return SHL; }
">>"                       { return SHR; }
"<="                       { return LE; }
">="                       { return GE; }
"=="                       { return EQ; }
"!="                       { return NE; }
"&&"                       { return LOG_AND; }
"||"                       { return LOG_OR; }
"+"                        { return '+'; }
"-"                        { return '-'; }
"*"                        { return '*'; }
"/"                        { return '/'; }
"%"                        { return '%'; }
"<"                        { return '<'; }
">"                        { return '>'; }
"&"                        { return '&'; }
"|"                        { return '|'; }
"^"                        { return '^'; }
"!"                        { return '!'; }
"~"                        { return '~'; }
"?="                       { return DEFAULT_ASSIGN; }
"="                        { return '='; }

[Aa]                       { return REG_A; }
[Xx]                       { return REG_X; }
[Yy]                       { return REG_Y; }

{HEX}                      { yylval.str = xstrdup(yytext); return NUMBER; }
{BIN}                      { yylval.str = xstrdup(yytext); return NUMBER; }
{DEC}                      { yylval.str = xstrdup(yytext); return NUMBER; }

{CHARCONST}                { yylval.str = xstrdup(yytext); return CHARCONST; }
{STRING}                   { yylval.str = xstrdup(yytext); return STRING; }

{IDENT}\?=                 {
                              size_t len = yyleng - 2;
                              yylval.str = (char *)malloc(len + 1);
                              if (!yylval.str)
                                 exit(1);
                              memcpy(yylval.str, yytext, len);
                              yylval.str[len] = '\0';
                              yyless((int)len);
                              return IDENT;
                           }

{IDENT}:{WS}*              {
                              size_t len = yyleng;

                              while (len > 0 &&
                                     (yytext[len - 1] == ' ' ||
                                      yytext[len - 1] == '\t' ||
                                      yytext[len - 1] == '\r'))
                                 --len;

                              --len;
                              yylval.str = (char *)malloc(len + 1);
                              if (!yylval.str)
                                 exit(1);

                              memcpy(yylval.str, yytext, len);
                              yylval.str[len] = '\0';
                              return LABEL_DEF;
                           }

{OPCODETOK}                {
                              if (opcode_token_is_mnemonic(yytext)) {
                                 yylval.str = xstrdup(yytext);
                                 if (suffix_is_plain_expression_mode(yytext))
                                    return OPCODE_EXPR_SUFFIX;
                                 return OPCODE;
                              }
                              yylval.str = xstrdup(yytext);
                              return IDENT;
                           }

.                          {
                              fprintf(stderr,
                                      "%s:%ld: lexer error: unexpected character '%s'\n",
                                      g_source_file, g_source_line, yytext);
                           }

<<EOF>>                    { return 0; }

%%
