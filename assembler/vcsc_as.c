//! @file assembler/main.c
//! @brief Implements assembler command-line entry point for the VCSC assembler.
//! @ingroup assembler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <getopt.h>

#include "ir.h"
#include "asm_pass.h"
#include "ihex.h"
#include "listing.h"
#include "source_loader.h"
#include "o26.h"
#include "opcode.h"
#include "util.h"
#include "xray.h"
#include "version.h"

int yyparse(void);
extern FILE *yyin;
extern program_ir_t g_program;

typedef struct
{
   const char *input_path;
   char **include_dirs;
   int include_dir_count;
   char **defines;
   int define_count;
   char **opcode_cfgs;
   int opcode_cfg_count;
   bool want_illegals;

   bool want_hex;
   bool want_lst;
   bool want_map;
   bool want_o26;

   const char *hex_path_arg;
   const char *lst_path_arg;
   const char *map_path_arg;
   const char *o26_path_arg;

   char *hex_path;
   char *lst_path;
   char *map_path;
   char *o26_path;
} options_t;

//! @brief Print the assembler command-line usage text.
static void usage(const char *argv0)
{
   fprintf(stderr,
      "usage: %s [options] file\n"
      "\n"
      "options:\n"
      "   -o, --output <file>     write relocatable o26 object output\n"
      "   -I, --include <dir>     add directory to include search path\n"
      "   -D <name[=value]>      define an early immutable symbol; value defaults to 1\n"
      "       --hex[=file]        write Intel HEX output\n"
      "       --lst[=file]        write listing output\n"
      "       --map[=file]        write map output\n"
      "       --opcode-cfg <file> load an additional opcode config file\n"
      "       --illegals          load the bundled illegals.cfg opcode set\n"
      "   -i, --input <file>      compatibility alias for positional input file\n"
      "       --o26[=file]        write object output; derive .o26 when file is omitted\n"
      "   -X <name>               enable named assembler xray option (use list to see them)\n"
      "   -h, --help              show this help\n"
      "   -V, --version           show version information\n"
      "\n"
      "notes:\n"
      "   bundled default.cfg is always loaded from the source tree or installed share/cfg\n"
      "   if no primary output is selected, relocatable o26 output is written to a.o26\n"
      "   use --o26 without a filename to derive the output name with suffix .o26\n"
      "\n"
      "examples:\n"
      "   %s prog.s26\n"
      "   %s -o prog.o26 prog.s26\n"
      "   %s --illegals --hex=prog.hex prog.s26\n"
      "   %s --opcode-cfg cpu65c02.cfg -I include prog.s26\n"
      "   %s -X passes --hex=prog.hex prog.s26\n",
      argv0, argv0, argv0, argv0, argv0, argv0);
}
//! @brief Create output path for main. The returned storage is owned by the caller or the object that immediately records it.
static char *make_output_path(const char *input_path, const char *ext)
{
   const char *slash;
   const char *base;
   const char *dot;
   size_t dir_len;
   size_t stem_len;
   size_t ext_len;
   char *out;

   slash = strrchr(input_path, '/');
#ifdef _WIN32
   {
      const char *bslash = strrchr(input_path, '\\');
      if (!slash || (bslash && bslash > slash))
         slash = bslash;
   }
#endif

   if (slash) {
      dir_len = (size_t)(slash - input_path + 1);
      base = slash + 1;
   } else {
      dir_len = 0;
      base = input_path;
   }

   dot = strrchr(base, '.');
   if (dot)
      stem_len = (size_t)(dot - base);
   else
      stem_len = strlen(base);

   ext_len = strlen(ext);

   out = (char *)malloc(dir_len + stem_len + 1 + ext_len + 1);
   if (!out) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   if (dir_len)
      memcpy(out, input_path, dir_len);

   memcpy(out + dir_len, base, stem_len);
   out[dir_len + stem_len] = '.';
   memcpy(out + dir_len + stem_len + 1, ext, ext_len);
   out[dir_len + stem_len + 1 + ext_len] = '\0';

   return out;
}

