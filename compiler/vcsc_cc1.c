//! @file compiler/main.c
//! @brief Implements compiler command-line entry point for the VCSC compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#ifdef _WIN32
#include <io.h>
#define access _access
#else
#include <unistd.h>
#endif

#include "ast.h"
#include "compile.h"
#include "compile_inline_inliner.h"
#include "compile_inline_identity.h"
#include "coverage.h"
#include "expropt.h"
#include "lextern.h"
#include "md5seen.h"
#include "messages.h"
#include "xray.h"
#include "version.h"

#include "parser.tab.h"

static char *arg0;

static void opt_help(char *);
static void opt_version(char *);
static void opt_define(char *);
static void opt_peephole(char *);
static void opt_no_peephole(char *);
static void opt_inline_select(char *);
static void opt_inline_candidates(char *);
static void opt_inline_prune_dead(char *);

//! @brief Handle opt xray logic for main.
static void opt_xray(char *n) {
   int i = lookup_xray(n);
   set_xray(i);
}

static char **inclist = NULL;
static int inclist_cnt = 0;
//! @brief Handle opt include logic for main.
static void opt_include(char *n) {
   inclist = (char **) realloc(inclist, sizeof(char *) * (inclist_cnt + 1));
   inclist[inclist_cnt++] = strdup(n);
}

static const char *outfile = NULL;
//! @brief Handle opt output logic for main.
static void opt_output(char *n) {
   outfile = n;
}

//! @brief Handle opt define logic for main.
static void opt_define(char *n) {
   lexer_define_alias_from_command_line(n);
}

//! @brief Enable compiler assembly peephole optimization.
static void opt_peephole(char *unused) {
   (void) unused;
   set_peephole_enabled(true);
}

//! @brief Disable compiler assembly peephole optimization.
static void opt_no_peephole(char *unused) {
   (void) unused;
   set_peephole_enabled(false);
}

//! @brief Select one optimizer-inline candidate already approved by the final-link driver.
static void opt_inline_select(char *name) {
   optimizer_inline_request_selection(name);
}

//! @brief Write mechanically/placement-legal optimizer candidates for driver trials.
static void opt_inline_candidates(char *path) {
   optimizer_inline_set_candidate_manifest(path);
}

//! @brief Enable internal unreachable-static-function pruning for measured optimization.
static void opt_inline_prune_dead(char *unused) {
   (void) unused;
   optimizer_inline_set_dead_pruning(true);
}

//! @brief Handle opt ignore logic for main.
static void opt_ignore(char *unused) {
   (void) unused;
}

//! @brief Find includes in main tables without transferring ownership.
const char *search_includes(const char *filename) {
   static char *ret = NULL;

   if (access(filename, F_OK) == 0) {
      return filename;
   }

   // hunt through list
   for (int i = 0; i < inclist_cnt; i++) {
      int l = strlen(filename) + 1 + strlen(inclist[i]) + 1;
      ret = (char *) realloc(ret, sizeof(char) * l);
      sprintf(ret, "%s/%s", inclist[i], filename);

      if (access(ret, F_OK) == 0) {
         debug("mapping %s -> %s", filename, ret);
         return ret;
      }
   }

   // an error...

   if (!inclist_cnt) {
      debug("could not find %s, no includes given", filename);
   }
   else {
      debug("could not find %s, searched %d place%s", filename, inclist_cnt, inclist_cnt > 1 ? "s" : "");
      for (int i = 0; i < inclist_cnt; i++) {
         debug("   %s", inclist[i]);
      }
   }

   return filename;
}

struct option_def {
   char  short_char;
   char *long_name;
   char *arg_name;
   char *help;
   void (*func)(char *);
};

static struct option_def options[] = {
   { 'X', "XRAY", "name", "enable named XRAY option for compiler debugging ('list' will list them)", opt_xray },
   { 'I', "include", "path", "add path to include search list", opt_include },
   { 'D', "define", "name[=value]", "predefine object-like alias (default value is 1)", opt_define },
   { 'o', "output", "file.s26", "write assembly output to file ('-' means stdout)", opt_output },
   { 0, "fpeephole", NULL, "enable compiler assembly peephole optimization (default)", opt_peephole },
   { 0, "fno-peephole", NULL, "disable all compiler assembly peephole rewrites", opt_no_peephole },
   { 0, "finline-select", "name", "internal: select one measured optimizer-inline candidate", opt_inline_select },
   { 0, "finline-candidates", "file", "internal: write legal optimizer-inline candidates", opt_inline_candidates },
   { 0, "finline-prune-dead", NULL, "internal: remove safe unreachable internal functions", opt_inline_prune_dead },
   { 0, "quiet", NULL, "accept GCC cc1's -quiet flag and ignore it", opt_ignore },
   { 0, "dumpbase", "name", "accept GCC cc1's -dumpbase flag and ignore it", opt_ignore },
   { 0, "dumpbase-ext", "ext", "accept GCC cc1's -dumpbase-ext flag and ignore it", opt_ignore },
   { 0, "dumpdir", "dir", "accept GCC cc1's -dumpdir flag and ignore it", opt_ignore },
   { '?', "help", NULL, "print usage information", opt_help },
   { 'V', "version", NULL, "print version information", opt_version }
};

#define NOPTS (sizeof(options) / sizeof(options[0]))

