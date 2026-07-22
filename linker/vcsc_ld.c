//! @file linker/vcsc_ld.c
//! @brief Implements linker command-line entry point for the VCSC linker.
//! @ingroup linker

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "vcsc_ld_internal.h"
#include "vcsc_ld_input.h"
#include "vcsc_ld_abi.h"
#include "version.h"

//! @brief Print the linker command-line usage text.
static void usage(FILE *fp)
{
   fprintf(fp,
      "Usage:\n"
      "  vcsc-ld [options] file...\n"
      "\n"
      "Options:\n"
      "  -o FILE              Write Intel HEX, or flat binary when FILE ends in .bin\n"
      "  -T FILE              Use required FILE as linker script/config\n"
      "  --script=FILE        Same as -T FILE\n"
      "  -Map FILE            Write linker map to FILE\n"
      "  -Map=FILE            Same as -Map FILE\n"
      "  -h, --help           Show this help text\n"
      "  -v, --version        Show linker version\n"
      "  -V                   Show generated version string\n"
      "\n"
      "Compatibility:\n"
      "  vcsc-ld [layout.cfg] input1.o26 [input2.o26 ... inputN.l26] output.hex [output.map]\n");
}

//! @brief Return whether a string ends with the requested suffix.
static int ends_with(const char *s, const char *suffix)
{
   size_t slen = strlen(s);
   size_t tlen = strlen(suffix);
   if (slen < tlen)
      return 0;
   return strcmp(s + slen - tlen, suffix) == 0;
}

//! @brief Handle str ieq logic for linker layout and image writer.
static int str_ieq(const char *a, const char *b)
{
   while (*a && *b) {
      int ca = toupper((unsigned char)*a++);
      int cb = toupper((unsigned char)*b++);
      if (ca != cb)
         return 0;
   }
   return *a == '\0' && *b == '\0';
}


//! @brief Duplicate a string for tool-owned storage, terminating with a diagnostic on failure.
char *xstrdup(const char *s)
{
   size_t n = strlen(s) + 1;
   char *p = (char *)malloc(n);
   if (!p) {
      fprintf(stderr, "vcsc-ld: out of memory\n");
      exit(1);
   }
   memcpy(p, s, n);
   return p;
}

//! @brief Return whether symbol backed metadata has prefix in linker layout and image writer.
static int symbol_backed_metadata_has_prefix(const char *name)
{
   return name && strncmp(name, SYMBOL_BACKED_META_PREFIX, sizeof(SYMBOL_BACKED_META_PREFIX) - 1) == 0;
}

//! @brief Return whether mem-region metadata has prefix in linker layout and image writer.
static int mem_region_metadata_has_prefix(const char *name)
{
   return name && strncmp(name, MEM_REGION_META_PREFIX, sizeof(MEM_REGION_META_PREFIX) - 1) == 0;
}

//! @brief Return whether reserved metadata has prefix in linker layout and image writer.
static int reserved_metadata_has_prefix(const char *name)
{
   return symbol_backed_metadata_has_prefix(name) || abi_metadata_has_prefix(name) || mem_region_metadata_has_prefix(name);
}

//! @brief Handle symbol backed metadata parse function logic for linker layout and image writer.
static int symbol_backed_metadata_parse_function(const char *name, const char **sym_out)
{
   const char *p;

   if (!symbol_backed_metadata_has_prefix(name))
      return 0;
   p = name + sizeof(SYMBOL_BACKED_META_PREFIX) - 1;
   if (strncmp(p, "F$", 2) != 0)
      return 0;
   p += 2;
   if (!*p)
      return 0;
   if (strchr(p, '$'))
      return 0;
   if (sym_out)
      *sym_out = p;
   return 1;
}

//! @brief Handle symbol backed metadata parse edge logic for linker layout and image writer.
static int symbol_backed_metadata_parse_edge(const char *name, char **caller_out, char **callee_out)
{
   const char *p;
   const char *sep;
   size_t caller_len;

   if (!symbol_backed_metadata_has_prefix(name))
      return 0;
   p = name + sizeof(SYMBOL_BACKED_META_PREFIX) - 1;
   if (strncmp(p, "E$", 2) != 0)
      return 0;
   p += 2;
   sep = strchr(p, '$');
   if (!sep || sep == p || !sep[1])
      return 0;
   if (strchr(sep + 1, '$'))
      return 0;
   caller_len = (size_t)(sep - p);
   if (caller_out) {
      *caller_out = (char *)xmalloc(caller_len + 1);
      memcpy(*caller_out, p, caller_len);
      (*caller_out)[caller_len] = '\0';
   }
   if (callee_out)
      *callee_out = xstrdup(sep + 1);
   return 1;
}

//! @brief Allocate memory for tool data structures, terminating with a diagnostic on failure.
void *xmalloc(size_t size)
{
   void *p = malloc(size ? size : 1);
   if (!p) {
      fprintf(stderr, "vcsc-ld: out of memory\n");
      exit(1);
   }
   return p;
}

//! @brief Create weak name for linker layout and image writer. The returned storage is owned by the caller or the object that immediately records it.
char *make_weak_name(const char *name)
{
   size_t n = strlen(name);
   char *out = (char *)xmalloc(n + 8);
   memcpy(out, "__weak_", 7);
   memcpy(out + 7, name, n + 1);
   return out;
}

//! @brief Allocate zeroed memory for tool data structures, terminating with a diagnostic on failure.
void *xcalloc(size_t count, size_t size)
{
   void *p = calloc(count ? count : 1, size ? size : 1);
   if (!p) {
      fprintf(stderr, "vcsc-ld: out of memory\n");
      exit(1);
   }
   return p;
}

//! @brief Resize tool-owned memory, terminating with a diagnostic on failure.
void *xrealloc(void *ptr, size_t size)
{
   void *p = realloc(ptr, size ? size : 1);
   if (!p) {
      fprintf(stderr, "vcsc-ld: out of memory\n");
      exit(1);
   }
   return p;
}

//! @brief Parse number into the normalized representation used by linker layout and image writer.
static parse_result_t parse_number(const char *s)
{
   parse_result_t r;
   char *end = NULL;

   while (isspace((unsigned char)*s))
      s++;

   r.ok = 0;
   r.value = 0;
   r.pos = 0;

   if (*s == '$') {
      r.value = strtoul(s + 1, &end, 16);
      if (end && end != s + 1)
         r.ok = 1;
   } else {
      r.value = strtoul(s, &end, 0);
      if (end && end != s)
         r.ok = 1;
   }

   if (r.ok)
      r.pos = (size_t)(end - s);
   return r;
}

//! @brief Find memory in linker layout and image writer tables without transferring ownership.
static const memory_region_t *find_memory(const linker_config_t *cfg, const char *name)
{
   size_t i;
   for (i = 0; i < cfg->mem_count; ++i) {
      if (str_ieq(cfg->mem[i].name, name))
         return &cfg->mem[i];
   }
   return NULL;
}

//! @brief Parse exactly four hexadecimal digits from mem-region metadata.
static int parse_hex4(const char *s, uint16_t *out)
{
   unsigned int v = 0;
   int i;

   if (!s || !out)
      return 0;
   for (i = 0; i < 4; ++i) {
      unsigned char c = (unsigned char)s[i];
      if (!isxdigit(c))
         return 0;
      v <<= 4;
      if (isdigit(c))
         v |= (unsigned int)(c - '0');
      else
         v |= (unsigned int)(toupper(c) - 'A' + 10);
   }
   *out = (uint16_t)v;
   return 1;
}

//! @brief Decode compiler-emitted mem-region metadata from an exported symbol name.
static int mem_region_metadata_parse(const char *name, char *region, size_t region_size,
      uint16_t *start, uint16_t *size, char *type, size_t type_size)
{
   const char *p;
   const char *smark;
   const char *zmark;
   const char *tmark;
   size_t region_len;
   size_t type_len;

   if (!mem_region_metadata_has_prefix(name))
      return 0;

   p = name + sizeof(MEM_REGION_META_PREFIX) - 1;
   smark = strstr(p, "$S");
   if (!smark || smark == p)
      return 0;
   region_len = (size_t)(smark - p);
   if (region_len >= region_size)
      return 0;
   memcpy(region, p, region_len);
   region[region_len] = '\0';

   if (!parse_hex4(smark + 2, start))
      return 0;
   zmark = smark + 6;
   if (strncmp(zmark, "$Z", 2) != 0)
      return 0;
   if (!parse_hex4(zmark + 2, size))
      return 0;
   tmark = zmark + 6;
   if (strncmp(tmark, "$T", 2) != 0)
      return 0;
   type_len = strlen(tmark + 2);
   if (type_len == 0 || type_len >= type_size || strchr(tmark + 2, '$'))
      return 0;
   memcpy(type, tmark + 2, type_len + 1);
   return 1;
}