//! @brief Return join path2 data used by main; returned pointers alias existing storage unless explicitly allocated by the function name.
static char *join_path2(const char *dir, const char *name)
{
   size_t dir_len;
   size_t name_len;
   int need_sep;
   char *out;

   if (!dir || !*dir)
      return xstrdup(name);

   dir_len = strlen(dir);
   name_len = strlen(name);
   need_sep = dir_len > 0 && dir[dir_len - 1] != '/' && dir[dir_len - 1] != '\\';

   out = (char *)malloc(dir_len + (size_t)need_sep + name_len + 1);
   if (!out) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   memcpy(out, dir, dir_len);
   if (need_sep)
      out[dir_len++] = '/';
   memcpy(out + dir_len, name, name_len);
   out[dir_len + name_len] = '\0';
   return out;
}

//! @brief Return dirname copy data used by main; returned pointers alias existing storage unless explicitly allocated by the function name.
static char *dirname_copy(const char *path)
{
   const char *slash;
   size_t len;
   char *out;

   slash = strrchr(path, '/');
#ifdef _WIN32
   {
      const char *bslash = strrchr(path, '\\');
      if (!slash || (bslash && bslash > slash))
         slash = bslash;
   }
#endif

   if (!slash)
      return xstrdup("");

   len = (size_t)(slash - path);
   if (len == 0)
      len = 1;

   out = (char *)malloc(len + 1);
   if (!out) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   memcpy(out, path, len);
   out[len] = '\0';
   return out;
}

//! @brief Add include dir to main state, growing storage or preserving uniqueness as needed.
static void add_include_dir(options_t *opt, const char *dir)
{
   char **new_dirs;

   new_dirs = (char **)realloc(opt->include_dirs, sizeof(*opt->include_dirs) * (size_t)(opt->include_dir_count + 1));
   if (!new_dirs) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   opt->include_dirs = new_dirs;
   opt->include_dirs[opt->include_dir_count++] = xstrdup(dir);
}

static int define_name_is_valid(const char *name)
{
   const unsigned char *p;

   if (!name || !*name)
      return 0;

   p = (const unsigned char *)name;
   if (!(('A' <= *p && *p <= 'Z') || ('a' <= *p && *p <= 'z') || *p == '_' || *p == '?'))
      return 0;

   p++;
   while (*p) {
      if (!(('A' <= *p && *p <= 'Z') ||
            ('a' <= *p && *p <= 'z') ||
            ('0' <= *p && *p <= '9') ||
            *p == '_' || *p == '?' || *p == '$'))
         return 0;
      p++;
   }

   return 1;
}

static char *make_define_line(const char *spec)
{
   const char *eq;
   const char *value;
   size_t name_len;
   size_t value_len;
   char *name;
   char *line;

   if (!spec || !*spec) {
      fprintf(stderr, "error: -D requires NAME or NAME=value\n");
      return NULL;
   }

   if (strchr(spec, '\n') || strchr(spec, '\r')) {
      fprintf(stderr, "error: newline is not allowed in -D definition\n");
      return NULL;
   }

   eq = strchr(spec, '=');
   name_len = eq ? (size_t)(eq - spec) : strlen(spec);
   value = eq ? eq + 1 : "1";

   if (name_len == 0) {
      fprintf(stderr, "error: invalid -D name '%s'\n", spec);
      return NULL;
   }
   if (eq && !*value) {
      fprintf(stderr, "error: -D%s is missing a value\n", spec);
      return NULL;
   }

   name = (char *)malloc(name_len + 1);
   if (!name) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }
   memcpy(name, spec, name_len);
   name[name_len] = '\0';

   if (!define_name_is_valid(name)) {
      fprintf(stderr, "error: invalid -D name '%s'\n", spec);
      free(name);
      return NULL;
   }

   value_len = strlen(value);
   line = (char *)malloc(name_len + 3 + value_len + 1);
   if (!line) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   memcpy(line, name, name_len);
   memcpy(line + name_len, " = ", 3);
   memcpy(line + name_len + 3, value, value_len + 1);
   free(name);
   return line;
}

static int add_define(options_t *opt, const char *spec)
{
   char **new_defines;
   char *line;

   line = make_define_line(spec);
   if (!line)
      return 0;

   new_defines = (char **)realloc(opt->defines, sizeof(*opt->defines) * (size_t)(opt->define_count + 1));
   if (!new_defines) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   opt->defines = new_defines;
   opt->defines[opt->define_count++] = line;
   return 1;
}

