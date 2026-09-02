//! @file driver/vcsc.c
//! @brief Implements toolchain driver command-line entry point for the VCSC driver.
//! @ingroup driver

#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#ifdef _WIN32
#include <direct.h>
#include <io.h>
#include <process.h>
#include <windows.h>
#define access _access
#define close _close
#define getcwd _getcwd
#define open _open
#define rmdir _rmdir
#define unlink _unlink
#ifndef R_OK
#define R_OK 4
#endif
#ifndef X_OK
#define X_OK 0
#endif
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

#include "version.h"
#include "inline_profit.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

typedef struct {
   char **items;
   size_t count;
   size_t cap;
} strvec_t;

typedef enum {
   INPUT_VCSC,
   INPUT_ASM,
   INPUT_OBJ,
   INPUT_ARC
} input_kind_t;

typedef struct {
   char *path;
   input_kind_t kind;
} input_t;

typedef struct {
   input_t *items;
   size_t count;
   size_t cap;
} inputvec_t;

typedef struct {
   bool compile_only;
   bool asm_only;
   bool verbose;
   bool dry_run;
   bool nostdlib;
   const char *output;
   const char *link_script;
   const char *map_path;
   const char *sym_path;
   const char *list_path;
   const char *cfg_path;
   bool no_map;
   bool no_sym;
   bool no_list;
   bool no_cfg;
   bool inline_profit;
   strvec_t include_dirs;
   strvec_t lib_dirs;
   strvec_t libs;
   strvec_t defines;
   strvec_t cc_extra;
   strvec_t as_extra;
   strvec_t ld_extra;
   inputvec_t inputs;
} driver_options_t;

typedef struct {
   char *path;
   bool keep;
} temp_path_t;

typedef struct {
   temp_path_t *items;
   size_t count;
   size_t cap;
   char tempdir[PATH_MAX];
   bool made_tempdir;
} temp_store_t;

typedef struct {
   char *source;
   size_t link_index;
   char *manifest;
   strvec_t candidates;
   strvec_t selected;
} inline_tu_t;

typedef struct {
   inline_tu_t *items;
   size_t count;
   size_t cap;
} inline_tuvec_t;

static const char *arg0;
static temp_store_t *active_temp_store;

//! @brief Report die diagnostics with the location/context expected by driver pipeline callers.
static void die(const char *fmt, ...)
{
   va_list ap;
   fprintf(stderr, "%s: ", arg0);
   va_start(ap, fmt);
   vfprintf(stderr, fmt, ap);
   va_end(ap);
   fputc('\n', stderr);
   exit(1);
}

//! @brief Reject one unsupported driver option and point at the complete help text.
static void unsupported_option(const char *arg)
{
   fprintf(stderr, "%s: unsupported option '%s'\n", arg0, arg);
   fprintf(stderr, "Try '%s --help' for a list of supported options.\n", arg0);
   exit(1);
}

//! @brief Allocate memory for tool data structures, terminating with a diagnostic on failure.
static void *xmalloc(size_t n)
{
   void *p = malloc(n ? n : 1);
   if (!p)
      die("out of memory");
   return p;
}

//! @brief Resize tool-owned memory, terminating with a diagnostic on failure.
static void *xrealloc(void *p, size_t n)
{
   void *q = realloc(p, n ? n : 1);
   if (!q)
      die("out of memory");
   return q;
}

//! @brief Duplicate a string for tool-owned storage, terminating with a diagnostic on failure.
static char *xstrdup(const char *s)
{
   char *p = strdup(s);
   if (!p)
      die("out of memory");
   return p;
}

//! @brief Handle strvec push owned logic for driver pipeline.
static void strvec_push_owned(strvec_t *v, char *s)
{
   if (v->count == v->cap) {
      v->cap = v->cap ? v->cap * 2 : 8;
      v->items = xrealloc(v->items, v->cap * sizeof(v->items[0]));
   }
   v->items[v->count++] = s;
}

//! @brief Handle strvec push logic for driver pipeline.
static void strvec_push(strvec_t *v, const char *s)
{
   strvec_push_owned(v, xstrdup(s));
}

static bool strvec_contains(const strvec_t *v, const char *s)
{
   size_t i;
   if (!v || !s) return false;
   for (i = 0; i < v->count; ++i)
      if (strcmp(v->items[i], s) == 0) return true;
   return false;
}

static void strvec_release(strvec_t *v)
{
   size_t i;
   if (!v) return;
   for (i = 0; i < v->count; ++i) free(v->items[i]);
   free(v->items);
   memset(v, 0, sizeof(*v));
}

static void strvec_clone_replace(strvec_t *dst, const strvec_t *src,
   size_t replace_index, const char *replacement)
{
   size_t i;
   memset(dst, 0, sizeof(*dst));
   for (i = 0; i < src->count; ++i)
      strvec_push(dst, (i == replace_index) ? replacement : src->items[i]);
}

static void inline_tuvec_push(inline_tuvec_t *v, const char *source,
   size_t link_index, const char *manifest)
{
   inline_tu_t *tu;
   if (v->count == v->cap) {
      v->cap = v->cap ? v->cap * 2 : 4;
      v->items = xrealloc(v->items, v->cap * sizeof(v->items[0]));
   }
   tu = &v->items[v->count++];
   memset(tu, 0, sizeof(*tu));
   tu->source = xstrdup(source);
   tu->link_index = link_index;
   tu->manifest = xstrdup(manifest);
}

static void read_inline_candidate_manifest(inline_tu_t *tu)
{
   FILE *fp;
   char line[512];
   if (!tu || !tu->manifest) return;
   fp = fopen(tu->manifest, "r");
   if (!fp) die("could not read inline candidate manifest '%s': %s",
                tu->manifest, strerror(errno));
   while (fgets(line, sizeof(line), fp)) {
      size_t n = strlen(line);
      while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = '\0';
      if (n && !strvec_contains(&tu->candidates, line)) strvec_push(&tu->candidates, line);
   }
   if (fclose(fp) != 0) die("could not close inline candidate manifest '%s'", tu->manifest);
}

//! @brief Handle inputvec push logic for driver pipeline.
static void inputvec_push(inputvec_t *v, const char *path, input_kind_t kind)
{
   if (v->count == v->cap) {
      v->cap = v->cap ? v->cap * 2 : 8;
      v->items = xrealloc(v->items, v->cap * sizeof(v->items[0]));
   }
   v->items[v->count].path = xstrdup(path);
   v->items[v->count].kind = kind;
   v->count++;
}

//! @brief Return the final path component; the pointer aliases the input path.
static const char *path_basename(const char *path)
{
   const char *slash = strrchr(path, '/');
   const char *bslash = strrchr(path, '\\');
   const char *base = path;

   if (slash && slash + 1 > base)
      base = slash + 1;
   if (bslash && bslash + 1 > base)
      base = bslash + 1;
   return base;
}

//! @brief Copy the directory component of a path into a bounded buffer.
static void path_dirname(const char *path, char *out, size_t out_sz)
{
   const char *base = path_basename(path);
   size_t len;

   if (base == path) {
      snprintf(out, out_sz, ".");
      return;
   }

   len = (size_t)(base - path);
   if (len > 0 && (path[len - 1] == '/' || path[len - 1] == '\\'))
      len--;

   if (len >= out_sz)
      die("path too long");

   memcpy(out, path, len);
   out[len] = '\0';
}

//! @brief Return the extension component of a path, or an empty suffix if there is none.
static const char *path_extension(const char *path)
{
   const char *base = path_basename(path);
   const char *dot = strrchr(base, '.');
   return dot ? dot : "";
}

//! @brief Copy the filename stem into a bounded buffer without its final extension.
static void path_stem(const char *path, char *out, size_t out_sz)
{
   const char *base = path_basename(path);
   const char *dot = strrchr(base, '.');
   size_t len = dot ? (size_t)(dot - base) : strlen(base);

   if (len + 1 > out_sz)
      die("filename stem too long for buffer");

   memcpy(out, base, len);
   out[len] = '\0';
}