//! @brief Validate compiler mem declarations against linker cfg MEMORY entries.
static void validate_mem_region_metadata(const linker_config_t *cfg, const input_set_t *in)
{
   size_t i;

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      size_t j;

      for (j = 0; j < obj->export_count; ++j) {
         const char *sym = obj->exports[j].name;
         char region[MAX_NAME];
         char type[8];
         uint16_t declared_start;
         uint16_t declared_size;
         const memory_region_t *mem;

         if (!mem_region_metadata_has_prefix(sym))
            continue;
         if (!mem_region_metadata_parse(sym, region, sizeof(region), &declared_start, &declared_size, type, sizeof(type))) {
            fprintf(stderr, "vcsc-ld: malformed mem-region metadata symbol '%s' in %s\n",
                  sym, obj->origin);
            exit(1);
         }

         mem = find_memory(cfg, region);
         if (!mem) {
            fprintf(stderr,
                  "vcsc-ld: mem region '%s' declared by %s is not present in linker cfg MEMORY. "
                  "Add a MEMORY entry named '%s' or change the n source mem declaration so they match.\n",
                  region, obj->origin, region);
            exit(1);
         }

         if (mem->start != declared_start) {
            fprintf(stderr,
                  "vcsc-ld: mem region '%s' start mismatch in %s: compiler mem declaration says $%04X "
                  "but linker cfg MEMORY %s starts at $%04X. Update the n source mem declaration or the linker cfg so they match.\n",
                  region, obj->origin, declared_start, mem->name, mem->start);
            exit(1);
         }
         if (mem->size != declared_size) {
            fprintf(stderr,
                  "vcsc-ld: mem region '%s' size mismatch in %s: compiler mem declaration says $%04X "
                  "but linker cfg MEMORY %s has size $%04X. Update the n source mem declaration or the linker cfg so they match.\n",
                  region, obj->origin, declared_size, mem->name, mem->size);
            exit(1);
         }
         if (!str_ieq(mem->type, type)) {
            fprintf(stderr,
                  "vcsc-ld: mem region '%s' type mismatch in %s: compiler mem declaration says %s "
                  "but linker cfg MEMORY %s has type %s. Update the n source mem declaration or the linker cfg so they match.\n",
                  region, obj->origin, type, mem->name, mem->type);
            exit(1);
         }
      }
   }
}


//! @brief Find segment rule in linker layout and image writer tables without transferring ownership.
static const segment_rule_t *find_segment_rule(const linker_config_t *cfg, const char *name)
{
   size_t i;
   for (i = 0; i < cfg->seg_count; ++i) {
      if (str_ieq(cfg->seg[i].name, name))
         return &cfg->seg[i];
   }
   return NULL;
}

//! @brief Trim leading and trailing whitespace in place and return the first non-space byte.
static char *trim(char *s)
{
   char *e;
   while (isspace((unsigned char)*s))
      s++;
   if (*s == '\0')
      return s;
   e = s + strlen(s) - 1;
   while (e > s && isspace((unsigned char)*e))
      *e-- = '\0';
   return s;
}

//! @brief Parse memory property into the normalized representation used by linker layout and image writer.
static void parse_memory_property(memory_region_t *mem, const char *key, const char *value)
{
   parse_result_t n;
   if (str_ieq(key, "start")) {
      n = parse_number(value);
      if (!n.ok || n.value > 0xFFFFu) {
         fprintf(stderr, "vcsc-ld: bad memory start '%s'\n", value);
         exit(1);
      }
      mem->start = (uint16_t)n.value;
   } else if (str_ieq(key, "size")) {
      n = parse_number(value);
      if (!n.ok || n.value > 0xFFFFu) {
         fprintf(stderr, "vcsc-ld: bad memory size '%s'\n", value);
         exit(1);
      }
      mem->size = (uint16_t)n.value;
   } else if (str_ieq(key, "type")) {
      snprintf(mem->type, sizeof(mem->type), "%s", trim((char *)value));
   } else if (str_ieq(key, "define")) {
      mem->define_yes = str_ieq(trim((char *)value), "yes");
   } else if (str_ieq(key, "callstack")) {
      value = trim((char *)value);
      if (str_ieq(value, "callgraph")) {
         mem->callstack_callgraph = 1;
      }
      else if (str_ieq(value, "no")) {
         mem->callstack_callgraph = 0;
      }
      else {
         fprintf(stderr, "vcsc-ld: bad memory callstack mode '%s'; expected callgraph or no\n", value);
         exit(1);
      }
   } else if (str_ieq(key, "callstack_extra")) {
      n = parse_number(value);
      if (!n.ok || n.value > 0xFFFFu) {
         fprintf(stderr, "vcsc-ld: bad memory callstack_extra '%s'\n", value);
         exit(1);
      }
      mem->callstack_extra = (uint16_t)n.value;
   }
}

//! @brief Parse segment property into the normalized representation used by linker layout and image writer.
static void parse_segment_property(segment_rule_t *seg, const char *key, const char *value)
{
   value = trim((char *)value);
   if (str_ieq(key, "load")) {
      snprintf(seg->load_name, sizeof(seg->load_name), "%s", value);
   } else if (str_ieq(key, "run")) {
      snprintf(seg->run_name, sizeof(seg->run_name), "%s", value);
   } else if (str_ieq(key, "type")) {
      snprintf(seg->type, sizeof(seg->type), "%s", value);
   } else if (str_ieq(key, "define")) {
      seg->define_yes = str_ieq(value, "yes");
   } else if (str_ieq(key, "align")) {
      parse_result_t n = parse_number(value);
      if (!n.ok || n.value == 0 || n.value > 0x8000u || (n.value & (n.value - 1u)) != 0) {
         fprintf(stderr, "vcsc-ld: bad segment alignment '%s'; expected a power of two from 1 through $8000\n", value);
         exit(1);
      }
      seg->align = (uint16_t)n.value;
   }
}

//! @brief Parse configuration file into the normalized representation used by linker layout and image writer.
static void parse_cfg_file(linker_config_t *cfg, const char *path)
{
   FILE *fp = fopen(path, "r");
   char line[1024];
   enum { NONE, MEMORY, SEGMENTS } block = NONE;

   if (!fp) {
      fprintf(stderr, "vcsc-ld: cannot open '%s': %s\n", path, strerror(errno));
      exit(1);
   }

   memset(cfg, 0, sizeof(*cfg));

   while (fgets(line, sizeof(line), fp)) {
      char *s = line;
      char *brace;
      char *comment = strchr(s, '#');
      if (comment)
         *comment = '\0';
      s = trim(s);
      if (*s == '\0')
         continue;

      if (str_ieq(s, "MEMORY {") || str_ieq(s, "MEMORY{")) {
         block = MEMORY;
         continue;
      }
      if (str_ieq(s, "SEGMENTS {") || str_ieq(s, "SEGMENTS{")) {
         block = SEGMENTS;
         continue;
      }
      if (strcmp(s, "}") == 0) {
         block = NONE;
         continue;
      }
      if (block == NONE)
         continue;

      brace = strchr(s, ':');
      if (!brace)
         continue;
      *brace++ = '\0';
      s = trim(s);
      brace = trim(brace);
      {
         char *semi = strrchr(brace, ';');
         char *tok;
         if (semi)
            *semi = '\0';

         if (block == MEMORY) {
            memory_region_t *mem;
            if (cfg->mem_count >= ARRAY_LEN(cfg->mem)) {
               fprintf(stderr, "vcsc-ld: too many MEMORY entries\n");
               exit(1);
            }
            mem = &cfg->mem[cfg->mem_count++];
            memset(mem, 0, sizeof(*mem));
            snprintf(mem->name, sizeof(mem->name), "%s", s);
            tok = strtok(brace, ",");
            while (tok) {
               char *eq = strchr(tok, '=');
               if (eq) {
                  *eq++ = '\0';
                  parse_memory_property(mem, trim(tok), trim(eq));
               }
               tok = strtok(NULL, ",");
            }
         } else {
            segment_rule_t *seg;
            if (cfg->seg_count >= ARRAY_LEN(cfg->seg)) {
               fprintf(stderr, "vcsc-ld: too many SEGMENTS entries\n");
               exit(1);
            }
            seg = &cfg->seg[cfg->seg_count++];
            memset(seg, 0, sizeof(*seg));
            snprintf(seg->name, sizeof(seg->name), "%s", s);
            tok = strtok(brace, ",");
            while (tok) {
               char *eq = strchr(tok, '=');
               if (eq) {
                  *eq++ = '\0';
                  parse_segment_property(seg, trim(tok), trim(eq));
               }
               tok = strtok(NULL, ",");
            }
         }
      }
   }

   fclose(fp);

   {
      size_t i;
      for (i = 0; i < cfg->mem_count; ++i) {
         if (cfg->mem[i].callstack_extra && !cfg->mem[i].callstack_callgraph) {
            fprintf(stderr,
               "vcsc-ld: MEMORY region '%s' sets callstack_extra but does not request callstack=callgraph\n",
               cfg->mem[i].name);
            exit(1);
         }
      }
   }
}




//! @brief Return whether symbol is init function in linker layout and image writer.
static int symbol_is_init_function(const char *name)
{
   return strcmp(name, "__init") == 0 || strncmp(name, "__init_", 7) == 0;
}

//! @brief Return whether one object exposes an ordinary symbol with this exact name.
static int call_graph_object_exports_symbol(const object_file_t *obj, const char *name)
{
   size_t i;

   if (!obj || !name)
      return 0;
   for (i = 0; i < obj->export_count; ++i) {
      if (strcmp(obj->exports[i].name, name) == 0)
         return 1;
   }
   return 0;
}

//! @brief Return whether one object imports an ordinary symbol with this exact name.
static int call_graph_object_imports_symbol(const object_file_t *obj, const char *name)
{
   size_t i;

   if (!obj || !name)
      return 0;
   for (i = 0; i < obj->undef_count; ++i) {
      if (strcmp(obj->undefs[i], name) == 0)
         return 1;
   }
   return 0;
}

//! @brief Give object-local functions a translation-unit-qualified graph identity.
static char *call_graph_object_function_name(const object_file_t *obj, const char *name)
{
   size_t need;
   char *qualified;

   if (!obj || !name)
      return xstrdup(name ? name : "?");

   /* A normally exported definition or unresolved import names one program-wide
      function. A metadata-only name is an internal-linkage function and must not
      collide with an identically named static function in another object. */
   if (call_graph_object_exports_symbol(obj, name) ||
       call_graph_object_imports_symbol(obj, name))
      return xstrdup(name);

   need = strlen(obj->origin) + strlen(name) + 3u;
   qualified = (char *)xmalloc(need);
   snprintf(qualified, need, "%s::%s", obj->origin, name);
   return qualified;
}