//! @brief Add opcode configuration to main state, growing storage or preserving uniqueness as needed.
static void add_opcode_cfg(options_t *opt, const char *path)
{
   char **new_cfgs;

   new_cfgs = (char **)realloc(opt->opcode_cfgs, sizeof(*opt->opcode_cfgs) * (size_t)(opt->opcode_cfg_count + 1));
   if (!new_cfgs) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   opt->opcode_cfgs = new_cfgs;
   opt->opcode_cfgs[opt->opcode_cfg_count++] = xstrdup(path);
}

//! @brief Return whether a filesystem path exists.
static int file_exists(const char *path)
{
   FILE *fp = fopen(path, "r");
   if (!fp)
      return 0;
   fclose(fp);
   return 1;
}

static char *find_installed_cfg_from_bin_dir(const char *bin_dir, const char *cfg_name)
{
   char *prefix;
   char *share;
   char *cfgdir;
   char *path;

   prefix = dirname_copy(bin_dir);
   share = join_path2(prefix, "share");
   cfgdir = join_path2(share, "cfg");
   path = join_path2(cfgdir, cfg_name);

   free(prefix);
   free(share);
   free(cfgdir);

   if (file_exists(path))
      return path;

   free(path);
   return NULL;
}


//! @brief Find configuration next to program in path in main tables without transferring ownership.
static char *find_cfg_next_to_program_in_path(const char *argv0, const char *cfg_name)
{
   const char *path_env;
   const char *p;

   path_env = getenv("PATH");
   if (!path_env || !*path_env || strchr(argv0, '/') || strchr(argv0, '\\'))
      return NULL;

   p = path_env;
   while (*p) {
#ifdef _WIN32
      const char *end = strchr(p, ';');
#else
      const char *end = strchr(p, ':');
#endif
      size_t len = end ? (size_t)(end - p) : strlen(p);
      char *dir;
      char *prog_path;
      char *cfg_path;

      dir = (char *)malloc(len + 1);
      if (!dir) {
         fprintf(stderr, "out of memory\n");
         exit(1);
      }
      memcpy(dir, p, len);
      dir[len] = '\0';

      prog_path = join_path2(dir, argv0);
      if (file_exists(prog_path)) {
         cfg_path = join_path2(dir, cfg_name);
         free(prog_path);
         if (file_exists(cfg_path)) {
            free(dir);
            return cfg_path;
         }
         free(cfg_path);

         cfg_path = find_installed_cfg_from_bin_dir(dir, cfg_name);
         free(dir);
         if (cfg_path)
            return cfg_path;
      } else {
         free(prog_path);
         free(dir);
      }

      if (!end)
         break;
      p = end + 1;
   }

   return NULL;
}

//! @brief Find bundled configuration path in main tables without transferring ownership.
static char *find_bundled_cfg_path(const char *argv0, const char *cfg_name)
{
   char *dir;
   char *path;

   dir = dirname_copy(argv0);
   path = join_path2(dir, cfg_name);
   if (file_exists(path)) {
      free(dir);
      return path;
   }
   free(path);

   path = find_installed_cfg_from_bin_dir(dir, cfg_name);
   free(dir);
   if (path)
      return path;

   path = find_cfg_next_to_program_in_path(argv0, cfg_name);
   if (path)
      return path;

   path = xstrdup(cfg_name);
   if (file_exists(path))
      return path;
   free(path);

   path = join_path2("assembler", cfg_name);
   if (file_exists(path))
      return path;
   free(path);

   return NULL;
}

//! @brief Load opcode configs for main and initialize the caller-visible state.
static bool load_opcode_configs(const char *argv0, const options_t *opt)
{
   char *default_cfg;
   char *illegals_cfg;
   int i;

   opcode_registry_reset();

   default_cfg = find_bundled_cfg_path(argv0, "default.cfg");
   if (!default_cfg) {
      fprintf(stderr, "error: could not locate bundled default.cfg for opcode table\n");
      return false;
   }

   if (!opcode_load_config_file(default_cfg)) {
      free(default_cfg);
      return false;
   }
   free(default_cfg);

   if (opt->want_illegals) {
      illegals_cfg = find_bundled_cfg_path(argv0, "illegals.cfg");
      if (!illegals_cfg) {
         fprintf(stderr, "error: could not locate bundled illegals.cfg\n");
         return false;
      }
      if (!opcode_load_config_file(illegals_cfg)) {
         free(illegals_cfg);
         return false;
      }
      free(illegals_cfg);
   }

   for (i = 0; i < opt->opcode_cfg_count; ++i) {
      if (!opcode_load_config_file(opt->opcode_cfgs[i]))
         return false;
   }

   return true;
}