//! @brief Copy a C string into a bounded buffer and preserve NUL termination.
static void copy_cstr(char *out, size_t out_sz, const char *src)
{
   size_t len = strlen(src);

   if (len + 1 > out_sz)
      die("path too long");

   memcpy(out, src, len + 1);
}

//! @brief Handle join path2 logic for driver pipeline.
static void join_path2(char *out, size_t out_sz, const char *a, const char *b)
{
   size_t alen = strlen(a);
   size_t blen = strlen(b);

   if (alen + 1 + blen + 1 > out_sz)
      die("path too long");

   memcpy(out, a, alen);
   out[alen] = '/';
   memcpy(out + alen + 1, b, blen + 1);
}

//! @brief Handle join path3 logic for driver pipeline.
static void join_path3(char *out, size_t out_sz, const char *a, const char *b, const char *c)
{
   size_t alen = strlen(a);
   size_t blen = strlen(b);
   size_t clen = strlen(c);

   if (alen + 1 + blen + 1 + clen + 1 > out_sz)
      die("path too long");

   memcpy(out, a, alen);
   out[alen] = '/';
   memcpy(out + alen + 1, b, blen);
   out[alen + 1 + blen] = '/';
   memcpy(out + alen + 1 + blen + 1, c, clen + 1);
}

//! @brief Return whether path is accessible in driver pipeline.
static bool path_is_accessible(const char *path, int mode)
{
#ifdef _WIN32
   int win_mode = mode == R_OK ? 4 : 0;
   return _access(path, win_mode) == 0;
#else
   return access(path, mode) == 0;
#endif
}

//! @brief Create suffixed path for driver pipeline.
static void make_suffixed_path(const char *path, const char *suffix, char *out, size_t out_sz)
{
   char dir[PATH_MAX];
   char stem[PATH_MAX];
   size_t dir_len;
   size_t stem_len;
   size_t suffix_len;

   path_dirname(path, dir, sizeof(dir));
   path_stem(path, stem, sizeof(stem));
   dir_len = strlen(dir);
   stem_len = strlen(stem);
   suffix_len = strlen(suffix);

   if (strcmp(dir, ".") == 0) {
      if (stem_len + suffix_len + 1 > out_sz)
         die("path too long");
      memcpy(out, stem, stem_len);
      memcpy(out + stem_len, suffix, suffix_len + 1);
      return;
   }

   if (dir_len + 1 + stem_len + suffix_len + 1 > out_sz)
      die("path too long");

   memcpy(out, dir, dir_len);
   out[dir_len] = '/';
   memcpy(out + dir_len + 1, stem, stem_len);
   memcpy(out + dir_len + 1 + stem_len, suffix, suffix_len + 1);
}

//! @brief Return whether a string ends with the requested suffix.
static bool ends_with(const char *s, const char *suffix)
{
   size_t slen = strlen(s);
   size_t tlen = strlen(suffix);
   if (slen < tlen)
      return false;
   return strcmp(s + slen - tlen, suffix) == 0;
}

//! @brief Parse input into the normalized representation used by driver pipeline.
static input_kind_t classify_input(const char *path)
{
   if (ends_with(path, ".c26"))
      return INPUT_VCSC;
   if (ends_with(path, ".s26") || ends_with(path, ".asm"))
      return INPUT_ASM;
   /* Temporary source-suffix compatibility: .s is accepted but no longer canonical. */
   if (ends_with(path, ".s")) {
      fprintf(stderr, "%s: warning: legacy assembler suffix '.s'; rename '%s' to use '.s26'\n", arg0, path);
      return INPUT_ASM;
   }
   if (ends_with(path, ".o26"))
      return INPUT_OBJ;
   if (ends_with(path, ".l26"))
      return INPUT_ARC;
   die("do not know how to handle input '%s'", path);
   return INPUT_VCSC;
}

//! @brief Print the driver command-line usage text.
static void usage(FILE *fp)
{
   fprintf(fp,
      "Usage: %s [options] file...\n"
      "\n"
      "A brutally pared-down Atari VCS C-like compiler.\n"
      "It invokes vcsc-cc1, vcsc-as, and vcsc-ld as needed.\n"
      "\n"
      "Overall options:\n"
      "  -c                   Compile/assemble, but do not link\n"
      "  -S                   Compile only; stop after assembly output\n"
      "  -o FILE              Write final output to FILE\n"
      "  -I DIR               Add DIR to compiler/assembler include search path\n"
      "  -DNAME[=VALUE]       Define NAME as VALUE, or 1 if VALUE is omitted\n"
      "  -fpeephole           Enable compiler peephole optimization (default)\n"
      "  -fno-peephole        Disable compiler peephole optimization\n"
      "  -finline-profit      Enable measured whole-program inlining/dead pruning\n"
      "  -L DIR               Add DIR to archive search path for -l\n"
      "  -lNAME               Link archive NAME (tries libNAME.l26 then NAME.l26)\n"
      "  -nostdlib            Do not link default runtime libraries automatically\n"
      "  -T FILE              Pass FILE to vcsc-ld as the linker script/config\n"
      "  -Map FILE            Name the linker map (default: OUTPUT stem + .map)\n"
      "  -Sym FILE            Name the Stella symbol file (default: .sym)\n"
      "  -List FILE           Name the Stella list file (default: .lst)\n"
      "  -Cfg FILE            Name the Stella/DiStella config file (default: .cfg)\n"
      "  --no-map             Do not write the default linker map\n"
      "  --no-sym             Do not write the default Stella symbol file\n"
      "  --no-list            Do not write the default Stella list file\n"
      "  --no-cfg             Do not write the default Stella config file\n"
      "  -v                   Print subordinate commands to stderr before running them\n"
      "  -###                 Print subordinate commands to stdout but do not run them\n"
      "  -Wc,ARG,...          Pass comma-split args to vcsc-cc1\n"
      "  -Wa,ARG,...          Pass comma-split args to vcsc-as\n"
      "  -Wl,ARG,...          Pass comma-split args to vcsc-ld\n"
      "  -Xcompiler ARG       Pass one extra arg to vcsc-cc1\n"
      "  -Xassembler ARG      Pass one extra arg to vcsc-as\n"
      "  -Xlinker ARG         Pass one extra arg to vcsc-ld\n"
      "  -print-prog-name=TOOL  Print path to cc1/as/ld/ar/sim and exit\n"
      "  -h, --help           Show this help\n"
      "  -V                   Show driver and companion tool versions\n"
      "\n"
      "Notes:\n"
      "  * default linked output is a.hex\n"
      "  * -S accepts only .c26 inputs\n"
      "  * with -c or -S, using -o requires exactly one source input\n"
      "  * with -S, -o - writes generated assembly to stdout\n"
      "  * object and linked outputs require a filename; -o - is rejected\n"
      "  * default linking uses the bundled VCS 4K C26 profile and adds libvcsc.l26\n",
      arg0);
}

//! @brief Add split commas to driver pipeline state, growing storage or preserving uniqueness as needed.
static void append_split_commas(strvec_t *v, const char *spec)
{
   char *copy = xstrdup(spec);
   char *p = copy;
   while (*p) {
      char *comma = strchr(p, ',');
      if (comma)
         *comma = '\0';
      if (*p)
         strvec_push(v, p);
      if (!comma)
         break;
      p = comma + 1;
   }
   free(copy);
}