//! @brief Handle call graph find or add node logic for linker layout and image writer.
static int call_graph_find_or_add_node(call_graph_node_t **nodes, size_t *count, const char *name)
{
   size_t i;

   for (i = 0; i < *count; ++i) {
      if (strcmp((*nodes)[i].name, name) == 0)
         return (int)i;
   }

   *nodes = (call_graph_node_t *)xrealloc(*nodes, (*count + 1) * sizeof(**nodes));
   (*nodes)[*count].name = xstrdup(name);
   (*nodes)[*count].has_symbol_backed_params = 0;
   return (int)(*count)++;
}

//! @brief Handle call graph add edge logic for linker layout and image writer.
static void call_graph_add_edge(call_graph_edge_t **edges, size_t *count, int from, int to)
{
   size_t i;

   for (i = 0; i < *count; ++i) {
      if ((*edges)[i].from == from && (*edges)[i].to == to)
         return;
   }

   *edges = (call_graph_edge_t *)xrealloc(*edges, (*count + 1) * sizeof(**edges));
   (*edges)[*count].from = from;
   (*edges)[*count].to = to;
   (*count)++;
}

//! @brief Extract call graph collect from object for linker layout and image writer.
static void call_graph_collect_from_object(const object_file_t *obj,
                                           call_graph_node_t **nodes, size_t *node_count,
                                           call_graph_edge_t **edges, size_t *edge_count)
{
   size_t i;

   for (i = 0; i < obj->export_count; ++i) {
      const char *name = obj->exports[i].name;
      const char *sym = NULL;
      char *caller = NULL;
      char *callee = NULL;

      if (symbol_backed_metadata_parse_function(name, &sym)) {
         char *qualified = call_graph_object_function_name(obj, sym);
         int idx = call_graph_find_or_add_node(nodes, node_count, qualified);
         (*nodes)[idx].has_symbol_backed_params = 1;
         free(qualified);
         continue;
      }

      if (symbol_backed_metadata_parse_edge(name, &caller, &callee)) {
         char *qualified_caller = call_graph_object_function_name(obj, caller);
         char *qualified_callee = call_graph_object_function_name(obj, callee);
         int from = call_graph_find_or_add_node(nodes, node_count, qualified_caller);
         int to = call_graph_find_or_add_node(nodes, node_count, qualified_callee);
         call_graph_add_edge(edges, edge_count, from, to);
         free(qualified_caller);
         free(qualified_callee);
      }

      free(caller);
      free(callee);
   }
}

//! @brief Handle call graph tarjan visit logic for linker layout and image writer.
static void call_graph_tarjan_visit(int v,
                                    const call_graph_edge_t *edges, size_t edge_count,
                                    int *index_counter,
                                    int *stack, int *stack_top,
                                    int *indices, int *lowlink, unsigned char *onstack,
                                    int *component, int *component_sizes, int *component_count)
{
   size_t i;

   indices[v] = *index_counter;
   lowlink[v] = *index_counter;
   (*index_counter)++;
   stack[(*stack_top)++] = v;
   onstack[v] = 1;

   for (i = 0; i < edge_count; ++i) {
      int w;

      if (edges[i].from != v)
         continue;
      w = edges[i].to;
      if (indices[w] < 0) {
         call_graph_tarjan_visit(w, edges, edge_count, index_counter, stack, stack_top,
            indices, lowlink, onstack, component, component_sizes, component_count);
         if (lowlink[w] < lowlink[v])
            lowlink[v] = lowlink[w];
      }
      else if (onstack[w] && indices[w] < lowlink[v]) {
         lowlink[v] = indices[w];
      }
   }

   if (lowlink[v] == indices[v]) {
      int cid = (*component_count)++;
      component_sizes[cid] = 0;
      for (;;) {
         int w = stack[--(*stack_top)];
         onstack[w] = 0;
         component[w] = cid;
         component_sizes[cid]++;
         if (w == v)
            break;
      }
   }
}

//! @brief Return display function symbol data used by linker layout and image writer; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *display_function_symbol(const char *name)
{
   static char buf[512];
   size_t len;

   const char *local_sep;

   if (!name)
      return "?";

   local_sep = strrchr(name, ':');
   if (local_sep && local_sep > name && local_sep[-1] == ':')
      name = local_sep + 1;

   len = strlen(name);
   if (len > 0 && name[len - 1] == '?') {
      if (len >= sizeof(buf))
         len = sizeof(buf) - 1;
      memcpy(buf, name, len - 1);
      buf[len - 1] = 0;
      return buf;
   }

   return name;
}

//! @brief Compute the longest node path in an already validated acyclic call graph.
static int call_graph_longest_depth_visit(int v,
                                          const call_graph_edge_t *edges, size_t edge_count,
                                          int *memo)
{
   size_t i;
   int best = 1;

   if (memo[v] > 0)
      return memo[v];

   for (i = 0; i < edge_count; ++i) {
      int child_depth;

      if (edges[i].from != v)
         continue;
      child_depth = 1 + call_graph_longest_depth_visit(edges[i].to, edges, edge_count, memo);
      if (child_depth > best)
         best = child_depth;
   }

   memo[v] = best;
   return best;
}

//! @brief Validate symbol backed call graph invariants and return its maximum function depth.
static uint16_t enforce_symbol_backed_call_graph(const input_set_t *in)
{
   call_graph_node_t *nodes = NULL;
   call_graph_edge_t *edges = NULL;
   size_t node_count = 0;
   size_t edge_count = 0;
   int *indices = NULL;
   int *lowlink = NULL;
   int *stack = NULL;
   int *component = NULL;
   int *component_sizes = NULL;
   unsigned char *onstack = NULL;
   unsigned char *component_has_symbol_backed = NULL;
   unsigned char *component_has_cycle = NULL;
   int *depth_memo = NULL;
   int max_depth = 0;
   int stack_top = 0;
   int index_counter = 0;
   int component_count = 0;
   size_t i;

   for (i = 0; i < in->object_count; ++i)
      call_graph_collect_from_object(&in->objects[i], &nodes, &node_count, &edges, &edge_count);

   if (node_count == 0)
      goto cleanup;

   indices = (int *)xmalloc(sizeof(*indices) * node_count);
   lowlink = (int *)xmalloc(sizeof(*lowlink) * node_count);
   stack = (int *)xmalloc(sizeof(*stack) * node_count);
   component = (int *)xmalloc(sizeof(*component) * node_count);
   component_sizes = (int *)xcalloc(node_count, sizeof(*component_sizes));
   onstack = (unsigned char *)xcalloc(node_count, sizeof(*onstack));
   component_has_symbol_backed = (unsigned char *)xcalloc(node_count, sizeof(*component_has_symbol_backed));
   component_has_cycle = (unsigned char *)xcalloc(node_count, sizeof(*component_has_cycle));

   for (i = 0; i < node_count; ++i) {
      indices[i] = -1;
      lowlink[i] = -1;
      component[i] = -1;
   }

   for (i = 0; i < node_count; ++i) {
      if (indices[i] < 0) {
         call_graph_tarjan_visit((int)i, edges, edge_count, &index_counter, stack, &stack_top,
            indices, lowlink, onstack, component, component_sizes, &component_count);
      }
   }

   for (i = 0; i < node_count; ++i) {
      if (component[i] >= 0 && nodes[i].has_symbol_backed_params)
         component_has_symbol_backed[component[i]] = 1;
   }
   for (i = 0; i < (size_t)component_count; ++i) {
      if (component_sizes[i] > 1)
         component_has_cycle[i] = 1;
   }
   for (i = 0; i < edge_count; ++i) {
      if (component[edges[i].from] == component[edges[i].to])
         component_has_cycle[component[edges[i].from]] = 1;
   }

   for (i = 0; i < (size_t)component_count; ++i) {
      size_t j;

      if (!component_has_cycle[i] || !component_has_symbol_backed[i])
         continue;

      for (j = 0; j < node_count; ++j) {
         if (component[j] == (int)i && nodes[j].has_symbol_backed_params) {
            fprintf(stderr, "vcsc-ld: call graph cycle reaches function '%s' with static activation storage\n", display_function_symbol(nodes[j].name));
            exit(1);
         }
      }
   }

   depth_memo = (int *)xcalloc(node_count, sizeof(*depth_memo));
   for (i = 0; i < node_count; ++i) {
      int depth = call_graph_longest_depth_visit((int)i, edges, edge_count, depth_memo);
      if (depth > max_depth)
         max_depth = depth;
   }

cleanup:
   for (i = 0; i < node_count; ++i)
      free(nodes[i].name);
   free(nodes);
   free(edges);
   free(indices);
   free(lowlink);
   free(stack);
   free(component);
   free(component_sizes);
   free(onstack);
   free(component_has_symbol_backed);
   free(component_has_cycle);
   free(depth_memo);
   return (uint16_t)max_depth;
}