//! @brief Handle opt help logic for main.
static void opt_help(char *unused) {
   (void) unused; // unused parameter
   printf("Usage: %s <flags> <filename>\n", arg0);
   printf("   one input filename is required and may appear anywhere on the command line\n");
   printf("   GNU cc1-style compatibility flags -quiet, -dumpbase, -dumpbase-ext, and -dumpdir are accepted\n");
   printf("   flags:\n");
   for (size_t i = 0; i < NOPTS; i++) {
      if (options[i].arg_name) {
         if (options[i].short_char) {
            printf("   -%c/--%s\t<%s>\t%s\n",
               options[i].short_char,
               options[i].long_name,
               options[i].arg_name,
               options[i].help);
         }
         else {
            printf("   -%s\t<%s>\t%s\n",
               options[i].long_name,
               options[i].arg_name,
               options[i].help);
         }
      }
      else {
         if (options[i].short_char) {
            printf("   -%c/--%s\t\t%s\n",
               options[i].short_char,
               options[i].long_name,
               options[i].help);
         }
         else {
            printf("   -%s\t\t%s\n",
               options[i].long_name,
               options[i].help);
         }
      }
   }
   exit(0);
}

//! @brief Handle opt version logic for main.
static void opt_version(char *unused) {
   (void) unused;
   puts(VERSION);
   exit(0);
}

//! @brief Reject one unsupported compiler option and point at the complete help text.
static void unsupported_option(const char *arg) {
   fprintf(stderr, "%s: unsupported option '%s'\n", arg0, arg);
   fprintf(stderr, "Try '%s --help' for a list of supported options.\n", arg0);
   exit(1);
}

static struct option_def *find_option(const char *arg, const char **inline_arg, bool *used_double_dash) {
   *inline_arg = NULL;
   *used_double_dash = false;

   if (arg[0] != '-' || arg[1] == '\0') {
      return NULL;
   }

   if (arg[1] == '-') {
      const char *name = arg + 2;
      const char *eq = strchr(name, '=');
      size_t name_len = eq ? (size_t) (eq - name) : strlen(name);
      *used_double_dash = true;
      if (eq) {
         *inline_arg = eq + 1;
      }
      for (size_t i = 0; i < NOPTS; i++) {
         if (!strncmp(options[i].long_name, name, name_len) && options[i].long_name[name_len] == '\0') {
            return &options[i];
         }
      }
      return NULL;
   }

   for (size_t i = 0; i < NOPTS; i++) {
      if (options[i].short_char && arg[1] == options[i].short_char && options[i].short_char != '\0') {
         if (arg[2] != '\0') {
            *inline_arg = arg + 2;
         }
         return &options[i];
      }
   }

   {
      const char *name = arg + 1;
      const char *eq = strchr(name, '=');
      size_t name_len = eq ? (size_t) (eq - name) : strlen(name);
      if (eq) {
         *inline_arg = eq + 1;
      }
      for (size_t i = 0; i < NOPTS; i++) {
         if (!strncmp(options[i].long_name, name, name_len) && options[i].long_name[name_len] == '\0') {
            return &options[i];
         }
      }
   }

   return NULL;
}

#ifdef _WIN32

char *strndup(const char *s, size_t n)
{
    size_t len = 0;
    char *copy;

    while (len < n && s[len] != '\0')
        ++len;

    copy = malloc(len + 1);
    if (copy == NULL)
        return NULL;

    memcpy(copy, s, len);
    copy[len] = '\0';

    return copy;
}

#endif

#define return "DON'T USE return, MUST USE exit !!!" // please don't break xray !!!
//! @brief Entry point for the compiler command; parses arguments, runs the requested pipeline, and returns process status.
int main(int argc, char** argv) {
   int ret;
   const char *input = NULL;

   arg0 = argv[0];

   argc--;
   argv++;

   while (argc) {
      const char *inline_arg = NULL;
      bool used_double_dash = false;
      struct option_def *opt = find_option(argv[0], &inline_arg, &used_double_dash);

      if (opt) {
         char *arg = NULL;
         argc--;
         argv++;

         if (opt->arg_name) {
            if (inline_arg && *inline_arg) {
               arg = (char *) inline_arg;
            }
            else if (argc == 0) {
               opt_help(NULL);
            }
            else {
               arg = argv[0];
               argc--;
               argv++;
            }
         }
         else if (inline_arg && *inline_arg && !used_double_dash) {
            opt_help(NULL);
         }

         opt->func(arg);
         continue;
      }

      if (argv[0][0] == '-' && argv[0][1] != '\0') {
         unsupported_option(argv[0]);
      }

      if (input) {
         fprintf(stderr, "%s: exactly one input file is required\n", arg0);
         exit(-1);
      }

      input = argv[0];
      argc--;
      argv++;
   }

   if (!input) {
      opt_help(NULL);
   }

   yyin = fopen(input, "r");
   if (!yyin) {
      perror(input);
      exit(-1);
   }
   md5seen(input, yyin);

   root_filename = current_filename = (char *) input;

#if YYDEBUG
   yydebug = 1;
#endif

   debug(";Parsing...\n");

   ret = yyparse();

   if (get_xray(XRAY_DUMPAST)) {
      parse_dump_node(root);
   }

   if (ret == 0) {
      debug(";Parse successful.\n");
      if (get_xray(XRAY_PARSEONLY)) {
         exit(0);
      }
   } else {
      error_unreachable(";Parse failed.\n");
      exit(-1);
   }

   if (get_xray(XRAY_COVERAGE)) {
      coverage_report();
      exit(0);
   }

   do_expropt();
   if (get_xray(XRAY_EXPROPTONLY)) {
      exit(0);
   }

   {
      FILE *out = stdout;
      bool close_out = false;

      if (outfile && strcmp(outfile, "-") != 0) {
         out = fopen(outfile, "w");
         if (!out) {
            perror(outfile);
            exit(-1);
         }
         close_out = true;
      }

      do_compile(out);

      if (close_out) {
         fclose(out);
      }
   }

   exit(0);
}