//! @brief Handle get self path logic for driver pipeline.
static void get_self_path(char *out, size_t out_sz, const char *argv0)
{
#ifdef _WIN32
   DWORD n;

   (void)argv0;
   if (out_sz > (size_t)UINT32_MAX)
      die("executable path buffer too large");
   n = GetModuleFileNameA(NULL, out, (DWORD)out_sz);
   if (n == 0 || (size_t)n >= out_sz)
      die("GetModuleFileName failed");
#else
   ssize_t n;
   char resolved[PATH_MAX];

   if (strchr(argv0, '/')) {
      if (realpath(argv0, resolved)) {
         copy_cstr(out, out_sz, resolved);
         return;
      }
      if (argv0[0] == '/') {
         copy_cstr(out, out_sz, argv0);
         return;
      }
      if (!getcwd(out, out_sz))
         die("getcwd failed: %s", strerror(errno));
      if (strlen(out) + 1 + strlen(argv0) + 1 > out_sz)
         die("path too long");
      strcat(out, "/");
      strcat(out, argv0);
      return;
   }
   n = readlink("/proc/self/exe", out, out_sz - 1);
   if (n >= 0) {
      out[n] = '\0';
      return;
   }
   copy_cstr(out, out_sz, argv0);
#endif
}

//! @brief Add the host executable suffix used by installed companion tools.
static void make_tool_filename(char *out, size_t out_sz, const char *tool)
{
#ifdef _WIN32
   int n = snprintf(out, out_sz, "%s.exe", tool);
   if (n < 0 || (size_t)n >= out_sz)
      die("tool filename too long");
#else
   copy_cstr(out, out_sz, tool);
#endif
}

//! @brief Handle build repo tree path logic for driver pipeline.
static void build_repo_tree_path(char *out, size_t out_sz, const char *self_path, const char *subdir, const char *tool)
{
   char self_dir[PATH_MAX];
   char repo_dir[PATH_MAX];
   char filename[PATH_MAX];
   path_dirname(self_path, self_dir, sizeof(self_dir));
   path_dirname(self_dir, repo_dir, sizeof(repo_dir));
   make_tool_filename(filename, sizeof(filename), tool);
   join_path3(out, out_sz, repo_dir, subdir, filename);
}

//! @brief Handle build installed tool path logic for driver pipeline.
static void build_installed_tool_path(char *out, size_t out_sz, const char *self_path, const char *tool)
{
   char self_dir[PATH_MAX];
   char filename[PATH_MAX];
   path_dirname(self_path, self_dir, sizeof(self_dir));
   make_tool_filename(filename, sizeof(filename), tool);
   join_path2(out, out_sz, self_dir, filename);
}

//! @brief Handle build installed prefix path logic for driver pipeline.
static void build_installed_prefix_path(char *out, size_t out_sz, const char *self_path, const char *subdir, const char *name)
{
   char self_dir[PATH_MAX];
   char prefix_dir[PATH_MAX];
   path_dirname(self_path, self_dir, sizeof(self_dir));
   path_dirname(self_dir, prefix_dir, sizeof(prefix_dir));
   join_path3(out, out_sz, prefix_dir, subdir, name);
}

//! @brief Compute tool paths and update driver pipeline state once prerequisite pass data is available.
static void resolve_tool_paths(const char *self_path,
   char *cc_path, size_t cc_sz,
   char *as_path, size_t as_sz,
   char *ld_path, size_t ld_sz,
   char *ar_path, size_t ar_sz,
   char *sim_path, size_t sim_sz,
   char *runtime_path, size_t runtime_sz,
   char *runtime_inc, size_t runtime_inc_sz,
   char *vcs_profile_path, size_t vcs_profile_sz)
{
   char cc_repo[PATH_MAX];
   char as_repo[PATH_MAX];
   char ld_repo[PATH_MAX];
   char ar_repo[PATH_MAX];
   char sim_repo[PATH_MAX];
   char runtime_repo[PATH_MAX];
   char runtime_inc_repo[PATH_MAX];
   char vcs_profile_repo[PATH_MAX];
   char cc_inst[PATH_MAX];
   char as_inst[PATH_MAX];
   char ld_inst[PATH_MAX];
   char ar_inst[PATH_MAX];
   char sim_inst[PATH_MAX];
   char runtime_inst[PATH_MAX];
   char runtime_inc_inst[PATH_MAX];
   char vcs_profile_inst[PATH_MAX];

   build_repo_tree_path(cc_repo, sizeof(cc_repo), self_path, "compiler", "vcsc-cc1");
   build_repo_tree_path(as_repo, sizeof(as_repo), self_path, "assembler", "vcsc-as");
   build_repo_tree_path(ld_repo, sizeof(ld_repo), self_path, "linker", "vcsc-ld");
   build_repo_tree_path(ar_repo, sizeof(ar_repo), self_path, "archiver", "vcsc-ar");
   build_repo_tree_path(sim_repo, sizeof(sim_repo), self_path, "simulator", "vcsc-sim");
   build_repo_tree_path(runtime_repo, sizeof(runtime_repo), self_path, "libraries/runtime", "libvcsc.l26");
   build_repo_tree_path(runtime_inc_repo, sizeof(runtime_inc_repo), self_path, "libraries/runtime", "vcsc-runtime.inc");
   build_repo_tree_path(vcs_profile_repo, sizeof(vcs_profile_repo), self_path, "libraries/vcs", "4K/mapper.c26");

   if (path_is_accessible(cc_repo, X_OK) &&
       path_is_accessible(as_repo, X_OK) &&
       path_is_accessible(ld_repo, X_OK) &&
       path_is_accessible(ar_repo, X_OK) &&
       path_is_accessible(sim_repo, X_OK) &&
       path_is_accessible(runtime_repo, R_OK) &&
       path_is_accessible(runtime_inc_repo, R_OK)) {
      copy_cstr(cc_path, cc_sz, cc_repo);
      copy_cstr(as_path, as_sz, as_repo);
      copy_cstr(ld_path, ld_sz, ld_repo);
      copy_cstr(ar_path, ar_sz, ar_repo);
      copy_cstr(sim_path, sim_sz, sim_repo);
      copy_cstr(runtime_path, runtime_sz, runtime_repo);
      path_dirname(runtime_inc_repo, runtime_inc, runtime_inc_sz);
      copy_cstr(vcs_profile_path, vcs_profile_sz, vcs_profile_repo);
      return;
   }

   build_installed_tool_path(cc_inst, sizeof(cc_inst), self_path, "vcsc-cc1");
   build_installed_tool_path(as_inst, sizeof(as_inst), self_path, "vcsc-as");
   build_installed_tool_path(ld_inst, sizeof(ld_inst), self_path, "vcsc-ld");
   build_installed_tool_path(ar_inst, sizeof(ar_inst), self_path, "vcsc-ar");
   build_installed_tool_path(sim_inst, sizeof(sim_inst), self_path, "vcsc-sim");
   build_installed_prefix_path(runtime_inst, sizeof(runtime_inst), self_path, "lib", "libvcsc.l26");
   build_installed_prefix_path(runtime_inc_inst, sizeof(runtime_inc_inst), self_path, "include", "vcsc-runtime.inc");
   build_installed_prefix_path(vcs_profile_inst, sizeof(vcs_profile_inst), self_path, "share/vcs", "4K/mapper.c26");

   if (path_is_accessible(cc_inst, X_OK) &&
       path_is_accessible(as_inst, X_OK) &&
       path_is_accessible(ld_inst, X_OK) &&
       path_is_accessible(ar_inst, X_OK) &&
       path_is_accessible(sim_inst, X_OK) &&
       path_is_accessible(runtime_inst, R_OK) &&
       path_is_accessible(runtime_inc_inst, R_OK)) {
      copy_cstr(cc_path, cc_sz, cc_inst);
      copy_cstr(as_path, as_sz, as_inst);
      copy_cstr(ld_path, ld_sz, ld_inst);
      copy_cstr(ar_path, ar_sz, ar_inst);
      copy_cstr(sim_path, sim_sz, sim_inst);
      copy_cstr(runtime_path, runtime_sz, runtime_inst);
      path_dirname(runtime_inc_inst, runtime_inc, runtime_inc_sz);
      copy_cstr(vcs_profile_path, vcs_profile_sz, vcs_profile_inst);
      return;
   }

   die("could not locate companion tools/runtime next to %s or in the source tree", self_path);
}