//! @brief Shrink the configured RAM arena by the stack requirement derived from the call graph.
static void reserve_call_stack_from_call_graph(linker_config_t *cfg, uint16_t depth, size_t init_count)
{
   memory_region_t *target = NULL;
   size_t i;
   uint32_t end;
   uint32_t bytes;

   for (i = 0; i < cfg->mem_count; ++i) {
      if (!cfg->mem[i].callstack_callgraph)
         continue;
      if (target) {
         fprintf(stderr, "vcsc-ld: more than one MEMORY region requests callstack=callgraph\n");
         exit(1);
      }
      target = &cfg->mem[i];
   }

   if (!target)
      return;

   /* Each active source function accounts for one two-byte JSR return address.
      The stock startup also preserves its two-byte init-table cursor while an
      init function runs. callstack_extra reserves a configuration-declared
      number of additional top-of-RAM bytes for stack use hidden inside included
      or separately assembled routines. */
   bytes = (uint32_t)depth * 2u;
   if (init_count > 0)
      bytes += 2u;
   bytes += target->callstack_extra;
   end = (uint32_t)target->start + (uint32_t)target->size;
   if (end > 0x10000u) {
      fprintf(stderr, "vcsc-ld: MEMORY region '%s' extends beyond address space\n", target->name);
      exit(1);
   }
   if (bytes > target->size) {
      fprintf(stderr, "vcsc-ld: call graph requires %" PRIu32 " hardware-stack bytes but MEMORY region '%s' has only %u\n",
              bytes, target->name, (unsigned)target->size);
      exit(1);
   }

   cfg->call_stack_enabled = 1;
   snprintf(cfg->call_stack_region, sizeof(cfg->call_stack_region), "%s", target->name);
   cfg->call_stack_depth = depth;
   cfg->call_stack_extra = target->callstack_extra;
   cfg->call_stack_size = (uint16_t)bytes;
   cfg->call_stack_start = (uint16_t)(end - bytes);
   cfg->call_stack_top = (uint16_t)(end - 1u);
   target->size = (uint16_t)(target->size - bytes);
}

//! @brief Add global to linker layout and image writer state, growing storage or preserving uniqueness as needed.
static void add_global(layout_t *layout, const char *name, uint16_t addr, uint8_t segid, const char *source)
{
   size_t i;
   for (i = 0; i < layout->global_count; ++i) {
      if (strcmp(layout->globals[i].name, name) == 0) {
         fprintf(stderr, "vcsc-ld: duplicate global symbol '%s' from %s and %s\n",
            name, layout->globals[i].source, source);
         exit(1);
      }
   }
   layout->globals = (global_symbol_t *)xrealloc(layout->globals,
      (layout->global_count + 1) * sizeof(*layout->globals));
   layout->globals[layout->global_count].name = xstrdup(name);
   layout->globals[layout->global_count].addr = addr;
   layout->globals[layout->global_count].segid = segid;
   layout->globals[layout->global_count].source = source;
   layout->global_count++;
}

//! @brief Add generated symbols to linker layout and image writer state, growing storage or preserving uniqueness as needed.
static void add_generated_symbols(layout_t *layout)
{
   add_global(layout, "__copy_table", layout->copy_table_addr, O26_SEG_ABS, "<linker>");
   add_global(layout, "__zero_table", layout->zero_table_addr, O26_SEG_ABS, "<linker>");
   add_global(layout, "__init_table", layout->init_table_addr, O26_SEG_ABS, "<linker>");
   add_global(layout, "__stack_start", layout->stack_start, O26_SEG_ABS, "<linker>");
   add_global(layout, "__stack_top", layout->stack_top, O26_SEG_ABS, "<linker>");
   if (layout->call_stack_enabled) {
      add_global(layout, "__call_stack_depth", layout->call_stack_depth, O26_SEG_ABS, "<linker>");
      add_global(layout, "__call_stack_extra", layout->call_stack_extra, O26_SEG_ABS, "<linker>");
      add_global(layout, "__call_stack_size", layout->call_stack_size, O26_SEG_ABS, "<linker>");
      add_global(layout, "__call_stack_start", layout->call_stack_start, O26_SEG_ABS, "<linker>");
      add_global(layout, "__call_stack_top", layout->call_stack_top, O26_SEG_ABS, "<linker>");
   }
}

//! @brief Find global addr in linker layout and image writer tables without transferring ownership.
static uint16_t lookup_global_addr(const layout_t *layout, const char *name)
{
   size_t i;
   char *weak;

   for (i = 0; i < layout->global_count; ++i) {
      if (strcmp(layout->globals[i].name, name) == 0)
         return layout->globals[i].addr;
   }

   weak = make_weak_name(name);
   for (i = 0; i < layout->global_count; ++i) {
      if (strcmp(layout->globals[i].name, weak) == 0) {
         uint16_t addr = layout->globals[i].addr;
         free(weak);
         return addr;
      }
   }
   free(weak);

   fprintf(stderr, "vcsc-ld: unresolved symbol '%s'\n", name);
   exit(1);
}

//! @brief Collect init functions in input from existing linker layout and image writer state for a later pass.
static size_t count_init_functions_in_input(const input_set_t *in)
{
   size_t i, j;
   size_t count = 0;

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->export_count; ++j) {
         if (symbol_is_init_function(obj->exports[j].name))
            count++;
      }
   }

   return count;
}

//! @brief Handle segment name matches prefix logic for linker layout and image writer.
static int segment_name_matches_prefix(const char *name, const char *prefix)
{
   size_t n;

   if (!name || !prefix)
      return 0;

   n = strlen(prefix);
   return strncasecmp(name, prefix, n) == 0 && (name[n] == '\0' || name[n] == '.');
}

//! @brief Return segment name suffix data used by linker layout and image writer; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *segment_name_suffix(const char *name)
{
   const char *dot;

   if (!name)
      return NULL;
   dot = strchr(name, '.');
   return (dot && dot[1]) ? dot + 1 : NULL;
}

//! @brief Return rule run region name data used by linker layout and image writer; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *rule_run_region_name(const segment_rule_t *rule)
{
   if (!rule)
      return NULL;
   return rule->run_name[0] ? rule->run_name : rule->load_name;
}

//! @brief Return ensure cursor data used by linker layout and image writer; returned pointers alias existing storage unless explicitly allocated by the function name.
static memory_cursor_t *ensure_cursor(layout_t *layout, const linker_config_t *cfg, const char *mem_name)
{
   size_t i;
   const memory_region_t *mem;

   for (i = 0; i < layout->cursor_count; ++i) {
      if (str_ieq(layout->cursors[i].name, mem_name))
         return &layout->cursors[i];
   }

   mem = find_memory(cfg, mem_name);
   if (!mem) {
      fprintf(stderr, "vcsc-ld: MEMORY region '%s' not found\n", mem_name);
      exit(1);
   }

   layout->cursors = (memory_cursor_t *)xrealloc(layout->cursors,
      (layout->cursor_count + 1) * sizeof(*layout->cursors));
   memset(&layout->cursors[layout->cursor_count], 0, sizeof(*layout->cursors));
   snprintf(layout->cursors[layout->cursor_count].name, sizeof(layout->cursors[layout->cursor_count].name), "%s", mem->name);
   layout->cursors[layout->cursor_count].cur = mem->start;
   layout->cursors[layout->cursor_count].end = (uint32_t)mem->start + (uint32_t)mem->size;
   return &layout->cursors[layout->cursor_count++];
}

//! @brief Extract alloc from region for linker layout and image writer.
static uint16_t alloc_from_region(layout_t *layout, const linker_config_t *cfg, const char *mem_name,
   uint16_t size, const char *what, const char *origin)
{
   memory_cursor_t *cursor = ensure_cursor(layout, cfg, mem_name);
   uint32_t addr = cursor->cur;
   uint32_t end = addr + size;

   if (end > 0x10000u || end > cursor->end || (str_ieq(mem_name, "ROM") && end > 0xFFFAu)) {
      fprintf(stderr, "vcsc-ld: %s overflow while placing %s from %s in %s\n", mem_name, what, origin, mem_name);
      exit(1);
   }

   cursor->cur = (uint16_t)end;
   return (uint16_t)addr;
}

//! @brief Allocate from a region after advancing its cursor to a power-of-two boundary.
static uint16_t alloc_from_region_aligned(layout_t *layout, const linker_config_t *cfg,
   const char *mem_name, uint16_t size, uint16_t alignment, const char *what, const char *origin)
{
   memory_cursor_t *cursor = ensure_cursor(layout, cfg, mem_name);
   uint32_t aligned;

   if (alignment <= 1)
      return alloc_from_region(layout, cfg, mem_name, size, what, origin);
   aligned = ((uint32_t)cursor->cur + alignment - 1u) & ~((uint32_t)alignment - 1u);
   if (aligned > cursor->end || aligned > 0xffffu) {
      fprintf(stderr, "vcsc-ld: %s overflow while aligning %s from %s to $%04X\n",
              mem_name, what, origin, alignment);
      exit(1);
   }
   cursor->cur = (uint16_t)aligned;
   return alloc_from_region(layout, cfg, mem_name, size, what, origin);
}

//! @brief Return the strongest linker-script alignment requested by text layouts in one object.
static uint16_t object_text_alignment(const linker_config_t *cfg, const object_file_t *obj)
{
   uint16_t result = 1;
   size_t i;

   for (i = 0; i < obj->layout_count; ++i) {
      const object_layout_t *lay = &obj->layouts[i];
      const segment_rule_t *rule;
      if (lay->segid != O26_SEG_TEXT || lay->size == 0)
         continue;
      rule = find_segment_rule(cfg, lay->name);
      if (rule && rule->align > result) {
         if ((lay->packed_base & (rule->align - 1u)) != 0) {
            fprintf(stderr, "vcsc-ld: segment %s in %s requests alignment $%04X but packed offset $%04X is not aligned\n",
                    lay->name, obj->origin, rule->align, lay->packed_base);
            exit(1);
         }
         result = rule->align;
      }
   }
   return result;
}