//! @brief Handle opt xray logic for main.
static void opt_xray(const char *name)
{
   assembler_set_xray(assembler_lookup_xray(name));
}

//! @brief Parse args into the normalized representation used by main.
static bool parse_args(int argc, char **argv, options_t *opt)
{
   int ch;
   int option_index = 0;
   const char *positional_input = NULL;
   bool default_o26_output = false;

   static struct option long_options[] = {
      { "input", required_argument, NULL, 'i' },
      { "include", required_argument, NULL, 'I' },
      { "define", required_argument, NULL, 'D' },
      { "output", required_argument, NULL, 'o' },
      { "hex", optional_argument, NULL, 1000 },
      { "lst", optional_argument, NULL, 1001 },
      { "map", optional_argument, NULL, 1002 },
      { "o26", optional_argument, NULL, 1003 },
      { "opcode-cfg", required_argument, NULL, 1004 },
      { "illegals", no_argument, NULL, 1005 },
      { "help", no_argument, NULL, 'h' },
      { "version", no_argument, NULL, 'V' },
      { NULL, 0, NULL, 0 }
   };

   memset(opt, 0, sizeof(*opt));
   opterr = 0;

   while ((ch = getopt_long(argc, argv, ":VX:hI:D:i:o:", long_options, &option_index)) != -1) {
      switch (ch) {
      case 'X':
         opt_xray(optarg);
         break;

      case 'h':
         usage(argv[0]);
         exit(0);

      case 'V':
         puts(VERSION);
         exit(0);

      case 'i':
         if (opt->input_path) {
            fprintf(stderr, "error: input file specified more than once\n");
            usage(argv[0]);
            return false;
         }
         opt->input_path = optarg;
         break;

      case 'I':
         add_include_dir(opt, optarg);
         break;

      case 'D':
         if (!add_define(opt, optarg)) {
            usage(argv[0]);
            return false;
         }
         break;

      case 'o':
         opt->want_o26 = true;
         opt->o26_path_arg = optarg;
         break;

      case 1000:
         opt->want_hex = true;
         opt->hex_path_arg = optarg;
         break;

      case 1001:
         opt->want_lst = true;
         opt->lst_path_arg = optarg;
         break;

      case 1002:
         opt->want_map = true;
         opt->map_path_arg = optarg;
         break;

      case 1003:
         opt->want_o26 = true;
         opt->o26_path_arg = optarg;
         break;

      case 1004:
         add_opcode_cfg(opt, optarg);
         break;

      case 1005:
         opt->want_illegals = true;
         break;

      case ':':
         fprintf(stderr, "%s: missing argument for option '%s'\n",
            argv[0], argv[optind - 1]);
         fprintf(stderr, "Try '%s --help' for a list of supported options.\n", argv[0]);
         return false;

      default:
         fprintf(stderr, "%s: unsupported option '%s'\n",
            argv[0], argv[optind - 1]);
         fprintf(stderr, "Try '%s --help' for a list of supported options.\n", argv[0]);
         return false;
      }
   }

   while (optind < argc) {
      if (positional_input) {
         fprintf(stderr, "error: unexpected positional argument: %s\n", argv[optind]);
         usage(argv[0]);
         return false;
      }
      positional_input = argv[optind++];
   }

   if (positional_input) {
      if (opt->input_path) {
         fprintf(stderr, "error: input file specified both positionally and with -i/--input\n");
         usage(argv[0]);
         return false;
      }
      opt->input_path = positional_input;
   }

   if (!opt->input_path) {
      fprintf(stderr, "error: input file is required\n");
      usage(argv[0]);
      return false;
   }

   if (!opt->want_hex && !opt->want_o26) {
      opt->want_o26 = true;
      default_o26_output = true;
   }

   if (opt->want_hex) {
      if (opt->hex_path_arg)
         opt->hex_path = xstrdup(opt->hex_path_arg);
      else
         opt->hex_path = make_output_path(opt->input_path, "hex");
   }

   if (opt->want_lst) {
      if (opt->lst_path_arg)
         opt->lst_path = xstrdup(opt->lst_path_arg);
      else
         opt->lst_path = make_output_path(opt->input_path, "lst");
   }

   if (opt->want_map) {
      if (opt->map_path_arg)
         opt->map_path = xstrdup(opt->map_path_arg);
      else
         opt->map_path = make_output_path(opt->input_path, "map");
   }

   if (opt->want_o26) {
      if (opt->o26_path_arg)
         opt->o26_path = xstrdup(opt->o26_path_arg);
      else if (default_o26_output)
         opt->o26_path = xstrdup("a.o26");
      else
         opt->o26_path = make_output_path(opt->input_path, "o26");
   }

   return true;
}