//! @brief Handle temp store init logic for driver pipeline.
static void temp_store_init(temp_store_t *ts)
{
   memset(ts, 0, sizeof(*ts));
}

//! @brief Handle temp store make dir logic for driver pipeline.
static void temp_store_make_dir(temp_store_t *ts)
{
   if (ts->made_tempdir)
      return;

#ifdef _WIN32
   {
      char root[PATH_MAX];
      DWORD root_len;
      DWORD pid = GetCurrentProcessId();
      unsigned long attempt;

      root_len = GetTempPathA((DWORD)sizeof(root), root);
      if (root_len == 0 || root_len >= sizeof(root))
         die("could not determine Windows temporary directory");

      for (attempt = 0; attempt < 10000; ++attempt) {
         int n = snprintf(ts->tempdir, sizeof(ts->tempdir), "%svcsc.%lu.%lu",
            root,
            (unsigned long)pid,
            attempt);
         if (n < 0 || (size_t)n >= sizeof(ts->tempdir))
            die("temporary directory path too long");
         if (CreateDirectoryA(ts->tempdir, NULL)) {
            ts->made_tempdir = true;
            return;
         }
         if (GetLastError() != ERROR_ALREADY_EXISTS)
            die("could not create temporary directory %s", ts->tempdir);
      }
      die("could not allocate a unique Windows temporary directory");
   }
#else
   {
      const char *root;
      size_t root_len;
      int n;

   root = getenv("TMPDIR");
   if (!root || !*root)
      root = "/tmp";
   root_len = strlen(root);
   n = snprintf(ts->tempdir, sizeof(ts->tempdir), "%s%svcsc.XXXXXX",
      root, root_len && root[root_len - 1] == '/' ? "" : "/");
   if (n < 0 || (size_t)n >= sizeof(ts->tempdir))
      die("temporary directory path too long");
   if (!mkdtemp(ts->tempdir))
      die("mkdtemp failed for %s: %s", ts->tempdir, strerror(errno));
   ts->made_tempdir = true;
   }
#endif
}

//! @brief Handle temp store add logic for driver pipeline.
static void temp_store_add(temp_store_t *ts, const char *path, bool keep)
{
   if (ts->count == ts->cap) {
      ts->cap = ts->cap ? ts->cap * 2 : 8;
      ts->items = xrealloc(ts->items, ts->cap * sizeof(ts->items[0]));
   }
   ts->items[ts->count].path = xstrdup(path);
   ts->items[ts->count].keep = keep;
   ts->count++;
}

//! @brief Create a temporary file and return a path stable until temp-store cleanup.
static const char *temp_store_make_file(temp_store_t *ts, const char *stem, const char *suffix)
{
   static unsigned long counter;
   char path[PATH_MAX];
   int fd;

   temp_store_make_dir(ts);
   for (;;) {
      char serial[32];
      size_t dir_len = strlen(ts->tempdir);
      size_t stem_len = strlen(stem);
      size_t suffix_len = strlen(suffix);
      int n = snprintf(serial, sizeof(serial), "%06lu", counter++);
      size_t serial_len;

      if (n < 0 || (size_t)n >= sizeof(serial))
         die("temporary filename serial formatting failed");
      serial_len = (size_t)n;
      if (dir_len + 1 + stem_len + 1 + serial_len + suffix_len + 1 > sizeof(path))
         die("temporary path too long");

      memcpy(path, ts->tempdir, dir_len);
      path[dir_len] = '/';
      memcpy(path + dir_len + 1, stem, stem_len);
      path[dir_len + 1 + stem_len] = '.';
      memcpy(path + dir_len + 1 + stem_len + 1, serial, serial_len);
      memcpy(path + dir_len + 1 + stem_len + 1 + serial_len, suffix, suffix_len + 1);

      fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
      if (fd >= 0)
         break;
      if (errno != EEXIST)
         die("temporary file create failed for %s: %s", path, strerror(errno));
   }
   close(fd);
   temp_store_add(ts, path, false);
   return ts->items[ts->count - 1].path;
}

//! @brief Handle temp store cleanup logic for driver pipeline.
static void temp_store_cleanup(temp_store_t *ts)
{
   size_t i;

   if (!ts)
      return;
   for (i = ts->count; i > 0; --i) {
      if (!ts->items[i - 1].keep)
         unlink(ts->items[i - 1].path);
      free(ts->items[i - 1].path);
   }
   if (ts->made_tempdir)
      rmdir(ts->tempdir);
   free(ts->items);
   ts->items = NULL;
   ts->count = 0;
   ts->cap = 0;
   ts->tempdir[0] = '\0';
   ts->made_tempdir = false;
}

//! @brief Remove driver intermediates when any normal exit path terminates the process.
static void temp_store_cleanup_at_exit(void)
{
   temp_store_cleanup(active_temp_store);
}

//! @brief Emit cmd for driver pipeline diagnostics or output files.
static void print_cmd(FILE *fp, char *const *argv)
{
   size_t i;
   for (i = 0; argv[i]; ++i) {
      if (i)
         fputc(' ', fp);
      fputs(argv[i], fp);
   }
   fputc('\n', fp);
}

//! @brief Run the argument vector stage of the driver tool pipeline.
static int run_argv(char *const *argv, bool verbose, bool dry_run)
{
#ifdef _WIN32
   intptr_t status;
#else
   pid_t pid;
   int status;
#endif

   if (dry_run)
      print_cmd(stdout, argv);
   else if (verbose)
      print_cmd(stderr, argv);
   if (dry_run)
      return 0;

#ifdef _WIN32
   status = _spawnv(_P_WAIT, argv[0], (const char * const *)argv);
   if (status < 0)
      die("spawn failed for %s: %s", argv[0], strerror(errno));
   return (int)status;
#else
   pid = fork();
   if (pid < 0)
      die("fork failed: %s", strerror(errno));
   if (pid == 0) {
      execv(argv[0], argv);
      fprintf(stderr, "%s: exec failed for %s: %s\n", arg0, argv[0], strerror(errno));
      _exit(127);
   }
   if (waitpid(pid, &status, 0) < 0)
      die("waitpid failed: %s", strerror(errno));

   if (WIFEXITED(status))
      return WEXITSTATUS(status);
   if (WIFSIGNALED(status))
      return 128 + WTERMSIG(status);
   return 1;
#endif
}

//! @brief Report one companion tool version by invoking the tool with -V.
static int print_companion_version(const char *name, const char *path, size_t size)
{
   char *const argv[] = { (char *)path, "-V", NULL };

   printf("%-8s : %-*s : ", name, (int)size, path);
   fflush(stdout);
   return run_argv(argv, false, false);
}

//! @brief Report driver and companion tool versions.
static int print_all_versions(const char *self_path, const char *cc_path, const char *as_path, const char *ld_path,
   const char *ar_path, const char *sim_path)
{
   int rc = 0;
   size_t size = strlen(self_path);
   size_t tmp;

   tmp = strlen(cc_path);
   if (tmp > size) { size = tmp; }
   tmp = strlen(as_path);
   if (tmp > size) { size = tmp; }
   tmp = strlen(ld_path);
   if (tmp > size) { size = tmp; }
   tmp = strlen(ar_path);
   if (tmp > size) { size = tmp; }
   tmp = strlen(sim_path);
   if (tmp > size) { size = tmp; }

   printf("%-8s : %-*s : %s\n", "vcsc", (int)size, self_path, VERSION);
   rc |= print_companion_version("vcsc-cc1", cc_path, size);
   rc |= print_companion_version("vcsc-as", as_path, size);
   rc |= print_companion_version("vcsc-ld", ld_path, size);
   rc |= print_companion_version("vcsc-ar", ar_path, size);
   rc |= print_companion_version("vcsc-sim", sim_path, size);
   return rc;
}