//! @brief Add copy record to linker layout and image writer state, growing storage or preserving uniqueness as needed.
static void add_copy_record(layout_t *layout, const char *name, uint16_t load_addr, uint16_t run_addr, uint16_t size)
{
   if (size == 0)
      return;
   layout->copy_records = (copy_record_t *)xrealloc(layout->copy_records,
      (layout->copy_record_count + 1) * sizeof(*layout->copy_records));
   layout->copy_records[layout->copy_record_count].name = xstrdup(name ? name : "DATA");
   layout->copy_records[layout->copy_record_count].load_addr = load_addr;
   layout->copy_records[layout->copy_record_count].run_addr = run_addr;
   layout->copy_records[layout->copy_record_count].size = size;
   layout->copy_record_count++;
}

//! @brief Add zero record to linker layout and image writer state, growing storage or preserving uniqueness as needed.
static void add_zero_record(layout_t *layout, const char *name, uint16_t run_addr, uint16_t size)
{
   if (size == 0)
      return;
   layout->zero_records = (zero_record_t *)xrealloc(layout->zero_records,
      (layout->zero_record_count + 1) * sizeof(*layout->zero_records));
   layout->zero_records[layout->zero_record_count].name = xstrdup(name ? name : "BSS");
   layout->zero_records[layout->zero_record_count].run_addr = run_addr;
   layout->zero_records[layout->zero_record_count].size = size;
   layout->zero_record_count++;
}

//! @brief Find layout for value in linker layout and image writer tables without transferring ownership.
static const object_layout_t *find_layout_for_value(const object_file_t *obj, uint8_t segid, uint16_t packed_value)
{
   const object_layout_t *fallback = NULL;
   const object_layout_t *page_bias = NULL;
   uint16_t page_bias_distance = 0xffffu;
   size_t i;

   for (i = 0; i < obj->layout_count; ++i) {
      const object_layout_t *lay = &obj->layouts[i];
      uint32_t start = lay->packed_base;
      uint32_t end = (uint32_t)lay->packed_base + lay->size;
      uint16_t before;

      if (lay->segid != segid)
         continue;
      if (packed_value >= start && packed_value < end)
         return lay;
      if (packed_value == end)
         fallback = lay;

      /* Cycle-counted 6502 code sometimes deliberately forms an absolute,Y
         base one page before a local table, then supplies a negative byte in Y
         so the effective address lands back inside the table.  The packed
         segment-relative addend consequently wraps below zero (for example
         $FF9F for local label $009F minus $0100).  Accept only a one-page
         backward bias and choose the nearest matching layout; ordinary direct
         in-range references above remain unambiguous. */
      before = (uint16_t)(lay->packed_base - packed_value);
      if (before > 0 && before <= 0x0100u && before < page_bias_distance) {
         page_bias = lay;
         page_bias_distance = before;
      }
   }

   return fallback ? fallback : page_bias;
}

//! @brief Handle object runtime addr for value logic for linker layout and image writer.
static uint16_t object_runtime_addr_for_value(const object_file_t *obj, uint8_t segid, uint16_t packed_value)
{
   const object_layout_t *lay;
   uint16_t base;

   if (segid == O26_SEG_ABS)
      return packed_value;

   lay = find_layout_for_value(obj, segid, packed_value);
   if (!lay) {
      fprintf(stderr, "vcsc-ld: could not map packed value $%04X in %s for segment %u\n", packed_value, obj->origin, (unsigned)segid);
      exit(1);
   }

   base = (segid == O26_SEG_TEXT) ? lay->load_addr : lay->run_addr;
   return (uint16_t)(base + (packed_value - lay->packed_base));
}

//! @brief Handle object layout load addr logic for linker layout and image writer.
static uint16_t object_layout_load_addr(const object_file_t *obj, const object_layout_t *lay)
{
   switch (lay->image_segid) {
      case O26_SEG_TEXT:
         return (uint16_t)(obj->place_text_load + lay->image_base);

      case O26_SEG_DATA:
         return (uint16_t)(obj->place_data_load + lay->image_base);

      default:
         return 0;
   }
}


#define ACTIVATION_SEGMENT_MARKER ".__vcsc_activation$"

typedef struct activation_piece_t {
   object_file_t *obj;
   object_layout_t *layout;
   int node;
   int region;
   uint16_t intra_offset;
   int needs_zero;
} activation_piece_t;

//! @brief Decode one compiler-owned activation segment name.
static int activation_segment_parse(const char *name,
                                    char *region, size_t region_size,
                                    const char **owner_out) {
   const char *first_dot;
   const char *marker;
   size_t region_len;

   if (!name || !region || region_size == 0 || !owner_out)
      return 0;
   first_dot = strchr(name, '.');
   marker = strstr(name, ACTIVATION_SEGMENT_MARKER);
   if (!first_dot || !marker || marker < first_dot || !marker[sizeof(ACTIVATION_SEGMENT_MARKER) - 1])
      return 0;
   if (!(segment_name_matches_prefix(name, "BSS") ||
         segment_name_matches_prefix(name, "ZEROPAGE") ||
         segment_name_matches_prefix(name, "ZP") ||
         segment_name_matches_prefix(name, "ZERO")))
      return 0;

   region_len = (marker == first_dot) ? 0u
      : (size_t)(marker - (first_dot + 1));
   if (region_len >= region_size)
      return 0;
   if (region_len > 0)
      memcpy(region, first_dot + 1, region_len);
   region[region_len] = '\0';
   *owner_out = marker + sizeof(ACTIVATION_SEGMENT_MARKER) - 1;
   return **owner_out != '\0';
}

//! @brief Find or append a memory-region name in the activation planner.
static int activation_region_find_or_add(char (**regions)[MAX_NAME], size_t *count,
                                         const char *name) {
   size_t i;
   for (i = 0; i < *count; ++i) {
      if (str_ieq((*regions)[i], name))
         return (int)i;
   }
   *regions = (char (*)[MAX_NAME])xrealloc(*regions, (*count + 1) * sizeof(**regions));
   memset(&(*regions)[*count], 0, sizeof(**regions));
   snprintf((*regions)[*count], MAX_NAME, "%s", name);
   return (int)(*count)++;
}

//! @brief Assign all compiler activation segments by weighted call-graph depth.
static void layout_activation_segments(const linker_config_t *cfg, input_set_t *in,
                                       layout_t *layout,
                                       const char *default_bss_region,
                                       const char *default_zp_region) {
   call_graph_node_t *nodes = NULL;
   call_graph_edge_t *edges = NULL;
   size_t node_count = 0;
   size_t edge_count = 0;
   char (*regions)[MAX_NAME] = NULL;
   size_t region_count = 0;
   activation_piece_t *pieces = NULL;
   size_t piece_count = 0;
   uint32_t *sizes = NULL;
   uint32_t *bases = NULL;
   size_t i, j;

   for (i = 0; i < in->object_count; ++i)
      call_graph_collect_from_object(&in->objects[i], &nodes, &node_count, &edges, &edge_count);

   /* First discover every activation owner and target memory region. */
   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->layout_count; ++j) {
         object_layout_t *lay = &obj->layouts[j];
         char explicit_region[MAX_NAME];
         const char *owner;
         const char *region_name;
         int node;
         int region;

         if (!activation_segment_parse(lay->name, explicit_region,
                                       sizeof(explicit_region), &owner))
            continue;
         region_name = explicit_region[0] ? explicit_region
            : (lay->segid == O26_SEG_ZP ? default_zp_region : default_bss_region);
         {
            char *qualified_owner = call_graph_object_function_name(obj, owner);
            node = call_graph_find_or_add_node(&nodes, &node_count, qualified_owner);
            free(qualified_owner);
         }
         region = activation_region_find_or_add(&regions, &region_count, region_name);

         pieces = (activation_piece_t *)xrealloc(pieces,
            (piece_count + 1) * sizeof(*pieces));
         memset(&pieces[piece_count], 0, sizeof(pieces[piece_count]));
         pieces[piece_count].obj = obj;
         pieces[piece_count].layout = lay;
         pieces[piece_count].node = node;
         pieces[piece_count].region = region;
         pieces[piece_count].needs_zero = (lay->segid == O26_SEG_BSS);
         piece_count++;
      }
   }

   if (piece_count == 0)
      goto cleanup;

   sizes = (uint32_t *)xcalloc(region_count * node_count, sizeof(*sizes));
   bases = (uint32_t *)xcalloc(region_count * node_count, sizeof(*bases));

   /* Concatenate each function's pieces within each physical memory region. */
   for (i = 0; i < piece_count; ++i) {
      activation_piece_t *piece = &pieces[i];
      size_t cell = (size_t)piece->region * node_count + (size_t)piece->node;
      if (sizes[cell] + piece->layout->size > 0xFFFFu) {
         fprintf(stderr, "vcsc-ld: activation for function '%s' exceeds 64 KiB\n",
                 display_function_symbol(nodes[piece->node].name));
         exit(1);
      }
      piece->intra_offset = (uint16_t)sizes[cell];
      sizes[cell] += piece->layout->size;
   }

   for (i = 0; i < region_count; ++i) {
      uint32_t extent = 0;
      uint16_t block_start;
      int changed;
      size_t pass;

      /* Weighted DAG relaxation: a callee begins after every live caller's
         region-local activation. Siblings therefore share the same bytes. */
      for (pass = 0; pass < node_count; ++pass) {
         changed = 0;
         for (j = 0; j < edge_count; ++j) {
            size_t from = (size_t)edges[j].from;
            size_t to = (size_t)edges[j].to;
            uint32_t candidate = bases[i * node_count + from] +
                                 sizes[i * node_count + from];
            if (candidate > bases[i * node_count + to]) {
               bases[i * node_count + to] = candidate;
               changed = 1;
            }
         }
         if (!changed)
            break;
      }
      if (changed) {
         fprintf(stderr, "vcsc-ld: activation overlay encountered a call-graph cycle\n");
         exit(1);
      }

      for (j = 0; j < node_count; ++j) {
         uint32_t end = bases[i * node_count + j] + sizes[i * node_count + j];
         if (end > extent)
            extent = end;
      }
      if (extent > 0xFFFFu) {
         fprintf(stderr, "vcsc-ld: activation overlay for MEMORY region '%s' exceeds 64 KiB\n",
                 regions[i]);
         exit(1);
      }
      block_start = alloc_from_region(layout, cfg, regions[i], (uint16_t)extent,
                                      "activation overlay", "<call graph>");

      for (j = 0; j < piece_count; ++j) {
         activation_piece_t *piece = &pieces[j];
         uint32_t addr;
         if (piece->region != (int)i)
            continue;
         addr = (uint32_t)block_start +
                bases[i * node_count + (size_t)piece->node] +
                piece->intra_offset;
         if (addr > 0xFFFFu) {
            fprintf(stderr, "vcsc-ld: activation address overflow for %s\n",
                    piece->layout->name);
            exit(1);
         }
         piece->layout->load_addr = 0;
         piece->layout->run_addr = (uint16_t)addr;
         if (piece->needs_zero)
            add_zero_record(layout, piece->layout->name,
                            piece->layout->run_addr, piece->layout->size);
      }
   }