//! @brief Release options storage owned by main.
static void free_options(options_t *opt)
{
   int i;

   for (i = 0; i < opt->include_dir_count; i++)
      free(opt->include_dirs[i]);
   free(opt->include_dirs);

   for (i = 0; i < opt->define_count; i++)
      free(opt->defines[i]);
   free(opt->defines);

   for (i = 0; i < opt->opcode_cfg_count; i++)
      free(opt->opcode_cfgs[i]);
   free(opt->opcode_cfgs);

   free(opt->hex_path);
   free(opt->lst_path);
   free(opt->map_path);
   free(opt->o26_path);
}

//! @brief Entry point for the assembler command; parses arguments, runs the requested pipeline, and returns process status.
int main(int argc, char **argv)
{
   options_t opt;
   asm_context_t ctx;
   listing_writer_t lst;
   FILE *hexfp = NULL;
   FILE *mapfp = NULL;
   FILE *o26fp = NULL;
   bool lst_open = false;
   bool ctx_init = false;
   bool ir_init = false;
   int rc = 1;

   if (!parse_args(argc, argv, &opt))
      return 1;

   if (!load_opcode_configs(argv[0], &opt)) {
      free_options(&opt);
      opcode_registry_free();
      return 1;
   }

   for (int i = 0; i < opt.include_dir_count; i++)
      source_loader_add_include_dir(opt.include_dirs[i]);

   yyin = source_loader_open_expanded_with_defines(opt.input_path, (const char *const *)opt.defines, opt.define_count);
   if (!yyin) {
      perror(opt.input_path);
      free_options(&opt);
      opcode_registry_free();
      return 1;
   }

   if (opt.want_hex) {
      hexfp = fopen(opt.hex_path, "w");
      if (!hexfp) {
         perror(opt.hex_path);
         goto cleanup;
      }
   }

   if (opt.want_lst) {
      if (!listing_open(&lst, opt.lst_path)) {
         perror(opt.lst_path);
         goto cleanup;
      }
      lst_open = true;
   }

   if (opt.want_map) {
      mapfp = fopen(opt.map_path, "w");
      if (!mapfp) {
         perror(opt.map_path);
         goto cleanup;
      }
   }

   if (opt.want_o26) {
      o26fp = fopen(opt.o26_path, "wb");
      if (!o26fp) {
         perror(opt.o26_path);
         goto cleanup;
      }
   }

   program_ir_init(&g_program);
   ir_init = true;

   rc = yyparse();
   fclose(yyin);
   yyin = NULL;

   if (rc != 0)
      goto cleanup;

   if (!program_ir_expand_repeats(&g_program)) {
      rc = 1;
      goto cleanup;
   }

   asm_context_init(&ctx, &g_program, lst_open ? &lst : NULL, opt.want_o26);
   ctx_init = true;

   asm_relax(&ctx);

   if (!opt.want_o26)
      asm_pass2(&ctx);

   if (ctx.error_count == 0 && o26fp) {
      if (!o26_write_object_file(o26fp, &ctx)) {
         rc = 1;
         goto cleanup;
      }
   }

   if (mapfp) {
      if (!asm_write_map_file(mapfp, &ctx)) {
         rc = 1;
         goto cleanup;
      }
   }

   if (ctx.error_count == 0 && hexfp) {
      if (!ihex_dump(hexfp, &ctx.image)) {
         rc = 1;
         goto cleanup;
      }
   }

   rc = ctx.error_count ? 1 : 0;

cleanup:
   if (ctx_init)
      asm_context_free(&ctx);

   if (mapfp)
      fclose(mapfp);
   if (o26fp)
      fclose(o26fp);

   if (lst_open)
      listing_close(&lst);

   if (hexfp)
      fclose(hexfp);

   if (yyin) {
      fclose(yyin);
      yyin = NULL;
   }

   if (ir_init)
      program_ir_free(&g_program);

   free_options(&opt);
   opcode_registry_free();
   return rc;
}