//! @brief Extract argument vector from vec for driver pipeline.
static void argv_from_vec(strvec_t *src, char ***outv)
{
   size_t i;
   char **argv = xmalloc((src->count + 1) * sizeof(argv[0]));
   for (i = 0; i < src->count; ++i)
      argv[i] = src->items[i];
   argv[src->count] = NULL;
   *outv = argv;
}

//! @brief Run the vec or die stage of the driver tool pipeline.
static void run_vec_or_die(strvec_t *cmd, bool verbose, bool dry_run)
{
   char **argv;
   int rc;
   argv_from_vec(cmd, &argv);
   rc = run_argv(argv, verbose, dry_run);
   free(argv);
   if (rc != 0)
      exit(rc ? rc : 1);
}

//! @brief Parse args into the normalized representation used by driver pipeline.
static void parse_args(int argc, char **argv, driver_options_t *opt,
   const char *cc_path, const char *as_path, const char *ld_path,
   const char *ar_path, const char *sim_path)
{
   int i;
   memset(opt, 0, sizeof(*opt));

   for (i = 1; i < argc; ++i) {
      const char *arg = argv[i];

      if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
         usage(stdout);
         exit(0);
      }
      if (strcmp(arg, "-c") == 0) {
         opt->compile_only = true;
         continue;
      }
      if (strcmp(arg, "-S") == 0) {
         opt->asm_only = true;
         continue;
      }
      if (strcmp(arg, "-v") == 0) {
         opt->verbose = true;
         continue;
      }
      if (strcmp(arg, "-###") == 0) {
         opt->dry_run = true;
         continue;
      }
      if (strcmp(arg, "-nostdlib") == 0) {
         opt->nostdlib = true;
         continue;
      }
      if (strcmp(arg, "-pipe") == 0) {
         continue;
      }
      if (strcmp(arg, "-o") == 0) {
         if (++i >= argc)
            die("missing argument for -o");
         opt->output = argv[i];
         continue;
      }
      if (strncmp(arg, "-o", 2) == 0 && arg[2] != '\0') {
         opt->output = arg + 2;
         continue;
      }
      if (strcmp(arg, "-I") == 0) {
         if (++i >= argc)
            die("missing argument for -I");
         strvec_push(&opt->include_dirs, argv[i]);
         continue;
      }
      if (strncmp(arg, "-I", 2) == 0 && arg[2] != '\0') {
         strvec_push(&opt->include_dirs, arg + 2);
         continue;
      }
      if (strcmp(arg, "-D") == 0) {
         if (++i >= argc)
            die("missing argument for -D");
         strvec_push(&opt->defines, argv[i]);
         continue;
      }
      if (strncmp(arg, "-D", 2) == 0 && arg[2] != '\0') {
         strvec_push(&opt->defines, arg + 2);
         continue;
      }
      if (strcmp(arg, "-L") == 0) {
         if (++i >= argc)
            die("missing argument for -L");
         strvec_push(&opt->lib_dirs, argv[i]);
         continue;
      }
      if (strncmp(arg, "-L", 2) == 0 && arg[2] != '\0') {
         strvec_push(&opt->lib_dirs, arg + 2);
         continue;
      }
      if (strncmp(arg, "-l", 2) == 0 && arg[2] != '\0') {
         strvec_push(&opt->libs, arg + 2);
         continue;
      }
      if (strcmp(arg, "-T") == 0) {
         if (++i >= argc)
            die("missing argument for -T");
         opt->link_script = argv[i];
         continue;
      }
      if (strncmp(arg, "-T", 2) == 0 && arg[2] != '\0') {
         opt->link_script = arg + 2;
         continue;
      }
      if (strcmp(arg, "-Map") == 0) {
         if (++i >= argc)
            die("missing argument for -Map");
         opt->map_path = argv[i];
         opt->no_map = false;
         continue;
      }
      if (strncmp(arg, "-Map=", 5) == 0) {
         opt->map_path = arg + 5;
         opt->no_map = false;
         continue;
      }
      if (strcmp(arg, "--map") == 0 || strcmp(arg, "-Sym") == 0 ||
          strcmp(arg, "--sym") == 0 || strcmp(arg, "-List") == 0 ||
          strcmp(arg, "--list") == 0 || strcmp(arg, "-Cfg") == 0 ||
          strcmp(arg, "--cfg") == 0) {
         const char *option = arg;
         const char *value;
         if (++i >= argc)
            die("missing argument for %s", option);
         value = argv[i];
         if (strcmp(option, "--map") == 0) {
            opt->map_path = value;
            opt->no_map = false;
         }
         else if (strcmp(option, "-Sym") == 0 || strcmp(option, "--sym") == 0) {
            opt->sym_path = value;
            opt->no_sym = false;
         }
         else if (strcmp(option, "-List") == 0 || strcmp(option, "--list") == 0) {
            opt->list_path = value;
            opt->no_list = false;
         }
         else {
            opt->cfg_path = value;
            opt->no_cfg = false;
         }
         continue;
      }
      if (strncmp(arg, "--map=", 6) == 0) {
         opt->map_path = arg + 6;
         opt->no_map = false;
         continue;
      }
      if (strncmp(arg, "-Sym=", 5) == 0 || strncmp(arg, "--sym=", 6) == 0) {
         opt->sym_path = arg + (arg[1] == '-' ? 6 : 5);
         opt->no_sym = false;
         continue;
      }
      if (strncmp(arg, "-List=", 6) == 0 || strncmp(arg, "--list=", 7) == 0) {
         opt->list_path = arg + (arg[1] == '-' ? 7 : 6);
         opt->no_list = false;
         continue;
      }
      if (strncmp(arg, "-Cfg=", 5) == 0 || strncmp(arg, "--cfg=", 6) == 0) {
         opt->cfg_path = arg + (arg[1] == '-' ? 6 : 5);
         opt->no_cfg = false;
         continue;
      }
      if (strcmp(arg, "--no-map") == 0) {
         opt->map_path = NULL;
         opt->no_map = true;
         continue;
      }
      if (strcmp(arg, "--no-sym") == 0) {
         opt->sym_path = NULL;
         opt->no_sym = true;
         continue;
      }
      if (strcmp(arg, "--no-list") == 0) {
         opt->list_path = NULL;
         opt->no_list = true;
         continue;
      }
      if (strcmp(arg, "--no-cfg") == 0) {
         opt->cfg_path = NULL;
         opt->no_cfg = true;
         continue;
      }
      if (strcmp(arg, "-fpeephole") == 0 || strcmp(arg, "-fno-peephole") == 0) {
         strvec_push(&opt->cc_extra, arg);
         continue;
      }
      if (strcmp(arg, "-finline-profit") == 0) {
         opt->inline_profit = true;
         continue;
      }
      if (strncmp(arg, "-Wc,", 4) == 0) {
         append_split_commas(&opt->cc_extra, arg + 4);
         continue;
      }
      if (strncmp(arg, "-Wa,", 4) == 0) {
         append_split_commas(&opt->as_extra, arg + 4);
         continue;
      }
      if (strncmp(arg, "-Wl,", 4) == 0) {
         append_split_commas(&opt->ld_extra, arg + 4);
         continue;
      }
      if (strcmp(arg, "-Xcompiler") == 0) {
         if (++i >= argc)
            die("missing argument for -Xcompiler");
         strvec_push(&opt->cc_extra, argv[i]);
         continue;
      }
      if (strcmp(arg, "-Xassembler") == 0) {
         if (++i >= argc)
            die("missing argument for -Xassembler");
         strvec_push(&opt->as_extra, argv[i]);
         continue;
      }
      if (strcmp(arg, "-Xlinker") == 0) {
         if (++i >= argc)
            die("missing argument for -Xlinker");
         strvec_push(&opt->ld_extra, argv[i]);
         continue;
      }
      if (strncmp(arg, "-print-prog-name=", 17) == 0) {
         const char *name = arg + 17;
         if (strcmp(name, "cc1") == 0)
            puts(cc_path);
         else if (strcmp(name, "as") == 0)
            puts(as_path);
         else if (strcmp(name, "ld") == 0)
            puts(ld_path);
         else if (strcmp(name, "ar") == 0)
            puts(ar_path);
         else if (strcmp(name, "sim") == 0)
            puts(sim_path);
         else
            die("unknown -print-prog-name target '%s'", name);
         exit(0);
      }
      if (arg[0] == '-' && arg[1] != '\0')
         unsupported_option(arg);

      inputvec_push(&opt->inputs, arg, classify_input(arg));
   }

   if (opt->compile_only && opt->asm_only)
      die("cannot combine -c and -S");
   if (opt->inputs.count == 0)
      die("no input files");
   if ((opt->compile_only || opt->asm_only) && opt->output && opt->inputs.count != 1)
      die("-o with -c or -S requires exactly one input file");
   if (opt->output && strcmp(opt->output, "-") == 0 && !opt->asm_only)
      die("-o - is supported only with -S; object and linked outputs require a filename");
}