cleanup:
   for (i = 0; i < node_count; ++i)
      free(nodes[i].name);
   free(nodes);
   free(edges);
   free(regions);
   free(pieces);
   free(sizes);
   free(bases);
}

//! @brief Compute objects and update linker layout and image writer state once prerequisite pass data is available.
static void layout_objects(const linker_config_t *cfg, input_set_t *in, layout_t *layout)
{
   const segment_rule_t *code = find_segment_rule(cfg, "CODE");
   const segment_rule_t *data = find_segment_rule(cfg, "DATA");
   const segment_rule_t *bss = find_segment_rule(cfg, "BSS");
   const segment_rule_t *zp = find_segment_rule(cfg, "ZEROPAGE");
   const char *code_load_name = code ? code->load_name : NULL;
   const char *data_load_name = data ? data->load_name : NULL;
   const char *data_run_name = rule_run_region_name(data);
   const char *bss_run_name = rule_run_region_name(bss);
   const char *zp_run_name = rule_run_region_name(zp);
   size_t i, j;

   if (!code_load_name || !data_load_name || !data_run_name || !bss_run_name || !zp_run_name) {
      fprintf(stderr, "vcsc-ld: config must define CODE, DATA, BSS, and ZEROPAGE segments with valid MEMORY targets\n");
      exit(1);
   }

   memset(layout, 0, sizeof(*layout));
   layout->call_stack_enabled = cfg->call_stack_enabled;
   layout->call_stack_depth = cfg->call_stack_depth;
   layout->call_stack_extra = cfg->call_stack_extra;
   layout->call_stack_size = cfg->call_stack_size;
   layout->call_stack_start = cfg->call_stack_start;
   layout->call_stack_top = cfg->call_stack_top;
   (void)ensure_cursor(layout, cfg, code_load_name);
   (void)ensure_cursor(layout, cfg, data_load_name);
   (void)ensure_cursor(layout, cfg, data_run_name);
   (void)ensure_cursor(layout, cfg, bss_run_name);
   (void)ensure_cursor(layout, cfg, zp_run_name);

   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      obj->place_text_load = alloc_from_region_aligned(layout, cfg, code_load_name,
         (uint16_t)obj->text.length, object_text_alignment(cfg, obj), "text", obj->origin);
      obj->place_data_load = alloc_from_region(layout, cfg, data_load_name, (uint16_t)obj->data.length, "data load image", obj->origin);

      for (j = 0; j < obj->layout_count; ++j) {
         object_layout_t *lay = &obj->layouts[j];
         const char *suffix = segment_name_suffix(lay->name);
         char activation_region[MAX_NAME];
         const char *activation_owner = NULL;

         lay->load_addr = 0;
         lay->run_addr = 0;

         if (activation_segment_parse(lay->name, activation_region,
                                      sizeof(activation_region),
                                      &activation_owner)) {
            (void)activation_owner;
            continue;
         }

         switch (lay->segid) {
            case O26_SEG_TEXT:
               lay->load_addr = object_layout_load_addr(obj, lay);
               lay->run_addr = lay->load_addr;
               break;

            case O26_SEG_DATA: {
               const char *run_name = (suffix && segment_name_matches_prefix(lay->name, "DATA")) ? suffix : data_run_name;
               lay->load_addr = object_layout_load_addr(obj, lay);
               lay->run_addr = alloc_from_region(layout, cfg, run_name, lay->size, lay->name, obj->origin);
               add_copy_record(layout, lay->name, lay->load_addr, lay->run_addr, lay->size);
               break;
            }

            case O26_SEG_BSS: {
               const char *run_name = (suffix && segment_name_matches_prefix(lay->name, "BSS")) ? suffix : bss_run_name;
               lay->run_addr = alloc_from_region(layout, cfg, run_name, lay->size, lay->name, obj->origin);
               add_zero_record(layout, lay->name, lay->run_addr, lay->size);
               break;
            }

            case O26_SEG_ZP: {
               const char *run_name = (suffix && (segment_name_matches_prefix(lay->name, "ZEROPAGE") || segment_name_matches_prefix(lay->name, "ZP") || segment_name_matches_prefix(lay->name, "ZERO"))) ? suffix : zp_run_name;
               lay->load_addr = object_layout_load_addr(obj, lay);
               lay->run_addr = alloc_from_region(layout, cfg, run_name, lay->size, lay->name, obj->origin);
               if (lay->image_segid == O26_SEG_DATA || lay->image_segid == O26_SEG_TEXT)
                  add_copy_record(layout, lay->name, lay->load_addr, lay->run_addr, lay->size);
               break;
            }
         }
      }
   }

   layout_activation_segments(cfg, in, layout, bss_run_name, zp_run_name);

   layout->copy_table_addr = alloc_from_region(layout, cfg, data_load_name,
      (uint16_t)((layout->copy_record_count + 1) * 6), "__copy_table", "<linker>");
   layout->zero_table_addr = alloc_from_region(layout, cfg, data_load_name,
      (uint16_t)((layout->zero_record_count + 1) * 4), "__zero_table", "<linker>");
   {
      size_t init_count = count_init_functions_in_input(in);
      layout->init_table_addr = alloc_from_region(layout, cfg, data_load_name,
         (uint16_t)((init_count + 1) * 2), "__init_table", "<linker>");
      layout->init_table_size = (uint16_t)((init_count + 1) * 2);
   }
   layout->copy_table_size = (uint16_t)((layout->copy_record_count + 1) * 6);
   layout->zero_table_size = (uint16_t)((layout->zero_record_count + 1) * 4);

   {
      memory_cursor_t *stack_cursor = ensure_cursor(layout, cfg, data_run_name);
      layout->stack_start = stack_cursor->cur;
      layout->stack_top = (uint16_t)(stack_cursor->end - 1u);
   }

   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->export_count; ++j) {
         uint16_t addr;

         if (reserved_metadata_has_prefix(obj->exports[j].name))
            continue;

         if (obj->exports[j].segid == O26_SEG_ABS)
            addr = obj->exports[j].value;
         else
            addr = object_runtime_addr_for_value(obj, obj->exports[j].segid, obj->exports[j].value);
         add_global(layout, obj->exports[j].name, addr, obj->exports[j].segid, obj->origin);
      }
   }
}

//! @brief Handle patch 8-bit logic for linker layout and image writer.
static void patch_u8(uint8_t *buf, size_t len, uint32_t off, uint8_t v, const char *origin)
{
   if (off >= len) {
      fprintf(stderr, "vcsc-ld: relocation offset out of range in %s\n", origin);
      exit(1);
   }
   buf[off] = v;
}

//! @brief Handle patch 16-bit logic for linker layout and image writer.
static void patch_u16(uint8_t *buf, size_t len, uint32_t off, uint16_t v, const char *origin)
{
   if (off + 1 >= len) {
      fprintf(stderr, "vcsc-ld: relocation word offset out of range in %s\n", origin);
      exit(1);
   }
   buf[off] = (uint8_t)(v & 0xFFu);
   buf[off + 1] = (uint8_t)((v >> 8) & 0xFFu);
}

//! @brief Handle apply segment relocs logic for linker layout and image writer.
static void apply_segment_relocs(object_file_t *obj, o26_segment_t *seg, const layout_t *layout, const char *seg_name)
{
   size_t i;
   for (i = 0; i < seg->reloc_count; ++i) {
      reloc_t *r = &seg->relocs[i];
      uint16_t target = 0;
      uint16_t current_word;
      const char *who = obj->origin;
      (void)seg_name;

      switch (r->type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD)) {
         case O26_RTYPE_WORD:
            current_word = (uint16_t)(seg->data[r->offset] | (seg->data[r->offset + 1] << 8));
            break;

         case O26_RTYPE_LOW:
            current_word = (uint16_t)(seg->data[r->offset] | ((r->has_aux_low ? r->aux_low : 0) << 8));
            break;

         case O26_RTYPE_HIGH:
            current_word = (uint16_t)((r->has_aux_low ? r->aux_low : 0) | (seg->data[r->offset] << 8));
            break;

         default:
            current_word = seg->data[r->offset];
            break;
      }

      if (r->segid == O26_SEG_UNDEF) {
         if (r->undef_index >= obj->undef_count) {
            fprintf(stderr, "vcsc-ld: bad undefined-symbol index in %s\n", who);
            exit(1);
         }
         target = (uint16_t)(lookup_global_addr(layout, obj->undefs[r->undef_index]) + current_word);
      } else {
         target = object_runtime_addr_for_value(obj, r->segid, current_word);
      }

      switch (r->type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD)) {
         case O26_RTYPE_LOW:
            patch_u8(seg->data, seg->length, r->offset, (uint8_t)(target & 0xFFu), who);
            break;
         case O26_RTYPE_HIGH:
            patch_u8(seg->data, seg->length, r->offset, (uint8_t)((target >> 8) & 0xFFu), who);
            break;
         case O26_RTYPE_WORD:
            patch_u16(seg->data, seg->length, r->offset, target, who);
            break;
         default:
            fprintf(stderr, "vcsc-ld: unsupported relocation type 0x%02x in %s\n", r->type, who);
            exit(1);
      }
   }
}