//! @brief Return whether -D defines will be consumed by a compile or assemble stage.
static bool defines_have_consumer(const driver_options_t *opt)
{
   size_t i;

   if (opt->defines.count == 0)
      return true;

   for (i = 0; i < opt->inputs.count; ++i) {
      input_kind_t kind = opt->inputs.items[i].kind;

      if (opt->asm_only) {
         if (kind == INPUT_VCSC)
            return true;
         continue;
      }

      if (opt->compile_only) {
         if (kind == INPUT_VCSC || kind == INPUT_ASM)
            return true;
         continue;
      }

      if (kind == INPUT_VCSC || kind == INPUT_ASM)
         return true;
   }

   return false;
}

//! @brief Add include flags to driver pipeline state, growing storage or preserving uniqueness as needed.
static void add_include_flags(strvec_t *cmd, const strvec_t *dirs)
{
   size_t i;
   for (i = 0; i < dirs->count; ++i) {
      strvec_push(cmd, "-I");
      strvec_push(cmd, dirs->items[i]);
   }
}

//! @brief Add command-line definition flags to a compiler or assembler command.
static void add_define_flags(strvec_t *cmd, const strvec_t *defs)
{
   size_t i;

   for (i = 0; i < defs->count; ++i) {
      strvec_push(cmd, "-D");
      strvec_push(cmd, defs->items[i]);
   }
}

//! @brief Return derive output path data used by driver pipeline; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *derive_output_path(const input_t *in, const char *suffix, const char *override, char *buf, size_t buf_sz)
{
   if (override)
      return override;
   make_suffixed_path(in->path, suffix, buf, buf_sz);
   return buf;
}

//! @brief Run one compiler stage with optional optimizer-inline trial controls.
static void run_cc_variant(const char *cc_path, const driver_options_t *opt,
   const char *runtime_inc, const char *input, const char *output,
   const strvec_t *inline_selected, const char *candidate_manifest,
   bool prune_dead)
{
   strvec_t cmd = {0};
   const char *dot = path_extension(input);
   char input_dir[PATH_MAX];

   path_dirname(input, input_dir, sizeof(input_dir));
   strvec_push(&cmd, cc_path);
   strvec_push(&cmd, "-quiet");
   if (!opt->asm_only)
      strvec_push(&cmd, "-flisting-provenance");
   strvec_push(&cmd, "-I");
   strvec_push(&cmd, input_dir);
   add_include_flags(&cmd, &opt->include_dirs);
   strvec_push(&cmd, "-I");
   strvec_push(&cmd, runtime_inc);
   add_define_flags(&cmd, &opt->defines);
   strvec_push(&cmd, input);
   strvec_push(&cmd, "-o");
   strvec_push(&cmd, output);
   strvec_push(&cmd, "-dumpbase");
   strvec_push(&cmd, path_basename(input));
   strvec_push(&cmd, "-dumpbase-ext");
   strvec_push(&cmd, *dot ? dot : ".c26");
   strvec_push(&cmd, "-dumpdir");
   strvec_push(&cmd, "./");
   if (prune_dead) {
      strvec_push(&cmd, "-finline-prune-dead");
   }
   if (candidate_manifest) {
      strvec_push(&cmd, "-finline-candidates");
      strvec_push(&cmd, candidate_manifest);
   }
   if (inline_selected) {
      for (size_t i = 0; i < inline_selected->count; ++i) {
         strvec_push(&cmd, "-finline-select");
         strvec_push(&cmd, inline_selected->items[i]);
      }
   }
   for (size_t i = 0; i < opt->cc_extra.count; ++i)
      strvec_push(&cmd, opt->cc_extra.items[i]);

   run_vec_or_die(&cmd, opt->verbose, opt->dry_run);
}

//! @brief Run the ordinary cc stage of the driver tool pipeline.
static void run_cc(const char *cc_path, const driver_options_t *opt, const char *runtime_inc, const char *input, const char *output)
{
   run_cc_variant(cc_path, opt, runtime_inc, input, output, NULL, NULL, false);
}

//! @brief Run the as stage of the driver tool pipeline.
static void run_as(const char *as_path, const driver_options_t *opt, const char *runtime_inc, const char *input, const char *output)
{
   strvec_t cmd = {0};
   strvec_push(&cmd, as_path);
   strvec_push(&cmd, "-I");
   strvec_push(&cmd, runtime_inc);
   add_include_flags(&cmd, &opt->include_dirs);
   add_define_flags(&cmd, &opt->defines);
   strvec_push(&cmd, "-o");
   strvec_push(&cmd, output);
   for (size_t i = 0; i < opt->as_extra.count; ++i)
      strvec_push(&cmd, opt->as_extra.items[i]);
   strvec_push(&cmd, input);
   run_vec_or_die(&cmd, opt->verbose, opt->dry_run);
}


//! @brief Find library in driver pipeline tables without transferring ownership.
static const char *find_library(const driver_options_t *opt, const char *name, char *buf, size_t buf_sz)
{
   size_t i;
   for (i = 0; i < opt->lib_dirs.count; ++i) {
      snprintf(buf, buf_sz, "%s/lib%s.l26", opt->lib_dirs.items[i], name);
      if (access(buf, R_OK) == 0)
         return buf;
      snprintf(buf, buf_sz, "%s/%s.l26", opt->lib_dirs.items[i], name);
      if (access(buf, R_OK) == 0)
         return buf;
   }
   die("could not find library for -l%s", name);
   return NULL;
}

//! @brief Return whether a binary/text input contains one metadata marker.
static bool file_contains_literal(const char *path, const char *needle)
{
   FILE *fp;
   size_t needle_len;
   size_t matched = 0;
   int ch;

   if (!path || !needle || !*needle)
      return false;
   fp = fopen(path, "rb");
   if (!fp)
      return false;
   needle_len = strlen(needle);
   while ((ch = fgetc(fp)) != EOF) {
      if ((unsigned char)ch == (unsigned char)needle[matched]) {
         matched++;
         if (matched == needle_len) {
            fclose(fp);
            return true;
         }
      }
      else {
         matched = ((unsigned char)ch == (unsigned char)needle[0]) ? 1u : 0u;
      }
   }
   fclose(fp);
   return false;
}

//! @brief Return whether command-line objects/archives already provide cartridge topology.
static bool link_inputs_contain_literal(const strvec_t *inputs, const char *needle)
{
   size_t i;
   for (i = 0; inputs && i < inputs->count; ++i)
      if (file_contains_literal(inputs->items[i], needle))
         return true;
   return false;
}

//! @brief Return whether command-line objects/archives already provide cartridge topology.
static bool link_inputs_have_cartridge_topology(const strvec_t *inputs)
{
   return link_inputs_contain_literal(inputs, "__cartmeta$");
}

//! @brief Return whether the selected C26 topology identifies Tigervision 3E.
static bool link_inputs_have_3e_topology(const strvec_t *inputs)
{
   /* __cartmeta V2 stores the four-byte signature as hex after $G.  "3E\0\0"
      is 33 45 00 00. Keep this driver-side test deliberately narrow: 3EX is a
      distinct mapper and must not silently receive 3E's 1K swap-RAM helper. */
   return link_inputs_contain_literal(inputs, "$G33450000$");
}

//! @brief Return whether generated code references one of the swapram mover entry points.
static bool link_inputs_need_swapram_helpers(const strvec_t *inputs)
{
   return link_inputs_contain_literal(inputs, "swapram_read") ||
          link_inputs_contain_literal(inputs, "swapram_write");
}

//! @brief Run the ld stage of the driver tool pipeline.
static void run_ld(const char *ld_path, const driver_options_t *opt,
   const strvec_t *link_inputs, const char *default_runtime)
{
   strvec_t cmd = {0};
   const char *link_script = opt->link_script;
   size_t i;

   strvec_push(&cmd, ld_path);
   strvec_push(&cmd, "-o");
   strvec_push(&cmd, opt->output ? opt->output : "a.hex");
   if (link_script) {
      strvec_push(&cmd, "-T");
      strvec_push(&cmd, link_script);
   }
   if (opt->no_map)
      strvec_push(&cmd, "--no-map");
   else if (opt->map_path) {
      strvec_push(&cmd, "-Map");
      strvec_push(&cmd, opt->map_path);
   }
   if (opt->no_sym)
      strvec_push(&cmd, "--no-sym");
   else if (opt->sym_path) {
      strvec_push(&cmd, "-Sym");
      strvec_push(&cmd, opt->sym_path);
   }
   if (opt->no_list)
      strvec_push(&cmd, "--no-list");
   else if (opt->list_path) {
      strvec_push(&cmd, "-List");
      strvec_push(&cmd, opt->list_path);
   }
   if (opt->no_cfg)
      strvec_push(&cmd, "--no-cfg");
   else if (opt->cfg_path) {
      strvec_push(&cmd, "-Cfg");
      strvec_push(&cmd, opt->cfg_path);
   }
   for (i = 0; i < opt->ld_extra.count; ++i)
      strvec_push(&cmd, opt->ld_extra.items[i]);
   for (i = 0; i < link_inputs->count; ++i)
      strvec_push(&cmd, link_inputs->items[i]);
   for (i = 0; i < opt->libs.count; ++i) {
      char libbuf[PATH_MAX];
      strvec_push(&cmd, find_library(opt, opt->libs.items[i], libbuf, sizeof(libbuf)));
   }
   if (!opt->nostdlib) {
      strvec_push(&cmd, default_runtime);
   }
   run_vec_or_die(&cmd, opt->verbose, opt->dry_run);
}

//! @brief Run one silent speculative link and return its status instead of exiting.
static int run_trial_ld(const char *ld_path, const driver_options_t *opt,
   const strvec_t *link_inputs, const char *default_runtime,
   const char *output, const char *map)
{
   strvec_t cmd = {0};
   const char *link_script = opt->link_script;
   char **argv;
   int rc;
   size_t i;

   strvec_push(&cmd, ld_path);
   strvec_push(&cmd, "--trial");
   strvec_push(&cmd, "-o");
   strvec_push(&cmd, output);
   if (link_script) {
      strvec_push(&cmd, "-T");
      strvec_push(&cmd, link_script);
   }
   strvec_push(&cmd, "-Map");
   strvec_push(&cmd, map);
   strvec_push(&cmd, "--no-sym");
   strvec_push(&cmd, "--no-list");
   strvec_push(&cmd, "--no-cfg");
   for (i = 0; i < opt->ld_extra.count; ++i) strvec_push(&cmd, opt->ld_extra.items[i]);
   for (i = 0; i < link_inputs->count; ++i) strvec_push(&cmd, link_inputs->items[i]);
   for (i = 0; i < opt->libs.count; ++i) {
      char libbuf[PATH_MAX];
      strvec_push(&cmd, find_library(opt, opt->libs.items[i], libbuf, sizeof(libbuf)));
   }
   if (!opt->nostdlib) strvec_push(&cmd, default_runtime);
   argv_from_vec(&cmd, &argv);
   rc = run_argv(argv, false, false);
   free(argv);
   strvec_release(&cmd);
   return rc;
}

//! @brief Greedily accept only candidates which improve a real final link.
static void optimize_inline_profitability(const char *cc_path, const char *as_path,
   const char *ld_path, const driver_options_t *opt, const char *runtime_inc,
   const char *runtime_path,
   strvec_t *link_inputs, inline_tuvec_t *tus, temp_store_t *temps)
{
   inline_link_metrics_t current;
   char error[256];
   const char *base_hex;
   const char *base_map;
   bool changed;

   if (!opt->inline_profit || opt->dry_run || !tus || tus->count == 0) return;
   for (size_t ti = 0; ti < tus->count; ++ti) read_inline_candidate_manifest(&tus->items[ti]);

   base_hex = temp_store_make_file(temps, "inline_baseline", ".hex");
   base_map = temp_store_make_file(temps, "inline_baseline", ".map");
   if (run_trial_ld(ld_path, opt, link_inputs, runtime_path,
                    base_hex, base_map) != 0) {
      /* Let the ordinary final link produce the real user diagnostic. */
      return;
   }
   if (!inline_link_metrics_read_map(base_map, &current, error, sizeof(error)))
      die("could not read baseline inline-profit metrics: %s", error);

   do {
      changed = false;
      for (size_t ti = 0; ti < tus->count; ++ti) {
         inline_tu_t *tu = &tus->items[ti];
         for (size_t ci = 0; ci < tu->candidates.count; ++ci) {
            const char *candidate = tu->candidates.items[ci];
            strvec_t selected = {0};
            strvec_t trial_inputs = {0};
            inline_link_metrics_t trial;
            inline_profit_decision_t decision;
            char stem[PATH_MAX];
            const char *trial_s;
            const char *trial_o;
            const char *trial_hex;
            const char *trial_map;

            if (strvec_contains(&tu->selected, candidate)) continue;
            for (size_t i = 0; i < tu->selected.count; ++i) strvec_push(&selected, tu->selected.items[i]);
            strvec_push(&selected, candidate);
            path_stem(tu->source, stem, sizeof(stem));
            trial_s = temp_store_make_file(temps, stem, ".inline.s26");
            trial_o = temp_store_make_file(temps, stem, ".inline.o26");
            run_cc_variant(cc_path, opt, runtime_inc, tu->source, trial_s, &selected, NULL, true);
            run_as(as_path, opt, runtime_inc, trial_s, trial_o);
            strvec_clone_replace(&trial_inputs, link_inputs, tu->link_index, trial_o);
            trial_hex = temp_store_make_file(temps, "inline_trial", ".hex");
            trial_map = temp_store_make_file(temps, "inline_trial", ".map");
            if (run_trial_ld(ld_path, opt, &trial_inputs, runtime_path,
                             trial_hex, trial_map) != 0 ||
                !inline_link_metrics_read_map(trial_map, &trial, error, sizeof(error))) {
               strvec_release(&selected);
               strvec_release(&trial_inputs);
               continue;
            }
            decision = inline_profit_decide(&current, &trial);
            if (opt->verbose) {
               fprintf(stderr,
                  "%s: inline %s: %s rom=%" PRIu64 "->%" PRIu64
                  " ram-objects=%" PRIu64 "->%" PRIu64 " stack=%" PRIu64 "->%" PRIu64 "\n",
                  arg0, candidate,
                  decision == INLINE_PROFIT_ACCEPT_ROM ? "accept-rom" :
                  decision == INLINE_PROFIT_ACCEPT_STACK ? "accept-stack" :
                  decision == INLINE_PROFIT_REJECT_RAM_REGRESSION ? "reject-ram-regression" : "reject",
                  current.rom_bytes, trial.rom_bytes,
                  current.ram_object_bytes, trial.ram_object_bytes,
                  current.hardware_stack_bytes, trial.hardware_stack_bytes);
            }
            if (decision == INLINE_PROFIT_ACCEPT_ROM || decision == INLINE_PROFIT_ACCEPT_STACK) {
               free(link_inputs->items[tu->link_index]);
               link_inputs->items[tu->link_index] = xstrdup(trial_o);
               strvec_push(&tu->selected, candidate);
               current = trial;
               changed = true;
            }
            strvec_release(&selected);
            strvec_release(&trial_inputs);
         }
      }
   } while (changed);
}