//! @brief Compute all and update linker layout and image writer state once prerequisite pass data is available.
static void resolve_all(input_set_t *in, const layout_t *layout)
{
   size_t i;
   for (i = 0; i < in->object_count; ++i) {
      apply_segment_relocs(&in->objects[i], &in->objects[i].text, layout, "text");
      apply_segment_relocs(&in->objects[i], &in->objects[i].data, layout, "data");
   }
}

//! @brief Handle image write logic for linker layout and image writer.
static void image_write(uint8_t *image, uint8_t *used, uint16_t addr, const uint8_t *src, size_t len, const char *who)
{
   size_t i;
   for (i = 0; i < len; ++i) {
      uint32_t a = (uint32_t)addr + i;
      if (a > 0xFFFFu) {
         fprintf(stderr, "vcsc-ld: image write overflow from %s\n", who);
         exit(1);
      }
      image[a] = src[i];
      used[a] = 1;
   }
}

//! @brief Handle build init table image logic for linker layout and image writer.
static void build_init_table_image(const input_set_t *in, const layout_t *layout, uint8_t *table)
{
   size_t i, j;
   size_t out = 0;

   memset(table, 0, layout->init_table_size);

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->export_count; ++j) {
         uint16_t addr;

         if (!symbol_is_init_function(obj->exports[j].name))
            continue;
         addr = lookup_global_addr(layout, obj->exports[j].name);
         table[out++] = (uint8_t)(addr & 0xFFu);
         table[out++] = (uint8_t)((addr >> 8) & 0xFFu);
      }
   }
}

//! @brief Handle build copy table image logic for linker layout and image writer.
static void build_copy_table_image(const layout_t *layout, uint8_t *table)
{
   size_t i;
   size_t out = 0;

   memset(table, 0, layout->copy_table_size);
   for (i = 0; i < layout->copy_record_count; ++i) {
      const copy_record_t *rec = &layout->copy_records[i];
      table[out++] = (uint8_t)(rec->load_addr & 0xFFu);
      table[out++] = (uint8_t)((rec->load_addr >> 8) & 0xFFu);
      table[out++] = (uint8_t)(rec->run_addr & 0xFFu);
      table[out++] = (uint8_t)((rec->run_addr >> 8) & 0xFFu);
      table[out++] = (uint8_t)(rec->size & 0xFFu);
      table[out++] = (uint8_t)((rec->size >> 8) & 0xFFu);
   }
}

//! @brief Handle build zero table image logic for linker layout and image writer.
static void build_zero_table_image(const layout_t *layout, uint8_t *table)
{
   size_t i;
   size_t out = 0;

   memset(table, 0, layout->zero_table_size);
   for (i = 0; i < layout->zero_record_count; ++i) {
      const zero_record_t *rec = &layout->zero_records[i];
      table[out++] = (uint8_t)(rec->run_addr & 0xFFu);
      table[out++] = (uint8_t)((rec->run_addr >> 8) & 0xFFu);
      table[out++] = (uint8_t)(rec->size & 0xFFu);
      table[out++] = (uint8_t)((rec->size >> 8) & 0xFFu);
   }
}

//! @brief Handle build rom image logic for linker layout and image writer.
static void build_rom_image(const linker_config_t *cfg, input_set_t *in, const layout_t *layout, uint8_t *image, uint8_t *used)
{
   const memory_region_t *rom = find_memory(cfg, "ROM");
   size_t i;
   uint16_t reset, nmi, irqbrk;
   if (!rom) {
      fprintf(stderr, "vcsc-ld: ROM memory region not found\n");
      exit(1);
   }
   memset(image, 0xFF, 65536);
   memset(used, 0, 65536);

   for (i = 0; i < in->object_count; ++i) {
      image_write(image, used, in->objects[i].place_text_load, in->objects[i].text.data,
         in->objects[i].text.length, in->objects[i].origin);
      image_write(image, used, in->objects[i].place_data_load, in->objects[i].data.data,
         in->objects[i].data.length, in->objects[i].origin);
   }

   if (layout->copy_table_size > 0) {
      uint8_t *table = (uint8_t *)xmalloc(layout->copy_table_size);
      build_copy_table_image(layout, table);
      image_write(image, used, layout->copy_table_addr, table, layout->copy_table_size, "<linker:__copy_table>");
      free(table);
   }

   if (layout->zero_table_size > 0) {
      uint8_t *table = (uint8_t *)xmalloc(layout->zero_table_size);
      build_zero_table_image(layout, table);
      image_write(image, used, layout->zero_table_addr, table, layout->zero_table_size, "<linker:__zero_table>");
      free(table);
   }

   if (layout->init_table_size > 0) {
      uint8_t *table = (uint8_t *)xmalloc(layout->init_table_size);
      build_init_table_image(in, layout, table);
      image_write(image, used, layout->init_table_addr, table, layout->init_table_size, "<linker:__init_table>");
      free(table);
   }

   reset = lookup_global_addr(layout, "__reset");
   nmi = lookup_global_addr(layout, "__nmi");
   irqbrk = lookup_global_addr(layout, "__irqbrk");

   image[0xFFFA] = (uint8_t)(nmi & 0xFFu);
   image[0xFFFB] = (uint8_t)((nmi >> 8) & 0xFFu);
   image[0xFFFC] = (uint8_t)(reset & 0xFFu);
   image[0xFFFD] = (uint8_t)((reset >> 8) & 0xFFu);
   image[0xFFFE] = (uint8_t)(irqbrk & 0xFFu);
   image[0xFFFF] = (uint8_t)((irqbrk >> 8) & 0xFFu);
   used[0xFFFA] = used[0xFFFB] = used[0xFFFC] = used[0xFFFD] = used[0xFFFE] = used[0xFFFF] = 1;
}

//! @brief Handle hex checksum logic for linker layout and image writer.
static uint8_t hex_checksum(const uint8_t *bytes, size_t n)
{
   uint32_t sum = 0;
   size_t i;
   for (i = 0; i < n; ++i)
      sum += bytes[i];
   return (uint8_t)((~sum + 1) & 0xFFu);
}

//! @brief Emit hex record for linker layout and image writer diagnostics or output files.
static void emit_hex_record(FILE *fp, uint16_t addr, const uint8_t *data, uint8_t len, uint8_t type)
{
   uint8_t hdr[4];
   size_t i;
   hdr[0] = len;
   hdr[1] = (uint8_t)((addr >> 8) & 0xFFu);
   hdr[2] = (uint8_t)(addr & 0xFFu);
   hdr[3] = type;
   fprintf(fp, ":%02X%04X%02X", len, addr, type);
   for (i = 0; i < len; ++i)
      fprintf(fp, "%02X", data[i]);
   {
      uint8_t csum = hex_checksum(hdr, sizeof(hdr));
      for (i = 0; i < len; ++i)
         csum = (uint8_t)(csum - data[i]);
      fprintf(fp, "%02X\n", csum);
   }
}

//! @brief Write intel hex using the on-disk format expected by linker layout and image writer.
static void write_intel_hex(const char *path, const uint8_t *image, const uint8_t *used)
{
   FILE *fp = fopen(path, "w");
   uint32_t addr = 0;
   if (!fp) {
      fprintf(stderr, "vcsc-ld: cannot create '%s': %s\n", path, strerror(errno));
      exit(1);
   }
   while (addr < 65536u) {
      uint8_t chunk[16];
      uint8_t len = 0;
      while (addr < 65536u && !used[addr])
         addr++;
      if (addr >= 65536u)
         break;
      while (addr + len < 65536u && used[addr + len] && len < sizeof(chunk)) {
         chunk[len] = image[addr + len];
         len++;
      }
      emit_hex_record(fp, (uint16_t)addr, chunk, len, 0x00);
      addr += len;
   }
   fprintf(fp, ":00000001FF\n");
   fclose(fp);
}

//! @brief Write a flat binary from the lowest used address through the highest.
static void write_flat_binary(const char *path, const uint8_t *image, const uint8_t *used)
{
   FILE *fp;
   uint32_t first = 0;
   uint32_t last = 65535u;
   uint32_t addr;

   while (first < 65536u && !used[first])
      first++;
   while (last > first && !used[last])
      last--;
   if (first >= 65536u) {
      fprintf(stderr, "vcsc-ld: cannot write empty flat binary '%s'\n", path);
      exit(1);
   }

   fp = fopen(path, "wb");
   if (!fp) {
      fprintf(stderr, "vcsc-ld: cannot create '%s': %s\n", path, strerror(errno));
      exit(1);
   }

   for (addr = first; addr <= last; ++addr) {
      uint8_t byte = used[addr] ? image[addr] : 0xFFu;
      if (fwrite(&byte, 1, 1, fp) != 1) {
         fprintf(stderr, "vcsc-ld: write failed for '%s': %s\n", path, strerror(errno));
         fclose(fp);
         exit(1);
      }
   }

   if (fclose(fp) != 0) {
      fprintf(stderr, "vcsc-ld: close failed for '%s': %s\n", path, strerror(errno));
      exit(1);
   }
}

//! @brief Write map file using the on-disk format expected by linker layout and image writer.
static void write_map_file(const char *path, const linker_config_t *cfg, const input_set_t *in, const layout_t *layout)
{
   FILE *fp;
   size_t i;
   if (!path)
      return;
   fp = fopen(path, "w");
   if (!fp) {
      fprintf(stderr, "vcsc-ld: cannot create '%s': %s\n", path, strerror(errno));
      exit(1);
   }

   fprintf(fp, "MEMORY\n");
   for (i = 0; i < cfg->mem_count; ++i) {
      fprintf(fp, "  %-10s start=$%04X size=$%04X type=%s\n",
         cfg->mem[i].name, cfg->mem[i].start, cfg->mem[i].size, cfg->mem[i].type);
   }

   fprintf(fp, "\nOBJECTS\n");
   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *o = &in->objects[i];
      size_t j;
      fprintf(fp, "  %s\n", o->origin);
      for (j = 0; j < o->layout_count; ++j) {
         const object_layout_t *lay = &o->layouts[j];
         if (lay->segid == O26_SEG_TEXT) {
            fprintf(fp, "     %-16s load=$%04X size=$%04X\n", lay->name, lay->load_addr, lay->size);
         }
         else if (lay->segid == O26_SEG_DATA) {
            fprintf(fp, "     %-16s load=$%04X run=$%04X size=$%04X\n", lay->name, lay->load_addr, lay->run_addr, lay->size);
         }
         else {
            fprintf(fp, "     %-16s run=$%04X size=$%04X\n", lay->name, lay->run_addr, lay->size);
         }
      }
   }

   fprintf(fp, "\nTABLES\n");
   fprintf(fp, "  __copy_table  $%04X size=$%04X\n", layout->copy_table_addr, layout->copy_table_size);
   fprintf(fp, "  __zero_table  $%04X size=$%04X\n", layout->zero_table_addr, layout->zero_table_size);
   fprintf(fp, "  __init_table  $%04X size=$%04X\n", layout->init_table_addr, layout->init_table_size);
   fprintf(fp, "  __stack_start $%04X\n", layout->stack_start);
   fprintf(fp, "  __stack_top   $%04X\n", layout->stack_top);
   if (layout->call_stack_enabled) {
      fprintf(fp, "\nCALL STACK\n");
      fprintf(fp, "  region=%s depth=%u bytes=$%04X physical=$%04X-$%04X extra=$%04X\n",
              cfg->call_stack_region,
              (unsigned)layout->call_stack_depth,
              layout->call_stack_size,
              layout->call_stack_start,
              layout->call_stack_top,
              layout->call_stack_extra);
   }

   fprintf(fp, "\nSYMBOLS\n");
   for (i = 0; i < layout->global_count; ++i) {
      fprintf(fp, "  $%04X  %-20s  %s\n",
         layout->globals[i].addr, layout->globals[i].name, layout->globals[i].source);
   }

   fclose(fp);
}

//! @brief Entry point for the linker command; parses arguments, runs the requested pipeline, and returns process status.
int main(int argc, char **argv)
{
   int argi;
   int end_of_options = 0;
   int hex_path_set = 0;
   const char *cfg_path = NULL;
   const char *compat_hex_path = NULL;
   const char *hex_path = "a.hex";
   const char *map_path = NULL;
   linker_config_t cfg;
   input_set_t inputs;
   layout_t layout;
   uint8_t *image;
   uint8_t *used;
   size_t i;

   memset(&inputs, 0, sizeof(inputs));
   memset(&layout, 0, sizeof(layout));

   if (argc < 2) {
      usage(stderr);
      return 1;
   }

   for (argi = 1; argi < argc; ++argi) {
      const char *arg = argv[argi];

      if (!end_of_options && strcmp(arg, "--") == 0) {
         end_of_options = 1;
         continue;
      }

      if (!end_of_options && arg[0] == '-' && arg[1] != '\0') {
         if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            usage(stdout);
            return 0;
         }
         if (strcmp(arg, "-v") == 0 || strcmp(arg, "--version") == 0 || strcmp(arg, "-V") == 0) {
            puts(VERSION);
            return 0;
         }
         if (strcmp(arg, "-o") == 0) {
            if (++argi >= argc) {
               fprintf(stderr, "vcsc-ld: missing argument for -o\n");
               return 1;
            }
            hex_path = argv[argi];
            hex_path_set = 1;
            continue;
         }
         if (strncmp(arg, "-o", 2) == 0 && arg[2] != '\0') {
            hex_path = arg + 2;
            hex_path_set = 1;
            continue;
         }
         if (strcmp(arg, "-T") == 0) {
            if (++argi >= argc) {
               fprintf(stderr, "vcsc-ld: missing argument for -T\n");
               return 1;
            }
            cfg_path = argv[argi];
            continue;
         }
         if (strncmp(arg, "-T", 2) == 0 && arg[2] != '\0') {
            cfg_path = arg + 2;
            continue;
         }
         if (strcmp(arg, "--script") == 0) {
            if (++argi >= argc) {
               fprintf(stderr, "vcsc-ld: missing argument for --script\n");
               return 1;
            }
            cfg_path = argv[argi];
            continue;
         }
         if (strncmp(arg, "--script=", 9) == 0) {
            cfg_path = arg + 9;
            continue;
         }
         if (strcmp(arg, "-Map") == 0) {
            if (++argi >= argc) {
               fprintf(stderr, "vcsc-ld: missing argument for -Map\n");
               return 1;
            }
            map_path = argv[argi];
            continue;
         }
         if (strncmp(arg, "-Map=", 5) == 0) {
            map_path = arg + 5;
            continue;
         }

         fprintf(stderr, "vcsc-ld: unsupported option '%s'\n", arg);
         return 1;
      }

      if (ends_with(arg, ".cfg") && cfg_path == NULL) {
         cfg_path = arg;
         continue;
      }

      if (ends_with(arg, ".o26")) {
         inputs.cmd_objects = (object_file_t *)xrealloc(inputs.cmd_objects,
            (inputs.cmd_object_count + 1) * sizeof(*inputs.cmd_objects));
         load_object(arg, &inputs.cmd_objects[inputs.cmd_object_count]);
         inputs.cmd_objects[inputs.cmd_object_count].from_cmdline = 1;
         inputs.order = (input_ref_t *)xrealloc(inputs.order,
            (inputs.order_count + 1) * sizeof(*inputs.order));
         inputs.order[inputs.order_count].kind = INPUT_REF_OBJECT;
         inputs.order[inputs.order_count].index = inputs.cmd_object_count;
         inputs.order_count++;
         inputs.cmd_object_count++;
         continue;
      }

      if (ends_with(arg, ".l26")) {
         inputs.archives = (archive_file_t *)xrealloc(inputs.archives,
            (inputs.archive_count + 1) * sizeof(*inputs.archives));
         load_archive(arg, &inputs.archives[inputs.archive_count]);
         inputs.order = (input_ref_t *)xrealloc(inputs.order,
            (inputs.order_count + 1) * sizeof(*inputs.order));
         inputs.order[inputs.order_count].kind = INPUT_REF_ARCHIVE;
         inputs.order[inputs.order_count].index = inputs.archive_count;
         inputs.order_count++;
         inputs.archive_count++;
         continue;
      }

      if (!hex_path_set && compat_hex_path == NULL &&
          (ends_with(arg, ".hex") || ends_with(arg, ".bin"))) {
         compat_hex_path = arg;
         continue;
      }

      if (compat_hex_path != NULL && map_path == NULL) {
         map_path = arg;
         continue;
      }

      fprintf(stderr, "vcsc-ld: cannot classify input '%s'\n", arg);
      return 1;
   }

   if (compat_hex_path != NULL)
      hex_path = compat_hex_path;

   if (inputs.cmd_object_count == 0 && inputs.archive_count == 0) {
      fprintf(stderr, "vcsc-ld: no input objects or archives\n");
      return 1;
   }

   if (!cfg_path) {
      fprintf(stderr,
         "vcsc-ld: no linker script/config supplied; use -T FILE or --script=FILE\n");
      return 1;
   }
   parse_cfg_file(&cfg, cfg_path);

   select_needed_objects(&inputs);
   validate_abi_metadata(&inputs);
   validate_mem_region_metadata(&cfg, &inputs);
   {
      uint16_t call_depth = enforce_symbol_backed_call_graph(&inputs);
      size_t init_count = count_init_functions_in_input(&inputs);
      reserve_call_stack_from_call_graph(&cfg, call_depth, init_count);
   }
   warn_unused_cmdline_objects(&inputs);
   layout_objects(&cfg, &inputs, &layout);
   add_generated_symbols(&layout);
   resolve_all(&inputs, &layout);

   image = (uint8_t *)xmalloc(65536);
   used = (uint8_t *)xmalloc(65536);
   build_rom_image(&cfg, &inputs, &layout, image, used);
   if (ends_with(hex_path, ".bin"))
      write_flat_binary(hex_path, image, used);
   else
      write_intel_hex(hex_path, image, used);
   write_map_file(map_path, &cfg, &inputs, &layout);

   free(image);
   free(used);

   for (i = 0; i < inputs.object_count; ++i)
      free_object(&inputs.objects[i]);
   free(inputs.objects);
   free(inputs.cmd_objects);
   free(inputs.order);
   free(inputs.archives);
   for (i = 0; i < layout.global_count; ++i)
      free(layout.globals[i].name);
   free(layout.globals);
   for (i = 0; i < layout.copy_record_count; ++i)
      free(layout.copy_records[i].name);
   free(layout.copy_records);
   for (i = 0; i < layout.zero_record_count; ++i)
      free(layout.zero_records[i].name);
   free(layout.zero_records);
   free(layout.cursors);

   return 0;
}