//! @brief Entry point for the driver command; parses arguments, runs the requested pipeline, and returns process status.
int main(int argc, char **argv)
{
   driver_options_t opt;
   temp_store_t temps;
   char self_path[PATH_MAX];
   char cc_path[PATH_MAX];
   char as_path[PATH_MAX];
   char ld_path[PATH_MAX];
   char ar_path[PATH_MAX];
   char sim_path[PATH_MAX];
   char runtime_path[PATH_MAX];
   char runtime_inc[PATH_MAX];
   char vcs_profile_path[PATH_MAX];
   strvec_t link_inputs = {0};
   inline_tuvec_t inline_tus = {0};
   size_t i;

   arg0 = argv[0];
   temp_store_init(&temps);
   get_self_path(self_path, sizeof(self_path), argv[0]);
   resolve_tool_paths(self_path,
      cc_path, sizeof(cc_path),
      as_path, sizeof(as_path),
      ld_path, sizeof(ld_path),
      ar_path, sizeof(ar_path),
      sim_path, sizeof(sim_path),
      runtime_path, sizeof(runtime_path),
      runtime_inc, sizeof(runtime_inc),
      vcs_profile_path, sizeof(vcs_profile_path));

   if (argc == 2 && strcmp(argv[1], "-V") == 0)
      return print_all_versions(self_path, cc_path, as_path, ld_path, ar_path, sim_path);

   parse_args(argc, argv, &opt, cc_path, as_path, ld_path, ar_path, sim_path);

   if (!defines_have_consumer(&opt))
      die("-D supplied, but no compile or assemble stage will use it");

   active_temp_store = &temps;
   if (atexit(temp_store_cleanup_at_exit) != 0)
      die("could not register temporary-file cleanup");

   for (i = 0; i < opt.inputs.count; ++i) {
      const input_t *in = &opt.inputs.items[i];
      char derived[PATH_MAX];
      char stem[PATH_MAX];
      const char *asm_path;
      const char *obj_path;

      if (opt.asm_only) {
         if (in->kind != INPUT_VCSC)
            die("-S only accepts .c26 inputs, got '%s'", in->path);
         asm_path = derive_output_path(in, ".s26", opt.output, derived, sizeof(derived));
         run_cc(cc_path, &opt, runtime_inc, in->path, asm_path);
         continue;
      }

      if (opt.compile_only) {
         if (in->kind == INPUT_VCSC) {
            if (opt.output)
               obj_path = opt.output;
            else {
               make_suffixed_path(in->path, ".o26", derived, sizeof(derived));
               obj_path = derived;
            }
            path_stem(in->path, stem, sizeof(stem));
            asm_path = temp_store_make_file(&temps, stem, ".s26");
            run_cc(cc_path, &opt, runtime_inc, in->path, asm_path);
            run_as(as_path, &opt, runtime_inc, asm_path, obj_path);
            continue;
         }
         if (in->kind == INPUT_ASM) {
            obj_path = derive_output_path(in, ".o26", opt.output, derived, sizeof(derived));
            run_as(as_path, &opt, runtime_inc, in->path, obj_path);
            continue;
         }
         die("-c only accepts .c26 or assembler inputs, got '%s'", in->path);
      }

      switch (in->kind) {
         case INPUT_VCSC:
            path_stem(in->path, stem, sizeof(stem));
            asm_path = temp_store_make_file(&temps, stem, ".s26");
            obj_path = temp_store_make_file(&temps, stem, ".o26");
            if (opt.inline_profit) {
               const char *manifest = temp_store_make_file(&temps, stem, ".inline-candidates");
               const char *pruned_s;
               const char *pruned_o;
               /* First compile and assemble the complete translation unit so
                  unreachable-function pruning cannot hide source or assembler
                  diagnostics. Then build the dead-stripped baseline used by
                  profitability trials and the final optimized link. */
               run_cc_variant(cc_path, &opt, runtime_inc, in->path, asm_path, NULL, manifest, false);
               run_as(as_path, &opt, runtime_inc, asm_path, obj_path);
               pruned_s = temp_store_make_file(&temps, stem, ".dead.s26");
               pruned_o = temp_store_make_file(&temps, stem, ".dead.o26");
               run_cc_variant(cc_path, &opt, runtime_inc, in->path, pruned_s, NULL, NULL, true);
               run_as(as_path, &opt, runtime_inc, pruned_s, pruned_o);
               inline_tuvec_push(&inline_tus, in->path, link_inputs.count, manifest);
               strvec_push(&link_inputs, pruned_o);
               break;
            }
            run_cc(cc_path, &opt, runtime_inc, in->path, asm_path);
            run_as(as_path, &opt, runtime_inc, asm_path, obj_path);
            strvec_push(&link_inputs, obj_path);
            break;
         case INPUT_ASM:
            path_stem(in->path, stem, sizeof(stem));
            obj_path = temp_store_make_file(&temps, stem, ".o26");
            run_as(as_path, &opt, runtime_inc, in->path, obj_path);
            strvec_push(&link_inputs, obj_path);
            break;
         case INPUT_OBJ:
         case INPUT_ARC:
            strvec_push(&link_inputs, in->path);
            break;
      }
   }

   if (!opt.asm_only && !opt.compile_only) {
      if (!opt.link_script && !link_inputs_have_cartridge_topology(&link_inputs)) {
         const char *asm_path;
         const char *obj_path;
         if (!path_is_accessible(vcs_profile_path, R_OK))
            die("could not read default VCS cartridge profile '%s': %s",
                vcs_profile_path, strerror(errno));
         asm_path = temp_store_make_file(&temps, "vcs_4k_profile", ".s26");
         obj_path = temp_store_make_file(&temps, "vcs_4k_profile", ".o26");
         run_cc(cc_path, &opt, runtime_inc, vcs_profile_path, asm_path);
         run_as(as_path, &opt, runtime_inc, asm_path, obj_path);
         strvec_push(&link_inputs, obj_path);
      }
      if (link_inputs_have_3e_topology(&link_inputs) &&
          link_inputs_need_swapram_helpers(&link_inputs) &&
          !link_inputs_contain_literal(&link_inputs, "__vcsc_3e_swapram_provider")) {
         char vcs_4k_dir[PATH_MAX];
         char vcs_root[PATH_MAX];
         char helper_path[PATH_MAX];
         const char *helper_obj;
         path_dirname(vcs_profile_path, vcs_4k_dir, sizeof(vcs_4k_dir));
         path_dirname(vcs_4k_dir, vcs_root, sizeof(vcs_root));
         join_path3(helper_path, sizeof(helper_path), vcs_root, "3E", "swapram.s26");
         if (!path_is_accessible(helper_path, R_OK))
            die("3E swapram access requires mapper helper '%s'", helper_path);
         helper_obj = temp_store_make_file(&temps, "3e_swapram", ".o26");
         run_as(as_path, &opt, runtime_inc, helper_path, helper_obj);
         strvec_push(&link_inputs, helper_obj);
      }
      optimize_inline_profitability(cc_path, as_path, ld_path, &opt, runtime_inc,
         runtime_path, &link_inputs, &inline_tus, &temps);
      run_ld(ld_path, &opt, &link_inputs, runtime_path);
   }

   temp_store_cleanup(&temps);
   active_temp_store = NULL;
   return 0;
}
