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

/* One identical six-byte BIT/JMP entry for NMI, RESET, and IRQ/BRK. */
enum {
   VECTOR_BRIDGE_ENTRY_SIZE = 6,
   VECTOR_BRIDGE_NMI_OFFSET = 0,
   VECTOR_BRIDGE_RESET_OFFSET = VECTOR_BRIDGE_ENTRY_SIZE,
   VECTOR_BRIDGE_IRQBRK_OFFSET = 2 * VECTOR_BRIDGE_ENTRY_SIZE,
   VECTOR_BRIDGE_SIZE = 3 * VECTOR_BRIDGE_ENTRY_SIZE,
   BANK_TRAMPOLINE_JMP = 1,
   BANK_TRAMPOLINE_JSR = 2,
   BANK_JMP_ENTRY_SIZE = 8,
   BANK_JSR_ENTRY_SIZE = 15
};

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
      "  --map=FILE           Same as -Map FILE\n"
      "  -Sym FILE            Write Stella/DASM symbol file to FILE\n"
      "  -Sym=FILE            Same as -Sym FILE\n"
      "  --sym=FILE           Same as -Sym FILE\n"
      "  -List FILE           Write Stella/DASM list file to FILE\n"
      "  -List=FILE           Same as -List FILE\n"
      "  --list=FILE          Same as -List FILE\n"
      "  -Cfg FILE            Write Stella/DiStella config file to FILE\n"
      "  -Cfg=FILE            Same as -Cfg FILE\n"
      "  --cfg=FILE           Same as -Cfg FILE\n"
      "  --no-map             Do not write the default linker map\n"
      "  --no-sym             Do not write the default Stella symbol file\n"
      "  --no-list            Do not write the default Stella list file\n"
      "  --no-cfg             Do not write the default Stella config file\n"
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

//! One optional linker sidecar output, either default-named, explicitly named, or disabled.
typedef struct {
   const char *path;
   int enabled;
   int explicit_path;
   char *owned_default;
} sidecar_option_t;

//! @brief Derive a same-stem sidecar path from the primary linker output.
static char *sidecar_path_from_output(const char *output, const char *suffix)
{
   const char *slash = strrchr(output, '/');
   const char *base = slash ? slash + 1 : output;
   const char *dot = strrchr(base, '.');
   size_t stem_len = dot ? (size_t)(dot - output) : strlen(output);
   size_t suffix_len = strlen(suffix);
   char *path = (char *)xmalloc(stem_len + suffix_len + 1);

   memcpy(path, output, stem_len);
   memcpy(path + stem_len, suffix, suffix_len + 1);
   return path;
}

//! @brief Finish one sidecar option by deriving its default path when enabled.
static void finalize_sidecar_option(sidecar_option_t *option,
                                    const char *output,
                                    const char *suffix)
{
   if (!option->enabled || option->path)
      return;
   option->owned_default = sidecar_path_from_output(output, suffix);
   option->path = option->owned_default;
}

//! @brief Set an explicitly named sidecar output, re-enabling it after --no-*.
static void set_sidecar_path(sidecar_option_t *option, const char *path)
{
   option->path = path;
   option->enabled = 1;
   option->explicit_path = 1;
}

//! @brief Disable one sidecar output, allowing a later explicit name to re-enable it.
static void disable_sidecar(sidecar_option_t *option)
{
   option->path = NULL;
   option->enabled = 0;
   option->explicit_path = 0;
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
   return name &&
      (strncmp(name, MEM_REGION_META_PREFIX, sizeof(MEM_REGION_META_PREFIX) - 1) == 0 ||
       strncmp(name, MEM_REGION_SPLIT_META_PREFIX, sizeof(MEM_REGION_SPLIT_META_PREFIX) - 1) == 0);
}

//! @brief Return whether declaration-contract metadata has its reserved prefix.
static int contract_metadata_has_prefix(const char *name)
{
   return name && strncmp(name, CONTRACT_META_PREFIX, sizeof(CONTRACT_META_PREFIX) - 1) == 0;
}

//! @brief Return whether semantic-use metadata has its reserved prefix.
static int semantic_use_metadata_has_prefix(const char *name)
{
   return name && strncmp(name, SEMANTIC_USE_META_PREFIX, sizeof(SEMANTIC_USE_META_PREFIX) - 1) == 0;
}

//! @brief Return whether reserved metadata has prefix in linker layout and image writer.
static int reserved_metadata_has_prefix(const char *name)
{
   return symbol_backed_metadata_has_prefix(name) || abi_metadata_has_prefix(name) ||
          mem_region_metadata_has_prefix(name) || contract_metadata_has_prefix(name) ||
          semantic_use_metadata_has_prefix(name);
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
      uint16_t *read_start, uint16_t *write_start, int *has_write_start,
      uint16_t *size, char *type, size_t type_size)
{
   const char *p;
   const char *first_mark;
   const char *wmark = NULL;
   const char *zmark;
   const char *tmark;
   size_t region_len;
   size_t type_len;
   int split;

   if (!mem_region_metadata_has_prefix(name))
      return 0;

   split = strncmp(name, MEM_REGION_SPLIT_META_PREFIX,
                   sizeof(MEM_REGION_SPLIT_META_PREFIX) - 1) == 0;
   p = name + (split ? sizeof(MEM_REGION_SPLIT_META_PREFIX) - 1
                     : sizeof(MEM_REGION_META_PREFIX) - 1);
   first_mark = strstr(p, split ? "$R" : "$S");
   if (!first_mark || first_mark == p)
      return 0;
   region_len = (size_t)(first_mark - p);
   if (region_len >= region_size)
      return 0;
   memcpy(region, p, region_len);
   region[region_len] = '\0';

   if (!parse_hex4(first_mark + 2, read_start))
      return 0;
   if (split) {
      wmark = first_mark + 6;
      if (strncmp(wmark, "$W", 2) != 0 || !parse_hex4(wmark + 2, write_start))
         return 0;
      zmark = wmark + 6;
   }
   else {
      *write_start = *read_start;
      zmark = first_mark + 6;
   }
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
   *has_write_start = split;
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
         uint16_t declared_read_start;
         uint16_t declared_write_start;
         int declared_split;
         uint16_t declared_size;
         const memory_region_t *mem;

         if (!mem_region_metadata_has_prefix(sym))
            continue;
         if (!mem_region_metadata_parse(sym, region, sizeof(region),
                                        &declared_read_start, &declared_write_start,
                                        &declared_split, &declared_size,
                                        type, sizeof(type))) {
            fprintf(stderr, "vcsc-ld: malformed mem-region metadata symbol '%s' in %s\n",
                  sym, obj->origin);
            exit(1);
         }

         mem = find_memory(cfg, region);
         if (!mem) {
            fprintf(stderr,
                  "vcsc-ld: mem region '%s' declared by %s is not present in linker cfg MEMORY. "
                  "Add a MEMORY entry named '%s' or change the VCSC source mem declaration so they match.\n",
                  region, obj->origin, region);
            exit(1);
         }

         if (mem->start != declared_read_start) {
            if (declared_split) {
               fprintf(stderr,
                     "vcsc-ld: mem region '%s' read_start mismatch in %s: compiler mem declaration says $%04X "
                     "but linker cfg MEMORY %s starts at $%04X. Update the VCSC source mem declaration or the linker cfg so they match.\n",
                     region, obj->origin, declared_read_start, mem->name, mem->start);
            }
            else {
               fprintf(stderr,
                     "vcsc-ld: mem region '%s' start mismatch in %s: compiler mem declaration says $%04X "
                     "but linker cfg MEMORY %s starts at $%04X. Update the VCSC source mem declaration or the linker cfg so they match.\n",
                     region, obj->origin, declared_read_start, mem->name, mem->start);
            }
            exit(1);
         }
         if (declared_split != mem->has_write_start ||
             (declared_split && mem->write_start != declared_write_start)) {
            fprintf(stderr,
                  "vcsc-ld: mem region '%s' write-alias mismatch in %s: compiler mem declaration says %s$%04X "
                  "but linker cfg MEMORY %s says %s$%04X. Update the VCSC source mem declaration or linker cfg so both aliases match.\n",
                  region, obj->origin, declared_split ? "" : "no alias / ",
                  declared_write_start, mem->name, mem->has_write_start ? "" : "no alias / ",
                  mem->write_start);
            exit(1);
         }
         if (mem->size != declared_size) {
            fprintf(stderr,
                  "vcsc-ld: mem region '%s' size mismatch in %s: compiler mem declaration says $%04X "
                  "but linker cfg MEMORY %s has size $%04X. Update the VCSC source mem declaration or the linker cfg so they match.\n",
                  region, obj->origin, declared_size, mem->name, mem->size);
            exit(1);
         }
         if (!str_ieq(mem->type, type)) {
            fprintf(stderr,
                  "vcsc-ld: mem region '%s' type mismatch in %s: compiler mem declaration says %s "
                  "but linker cfg MEMORY %s has type %s. Update the VCSC source mem declaration or the linker cfg so they match.\n",
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


//! @brief Find the linker rule governing a private compiler-owned subsegment.
static const segment_rule_t *find_layout_segment_rule(const linker_config_t *cfg,
                                                       const char *name,
                                                       const segment_rule_t *fallback)
{
   const segment_rule_t *rule = find_segment_rule(cfg, name);
   static const char *const private_suffixes[] = {
      ".__vcsc_function$", ".__vcsc_object$", ".__vcsc_page$", NULL
   };
   char base[MAX_NAME];
   const char *dot;
   size_t n;

   if (rule || !name)
      return rule ? rule : fallback;

   /* Compiler-owned private layouts retain the source segment before their
      metadata suffix. Prefer the longest named segment rule so CODE.bank1
      governs CODE.bank1.__vcsc_function$foo rather than falling back to CODE. */
   for (size_t i = 0; private_suffixes[i]; ++i) {
      const char *suffix = strstr(name, private_suffixes[i]);
      if (!suffix)
         continue;
      n = (size_t)(suffix - name);
      if (n == 0 || n >= sizeof(base))
         break;
      memcpy(base, name, n);
      base[n] = '\0';
      rule = find_segment_rule(cfg, base);
      if (rule)
         return rule;
      break;
   }

   dot = strchr(name, '.');
   n = dot ? (size_t)(dot - name) : strlen(name);
   if (n == 0 || n >= sizeof(base))
      return fallback;
   memcpy(base, name, n);
   base[n] = '\0';
   rule = find_segment_rule(cfg, base);
   return rule ? rule : fallback;
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

//! @brief Parse yes/no into a configuration boolean.
static int parse_yes_no(const char *key, const char *value)
{
   value = trim((char *)value);
   if (str_ieq(value, "yes"))
      return 1;
   if (str_ieq(value, "no"))
      return 0;
   fprintf(stderr, "vcsc-ld: bad %s value '%s'; expected yes or no\n", key, value);
   exit(1);
}

//! @brief Parse a bounded numeric configuration property.
static uint16_t parse_u16_property(const char *kind, const char *value,
                                   uint32_t minimum, uint32_t maximum)
{
   parse_result_t n = parse_number(value);
   if (!n.ok || n.pos != strlen(trim((char *)value)) ||
       n.value < minimum || n.value > maximum) {
      fprintf(stderr, "vcsc-ld: bad %s '%s'\n", kind, value);
      exit(1);
   }
   return (uint16_t)n.value;
}

//! @brief Append one zeroed MEMORY entry to a dynamically sized config.
static memory_region_t *append_memory_region(linker_config_t *cfg)
{
   cfg->mem = (memory_region_t *)xrealloc(
      cfg->mem, (cfg->mem_count + 1) * sizeof(*cfg->mem));
   memset(&cfg->mem[cfg->mem_count], 0, sizeof(*cfg->mem));
   return &cfg->mem[cfg->mem_count++];
}

//! @brief Append one zeroed SEGMENTS entry to a dynamically sized config.
static segment_rule_t *append_segment_rule(linker_config_t *cfg)
{
   cfg->seg = (segment_rule_t *)xrealloc(
      cfg->seg, (cfg->seg_count + 1) * sizeof(*cfg->seg));
   memset(&cfg->seg[cfg->seg_count], 0, sizeof(*cfg->seg));
   return &cfg->seg[cfg->seg_count++];
}

//! @brief Append one zeroed BANKS entry to a dynamically sized config.
static cartridge_bank_t *append_cartridge_bank(linker_config_t *cfg)
{
   cfg->banks = (cartridge_bank_t *)xrealloc(
      cfg->banks, (cfg->bank_count + 1) * sizeof(*cfg->banks));
   memset(&cfg->banks[cfg->bank_count], 0, sizeof(*cfg->banks));
   return &cfg->banks[cfg->bank_count++];
}

//! @brief Parse memory property into the normalized representation used by linker layout and image writer.
static void parse_memory_property(memory_region_t *mem, const char *key, const char *value)
{
   parse_result_t n;
   value = trim((char *)value);
   if (str_ieq(key, "start") || str_ieq(key, "read_start")) {
      mem->start = parse_u16_property("memory read/start", value, 0, 0xFFFFu);
   } else if (str_ieq(key, "write_start")) {
      mem->write_start = parse_u16_property("memory write_start", value, 0, 0xFFFFu);
      mem->has_write_start = 1;
   } else if (str_ieq(key, "size")) {
      mem->size = parse_u16_property("memory size", value, 1, 0xFFFFu);
   } else if (str_ieq(key, "type")) {
      snprintf(mem->type, sizeof(mem->type), "%s", value);
   } else if (str_ieq(key, "define")) {
      mem->define_yes = parse_yes_no("memory define", value);
   } else if (str_ieq(key, "callstack")) {
      if (str_ieq(value, "callgraph")) {
         mem->callstack_callgraph = 1;
      } else if (str_ieq(value, "no")) {
         mem->callstack_callgraph = 0;
      } else {
         fprintf(stderr, "vcsc-ld: bad memory callstack mode '%s'; expected callgraph or no\n", value);
         exit(1);
      }
   } else if (str_ieq(key, "callstack_extra")) {
      mem->callstack_extra =
         parse_u16_property("memory callstack_extra", value, 0, 0xFFFFu);
   } else if (str_ieq(key, "file")) {
      snprintf(mem->file, sizeof(mem->file), "%s", value);
   } else if (str_ieq(key, "fill")) {
      mem->fill_yes = parse_yes_no("memory fill", value);
   } else if (str_ieq(key, "fillval")) {
      n = parse_number(value);
      if (!n.ok || n.pos != strlen(value) || n.value > 0xFFu) {
         fprintf(stderr, "vcsc-ld: bad memory fillval '%s'\n", value);
         exit(1);
      }
      mem->fill_value = (uint8_t)n.value;
      mem->has_fill_value = 1;
   } else if (str_ieq(key, "bank")) {
      snprintf(mem->bank_name, sizeof(mem->bank_name), "%s", value);
   } else {
      fprintf(stderr, "vcsc-ld: unknown MEMORY property '%s'\n", key);
      exit(1);
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
      seg->define_yes = parse_yes_no("segment define", value);
   } else if (str_ieq(key, "align")) {
      parse_result_t n = parse_number(value);
      if (!n.ok || n.pos != strlen(value) || n.value == 0 || n.value > 0x8000u ||
          (n.value & (n.value - 1u)) != 0) {
         fprintf(stderr, "vcsc-ld: bad segment alignment '%s'; expected a power of two from 1 through $8000\n", value);
         exit(1);
      }
      seg->align = (uint16_t)n.value;
   } else if (str_ieq(key, "start")) {
      seg->start = parse_u16_property("segment start", value, 0, 0xFFFFu);
      seg->has_start = 1;
   } else {
      fprintf(stderr, "vcsc-ld: unknown SEGMENTS property '%s'\n", key);
      exit(1);
   }
}

//! @brief Parse one CARTRIDGE property.
static void parse_cartridge_property(linker_config_t *cfg,
                                     const char *key, const char *value)
{
   parse_result_t n;
   value = trim((char *)value);
   if (str_ieq(key, "mapper")) {
      snprintf(cfg->mapper, sizeof(cfg->mapper), "%s", value);
   } else if (str_ieq(key, "fillval")) {
      n = parse_number(value);
      if (!n.ok || n.pos != strlen(value) || n.value > 0xFFu) {
         fprintf(stderr, "vcsc-ld: bad cartridge fillval '%s'\n", value);
         exit(1);
      }
      cfg->cartridge_fill_value = (uint8_t)n.value;
   } else if (str_ieq(key, "vectorbridge")) {
      cfg->vector_bridge_offset =
         parse_u16_property("cartridge vectorbridge", value, 0, 0x0FFFu);
      cfg->has_vector_bridge_offset = 1;
   } else if (str_ieq(key, "trampoline")) {
      cfg->trampoline_offset =
         parse_u16_property("cartridge trampoline", value, 0, 0x0FFFu);
      cfg->has_trampoline_offset = 1;
   } else if (str_ieq(key, "trampolinesize")) {
      cfg->trampoline_size =
         parse_u16_property("cartridge trampolinesize", value, 1, 0x1000u);
      cfg->has_trampoline_size = 1;
   } else {
      fprintf(stderr, "vcsc-ld: unknown CARTRIDGE property '%s'\n", key);
      exit(1);
   }
}

//! @brief Parse one BANKS property.
static void parse_bank_property(cartridge_bank_t *bank,
                                const char *key, const char *value)
{
   value = trim((char *)value);
   if (str_ieq(key, "start")) {
      bank->start = parse_u16_property("bank start", value, 0, 0xFFFFu);
   } else if (str_ieq(key, "size")) {
      bank->size = parse_u16_property("bank size", value, 1, 0xFFFFu);
   } else if (str_ieq(key, "hotspot")) {
      bank->hotspot = parse_u16_property("bank hotspot", value, 0, 0xFFFFu);
   } else if (str_ieq(key, "startup")) {
      bank->startup = parse_yes_no("bank startup", value);
   } else {
      fprintf(stderr, "vcsc-ld: unknown BANKS property '%s'\n", key);
      exit(1);
   }
}

//! @brief Parse comma-separated key/value properties for one configuration entry.
static void parse_property_list(linker_config_t *cfg, int block,
                                void *entry, char *properties)
{
   char *tok = strtok(properties, ",");
   while (tok) {
      char *eq = strchr(tok, '=');
      char *key;
      char *value;
      if (!eq) {
         fprintf(stderr, "vcsc-ld: malformed configuration property '%s'; expected key=value\n",
                 trim(tok));
         exit(1);
      }
      *eq++ = '\0';
      key = trim(tok);
      value = trim(eq);
      if (*key == '\0' || *value == '\0') {
         fprintf(stderr, "vcsc-ld: malformed empty configuration property\n");
         exit(1);
      }
      if (block == 1)
         parse_cartridge_property(cfg, key, value);
      else if (block == 2)
         parse_bank_property((cartridge_bank_t *)entry, key, value);
      else if (block == 3)
         parse_memory_property((memory_region_t *)entry, key, value);
      else
         parse_segment_property((segment_rule_t *)entry, key, value);
      tok = strtok(NULL, ",");
   }
}

//! @brief Find a configured cartridge bank by name.
static const cartridge_bank_t *find_cartridge_bank(const linker_config_t *cfg,
                                                    const char *name)
{
   size_t i;
   if (!cfg || !name)
      return NULL;
   for (i = 0; i < cfg->bank_count; ++i) {
      if (str_ieq(cfg->banks[i].name, name))
         return &cfg->banks[i];
   }
   return NULL;
}

//! @brief Return whether one segment rule may place ordinary code/data bytes.
static int segment_rule_is_ordinary_allocatable(const segment_rule_t *seg)
{
   if (!seg)
      return 0;
   if (str_ieq(seg->name, "VECTORS"))
      return 0;
   return str_ieq(seg->type, "ro") || str_ieq(seg->type, "data");
}

//! @brief Validate one fully parsed linker configuration.
static void validate_linker_config(linker_config_t *cfg)
{
   size_t i;
   size_t j;
   size_t startup_count = 0;

   for (i = 0; i < cfg->mem_count; ++i) {
      memory_region_t *mem = &cfg->mem[i];
      uint32_t end = (uint32_t)mem->start + mem->size;
      mem->physical_size = mem->size;
      if (!mem->name[0] || mem->size == 0) {
         fprintf(stderr, "vcsc-ld: incomplete MEMORY entry '%s' start=$%04X size=$%04X type='%s'\n",
                 mem->name[0] ? mem->name : "<unnamed>", mem->start, mem->size, mem->type);
         exit(1);
      }
      if (end > 0x10000u ||
          (mem->has_write_start && (uint32_t)mem->write_start + mem->size > 0x10000u)) {
         fprintf(stderr, "vcsc-ld: MEMORY region '%s' read/write aliases extend beyond address space\n",
                 mem->name);
         exit(1);
      }
      if (mem->has_write_start && !str_ieq(mem->type, "rw")) {
         fprintf(stderr, "vcsc-ld: MEMORY region '%s' uses write_start but is not type=rw\n",
                 mem->name);
         exit(1);
      }
      if (mem->has_write_start && mem->bank_name[0]) {
         fprintf(stderr,
                 "vcsc-ld: split-address MEMORY region '%s' must be shared and may not specify bank=%s\n",
                 mem->name, mem->bank_name);
         exit(1);
      }
      if (mem->callstack_extra && !mem->callstack_callgraph) {
         fprintf(stderr,
            "vcsc-ld: MEMORY region '%s' sets callstack_extra but does not request callstack=callgraph\n",
            mem->name);
         exit(1);
      }
      for (j = i + 1; j < cfg->mem_count; ++j) {
         if (str_ieq(mem->name, cfg->mem[j].name)) {
            fprintf(stderr, "vcsc-ld: duplicate MEMORY region '%s'\n", mem->name);
            exit(1);
         }
      }
   }

   for (i = 0; i < cfg->seg_count; ++i) {
      segment_rule_t *seg = &cfg->seg[i];
      if (!seg->name[0] || !seg->load_name[0] || !seg->type[0]) {
         fprintf(stderr, "vcsc-ld: incomplete SEGMENTS entry '%s'\n",
                 seg->name[0] ? seg->name : "<unnamed>");
         exit(1);
      }
      if (!find_memory(cfg, seg->load_name)) {
         fprintf(stderr, "vcsc-ld: SEGMENTS entry '%s' names unknown load region '%s'\n",
                 seg->name, seg->load_name);
         exit(1);
      }
      if (seg->run_name[0] && !find_memory(cfg, seg->run_name)) {
         fprintf(stderr, "vcsc-ld: SEGMENTS entry '%s' names unknown run region '%s'\n",
                 seg->name, seg->run_name);
         exit(1);
      }
      for (j = i + 1; j < cfg->seg_count; ++j) {
         if (str_ieq(seg->name, cfg->seg[j].name)) {
            fprintf(stderr, "vcsc-ld: duplicate SEGMENTS entry '%s'\n", seg->name);
            exit(1);
         }
      }
   }

   if (cfg->bank_count == 0) {
      if (cfg->mapper[0]) {
         fprintf(stderr, "vcsc-ld: CARTRIDGE mapper requires a BANKS block\n");
         exit(1);
      }
      cfg->cartridge_banked = 0;
      return;
   }

   cfg->cartridge_banked = 1;
   if (!cfg->mapper[0]) {
      fprintf(stderr, "vcsc-ld: banked configuration requires CARTRIDGE mapper\n");
      exit(1);
   }
   if (!cfg->has_vector_bridge_offset) {
      fprintf(stderr,
              "vcsc-ld: banked configuration requires CARTRIDGE vectorbridge\n");
      exit(1);
   }
   if (!cfg->has_trampoline_offset || !cfg->has_trampoline_size) {
      fprintf(stderr,
              "vcsc-ld: banked configuration requires CARTRIDGE trampoline and trampolinesize\n");
      exit(1);
   }
   if ((uint32_t)cfg->trampoline_offset + cfg->trampoline_size > 0x1000u) {
      fprintf(stderr,
              "vcsc-ld: CARTRIDGE trampoline $%03X plus $%03X bytes exceeds one 4K bank\n",
              cfg->trampoline_offset, cfg->trampoline_size);
      exit(1);
   }
   if ((uint32_t)cfg->trampoline_offset + cfg->trampoline_size > 0x0FFAu) {
      fprintf(stderr,
              "vcsc-ld: CARTRIDGE trampoline $%03X plus $%03X bytes overlaps the per-bank vectors\n",
              cfg->trampoline_offset, cfg->trampoline_size);
      exit(1);
   }
   if ((uint32_t)cfg->trampoline_offset + cfg->trampoline_size > cfg->vector_bridge_offset &&
       (uint32_t)cfg->vector_bridge_offset + VECTOR_BRIDGE_SIZE > cfg->trampoline_offset) {
      fprintf(stderr,
              "vcsc-ld: CARTRIDGE trampoline $%03X-$%03X overlaps vectorbridge $%03X-$%03X\n",
              cfg->trampoline_offset,
              (uint16_t)(cfg->trampoline_offset + cfg->trampoline_size - 1u),
              cfg->vector_bridge_offset,
              (uint16_t)(cfg->vector_bridge_offset + VECTOR_BRIDGE_SIZE - 1u));
      exit(1);
   }
   if ((uint32_t)cfg->vector_bridge_offset + VECTOR_BRIDGE_SIZE > 0x0FFAu) {
      fprintf(stderr,
              "vcsc-ld: CARTRIDGE vectorbridge $%03X plus %u bytes overlaps the per-bank vectors\n",
              cfg->vector_bridge_offset, VECTOR_BRIDGE_SIZE);
      exit(1);
   }

   for (i = 0; i < cfg->bank_count; ++i) {
      cartridge_bank_t *bank = &cfg->banks[i];
      uint32_t end = (uint32_t)bank->start + bank->size;
      if (!bank->name[0] || bank->size != 0x1000u ||
          (bank->start & 0x0fffu) != 0 || end > 0x10000u) {
         fprintf(stderr,
                 "vcsc-ld: BANKS entry '%s' must describe one aligned 4K logical bank\n",
                 bank->name[0] ? bank->name : "<unnamed>");
         exit(1);
      }
      if (bank->hotspot < 0x1000u || bank->hotspot > 0x1fffu) {
         fprintf(stderr,
                 "vcsc-ld: BANKS entry '%s' hotspot $%04X is outside $1000-$1FFF\n",
                 bank->name, bank->hotspot);
         exit(1);
      }
      if (bank->startup)
         startup_count++;
      for (j = i + 1; j < cfg->bank_count; ++j) {
         cartridge_bank_t *other = &cfg->banks[j];
         uint32_t other_end = (uint32_t)other->start + other->size;
         if (str_ieq(bank->name, other->name)) {
            fprintf(stderr, "vcsc-ld: duplicate BANKS entry '%s'\n", bank->name);
            exit(1);
         }
         if (bank->start < other_end && other->start < end) {
            fprintf(stderr, "vcsc-ld: logical cartridge banks '%s' and '%s' overlap\n",
                    bank->name, other->name);
            exit(1);
         }
         if (bank->hotspot == other->hotspot) {
            fprintf(stderr, "vcsc-ld: duplicate bank hotspot $%04X for '%s' and '%s'\n",
                    bank->hotspot, bank->name, other->name);
            exit(1);
         }
      }
   }
   if (startup_count != 1) {
      fprintf(stderr, "vcsc-ld: banked configuration must mark exactly one BANKS entry startup=yes\n");
      exit(1);
   }

   {
      size_t expected_count = 0;
      uint16_t first_file_hotspot = 0;
      int superchip_mapper = 0;
      if (str_ieq(cfg->mapper, "F8") || str_ieq(cfg->mapper, "F8SC")) {
         expected_count = 2;
         first_file_hotspot = 0x1FF8u;
         superchip_mapper = str_ieq(cfg->mapper, "F8SC");
      } else if (str_ieq(cfg->mapper, "F6") || str_ieq(cfg->mapper, "F6SC")) {
         expected_count = 4;
         first_file_hotspot = 0x1FF6u;
         superchip_mapper = str_ieq(cfg->mapper, "F6SC");
      } else if (str_ieq(cfg->mapper, "F4") || str_ieq(cfg->mapper, "F4SC")) {
         expected_count = 8;
         first_file_hotspot = 0x1FF4u;
         superchip_mapper = str_ieq(cfg->mapper, "F4SC");
      } else {
         fprintf(stderr,
                 "vcsc-ld: unsupported full-window mapper '%s'; expected F8/F6/F4 or an SC variant\n",
                 cfg->mapper);
         exit(1);
      }
      if (cfg->bank_count != expected_count) {
         fprintf(stderr, "vcsc-ld: mapper %s requires %zu banks, found %zu\n",
                 cfg->mapper, expected_count, cfg->bank_count);
         exit(1);
      }
      for (i = 0; i < expected_count; ++i) {
         const cartridge_bank_t *bank = NULL;
         size_t j;
         size_t file_index = i;
         uint16_t expected_start = (uint16_t)(0xF000u -
            (uint16_t)((expected_count - 1u - file_index) * 0x2000u));
         uint16_t expected_hotspot =
            (uint16_t)(first_file_hotspot + (uint16_t)file_index);

         /* Bank names are policy-free labels.  Physical/file order is the
            ascending logical-address order used by write_flat_binary(), and
            mapper selector hotspots increase with that file index. */
         for (j = 0; j < cfg->bank_count; ++j) {
            if (cfg->banks[j].start == expected_start) {
               bank = &cfg->banks[j];
               break;
            }
         }
         if (!bank) {
            fprintf(stderr,
                    "vcsc-ld: mapper %s is missing its physical/file chunk %zu logical bank at $%04X\n",
                    cfg->mapper, file_index, expected_start);
            exit(1);
         }
         if (bank->hotspot != expected_hotspot) {
            fprintf(stderr,
                    "vcsc-ld: %s (physical/file chunk %zu) must use %s selector hotspot $%04X\n",
                    bank->name, file_index, cfg->mapper, expected_hotspot);
            exit(1);
         }
      }

      if (superchip_mapper) {
         for (i = 0; i < cfg->mem_count; ++i) {
            const memory_region_t *region = &cfg->mem[i];
            const cartridge_bank_t *bank;
            uint32_t end;
            if (!region->bank_name[0] || !str_ieq(region->type, "ro"))
               continue;
            bank = find_cartridge_bank(cfg, region->bank_name);
            if (!bank)
               continue;
            end = (uint32_t)region->start + region->size;
            if (region->start < (uint16_t)(bank->start + 0x0100u) &&
                end > bank->start) {
               fprintf(stderr,
                       "vcsc-ld: %s read-only region '%s' overlaps the Superchip RAM-port prefix $%04X-$%04X\n",
                       cfg->mapper, region->name, bank->start,
                       (uint16_t)(bank->start + 0x00FFu));
               exit(1);
            }
         }
      }
   }

   for (i = 0; i < cfg->bank_count; ++i) {
      uint16_t selector_offset = (uint16_t)(cfg->banks[i].hotspot & 0x0FFFu);
      if (selector_offset >= cfg->vector_bridge_offset &&
          selector_offset < (uint16_t)(cfg->vector_bridge_offset + VECTOR_BRIDGE_SIZE)) {
         fprintf(stderr,
                 "vcsc-ld: CARTRIDGE vectorbridge $%03X overlaps %s selector hotspot $%04X\n",
                 cfg->vector_bridge_offset, cfg->banks[i].name,
                 cfg->banks[i].hotspot);
         exit(1);
      }
      if (selector_offset >= cfg->trampoline_offset &&
          selector_offset < (uint16_t)(cfg->trampoline_offset + cfg->trampoline_size)) {
         fprintf(stderr,
                 "vcsc-ld: CARTRIDGE trampoline $%03X-$%03X overlaps %s selector hotspot $%04X\n",
                 cfg->trampoline_offset,
                 (uint16_t)(cfg->trampoline_offset + cfg->trampoline_size - 1u),
                 cfg->banks[i].name, cfg->banks[i].hotspot);
         exit(1);
      }
   }

   for (i = 0; i < cfg->mem_count; ++i) {
      memory_region_t *mem = &cfg->mem[i];
      const cartridge_bank_t *bank;
      uint32_t mem_end;
      if (!mem->bank_name[0]) {
         int cartridge_output = str_ieq(mem->type, "ro");
         for (j = 0; j < cfg->seg_count; ++j) {
            if (str_ieq(cfg->seg[j].load_name, mem->name) &&
                (str_ieq(cfg->seg[j].type, "ro") ||
                 str_ieq(cfg->seg[j].type, "data"))) {
               cartridge_output = 1;
               break;
            }
         }
         if (cartridge_output) {
            fprintf(stderr,
                    "vcsc-ld: banked cartridge MEMORY region '%s' must name bank=...\n",
                    mem->name);
            exit(1);
         }
         continue;
      }
      bank = find_cartridge_bank(cfg, mem->bank_name);
      if (!bank) {
         fprintf(stderr, "vcsc-ld: MEMORY region '%s' names unknown bank '%s'\n",
                 mem->name, mem->bank_name);
         exit(1);
      }
      mem_end = (uint32_t)mem->start + mem->size;
      if (mem->start < bank->start ||
          mem_end > (uint32_t)bank->start + bank->size) {
         fprintf(stderr,
                 "vcsc-ld: MEMORY region '%s' lies outside cartridge bank '%s'\n",
                 mem->name, bank->name);
         exit(1);
      }
      for (j = i + 1; j < cfg->mem_count; ++j) {
         memory_region_t *other = &cfg->mem[j];
         uint32_t other_end;
         if (!other->bank_name[0] ||
             !str_ieq(mem->bank_name, other->bank_name))
            continue;
         other_end = (uint32_t)other->start + other->size;
         if (mem->start < other_end && other->start < mem_end) {
            fprintf(stderr,
                    "vcsc-ld: MEMORY regions '%s' and '%s' overlap inside bank '%s'\n",
                    mem->name, other->name, mem->bank_name);
            exit(1);
         }
      }
   }

   /* Every selector hotspot is visible at the same low twelve-bit offset in
      every physical bank. Reject any ordinary allocatable segment region that
      covers one of those bytes. Non-allocatable vector and bridge regions may
      own fixed bytes that deliberately overlap mapper hotspots. */
   for (i = 0; i < cfg->seg_count; ++i) {
      const segment_rule_t *seg = &cfg->seg[i];
      const memory_region_t *mem;
      const cartridge_bank_t *bank;
      if (!segment_rule_is_ordinary_allocatable(seg))
         continue;
      mem = find_memory(cfg, seg->load_name);
      if (!mem || !mem->bank_name[0])
         continue;
      bank = find_cartridge_bank(cfg, mem->bank_name);
      if (!bank)
         continue;
      {
         uint32_t mem_end = (uint32_t)mem->start + mem->size;
         uint16_t logical_trampoline =
            (uint16_t)(bank->start + cfg->trampoline_offset);
         uint32_t logical_trampoline_end =
            (uint32_t)logical_trampoline + cfg->trampoline_size;
         uint16_t logical_bridge =
            (uint16_t)(bank->start + cfg->vector_bridge_offset);
         uint32_t logical_bridge_end =
            (uint32_t)logical_bridge + VECTOR_BRIDGE_SIZE;
         if (mem->start < logical_trampoline_end && logical_trampoline < mem_end) {
            fprintf(stderr,
                    "vcsc-ld: segment '%s' region '%s' covers reserved trampoline $%04X-$%04X in %s\n",
                    seg->name, mem->name, logical_trampoline,
                    (uint16_t)(logical_trampoline_end - 1u), bank->name);
            exit(1);
         }
         if (mem->start < logical_bridge_end && logical_bridge < mem_end) {
            fprintf(stderr,
                    "vcsc-ld: segment '%s' region '%s' covers reserved vector bridge $%04X-$%04X in %s\n",
                    seg->name, mem->name, logical_bridge,
                    (uint16_t)(logical_bridge_end - 1u), bank->name);
            exit(1);
         }
         for (j = 0; j < cfg->bank_count; ++j) {
            uint16_t logical_hotspot =
               (uint16_t)(bank->start + (cfg->banks[j].hotspot & 0x0fffu));
            if (logical_hotspot >= mem->start && logical_hotspot < mem_end) {
               fprintf(stderr,
                       "vcsc-ld: segment '%s' region '%s' covers reserved bank hotspot $%04X in %s\n",
                       seg->name, mem->name, logical_hotspot, bank->name);
               exit(1);
            }
         }
      }
   }
}

//! @brief Parse configuration file into the normalized representation used by linker layout and image writer.
static void parse_cfg_file(linker_config_t *cfg, const char *path)
{
   FILE *fp = fopen(path, "r");
   char line[1024];
   enum { NONE, CARTRIDGE, BANKS, MEMORY, SEGMENTS } block = NONE;
   unsigned line_number = 0;

   if (!fp) {
      fprintf(stderr, "vcsc-ld: cannot open '%s': %s\n", path, strerror(errno));
      exit(1);
   }

   memset(cfg, 0, sizeof(*cfg));
   cfg->cartridge_fill_value = 0xFFu;

   while (fgets(line, sizeof(line), fp)) {
      char *s = line;
      char *colon;
      char *comment;
      char *semi;
      line_number++;

      comment = strchr(s, '#');
      if (comment)
         *comment = '\0';
      s = trim(s);
      if (*s == '\0')
         continue;

      if (str_ieq(s, "CARTRIDGE {") || str_ieq(s, "CARTRIDGE{")) {
         if (block != NONE) {
            fprintf(stderr, "vcsc-ld: nested block at %s:%u\n", path, line_number);
            exit(1);
         }
         block = CARTRIDGE;
         continue;
      }
      if (str_ieq(s, "BANKS {") || str_ieq(s, "BANKS{")) {
         if (block != NONE) {
            fprintf(stderr, "vcsc-ld: nested block at %s:%u\n", path, line_number);
            exit(1);
         }
         block = BANKS;
         continue;
      }
      if (str_ieq(s, "MEMORY {") || str_ieq(s, "MEMORY{")) {
         if (block != NONE) {
            fprintf(stderr, "vcsc-ld: nested block at %s:%u\n", path, line_number);
            exit(1);
         }
         block = MEMORY;
         continue;
      }
      if (str_ieq(s, "SEGMENTS {") || str_ieq(s, "SEGMENTS{")) {
         if (block != NONE) {
            fprintf(stderr, "vcsc-ld: nested block at %s:%u\n", path, line_number);
            exit(1);
         }
         block = SEGMENTS;
         continue;
      }
      if (strcmp(s, "}") == 0) {
         if (block == NONE) {
            fprintf(stderr, "vcsc-ld: unmatched '}' at %s:%u\n", path, line_number);
            exit(1);
         }
         block = NONE;
         continue;
      }
      if (block == NONE) {
         fprintf(stderr, "vcsc-ld: unrecognized top-level text at %s:%u: %s\n",
                 path, line_number, s);
         exit(1);
      }

      semi = strrchr(s, ';');
      if (!semi || trim(semi + 1)[0] != '\0') {
         fprintf(stderr, "vcsc-ld: configuration entry must end with ';' at %s:%u\n",
                 path, line_number);
         exit(1);
      }
      *semi = '\0';

      if (block == CARTRIDGE) {
         char *eq = strchr(s, '=');
         if (!eq) {
            fprintf(stderr, "vcsc-ld: malformed CARTRIDGE entry at %s:%u\n",
                    path, line_number);
            exit(1);
         }
         *eq++ = '\0';
         parse_cartridge_property(cfg, trim(s), trim(eq));
         continue;
      }

      colon = strchr(s, ':');
      if (!colon) {
         fprintf(stderr, "vcsc-ld: malformed named entry at %s:%u\n",
                 path, line_number);
         exit(1);
      }
      *colon++ = '\0';
      s = trim(s);
      colon = trim(colon);
      if (*s == '\0' || *colon == '\0') {
         fprintf(stderr, "vcsc-ld: malformed empty named entry at %s:%u\n",
                 path, line_number);
         exit(1);
      }

      if (block == BANKS) {
         cartridge_bank_t *bank = append_cartridge_bank(cfg);
         snprintf(bank->name, sizeof(bank->name), "%s", s);
         parse_property_list(cfg, 2, bank, colon);
      } else if (block == MEMORY) {
         memory_region_t *mem = append_memory_region(cfg);
         snprintf(mem->name, sizeof(mem->name), "%s", s);
         parse_property_list(cfg, 3, mem, colon);
      } else {
         segment_rule_t *seg = append_segment_rule(cfg);
         snprintf(seg->name, sizeof(seg->name), "%s", s);
         parse_property_list(cfg, 4, seg, colon);
      }
   }

   if (ferror(fp)) {
      fprintf(stderr, "vcsc-ld: read failed for '%s': %s\n", path, strerror(errno));
      fclose(fp);
      exit(1);
   }
   fclose(fp);
   if (block != NONE) {
      fprintf(stderr, "vcsc-ld: unterminated configuration block in '%s'\n", path);
      exit(1);
   }

   validate_linker_config(cfg);
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

//! @brief Return the source-level function name carried by one private code layout.
static const char *call_graph_layout_function_name(const object_layout_t *layout)
{
   static const char marker[] = ".__vcsc_function$";
   const char *p;

   if (!layout || !layout->name)
      return NULL;
   p = strstr(layout->name, marker);
   return p ? p + sizeof(marker) - 1u : NULL;
}

//! @brief Find the object and private code layout implementing one graph node.
static const object_layout_t *call_graph_find_function_layout(
                                             const input_set_t *in,
                                             const char *node_name,
                                             const object_file_t **object_out)
{
   const char *separator = NULL;
   const char *scan;
   const char *function_name = node_name;
   size_t origin_len = 0;
   size_t i;

   if (object_out)
      *object_out = NULL;
   if (!in || !node_name)
      return NULL;

   for (scan = node_name; (scan = strstr(scan, "::")) != NULL; scan += 2)
      separator = scan;
   if (separator) {
      origin_len = (size_t)(separator - node_name);
      function_name = separator + 2;
   }

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      size_t j;

      if (separator) {
         if (strlen(obj->origin) != origin_len ||
             strncmp(obj->origin, node_name, origin_len) != 0)
            continue;
      }
      else if (!call_graph_object_exports_symbol(obj, function_name)) {
         continue;
      }

      for (j = 0; j < obj->layout_count; ++j) {
         const object_layout_t *layout = &obj->layouts[j];
         const char *layout_function = call_graph_layout_function_name(layout);
         if (layout_function && strcmp(layout_function, function_name) == 0) {
            if (object_out)
               *object_out = obj;
            return layout;
         }
      }
   }

   return NULL;
}

//! @brief Resolve a graph node's statically configured full-window bank.
static const cartridge_bank_t *call_graph_function_bank(const linker_config_t *cfg,
                                                        const input_set_t *in,
                                                        const char *node_name)
{
   const object_layout_t *layout;
   const segment_rule_t *fallback;
   const segment_rule_t *rule;
   const memory_region_t *memory;

   if (!cfg || !cfg->cartridge_banked)
      return NULL;
   layout = call_graph_find_function_layout(in, node_name, NULL);
   if (!layout)
      return NULL;
   if (layout->placement_bank[0])
      return find_cartridge_bank(cfg, layout->placement_bank);
   fallback = find_segment_rule(cfg, "CODE");
   rule = find_layout_segment_rule(cfg, layout->name, fallback);
   if (!rule || !rule->load_name[0])
      return NULL;
   memory = find_memory(cfg, rule->load_name);
   if (!memory || !memory->bank_name[0])
      return NULL;
   return find_cartridge_bank(cfg, memory->bank_name);
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

//! @brief Compute the longest active hardware-return path including bank bridges.
static int call_graph_longest_weighted_depth_visit(
                                          int v,
                                          const call_graph_edge_t *edges,
                                          size_t edge_count,
                                          const cartridge_bank_t *const *banks,
                                          int *memo)
{
   size_t i;
   int best = 1;

   if (memo[v] > 0)
      return memo[v];

   for (i = 0; i < edge_count; ++i) {
      int child_depth;
      int bridge_depth = 0;

      if (edges[i].from != v)
         continue;
      if (banks && banks[v] && banks[edges[i].to] &&
          banks[v] != banks[edges[i].to])
         bridge_depth = 1;
      child_depth = 1 + bridge_depth +
         call_graph_longest_weighted_depth_visit(edges[i].to, edges,
                                                 edge_count, banks, memo);
      if (child_depth > best)
         best = child_depth;
   }

   memo[v] = best;
   return best;
}

//! @brief Validate symbol backed call graph invariants and return its maximum function depth.
static uint16_t enforce_symbol_backed_call_graph(const input_set_t *in,
                                                 const linker_config_t *cfg,
                                                 uint16_t *weighted_depth_out)
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
   int *weighted_depth_memo = NULL;
   const cartridge_bank_t **node_banks = NULL;
   int max_depth = 0;
   int max_weighted_depth = 0;
   int stack_top = 0;
   int index_counter = 0;
   int component_count = 0;
   size_t i;

   for (i = 0; i < in->object_count; ++i)
      call_graph_collect_from_object(&in->objects[i], &nodes, &node_count, &edges, &edge_count);

   if (weighted_depth_out)
      *weighted_depth_out = 0;
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
   weighted_depth_memo = (int *)xcalloc(node_count, sizeof(*weighted_depth_memo));
   node_banks = (const cartridge_bank_t **)xcalloc(node_count, sizeof(*node_banks));
   for (i = 0; i < node_count; ++i)
      node_banks[i] = call_graph_function_bank(cfg, in, nodes[i].name);
   for (i = 0; i < node_count; ++i) {
      int depth = call_graph_longest_depth_visit((int)i, edges, edge_count, depth_memo);
      int weighted_depth = call_graph_longest_weighted_depth_visit(
         (int)i, edges, edge_count, node_banks, weighted_depth_memo);
      if (depth > max_depth)
         max_depth = depth;
      if (weighted_depth > max_weighted_depth)
         max_weighted_depth = weighted_depth;
   }
   if (weighted_depth_out)
      *weighted_depth_out = (uint16_t)max_weighted_depth;

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
   free(weighted_depth_memo);
   free(node_banks);
   return (uint16_t)max_depth;
}


typedef struct {
   char *kind;
   char *strength;
   char *symbol;
   char *owner;
   char *file;
   char *invoke;
   char *detail;
   int line;
   int column;
   const object_file_t *obj;
} declaration_contract_record_t;

typedef struct {
   char *kind;
   char *symbol;
   char *owner;
   char *function;
   char *file;
   char *invoke;
   int line;
   int column;
   const object_file_t *obj;
} semantic_use_record_t;

//! @brief Decode one compiler metadata field encoded with QHH byte escapes.
static char *contract_meta_decode(const char *encoded)
{
   size_t n = strlen(encoded);
   char *decoded = (char *)xmalloc(n + 1);
   size_t i = 0;
   size_t o = 0;

   while (i < n) {
      if (encoded[i] != 'Q') {
         decoded[o++] = encoded[i++];
         continue;
      }
      if (i + 2 >= n || !isxdigit((unsigned char)encoded[i + 1]) ||
          !isxdigit((unsigned char)encoded[i + 2])) {
         free(decoded);
         return NULL;
      }
      {
         char hex[3];
         hex[0] = encoded[i + 1];
         hex[1] = encoded[i + 2];
         hex[2] = '\0';
         decoded[o++] = (char)strtoul(hex, NULL, 16);
      }
      i += 3;
   }
   decoded[o] = '\0';
   return decoded;
}

//! @brief Remove and decode the next dollar-delimited metadata field.
static char *contract_meta_next_field(const char **cursor)
{
   const char *end;
   char *encoded;
   char *decoded;
   size_t n;

   if (!cursor || !*cursor)
      return NULL;
   end = strchr(*cursor, '$');
   if (!end)
      return NULL;
   n = (size_t)(end - *cursor);
   encoded = (char *)xmalloc(n + 1);
   memcpy(encoded, *cursor, n);
   encoded[n] = '\0';
   *cursor = end + 1;
   decoded = contract_meta_decode(encoded);
   free(encoded);
   return decoded;
}

//! @brief Decode the final undelimited metadata field.
static char *contract_meta_last_field(const char **cursor)
{
   char *decoded;
   if (!cursor || !*cursor)
      return NULL;
   decoded = contract_meta_decode(*cursor);
   *cursor += strlen(*cursor);
   return decoded;
}

//! @brief Parse a field such as L12 or C7.
static int contract_meta_parse_location(const char *field, char prefix, int *out)
{
   char *end = NULL;
   long value;
   if (!field || field[0] != prefix || !isdigit((unsigned char)field[1]))
      return 0;
   value = strtol(field + 1, &end, 10);
   if (!end || *end || value < 0 || value > 0x7fffffffL)
      return 0;
   *out = (int)value;
   return 1;
}

//! @brief Release one parsed declaration contract record.
static void declaration_contract_record_free(declaration_contract_record_t *r)
{
   if (!r)
      return;
   free(r->kind);
   free(r->strength);
   free(r->symbol);
   free(r->owner);
   free(r->file);
   free(r->invoke);
   free(r->detail);
   memset(r, 0, sizeof(*r));
}

//! @brief Release one parsed semantic-use record.
static void semantic_use_record_free(semantic_use_record_t *r)
{
   if (!r)
      return;
   free(r->kind);
   free(r->symbol);
   free(r->owner);
   free(r->function);
   free(r->file);
   free(r->invoke);
   memset(r, 0, sizeof(*r));
}

//! @brief Parse one declaration-contract metadata export.
static int declaration_contract_record_parse(const char *name,
                                              const object_file_t *obj,
                                              declaration_contract_record_t *out)
{
   const char *p;
   char *label_owner = NULL;
   char *label_decl = NULL;
   char *line = NULL;
   char *column = NULL;
   char *label_invoke = NULL;
   char *label_type = NULL;
   char *fingerprint = NULL;
   int ok = 0;

   memset(out, 0, sizeof(*out));
   if (!contract_metadata_has_prefix(name))
      return 0;
   p = name + sizeof(CONTRACT_META_PREFIX) - 1;
   out->kind = contract_meta_next_field(&p);
   out->strength = contract_meta_next_field(&p);
   out->symbol = contract_meta_next_field(&p);
   label_owner = contract_meta_next_field(&p);
   out->owner = contract_meta_next_field(&p);
   label_decl = contract_meta_next_field(&p);
   out->file = contract_meta_next_field(&p);
   line = contract_meta_next_field(&p);
   column = contract_meta_next_field(&p);
   label_invoke = contract_meta_next_field(&p);
   out->invoke = contract_meta_next_field(&p);
   label_type = contract_meta_next_field(&p);
   fingerprint = contract_meta_next_field(&p);
   out->detail = contract_meta_last_field(&p);
   out->obj = obj;

   ok = out->kind && out->strength && out->symbol && out->owner && out->file &&
        out->invoke && out->detail && label_owner && !strcmp(label_owner, "owner") &&
        label_decl && !strcmp(label_decl, "decl") && label_invoke &&
        !strcmp(label_invoke, "invoke") && label_type && !strcmp(label_type, "type") &&
        fingerprint && line && column &&
        contract_meta_parse_location(line, 'L', &out->line) &&
        contract_meta_parse_location(column, 'C', &out->column) &&
        (!strcmp(out->kind, "object") || !strcmp(out->kind, "function")) &&
        (!strcmp(out->strength, "require") || !strcmp(out->strength, "recommend"));

   free(label_owner);
   free(label_decl);
   free(line);
   free(column);
   free(label_invoke);
   free(label_type);
   free(fingerprint);
   if (!ok)
      declaration_contract_record_free(out);
   return ok;
}

//! @brief Parse one semantic-use metadata export.
static int semantic_use_record_parse(const char *name,
                                     const object_file_t *obj,
                                     semantic_use_record_t *out)
{
   const char *p;
   char *label_owner = NULL;
   char *label_function = NULL;
   char *label_use = NULL;
   char *line = NULL;
   char *column = NULL;
   char *label_invoke = NULL;
   int ok = 0;

   memset(out, 0, sizeof(*out));
   if (!semantic_use_metadata_has_prefix(name))
      return 0;
   p = name + sizeof(SEMANTIC_USE_META_PREFIX) - 1;
   out->kind = contract_meta_next_field(&p);
   out->symbol = contract_meta_next_field(&p);
   label_owner = contract_meta_next_field(&p);
   out->owner = contract_meta_next_field(&p);
   label_function = contract_meta_next_field(&p);
   out->function = contract_meta_next_field(&p);
   label_use = contract_meta_next_field(&p);
   out->file = contract_meta_next_field(&p);
   line = contract_meta_next_field(&p);
   column = contract_meta_next_field(&p);
   label_invoke = contract_meta_next_field(&p);
   out->invoke = contract_meta_last_field(&p);
   out->obj = obj;

   ok = out->kind && out->symbol && out->owner && out->function && out->file &&
        out->invoke && label_owner && !strcmp(label_owner, "owner") &&
        label_function && !strcmp(label_function, "function") && label_use &&
        !strcmp(label_use, "use") && label_invoke && !strcmp(label_invoke, "invoke") &&
        line && column && contract_meta_parse_location(line, 'L', &out->line) &&
        contract_meta_parse_location(column, 'C', &out->column) &&
        (!strcmp(out->kind, "call") || !strcmp(out->kind, "read") ||
         !strcmp(out->kind, "write") || !strcmp(out->kind, "address") ||
         !strcmp(out->kind, "ref"));

   free(label_owner);
   free(label_function);
   free(label_use);
   free(line);
   free(column);
   free(label_invoke);
   if (!ok)
      semantic_use_record_free(out);
   return ok;
}

//! @brief Find one exact call-graph node name.
static int contract_call_graph_find_node(const call_graph_node_t *nodes,
                                         size_t count, const char *name)
{
   size_t i;
   for (i = 0; i < count; ++i) {
      if (!strcmp(nodes[i].name, name))
         return (int)i;
   }
   return -1;
}

//! @brief Mark functions reachable from main and runtime initializer roots.
static unsigned char *contract_call_graph_reachability(const input_set_t *in,
                                                        call_graph_node_t **nodes_out,
                                                        size_t *node_count_out)
{
   call_graph_node_t *nodes = NULL;
   call_graph_edge_t *edges = NULL;
   size_t node_count = 0;
   size_t edge_count = 0;
   unsigned char *reachable;
   int changed;
   size_t i;

   for (i = 0; i < in->object_count; ++i)
      call_graph_collect_from_object(&in->objects[i], &nodes, &node_count,
                                     &edges, &edge_count);
   reachable = (unsigned char *)xcalloc(node_count ? node_count : 1,
                                       sizeof(*reachable));
   for (i = 0; i < node_count; ++i) {
      const char *display = display_function_symbol(nodes[i].name);
      if (!strcmp(display, "main") || symbol_is_init_function(display))
         reachable[i] = 1;
   }
   do {
      changed = 0;
      for (i = 0; i < edge_count; ++i) {
         if (reachable[edges[i].from] && !reachable[edges[i].to]) {
            reachable[edges[i].to] = 1;
            changed = 1;
         }
      }
   } while (changed);

   free(edges);
   *nodes_out = nodes;
   *node_count_out = node_count;
   return reachable;
}

//! @brief Return whether one semantic use occurs in reachable code.
static int semantic_use_is_reachable(const semantic_use_record_t *use,
                                     const call_graph_node_t *nodes,
                                     size_t node_count,
                                     const unsigned char *reachable)
{
   char *qualified;
   int node;

   if (!use || !strcmp(use->function, "none"))
      return 0;
   qualified = call_graph_object_function_name(use->obj, use->function);
   node = contract_call_graph_find_node(nodes, node_count, qualified);
   free(qualified);
   return node >= 0 && reachable[node];
}

//! @brief Return whether a reachable use comes from outside the contract owner.
static int semantic_use_is_external(const declaration_contract_record_t *contract,
                                    const semantic_use_record_t *use)
{
   return strcmp(contract->owner, use->owner) != 0 ||
          strcmp(contract->invoke, use->invoke) != 0;
}

//! @brief Merge a parsed contract into the selected-program contract table.
static void declaration_contract_merge(declaration_contract_record_t **records,
                                       size_t *count,
                                       declaration_contract_record_t *incoming)
{
   size_t i;
   for (i = 0; i < *count; ++i) {
      declaration_contract_record_t *old = &(*records)[i];
      if (strcmp(old->kind, incoming->kind) || strcmp(old->symbol, incoming->symbol) ||
          strcmp(old->owner, incoming->owner) || strcmp(old->invoke, incoming->invoke))
         continue;
      if (!strcmp(incoming->strength, "require") && strcmp(old->strength, "require")) {
         declaration_contract_record_free(old);
         *old = *incoming;
         memset(incoming, 0, sizeof(*incoming));
      }
      return;
   }
   *records = (declaration_contract_record_t *)xrealloc(*records,
      (*count + 1) * sizeof(**records));
   (*records)[*count] = *incoming;
   memset(incoming, 0, sizeof(*incoming));
   (*count)++;
}

//! @brief Enforce selected-program declaration-use contracts after reachability.
static void enforce_declaration_use_contracts(const input_set_t *in)
{
   declaration_contract_record_t *contracts = NULL;
   semantic_use_record_t *uses = NULL;
   size_t contract_count = 0;
   size_t use_count = 0;
   call_graph_node_t *nodes = NULL;
   size_t node_count = 0;
   unsigned char *reachable;
   size_t i, j;
   int errors = 0;

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->export_count; ++j) {
         const char *name = obj->exports[j].name;
         if (contract_metadata_has_prefix(name)) {
            declaration_contract_record_t parsed;
            if (!declaration_contract_record_parse(name, obj, &parsed)) {
               fprintf(stderr, "vcsc-ld: malformed declaration-contract metadata '%s' in %s\n",
                       name, obj->origin);
               exit(1);
            }
            declaration_contract_merge(&contracts, &contract_count, &parsed);
         }
         else if (semantic_use_metadata_has_prefix(name)) {
            semantic_use_record_t parsed;
            if (!semantic_use_record_parse(name, obj, &parsed)) {
               fprintf(stderr, "vcsc-ld: malformed semantic-use metadata '%s' in %s\n",
                       name, obj->origin);
               exit(1);
            }
            uses = (semantic_use_record_t *)xrealloc(uses,
               (use_count + 1) * sizeof(*uses));
            uses[use_count++] = parsed;
         }
      }
   }

   reachable = contract_call_graph_reachability(in, &nodes, &node_count);
   for (i = 0; i < contract_count; ++i) {
      declaration_contract_record_t *contract = &contracts[i];
      int satisfied = 0;
      for (j = 0; j < use_count; ++j) {
         semantic_use_record_t *use = &uses[j];
         if (strcmp(contract->symbol, use->symbol))
            continue;
         if (!strcmp(contract->kind, "function") && strcmp(use->kind, "call"))
            continue;
         if (!strcmp(contract->kind, "object") && !strcmp(use->kind, "call"))
            continue;
         if (!semantic_use_is_external(contract, use) ||
             !semantic_use_is_reachable(use, nodes, node_count, reachable))
            continue;
         satisfied = 1;
         break;
      }
      if (!satisfied) {
         const char *level = contract->strength;
         const char *noun = !strcmp(contract->kind, "object") ? "variable" : "function";
         fprintf(stderr, "%s:%d:%d: vcsc-ld: %s%s %s '%s' not used\n",
                 contract->file, contract->line, contract->column,
                 !strcmp(level, "recommend") ? "warning: " : "",
                 !strcmp(level, "require") ? "required" : "recommended",
                 noun, contract->symbol);
         if (contract->detail && *contract->detail)
            fprintf(stderr, "  declared type: %s\n", contract->detail);
         if (strcmp(contract->invoke, "none"))
            fprintf(stderr, "  template invocation: %s\n", contract->invoke);
         if (!strcmp(level, "require"))
            errors++;
      }
   }

   for (i = 0; i < node_count; ++i)
      free(nodes[i].name);
   free(nodes);
   free(reachable);
   for (i = 0; i < contract_count; ++i)
      declaration_contract_record_free(&contracts[i]);
   free(contracts);
   for (i = 0; i < use_count; ++i)
      semantic_use_record_free(&uses[i]);
   free(uses);
   if (errors)
      exit(1);
}

//! @brief Shrink the configured RAM arena by the stack requirement derived from the call graph.
static void reserve_call_stack_from_call_graph(linker_config_t *cfg,
                                               uint16_t depth,
                                               uint16_t weighted_depth,
                                               size_t init_count)
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
      A cross-bank edge contributes one additional two-byte return address for
      the JSR inside the common trampoline entry. weighted_depth is therefore
      the maximum number of simultaneously active hardware return addresses.
      The stock startup also preserves its two-byte init-table cursor while an
      init function runs. callstack_extra reserves a configuration-declared
      number of additional top-of-RAM bytes for stack use hidden inside included
      or separately assembled routines. */
   if (weighted_depth < depth)
      weighted_depth = depth;
   bytes = (uint32_t)weighted_depth * 2u;
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
   cfg->call_stack_weighted_depth = weighted_depth;
   cfg->call_stack_bank_extra_slots = (uint16_t)(weighted_depth - depth);
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
      add_global(layout, "__call_stack_weighted_depth", layout->call_stack_weighted_depth, O26_SEG_ABS, "<linker>");
      add_global(layout, "__call_stack_bank_extra_slots", layout->call_stack_bank_extra_slots, O26_SEG_ABS, "<linker>");
      add_global(layout, "__call_stack_extra", layout->call_stack_extra, O26_SEG_ABS, "<linker>");
      add_global(layout, "__call_stack_size", layout->call_stack_size, O26_SEG_ABS, "<linker>");
      add_global(layout, "__call_stack_start", layout->call_stack_start, O26_SEG_ABS, "<linker>");
      add_global(layout, "__call_stack_top", layout->call_stack_top, O26_SEG_ABS, "<linker>");
   }
}

//! @brief Find a global symbol in linker layout state without transferring ownership.
static const global_symbol_t *lookup_global_symbol(const layout_t *layout,
                                                   const char *name)
{
   size_t i;
   char *weak;

   for (i = 0; i < layout->global_count; ++i) {
      if (strcmp(layout->globals[i].name, name) == 0)
         return &layout->globals[i];
   }

   weak = make_weak_name(name);
   for (i = 0; i < layout->global_count; ++i) {
      if (strcmp(layout->globals[i].name, weak) == 0) {
         free(weak);
         return &layout->globals[i];
      }
   }
   free(weak);

   fprintf(stderr, "vcsc-ld: unresolved symbol '%s'\n", name);
   exit(1);
}

//! @brief Find global addr in linker layout and image writer tables without transferring ownership.
static uint16_t lookup_global_addr(const layout_t *layout, const char *name)
{
   return lookup_global_symbol(layout, name)->addr;
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

//! @brief Return the optional named-memory suffix before compiler-owned object metadata.
static const char *segment_name_suffix(const char *name, char *buf, size_t bufsz)
{
   const char *dot;
   const char *end;
   size_t n;

   if (!name || !buf || bufsz == 0)
      return NULL;
   dot = strchr(name, '.');
   if (!dot || !dot[1])
      return NULL;
   dot++;
   if (!strncmp(dot, "__vcsc_page$", sizeof("__vcsc_page$") - 1) ||
       !strncmp(dot, "__vcsc_object$", sizeof("__vcsc_object$") - 1))
      return NULL;
   end = strstr(dot, ".__vcsc_object$");
   if (!end)
      end = strstr(dot, ".__vcsc_page$");
   n = end ? (size_t)(end - dot) : strlen(dot);
   if (n == 0 || n >= bufsz)
      return NULL;
   memcpy(buf, dot, n);
   buf[n] = '\0';
   return buf;
}

//! @brief Return rule run region name data used by linker layout and image writer; returned pointers alias existing storage unless explicitly allocated by the function name.
static const char *rule_run_region_name(const segment_rule_t *rule)
{
   if (!rule)
      return NULL;
   return rule->run_name[0] ? rule->run_name : rule->load_name;
}

//! @brief Translate a runtime read alias to the corresponding write alias.
static uint16_t memory_runtime_write_address(const linker_config_t *cfg,
                                             const char *mem_name,
                                             uint16_t read_addr,
                                             uint16_t size)
{
   const memory_region_t *mem = find_memory(cfg, mem_name);
   uint32_t offset;
   uint32_t write_addr;

   if (!mem) {
      fprintf(stderr, "vcsc-ld: MEMORY region '%s' not found while resolving write alias\n",
              mem_name ? mem_name : "<unnamed>");
      exit(1);
   }
   if (!mem->has_write_start)
      return read_addr;
   if (read_addr < mem->start ||
       (uint32_t)read_addr + size > (uint32_t)mem->start + mem->size) {
      fprintf(stderr,
              "vcsc-ld: runtime object $%04X+$%04X lies outside split-address MEMORY region '%s' read window $%04X-$%04X\n",
              read_addr, size, mem->name, mem->start,
              (uint16_t)((uint32_t)mem->start + mem->size - 1u));
      exit(1);
   }
   offset = (uint32_t)read_addr - mem->start;
   write_addr = (uint32_t)mem->write_start + offset;
   if (write_addr + size > 0x10000u) {
      fprintf(stderr, "vcsc-ld: write alias overflow for MEMORY region '%s'\n", mem->name);
      exit(1);
   }
   return (uint16_t)write_addr;
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

static int range_fits_one_page(uint32_t addr, uint16_t size);

//! @brief Return whether branch source and target both belong to one movable layout.
static int branch_fully_in_layout(const branch_t *branch,
                                  const object_layout_t *lay)
{
   uint32_t packed_end;

   if (!branch || !lay || branch->segid != lay->segid || lay->size == 0)
      return 0;
   packed_end = (uint32_t)lay->packed_base + lay->size;
   return branch->source >= lay->packed_base && branch->source < packed_end &&
          branch->target >= lay->packed_base && branch->target < packed_end;
}

//! @brief Return whether all hard branch-page contracts hold at a candidate base.
static int layout_branch_contracts_hold_at(const object_file_t *obj,
                                           const object_layout_t *lay,
                                           uint16_t candidate)
{
   size_t i;

   for (i = 0; i < obj->branch_count; ++i) {
      const branch_t *branch = &obj->branches[i];
      uint32_t source;
      uint32_t target;
      int crosses;

      if (!branch_fully_in_layout(branch, lay) ||
          branch->page_policy == BRANCH_PAGE_FLEX)
         continue;
      source = (uint32_t)candidate + branch->source - lay->packed_base;
      target = (uint32_t)candidate + branch->target - lay->packed_base;
      crosses = ((((source + 2u) ^ target) & 0xff00u) != 0);
      if ((branch->page_policy == BRANCH_PAGE_SAME && crosses) ||
          (branch->page_policy == BRANCH_PAGE_CROSS && !crosses))
         return 0;
   }
   return 1;
}

//! @brief Reject hard branch contracts whose target is outside the source layout.
static void validate_layout_hard_branch_scope(const object_file_t *obj,
                                              const object_layout_t *lay)
{
   size_t i;
   uint32_t packed_end;

   if (!obj || !lay || lay->size == 0)
      return;
   packed_end = (uint32_t)lay->packed_base + lay->size;
   for (i = 0; i < obj->branch_count; ++i) {
      const branch_t *branch = &obj->branches[i];
      if (branch->page_policy == BRANCH_PAGE_FLEX || branch->segid != lay->segid ||
          branch->source < lay->packed_base || branch->source >= packed_end)
         continue;
      if (branch->target < lay->packed_base || branch->target >= packed_end) {
         fprintf(stderr,
                 "vcsc-ld: hard branch-page annotation at packed $%04X in %s targets outside movable layout %s\n",
                 branch->source, obj->origin, lay->name);
         exit(1);
      }
   }
}

//! @brief Count flexible taken branches in one layout that cross at a candidate base.
static size_t layout_branch_crossings_at(const object_file_t *obj,
                                         const object_layout_t *lay,
                                         uint16_t candidate)
{
   size_t i;
   size_t crossings = 0;

   if (!obj || !lay || lay->size == 0)
      return 0;
   for (i = 0; i < obj->branch_count; ++i) {
      const branch_t *branch = &obj->branches[i];
      uint32_t source;
      uint32_t target;

      if (!branch_fully_in_layout(branch, lay) ||
          branch->page_policy != BRANCH_PAGE_FLEX)
         continue;
      source = (uint32_t)candidate + branch->source - lay->packed_base;
      target = (uint32_t)candidate + branch->target - lay->packed_base;
      if ((((source + 2u) ^ target) & 0xff00u) != 0)
         crossings++;
   }
   return crossings;
}

//! @brief Return whether one layout contains any retained relative-branch source.
static int layout_has_branches(const object_file_t *obj,
                               const object_layout_t *lay)
{
   size_t i;
   uint32_t packed_end;

   if (!obj || !lay || lay->size == 0)
      return 0;
   packed_end = (uint32_t)lay->packed_base + lay->size;
   for (i = 0; i < obj->branch_count; ++i) {
      const branch_t *branch = &obj->branches[i];
      if (branch->segid == lay->segid &&
          branch->source >= lay->packed_base && branch->source < packed_end)
         return 1;
   }
   return 0;
}

//! @brief Remember an unused address interval created by alignment or a hard placement constraint.
static void cursor_add_hole(memory_cursor_t *cursor, uint32_t start, uint32_t end)
{
   if (!cursor || end <= start)
      return;
   cursor->holes = (memory_hole_t *)xrealloc(cursor->holes,
      (cursor->hole_count + 1) * sizeof(*cursor->holes));
   cursor->holes[cursor->hole_count].start = start;
   cursor->holes[cursor->hole_count].end = end;
   cursor->hole_count++;
}

//! @brief Consume one same-page range from the earliest previously created hole.
static uint32_t align_up_u32(uint32_t value, uint16_t alignment)
{
   if (alignment <= 1)
      return value;
   return (value + alignment - 1u) & ~((uint32_t)alignment - 1u);
}

//! @brief Return whether all hard page constraints for one object hold at an address.
static int object_page_constraints_hold(const object_layout_t *lay, uint32_t addr)
{
   if (!lay)
      return 1;
   /* A multi-byte object in the 6502 zero page may not wrap from $FF to
      $00.  Intentional wraparound remains expressible as separate one-byte
      objects; it is not a valid placement for one contiguous object. */
   if (lay->segid == O26_SEG_ZP &&
       addr + (uint32_t)lay->size > 0x0100u)
      return 0;
   if ((lay->flags & O26_LAYOUT_PAGE_CONTAINED) &&
       !range_fits_one_page(addr, lay->size))
      return 0;
   if (lay->flags & O26_LAYOUT_INDEX_RANGE) {
      uint32_t range_addr = addr + lay->index_range_start;
      uint16_t range_size = (uint16_t)(lay->index_range_max + 1u);
      if (!range_fits_one_page(range_addr, range_size))
         return 0;
   }
   return 1;
}

//! @brief Consume the earliest hole satisfying alignment and page constraints.
static int cursor_take_hole(memory_cursor_t *cursor, uint16_t size, uint16_t alignment,
                            int prefer_whole_page, const object_layout_t *constraints,
                            uint16_t *addr_out)
{
   size_t i;
   size_t best_i = 0;
   uint32_t best_addr = 0;
   int found = 0;

   if (!cursor || !addr_out || size == 0)
      return 0;
   for (i = 0; i < cursor->hole_count; ++i) {
      memory_hole_t hole = cursor->holes[i];
      uint32_t addr = align_up_u32(hole.start, alignment);

      while (addr + size <= hole.end && addr <= 0xffffu) {
         if (object_page_constraints_hold(constraints, addr) &&
             (!prefer_whole_page || range_fits_one_page(addr, size)))
            break;
         addr = align_up_u32(addr + 1u, alignment);
      }
      if (addr + size > hole.end || addr > 0xffffu)
         continue;
      if (!found || addr < best_addr) {
         found = 1;
         best_i = i;
         best_addr = addr;
      }
   }
   if (found) {
      memory_hole_t hole = cursor->holes[best_i];
      uint32_t before_end = best_addr;
      uint32_t after_start = best_addr + size;

      if (before_end > hole.start && after_start < hole.end) {
         cursor->holes[best_i].end = before_end;
         cursor_add_hole(cursor, after_start, hole.end);
      } else if (before_end > hole.start) {
         cursor->holes[best_i].end = before_end;
      } else if (after_start < hole.end) {
         cursor->holes[best_i].start = after_start;
      } else {
         memmove(&cursor->holes[best_i], &cursor->holes[best_i + 1],
                 (cursor->hole_count - best_i - 1) * sizeof(*cursor->holes));
         cursor->hole_count--;
      }
      *addr_out = (uint16_t)best_addr;
      return 1;
   }
   return 0;
}

//! @brief Consume an already selected subrange from one cursor hole.
static void cursor_consume_hole_range(memory_cursor_t *cursor, size_t hole_index,
                                      uint32_t addr, uint16_t size)
{
   memory_hole_t hole = cursor->holes[hole_index];
   uint32_t before_end = addr;
   uint32_t after_start = addr + size;

   if (before_end > hole.start && after_start < hole.end) {
      cursor->holes[hole_index].end = before_end;
      cursor_add_hole(cursor, after_start, hole.end);
   } else if (before_end > hole.start) {
      cursor->holes[hole_index].end = before_end;
   } else if (after_start < hole.end) {
      cursor->holes[hole_index].start = after_start;
   } else {
      memmove(&cursor->holes[hole_index], &cursor->holes[hole_index + 1],
              (cursor->hole_count - hole_index - 1) * sizeof(*cursor->holes));
      cursor->hole_count--;
   }
}

//! @brief Return whether a complete object range remains within one 256-byte page.
static int range_fits_one_page(uint32_t addr, uint16_t size)
{
   if (size > 0x0100u)
      return 0;
   return (addr & 0xffu) + (uint32_t)size <= 0x0100u;
}

//! @brief Place one object with required alignment and hard or soft page policy.
static uint16_t alloc_from_region_policy(layout_t *layout, const linker_config_t *cfg,
   const char *mem_name, uint16_t size, uint16_t alignment,
   const object_layout_t *constraints, const char *what, const char *origin)
{
   memory_cursor_t *cursor = ensure_cursor(layout, cfg, mem_name);
   uint16_t hole_addr;
   uint32_t addr;
   uint32_t end;
   int wants_page = size > 0 && size <= 0x0100u;
   int hard_page = constraints &&
      (constraints->flags & O26_LAYOUT_PAGE_CONTAINED);
   int has_hard_constraint = constraints &&
      (constraints->flags & (O26_LAYOUT_PAGE_CONTAINED | O26_LAYOUT_INDEX_RANGE));

   if (size == 0)
      return cursor->cur;
   if (hard_page && size > 0x0100u) {
      fprintf(stderr, "vcsc-ld: hard page containment impossible for %s from %s: size $%04X exceeds 256 bytes\n",
              what, origin, size);
      exit(1);
   }
   if ((wants_page || has_hard_constraint) &&
       cursor_take_hole(cursor, size, alignment, wants_page, constraints, &hole_addr))
      return hole_addr;

   addr = align_up_u32(cursor->cur, alignment);
   while (!object_page_constraints_hold(constraints, addr)) {
      addr = align_up_u32(addr + 1u, alignment);
      if (constraints && constraints->segid == O26_SEG_ZP && addr >= 0x0100u) {
         fprintf(stderr,
                 "vcsc-ld: zero-page object %s from %s cannot cross $00FF/$0000; use separate one-byte objects only for intentional wrap semantics\n",
                 what, origin);
         exit(1);
      }
   }
   cursor_add_hole(cursor, cursor->cur, addr);
   end = addr + size;
   if (constraints && constraints->segid == O26_SEG_ZP && size > 1 &&
       end > cursor->end) {
      fprintf(stderr,
              "vcsc-ld: zero-page object %s from %s cannot cross $00FF/$0000; use separate one-byte objects only for intentional wrap semantics\n",
              what, origin);
      exit(1);
   }
   if (end > 0x10000u || end > cursor->end || (str_ieq(mem_name, "ROM") && end > 0xFFFAu)) {
      fprintf(stderr, "vcsc-ld: %s overflow while placing %s from %s in %s\n",
              mem_name, what, origin, mem_name);
      exit(1);
   }
   cursor->cur = (uint16_t)end;
   return (uint16_t)addr;
}

//! @brief Place one code layout by bounded exhaustive low-byte branch scoring.
static uint16_t alloc_code_branch_aware(layout_t *layout, const linker_config_t *cfg,
   const char *mem_name, const object_file_t *obj, const object_layout_t *lay,
   uint16_t alignment, const char *what, const char *origin)
{
   memory_cursor_t *cursor;
   uint32_t limit;
   uint32_t addr;
   uint32_t tail_last;
   uint32_t step = alignment > 1 ? alignment : 1;
   size_t i;
   int found = 0;
   int saw_place_candidate = 0;
   int best_from_hole = 0;
   size_t best_hole = 0;
   uint32_t best_addr = 0;
   uint32_t best_growth = 0;
   size_t best_crossings = 0;
   int best_page_penalty = 0;

   if (!layout_has_branches(obj, lay))
      return alloc_from_region_policy(layout, cfg, mem_name, lay->size,
         alignment, lay, what, origin);

   validate_layout_hard_branch_scope(obj, lay);
   cursor = ensure_cursor(layout, cfg, mem_name);
   if (lay->size == 0)
      return cursor->cur;
   if ((lay->flags & O26_LAYOUT_PAGE_CONTAINED) && lay->size > 0x0100u) {
      fprintf(stderr, "vcsc-ld: hard page containment impossible for %s from %s: size $%04X exceeds 256 bytes\n",
              what, origin, lay->size);
      exit(1);
   }
   limit = cursor->end;
   if (str_ieq(mem_name, "ROM") && limit > 0xFFFAu)
      limit = 0xFFFAu;

#define CONSIDER_BRANCH_CANDIDATE(candidate_, growth_, from_hole_, hole_) do { \
      uint32_t candidate_value__ = (candidate_); \
      size_t crossings__; \
      saw_place_candidate = 1; \
      if (!layout_branch_contracts_hold_at(obj, lay, (uint16_t)candidate_value__)) \
         break; \
      crossings__ = layout_branch_crossings_at(obj, lay, (uint16_t)candidate_value__); \
      int page_penalty__ = range_fits_one_page(candidate_value__, lay->size) ? 0 : 1; \
      uint32_t growth_value__ = (growth_); \
      if (!found || crossings__ < best_crossings || \
          (crossings__ == best_crossings && growth_value__ < best_growth) || \
          (crossings__ == best_crossings && growth_value__ == best_growth && \
           page_penalty__ < best_page_penalty) || \
          (crossings__ == best_crossings && growth_value__ == best_growth && \
           page_penalty__ == best_page_penalty && candidate_value__ < best_addr)) { \
         found = 1; \
         best_crossings = crossings__; \
         best_growth = growth_value__; \
         best_page_penalty = page_penalty__; \
         best_addr = candidate_value__; \
         best_from_hole = (from_hole_); \
         best_hole = (hole_); \
      } \
   } while (0)

   /* Existing holes are zero-growth local moves. Exhaustively score their
      aligned starts; VCS cartridge regions are tiny, so this remains bounded. */
   for (i = 0; i < cursor->hole_count; ++i) {
      const memory_hole_t hole = cursor->holes[i];
      addr = align_up_u32(hole.start, alignment);
      while (addr + lay->size <= hole.end && addr + lay->size <= limit) {
         if (object_page_constraints_hold(lay, addr))
            CONSIDER_BRANCH_CANDIDATE(addr, 0, 1, i);
         if (addr > 0xffffu - step)
            break;
         addr += step;
      }
   }

   /* At the high-water mark, one 256-byte sweep covers every useful low-byte
      placement. A farther candidate repeats an already tested branch phase
      while growing the image by at least one unnecessary page. */
   addr = align_up_u32(cursor->cur, alignment);
   tail_last = (uint32_t)cursor->cur + 0xffu;
   if (tail_last > 0xffffu)
      tail_last = 0xffffu;
   while (addr <= tail_last && addr + lay->size <= limit) {
      if (object_page_constraints_hold(lay, addr))
         CONSIDER_BRANCH_CANDIDATE(addr, addr + lay->size - cursor->cur, 0, 0);
      if (addr > 0xffffu - step)
         break;
      addr += step;
   }

#undef CONSIDER_BRANCH_CANDIDATE

   if (!found) {
      if (saw_place_candidate) {
         fprintf(stderr,
                 "vcsc-ld: cannot place %s from %s: .same/.cross branch-page requirements are mutually unsatisfiable\n",
                 what, origin);
      } else {
         fprintf(stderr, "vcsc-ld: %s overflow while branch-placing %s from %s in %s\n",
                 mem_name, what, origin, mem_name);
      }
      exit(1);
   }
   if (best_from_hole) {
      cursor_consume_hole_range(cursor, best_hole, best_addr, lay->size);
   } else {
      cursor_add_hole(cursor, cursor->cur, best_addr);
      cursor->cur = (uint16_t)(best_addr + lay->size);
   }
   return (uint16_t)best_addr;
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

//! @brief Resolve a packed affine expression against its exact defining layout.
static uint16_t object_runtime_addr_for_layout_value(const object_file_t *obj,
   uint16_t layout_index, uint8_t segid, uint16_t packed_value)
{
   const object_layout_t *lay;
   uint16_t base;

   if (layout_index >= obj->layout_count) {
      fprintf(stderr, "vcsc-ld: relocation layout index %u is out of range in %s\n",
              (unsigned)layout_index, obj->origin);
      exit(1);
   }
   lay = &obj->layouts[layout_index];
   if (lay->segid != segid) {
      fprintf(stderr,
              "vcsc-ld: relocation layout '%s' has segment %u, expected %u in %s\n",
              lay->name, (unsigned)lay->segid, (unsigned)segid, obj->origin);
      exit(1);
   }

   base = (segid == O26_SEG_TEXT) ? lay->load_addr : lay->run_addr;
   return (uint16_t)((int)base + (int)packed_value - (int)lay->packed_base);
}

//! @brief Find the configured logical cartridge bank containing one address.
static const cartridge_bank_t *cartridge_bank_for_address(const linker_config_t *cfg,
                                                          uint16_t address)
{
   size_t i;

   if (!cfg || !cfg->cartridge_banked)
      return NULL;
   for (i = 0; i < cfg->bank_count; ++i) {
      const cartridge_bank_t *bank = &cfg->banks[i];
      uint32_t end = (uint32_t)bank->start + bank->size;
      if (address >= bank->start && (uint32_t)address < end)
         return bank;
   }
   return NULL;
}

//! @brief Find the movable layout whose serialized bytes contain one relocation.
static const object_layout_t *find_layout_for_image_offset(const object_file_t *obj,
                                                           uint8_t image_segid,
                                                           uint32_t offset)
{
   size_t i;

   for (i = 0; i < obj->layout_count; ++i) {
      const object_layout_t *lay = &obj->layouts[i];
      uint32_t end = (uint32_t)lay->image_base + lay->size;
      if (lay->image_segid == image_segid &&
          offset >= lay->image_base && offset < end)
         return lay;
   }
   return NULL;
}

typedef struct {
   object_file_t *obj;
   object_layout_t *layout;
   const memory_region_t *configured_memory;
   const cartridge_bank_t *configured_bank;
   const memory_region_t *pin_memory;
   const cartridge_bank_t *pin_bank;
   size_t stable_order;
   int parent;
   int rank;
   int directly_pinned;
} bank_placement_item_t;

typedef struct {
   int first;
   int second;
   uint32_t weight;
} bank_placement_edge_t;

typedef struct {
   int root;
   uint16_t id;
   size_t stable_order;
   uint32_t bytes;
   uint32_t degree;
   uint32_t cut_weight;
   const cartridge_bank_t *bank;
   int pinned;
   int assigned;
} bank_placement_component_t;

typedef struct {
   const memory_region_t *memory;
   uint32_t capacity;
   uint32_t used;
} bank_placement_budget_t;

//! @brief Return the allocatable ROM memory region configured for one layout before automatic banking.
static const memory_region_t *bank_placement_layout_memory(const linker_config_t *cfg,
                                                            const object_layout_t *lay)
{
   const segment_rule_t *fallback;
   const segment_rule_t *rule;

   if (!cfg || !lay)
      return NULL;
   fallback = find_segment_rule(cfg,
      lay->segid == O26_SEG_TEXT ? "CODE" : "DATA");
   rule = find_layout_segment_rule(cfg, lay->name, fallback);
   if (!rule || !rule->load_name[0])
      return NULL;
   return find_memory(cfg, rule->load_name);
}

//! @brief Split a compiler-private layout name into its source segment prefix.
static int bank_placement_private_base(const char *name, char *base, size_t base_size)
{
   static const char *const markers[] = {
      ".__vcsc_function$", ".__vcsc_object$", ".__vcsc_page$", NULL
   };
   size_t i;

   if (!name || !base || base_size == 0)
      return 0;
   for (i = 0; markers[i]; ++i) {
      const char *marker = strstr(name, markers[i]);
      size_t n;
      if (!marker)
         continue;
      n = (size_t)(marker - name);
      if (n == 0 || n >= base_size)
         return 0;
      memcpy(base, name, n);
      base[n] = '\0';
      return 1;
   }
   return 0;
}

//! @brief Return whether a private ROM layout has no explicit named-memory pin.
static int bank_placement_layout_is_automatic_candidate(const object_layout_t *lay)
{
   char base[MAX_NAME];

   if (!lay || lay->segid != O26_SEG_TEXT ||
       !bank_placement_private_base(lay->name, base, sizeof(base)))
      return 0;
   return str_ieq(base, "CODE") || str_ieq(base, "RODATA");
}

//! @brief Return the startup/home bank from a validated banked profile.
static const cartridge_bank_t *bank_placement_startup_bank(const linker_config_t *cfg)
{
   size_t i;

   if (!cfg)
      return NULL;
   for (i = 0; i < cfg->bank_count; ++i) {
      if (cfg->banks[i].startup)
         return &cfg->banks[i];
   }
   return NULL;
}

//! @brief Select the deterministic ordinary ROM allocation region for one bank.
static const memory_region_t *bank_placement_auto_memory(const linker_config_t *cfg,
                                                          const cartridge_bank_t *bank)
{
   const memory_region_t *best = NULL;
   size_t i;

   if (!cfg || !bank)
      return NULL;
   for (i = 0; i < cfg->mem_count; ++i) {
      const memory_region_t *mem = &cfg->mem[i];
      if (!mem->bank_name[0] || !str_ieq(mem->bank_name, bank->name) ||
          !str_ieq(mem->type, "ro") || mem->size == 0)
         continue;
      if (!best || mem->size > best->size ||
          (mem->size == best->size && mem->start < best->start) ||
          (mem->size == best->size && mem->start == best->start &&
           strcmp(mem->name, best->name) < 0))
         best = mem;
   }
   return best;
}

//! @brief Find one placement item by its exact movable-layout identity.
static int bank_placement_find_item(const bank_placement_item_t *items,
                                    size_t count,
                                    const object_layout_t *layout)
{
   size_t i;
   for (i = 0; i < count; ++i) {
      if (items[i].layout == layout)
         return (int)i;
   }
   return -1;
}

//! @brief Union-find root for one hard same-bank placement item.
static int bank_placement_root(bank_placement_item_t *items, int item)
{
   if (items[item].parent != item)
      items[item].parent = bank_placement_root(items, items[item].parent);
   return items[item].parent;
}

//! @brief Merge two layouts joined by a cross-bank-forbidden ROM relationship.
static void bank_placement_union(bank_placement_item_t *items, int first, int second)
{
   int a = bank_placement_root(items, first);
   int b = bank_placement_root(items, second);

   if (a == b)
      return;
   if (items[a].rank < items[b].rank) {
      int tmp = a;
      a = b;
      b = tmp;
   }
   items[b].parent = a;
   if (items[a].rank == items[b].rank)
      items[a].rank++;
}

//! @brief Add or weight one undirected soft control-transfer placement edge.
static void bank_placement_add_edge(bank_placement_edge_t **edges,
                                    size_t *count,
                                    int first, int second,
                                    uint32_t weight)
{
   size_t i;

   if (first < 0 || second < 0 || first == second || weight == 0)
      return;
   if (first > second) {
      int tmp = first;
      first = second;
      second = tmp;
   }
   for (i = 0; i < *count; ++i) {
      if ((*edges)[i].first == first && (*edges)[i].second == second) {
         (*edges)[i].weight += weight;
         return;
      }
   }
   *edges = (bank_placement_edge_t *)xrealloc(*edges,
      (*count + 1) * sizeof(**edges));
   (*edges)[*count].first = first;
   (*edges)[*count].second = second;
   (*edges)[*count].weight = weight;
   (*count)++;
}

//! @brief Find an exported definition and its owning movable layout before addresses exist.
static const object_layout_t *bank_placement_export_layout(const input_set_t *in,
                                                            const char *name,
                                                            const object_file_t **object_out,
                                                            const symbol_t **symbol_out)
{
   char *weak;
   size_t pass;
   size_t i, j;

   if (object_out)
      *object_out = NULL;
   if (symbol_out)
      *symbol_out = NULL;
   if (!in || !name)
      return NULL;
   weak = make_weak_name(name);
   for (pass = 0; pass < 2; ++pass) {
      const char *wanted = pass == 0 ? name : weak;
      for (i = 0; i < in->object_count; ++i) {
         const object_file_t *obj = &in->objects[i];
         for (j = 0; j < obj->export_count; ++j) {
            const symbol_t *sym = &obj->exports[j];
            if (strcmp(sym->name, wanted) != 0)
               continue;
            if (object_out)
               *object_out = obj;
            if (symbol_out)
               *symbol_out = sym;
            free(weak);
            return sym->segid == O26_SEG_TEXT
               ? find_layout_for_value(obj, sym->segid, sym->value) : NULL;
         }
      }
   }
   free(weak);
   return NULL;
}

typedef struct {
   const object_layout_t *layout;
   const cartridge_bank_t *fixed_bank;
} bank_placement_target_t;

//! @brief Resolve the ownership relevant to pre-layout same-bank and call edges.
static bank_placement_target_t bank_placement_reloc_target(const linker_config_t *cfg,
                                                            const input_set_t *in,
                                                            const object_file_t *obj,
                                                            const reloc_t *reloc,
                                                            uint16_t current_word)
{
   bank_placement_target_t result;

   memset(&result, 0, sizeof(result));
   if (reloc->segid == O26_SEG_UNDEF) {
      const object_file_t *provider = NULL;
      const symbol_t *symbol = NULL;
      if (reloc->undef_index >= obj->undef_count)
         return result;
      result.layout = bank_placement_export_layout(in,
         obj->undefs[reloc->undef_index], &provider, &symbol);
      if (!result.layout && symbol && symbol->segid == O26_SEG_ABS)
         result.fixed_bank = cartridge_bank_for_address(cfg,
            (uint16_t)(symbol->value + current_word));
      return result;
   }
   if (reloc->has_layout_index) {
      if (reloc->layout_index < obj->layout_count &&
          obj->layouts[reloc->layout_index].segid == O26_SEG_TEXT)
         result.layout = &obj->layouts[reloc->layout_index];
      return result;
   }
   if (reloc->segid == O26_SEG_TEXT) {
      result.layout = find_layout_for_value(obj, reloc->segid, current_word);
      return result;
   }
   if (reloc->segid == O26_SEG_ABS)
      result.fixed_bank = cartridge_bank_for_address(cfg, current_word);
   return result;
}

//! @brief Read the unresolved 16-bit affine value carried by one relocation.
static uint16_t bank_placement_current_word(const o26_segment_t *segment,
                                            const reloc_t *reloc)
{
   switch (reloc->type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD)) {
      case O26_RTYPE_WORD:
         if (reloc->offset + 1 < segment->length)
            return (uint16_t)(segment->data[reloc->offset] |
                              (segment->data[reloc->offset + 1] << 8));
         break;
      case O26_RTYPE_LOW:
         if (reloc->offset < segment->length)
            return (uint16_t)(segment->data[reloc->offset] |
                              ((reloc->has_aux_low ? reloc->aux_low : 0) << 8));
         break;
      case O26_RTYPE_HIGH:
         if (reloc->offset < segment->length)
            return (uint16_t)((reloc->has_aux_low ? reloc->aux_low : 0) |
                              (segment->data[reloc->offset] << 8));
         break;
   }
   return reloc->offset < segment->length ? segment->data[reloc->offset] : 0;
}

//! @brief Attach a hard bank pin discovered before component collapse.
static void bank_placement_pin_item(bank_placement_item_t *item,
                                    const cartridge_bank_t *bank,
                                    const memory_region_t *memory,
                                    int direct)
{
   if (!item || !bank)
      return;
   if (item->pin_bank && item->pin_bank != bank) {
      fprintf(stderr,
              "vcsc-ld: contradictory bank pins for layout %s from %s: %s and %s\n",
              item->layout->name, item->obj->origin,
              item->pin_bank->name, bank->name);
      exit(1);
   }
   item->pin_bank = bank;
   if (memory)
      item->pin_memory = memory;
   if (direct)
      item->directly_pinned = 1;
}

//! @brief Find or create the capacity ledger for one allocatable banked ROM region.
static bank_placement_budget_t *bank_placement_budget_for(
                                      bank_placement_budget_t **budgets,
                                      size_t *count,
                                      const memory_region_t *memory)
{
   size_t i;

   if (!memory)
      return NULL;
   for (i = 0; i < *count; ++i) {
      if ((*budgets)[i].memory == memory)
         return &(*budgets)[i];
   }
   *budgets = (bank_placement_budget_t *)xrealloc(*budgets,
      (*count + 1) * sizeof(**budgets));
   (*budgets)[*count].memory = memory;
   (*budgets)[*count].capacity = memory->size;
   (*budgets)[*count].used = 0;
   return &(*budgets)[(*count)++];
}

//! @brief Consume one region's placement budget with a source-located diagnostic.
static void bank_placement_consume(bank_placement_budget_t **budgets,
                                   size_t *budget_count,
                                   const memory_region_t *memory,
                                   uint32_t bytes,
                                   const char *what,
                                   const char *origin)
{
   bank_placement_budget_t *budget;

   if (!memory || bytes == 0)
      return;
   budget = bank_placement_budget_for(budgets, budget_count, memory);
   if (budget->used + bytes > budget->capacity) {
      fprintf(stderr,
              "vcsc-ld: bank placement overflow in MEMORY %s while assigning %s from %s: need $%04" PRIX32 " bytes with $%04" PRIX32 " free\n",
              memory->name, what ? what : "layout", origin ? origin : "?",
              bytes, budget->capacity - budget->used);
      exit(1);
   }
   budget->used += bytes;
}

//! @brief Return available bytes in one auto-placement memory region.
static uint32_t bank_placement_budget_free(bank_placement_budget_t **budgets,
                                           size_t *budget_count,
                                           const memory_region_t *memory)
{
   bank_placement_budget_t *budget =
      bank_placement_budget_for(budgets, budget_count, memory);
   return budget->capacity >= budget->used ? budget->capacity - budget->used : 0;
}

//! @brief Give a stable preference rank to a candidate logical bank.
static int bank_placement_bank_precedes(const cartridge_bank_t *a,
                                        const cartridge_bank_t *b)
{
   if (!b)
      return 1;
   if (a->startup != b->startup)
      return a->startup > b->startup;
   if (a->start != b->start)
      return a->start > b->start;
   return strcmp(a->name, b->name) < 0;
}

//! @brief Reserve fixed ROM data images and generated startup tables before auto packing.
static void bank_placement_reserve_fixed_rom(const linker_config_t *cfg,
                                             const input_set_t *in,
                                             bank_placement_budget_t **budgets,
                                             size_t *budget_count)
{
   size_t i, j;
   size_t copy_count = 0;
   size_t zero_count = 0;
   const segment_rule_t *data_rule = find_segment_rule(cfg, "DATA");
   const memory_region_t *table_memory = data_rule && data_rule->load_name[0]
      ? find_memory(cfg, data_rule->load_name) : NULL;

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->layout_count; ++j) {
         const object_layout_t *lay = &obj->layouts[j];
         if (lay->segid != O26_SEG_TEXT &&
             (lay->image_segid == O26_SEG_DATA || lay->image_segid == O26_SEG_TEXT)) {
            const memory_region_t *memory = bank_placement_layout_memory(cfg, lay);
            bank_placement_consume(budgets, budget_count, memory, lay->size,
                                   lay->name, obj->origin);
         }
         if (lay->segid == O26_SEG_DATA ||
             (lay->segid == O26_SEG_ZP &&
              (lay->image_segid == O26_SEG_DATA || lay->image_segid == O26_SEG_TEXT)))
            copy_count++;
         if (lay->segid == O26_SEG_BSS ||
             (lay->segid == O26_SEG_ZP &&
              lay->image_segid != O26_SEG_DATA && lay->image_segid != O26_SEG_TEXT &&
              strstr(lay->name, ".__vcsc_object$") != NULL))
            zero_count++;
      }
   }
   if (table_memory) {
      uint32_t table_bytes = (uint32_t)(copy_count + 1u) * 6u +
                             (uint32_t)(zero_count + 1u) * 4u +
                             (uint32_t)(count_init_functions_in_input(in) + 1u) * 2u;
      bank_placement_consume(budgets, budget_count, table_memory, table_bytes,
                             "linker startup tables", "<linker>");
   }
}

//! @brief Assign one complete hard component to a logical bank and concrete regions.
static void bank_placement_assign_component(const linker_config_t *cfg,
                                            bank_placement_item_t *items,
                                            size_t item_count,
                                            bank_placement_component_t *component,
                                            const cartridge_bank_t *bank,
                                            bank_placement_budget_t **budgets,
                                            size_t *budget_count)
{
   const memory_region_t *auto_memory = bank_placement_auto_memory(cfg, bank);
   size_t i;

   for (i = 0; i < item_count; ++i) {
      const memory_region_t *memory;
      if (bank_placement_root(items, (int)i) != component->root)
         continue;
      memory = items[i].pin_memory ? items[i].pin_memory : auto_memory;
      if (!memory) {
         fprintf(stderr,
                 "vcsc-ld: no ordinary allocatable ROM MEMORY region is available in %s for automatic layout %s from %s\n",
                 bank->name, items[i].layout->name, items[i].obj->origin);
         exit(1);
      }
      if (!memory->bank_name[0] || !str_ieq(memory->bank_name, bank->name)) {
         fprintf(stderr,
                 "vcsc-ld: layout %s from %s is assigned to %s but MEMORY %s belongs to %s\n",
                 items[i].layout->name, items[i].obj->origin, bank->name,
                 memory->name, memory->bank_name[0] ? memory->bank_name : "no bank");
         exit(1);
      }
      bank_placement_consume(budgets, budget_count, memory,
                             items[i].layout->size,
                             items[i].layout->name, items[i].obj->origin);
      snprintf(items[i].layout->placement_memory,
               sizeof(items[i].layout->placement_memory), "%s", memory->name);
      snprintf(items[i].layout->placement_bank,
               sizeof(items[i].layout->placement_bank), "%s", bank->name);
      items[i].layout->placement_mode = items[i].directly_pinned
         ? BANK_PLACEMENT_PINNED : BANK_PLACEMENT_AUTOMATIC;
   }
   component->bank = bank;
   component->assigned = 1;
}

//! @brief Perform deterministic hard-component and soft-call-aware full-window placement.
static void assign_automatic_bank_placements(const linker_config_t *cfg,
                                             input_set_t *in)
{
   bank_placement_item_t *items = NULL;
   bank_placement_edge_t *edges = NULL;
   bank_placement_component_t *components = NULL;
   bank_placement_budget_t *budgets = NULL;
   size_t item_count = 0;
   size_t edge_count = 0;
   size_t component_count = 0;
   size_t budget_count = 0;
   const cartridge_bank_t *startup;
   size_t i, j;

   if (!cfg || !cfg->cartridge_banked)
      return;
   startup = bank_placement_startup_bank(cfg);
   if (!startup) {
      fprintf(stderr, "vcsc-ld: banked automatic placement requires one startup bank\n");
      exit(1);
   }

   /* Every ROM-resident movable layout participates, including fixed runtime
      material.  Fixed layouts act as anchors for hard data and soft calls. */
   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->layout_count; ++j) {
         object_layout_t *lay = &obj->layouts[j];
         const memory_region_t *memory;
         const cartridge_bank_t *bank;
         char base[MAX_NAME];
         const char *function_name;
         int automatic;
         int is_main = 0;
         int reserved_runtime = 0;

         if (lay->segid != O26_SEG_TEXT || lay->size == 0)
            continue;
         memory = bank_placement_layout_memory(cfg, lay);
         if (!memory || !memory->bank_name[0])
            continue;
         bank = find_cartridge_bank(cfg, memory->bank_name);
         if (!bank)
            continue;
         automatic = bank_placement_layout_is_automatic_candidate(lay);
         function_name = call_graph_layout_function_name(lay);
         is_main = function_name && strcmp(function_name, "main") == 0;
         reserved_runtime = function_name && function_name[0] == '_';

         items = (bank_placement_item_t *)xrealloc(items,
            (item_count + 1) * sizeof(*items));
         memset(&items[item_count], 0, sizeof(items[item_count]));
         items[item_count].obj = obj;
         items[item_count].layout = lay;
         items[item_count].configured_memory = memory;
         items[item_count].configured_bank = bank;
         items[item_count].stable_order = item_count;
         items[item_count].parent = (int)item_count;
         if (is_main) {
            const memory_region_t *pin_memory;
            if (!automatic && bank != startup) {
               fprintf(stderr,
                       "vcsc-ld: entry function 'main' is placed in MEMORY region '%s', which belongs to non-startup bank '%s'; the configured startup bank is '%s'\n",
                       memory->name, bank->name, startup->name);
               exit(1);
            }
            pin_memory = automatic ? bank_placement_auto_memory(cfg, startup) : memory;
            if (!pin_memory) {
               fprintf(stderr,
                       "vcsc-ld: startup bank '%s' has no ordinary allocatable ROM MEMORY region for entry function 'main'\n",
                       startup->name);
               exit(1);
            }
            bank_placement_pin_item(&items[item_count], startup,
                                    pin_memory, 1);
         }
         else if (!automatic || reserved_runtime) {
            const cartridge_bank_t *pin_bank = reserved_runtime ? startup : bank;
            const memory_region_t *pin_memory = memory;
            if (reserved_runtime && bank != startup)
               pin_memory = bank_placement_auto_memory(cfg, startup);
            bank_placement_pin_item(&items[item_count], pin_bank,
                                    pin_memory, 1);
         }
         (void)bank_placement_private_base(lay->name, base, sizeof(base));
         item_count++;
      }
   }
   if (item_count == 0)
      goto cleanup;

   /* Classify symbolic relocations before addresses exist.  Data/branch edges
      are hard same-bank constraints; direct JSR/JMP edges are weighted soft
      preferences because the common trampoline table can implement them. */
   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      o26_segment_t *segments[2] = { &obj->text, &obj->data };
      uint8_t image_segids[2] = { O26_SEG_TEXT, O26_SEG_DATA };
      size_t s;
      for (s = 0; s < 2; ++s) {
         o26_segment_t *segment = segments[s];
         size_t rindex;
         for (rindex = 0; rindex < segment->reloc_count; ++rindex) {
            reloc_t *reloc = &segment->relocs[rindex];
            const object_layout_t *source_layout =
               find_layout_for_image_offset(obj, image_segids[s], reloc->offset);
            bank_placement_target_t target;
            int source_item;
            int target_item;
            uint16_t current_word;
            uint8_t control;

            if (!source_layout)
               continue;
            current_word = bank_placement_current_word(segment, reloc);
            target = bank_placement_reloc_target(cfg, in, obj, reloc, current_word);
            source_item = bank_placement_find_item(items, item_count, source_layout);
            target_item = bank_placement_find_item(items, item_count, target.layout);
            control = reloc->type & O26_RTYPE_CONTROL_MASK;

            if ((control == O26_RTYPE_CONTROL_JSR ||
                 control == O26_RTYPE_CONTROL_JMP) &&
                !(reloc->type & O26_RTYPE_INDIRECT_JMP)) {
               bank_placement_add_edge(&edges, &edge_count,
                  source_item, target_item,
                  control == O26_RTYPE_CONTROL_JSR ? BANK_JSR_ENTRY_SIZE
                                                   : BANK_JMP_ENTRY_SIZE);
               continue;
            }

            if (source_item >= 0 && target_item >= 0) {
               bank_placement_union(items, source_item, target_item);
            }
            else if (target_item >= 0) {
               const memory_region_t *source_memory =
                  bank_placement_layout_memory(cfg, source_layout);
               const cartridge_bank_t *source_bank =
                  source_memory && source_memory->bank_name[0]
                     ? find_cartridge_bank(cfg, source_memory->bank_name) : NULL;
               if (source_bank)
                  bank_placement_pin_item(&items[target_item], source_bank,
                                          NULL, 1);
            }
            else if (source_item >= 0 && target.fixed_bank) {
               bank_placement_pin_item(&items[source_item], target.fixed_bank,
                                       NULL, 1);
            }
         }
      }

      /* Retained short branches are also hard same-bank edges. */
      for (j = 0; j < obj->branch_count; ++j) {
         const branch_t *branch = &obj->branches[j];
         const object_layout_t *source =
            find_layout_for_value(obj, branch->segid, branch->source);
         const object_layout_t *target =
            find_layout_for_value(obj, branch->segid, branch->target);
         int source_item = bank_placement_find_item(items, item_count, source);
         int target_item = bank_placement_find_item(items, item_count, target);
         if (source_item >= 0 && target_item >= 0)
            bank_placement_union(items, source_item, target_item);
      }
   }

   /* Compact union-find roots into stable component records and diagnose
      incompatible explicit or inherited hard pins. */
   for (i = 0; i < item_count; ++i) {
      int root = bank_placement_root(items, (int)i);
      size_t c;
      for (c = 0; c < component_count; ++c) {
         if (components[c].root == root)
            break;
      }
      if (c == component_count) {
         components = (bank_placement_component_t *)xrealloc(components,
            (component_count + 1) * sizeof(*components));
         memset(&components[component_count], 0, sizeof(components[component_count]));
         components[component_count].root = root;
         components[component_count].id = (uint16_t)component_count;
         components[component_count].stable_order = items[i].stable_order;
         component_count++;
      }
      components[c].bytes += items[i].layout->size;
      if (items[i].stable_order < components[c].stable_order)
         components[c].stable_order = items[i].stable_order;
      if (items[i].pin_bank) {
         if (components[c].bank && components[c].bank != items[i].pin_bank) {
            fprintf(stderr,
                    "vcsc-ld: hard bank-placement component %u has contradictory pins: %s from %s requires %s, but another member requires %s\n",
                    components[c].id, items[i].layout->name,
                    items[i].obj->origin, items[i].pin_bank->name,
                    components[c].bank->name);
            exit(1);
         }
         components[c].bank = items[i].pin_bank;
         components[c].pinned = 1;
      }
   }

   /* Collapse soft edges to components and accumulate deterministic degree. */
   for (i = 0; i < edge_count; ++i) {
      int first_root = bank_placement_root(items, edges[i].first);
      int second_root = bank_placement_root(items, edges[i].second);
      size_t first_component = 0;
      size_t second_component = 0;
      if (first_root == second_root)
         continue;
      while (components[first_component].root != first_root)
         first_component++;
      while (components[second_component].root != second_root)
         second_component++;
      components[first_component].degree += edges[i].weight;
      components[second_component].degree += edges[i].weight;
   }

   bank_placement_reserve_fixed_rom(cfg, in, &budgets, &budget_count);

   /* Hard-pinned components are assigned first in stable order. */
   for (;;) {
      bank_placement_component_t *next = NULL;
      for (i = 0; i < component_count; ++i) {
         if (!components[i].pinned || components[i].assigned)
            continue;
         if (!next || components[i].stable_order < next->stable_order)
            next = &components[i];
      }
      if (!next)
         break;
      bank_placement_assign_component(cfg, items, item_count, next,
                                      next->bank, &budgets, &budget_count);
   }

   /* First-fit-decreasing component order, with a weighted cut-cost choice
      among banks that still have enough ordinary ROM capacity. */
   for (;;) {
      bank_placement_component_t *next = NULL;
      const cartridge_bank_t *best_bank = NULL;
      uint32_t best_cut = 0;

      for (i = 0; i < component_count; ++i) {
         if (components[i].assigned)
            continue;
         if (!next || components[i].bytes > next->bytes ||
             (components[i].bytes == next->bytes &&
              components[i].degree > next->degree) ||
             (components[i].bytes == next->bytes &&
              components[i].degree == next->degree &&
              components[i].stable_order < next->stable_order))
            next = &components[i];
      }
      if (!next)
         break;

      for (i = 0; i < cfg->bank_count; ++i) {
         const cartridge_bank_t *candidate = &cfg->banks[i];
         const memory_region_t *memory = bank_placement_auto_memory(cfg, candidate);
         uint32_t cut = 0;
         size_t e;

         if (!memory || bank_placement_budget_free(&budgets, &budget_count, memory) < next->bytes)
            continue;
         for (e = 0; e < edge_count; ++e) {
            int first_root = bank_placement_root(items, edges[e].first);
            int second_root = bank_placement_root(items, edges[e].second);
            int other_root = -1;
            size_t c;
            if (first_root == next->root)
               other_root = second_root;
            else if (second_root == next->root)
               other_root = first_root;
            if (other_root < 0 || other_root == next->root)
               continue;
            for (c = 0; c < component_count; ++c) {
               if (components[c].root == other_root && components[c].assigned) {
                  if (components[c].bank != candidate)
                     cut += edges[e].weight;
                  break;
               }
            }
         }
         if (!best_bank || cut < best_cut ||
             (cut == best_cut && bank_placement_bank_precedes(candidate, best_bank))) {
            best_bank = candidate;
            best_cut = cut;
         }
      }

      if (!best_bank) {
         fprintf(stderr,
                 "vcsc-ld: automatic bank placement cannot fit hard component %u ($%04" PRIX32 " bytes); available ordinary ROM:",
                 next->id, next->bytes);
         for (i = 0; i < cfg->bank_count; ++i) {
            const memory_region_t *memory = bank_placement_auto_memory(cfg, &cfg->banks[i]);
            fprintf(stderr, " %s/%s=$%04" PRIX32,
                    cfg->banks[i].name, memory ? memory->name : "<none>",
                    memory ? bank_placement_budget_free(&budgets, &budget_count, memory) : 0);
         }
         fputc('\n', stderr);
         exit(1);
      }
      bank_placement_assign_component(cfg, items, item_count, next,
                                      best_bank, &budgets, &budget_count);
   }

   /* Record final component identity, pin state, byte cost, and cut weight for
      map output and later weighted call-stack analysis. */
   for (i = 0; i < edge_count; ++i) {
      int first_root = bank_placement_root(items, edges[i].first);
      int second_root = bank_placement_root(items, edges[i].second);
      size_t first_component = 0;
      size_t second_component = 0;
      if (first_root == second_root)
         continue;
      while (components[first_component].root != first_root)
         first_component++;
      while (components[second_component].root != second_root)
         second_component++;
      if (components[first_component].bank != components[second_component].bank) {
         components[first_component].cut_weight += edges[i].weight;
         components[second_component].cut_weight += edges[i].weight;
      }
   }
   for (i = 0; i < item_count; ++i) {
      int root = bank_placement_root(items, (int)i);
      size_t c = 0;
      while (components[c].root != root)
         c++;
      items[i].layout->placement_component = components[c].id;
      items[i].layout->placement_component_pinned = (uint8_t)components[c].pinned;
      items[i].layout->placement_component_bytes = components[c].bytes;
      items[i].layout->placement_cut_weight = components[c].cut_weight;
   }

cleanup:
   free(items);
   free(edges);
   free(components);
   free(budgets);
}

typedef struct {
   uint16_t address;
   uint16_t owner_address;
   uint8_t segid;
   const char *name;
   const object_layout_t *owner_layout;
} resolved_reloc_target_t;

//! @brief Resolve one relocation while retaining the symbol/layout address used for bank identity.
static resolved_reloc_target_t resolve_reloc_target(const object_file_t *obj,
                                                    const reloc_t *r,
                                                    uint16_t current_word,
                                                    const layout_t *layout)
{
   resolved_reloc_target_t result;

   memset(&result, 0, sizeof(result));
   result.name = "<local relocation>";

   if (r->segid == O26_SEG_UNDEF) {
      const global_symbol_t *global;
      if (r->undef_index >= obj->undef_count) {
         fprintf(stderr, "vcsc-ld: bad undefined-symbol index in %s\n", obj->origin);
         exit(1);
      }
      global = lookup_global_symbol(layout, obj->undefs[r->undef_index]);
      result.address = (uint16_t)(global->addr + current_word);
      result.owner_address = global->addr;
      result.segid = global->segid;
      result.name = obj->undefs[r->undef_index];
      return result;
   }

   if (r->has_layout_index) {
      const object_layout_t *lay;
      uint16_t base;
      if (r->layout_index >= obj->layout_count) {
         fprintf(stderr, "vcsc-ld: relocation layout index %u is out of range in %s\n",
                 (unsigned)r->layout_index, obj->origin);
         exit(1);
      }
      lay = &obj->layouts[r->layout_index];
      if (lay->segid != r->segid) {
         fprintf(stderr,
                 "vcsc-ld: relocation layout '%s' has segment %u, expected %u in %s\n",
                 lay->name, (unsigned)lay->segid, (unsigned)r->segid, obj->origin);
         exit(1);
      }
      base = (r->segid == O26_SEG_TEXT) ? lay->load_addr : lay->run_addr;
      result.address = object_runtime_addr_for_layout_value(obj, r->layout_index,
                                                            r->segid, current_word);
      result.owner_address = base;
      result.segid = r->segid;
      result.name = lay->name;
      result.owner_layout = lay;
      return result;
   }

   if (r->segid == O26_SEG_ABS) {
      result.address = current_word;
      result.owner_address = current_word;
      result.segid = O26_SEG_ABS;
      result.name = "<absolute symbol>";
      return result;
   }

   result.owner_layout = find_layout_for_value(obj, r->segid, current_word);
   if (!result.owner_layout) {
      fprintf(stderr, "vcsc-ld: could not map packed relocation value $%04X in %s for segment %u\n",
              current_word, obj->origin, (unsigned)r->segid);
      exit(1);
   }
   result.owner_address = (r->segid == O26_SEG_TEXT)
      ? result.owner_layout->load_addr : result.owner_layout->run_addr;
   result.address = object_runtime_addr_for_value(obj, r->segid, current_word);
   result.segid = r->segid;
   result.name = result.owner_layout->name;
   return result;
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
      block_start = alloc_from_region_policy(layout, cfg, regions[i], (uint16_t)extent,
                                      1, NULL, "activation overlay", "<call graph>");

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
                            memory_runtime_write_address(cfg, regions[i],
                                                         piece->layout->run_addr,
                                                         piece->layout->size),
                            piece->layout->size);
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
   layout->call_stack_weighted_depth = cfg->call_stack_weighted_depth;
   layout->call_stack_bank_extra_slots = cfg->call_stack_bank_extra_slots;
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

      obj->place_text_load = 0;
      obj->place_data_load = 0;
      for (j = 0; j < obj->layout_count; ++j) {
         obj->layouts[j].load_addr = 0;
         obj->layouts[j].run_addr = 0;
      }

      /* Place each ROM-resident text layout independently. Compiler data
         objects therefore remain individually movable instead of inheriting
         the page fate of an entire translation unit. */
      for (j = 0; j < obj->layout_count; ++j) {
         object_layout_t *lay = &obj->layouts[j];
         const segment_rule_t *rule;
         const char *load_name;

         if (lay->segid != O26_SEG_TEXT)
            continue;
         rule = find_layout_segment_rule(cfg, lay->name, code);
         load_name = lay->placement_memory[0] ? lay->placement_memory
            : ((rule && rule->load_name[0]) ? rule->load_name : code_load_name);
         lay->load_addr = alloc_code_branch_aware(layout, cfg, load_name, obj, lay,
            rule ? rule->align : 1, lay->name, obj->origin);
         lay->run_addr = lay->load_addr;
      }

      /* Place initialized RAM images independently as ordinary soft ROM
         objects. Hard page containment applies to the runtime object, not to
         its initializer copy in cartridge ROM. */
      for (j = 0; j < obj->layout_count; ++j) {
         object_layout_t *lay = &obj->layouts[j];
         const segment_rule_t *rule;
         const char *load_name;

         if (lay->segid == O26_SEG_TEXT ||
             (lay->image_segid != O26_SEG_DATA && lay->image_segid != O26_SEG_TEXT))
            continue;
         rule = find_layout_segment_rule(cfg, lay->name, data);
         load_name = (rule && rule->load_name[0]) ? rule->load_name : data_load_name;
         lay->load_addr = alloc_from_region_policy(layout, cfg, load_name, lay->size,
            rule ? rule->align : 1, NULL, lay->name, obj->origin);
      }

      for (j = 0; j < obj->layout_count; ++j) {
         object_layout_t *lay = &obj->layouts[j];
         char suffix_storage[MAX_NAME];
         const char *suffix = segment_name_suffix(lay->name, suffix_storage, sizeof(suffix_storage));
         char activation_region[MAX_NAME];
         const char *activation_owner = NULL;

         if (activation_segment_parse(lay->name, activation_region,
                                      sizeof(activation_region),
                                      &activation_owner)) {
            (void)activation_owner;
            continue;
         }

         switch (lay->segid) {
            case O26_SEG_TEXT:
               break;

            case O26_SEG_DATA: {
               const char *run_name = (suffix && segment_name_matches_prefix(lay->name, "DATA")) ? suffix : data_run_name;
               lay->run_addr = alloc_from_region_policy(layout, cfg, run_name, lay->size, 1,
                  lay, lay->name, obj->origin);
               add_copy_record(layout, lay->name, lay->load_addr,
                               memory_runtime_write_address(cfg, run_name, lay->run_addr, lay->size),
                               lay->size);
               break;
            }

            case O26_SEG_BSS: {
               const char *run_name = (suffix && segment_name_matches_prefix(lay->name, "BSS")) ? suffix : bss_run_name;
               lay->run_addr = alloc_from_region_policy(layout, cfg, run_name, lay->size, 1,
                  lay, lay->name, obj->origin);
               add_zero_record(layout, lay->name,
                               memory_runtime_write_address(cfg, run_name, lay->run_addr, lay->size),
                               lay->size);
               break;
            }

            case O26_SEG_ZP: {
               const char *run_name = (suffix && (segment_name_matches_prefix(lay->name, "ZEROPAGE") || segment_name_matches_prefix(lay->name, "ZP") || segment_name_matches_prefix(lay->name, "ZERO"))) ? suffix : zp_run_name;
               lay->run_addr = alloc_from_region_policy(layout, cfg, run_name, lay->size, 1,
                  lay, lay->name, obj->origin);
               if (lay->image_segid == O26_SEG_DATA || lay->image_segid == O26_SEG_TEXT)
                  add_copy_record(layout, lay->name, lay->load_addr,
                                  memory_runtime_write_address(cfg, run_name, lay->run_addr, lay->size),
                                  lay->size);
               else if (strstr(lay->name, ".__vcsc_object$") != NULL)
                  add_zero_record(layout, lay->name,
                                  memory_runtime_write_address(cfg, run_name, lay->run_addr, lay->size),
                                  lay->size);
               break;
            }
         }
      }
   }

   layout_activation_segments(cfg, in, layout, bss_run_name, zp_run_name);

   layout->copy_table_addr = alloc_from_region_policy(layout, cfg, data_load_name,
      (uint16_t)((layout->copy_record_count + 1) * 6), 1, NULL,
      "__copy_table", "<linker>");
   layout->zero_table_addr = alloc_from_region_policy(layout, cfg, data_load_name,
      (uint16_t)((layout->zero_record_count + 1) * 4), 1, NULL,
      "__zero_table", "<linker>");
   {
      size_t init_count = count_init_functions_in_input(in);
      layout->init_table_addr = alloc_from_region_policy(layout, cfg, data_load_name,
         (uint16_t)((init_count + 1) * 2), 1, NULL,
         "__init_table", "<linker>");
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

//! @brief Return a stable diagnostic spelling for one relocation width.
static const char *relocation_width_name(uint8_t type)
{
   switch (type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD)) {
      case O26_RTYPE_LOW:  return "low-byte";
      case O26_RTYPE_HIGH: return "high-byte";
      case O26_RTYPE_WORD: return "word";
      default:             return "unknown-width";
   }
}

//! @brief Return the encoded byte size for one generated bank trampoline entry.
static uint16_t bank_trampoline_entry_size(uint8_t kind)
{
   return kind == BANK_TRAMPOLINE_JSR ? BANK_JSR_ENTRY_SIZE : BANK_JMP_ENTRY_SIZE;
}

//! @brief Return the inline indirect-target word offset within one entry.
static uint16_t bank_trampoline_pointer_offset(uint8_t kind)
{
   return kind == BANK_TRAMPOLINE_JSR ? 13u : 6u;
}

//! @brief Find or append one deduplicated direct cross-bank transfer entry.
static bank_trampoline_entry_t *find_or_add_bank_trampoline_entry(
                                                       layout_t *layout,
                                                       const linker_config_t *cfg,
                                                       const resolved_reloc_target_t *target,
                                                       const cartridge_bank_t *source_bank,
                                                       const cartridge_bank_t *destination_bank,
                                                       uint8_t kind)
{
   size_t i;
   bank_trampoline_entry_t *entry;
   uint16_t next_offset;
   uint16_t entry_size;
   uint16_t pointer_offset;
   uint32_t next_end;

   for (i = 0; i < layout->bank_trampoline_entry_count; ++i) {
      entry = &layout->bank_trampoline_entries[i];
      if (entry->kind == kind &&
          entry->target_addr == target->address &&
          entry->destination_hotspot == destination_bank->hotspot &&
          (kind != BANK_TRAMPOLINE_JSR ||
           entry->source_hotspot == source_bank->hotspot))
         return entry;
   }

   entry_size = bank_trampoline_entry_size(kind);
   pointer_offset = bank_trampoline_pointer_offset(kind);
   next_offset = layout->bank_trampoline_used;
   /* The inline target word is read by NMOS JMP (absolute).  Insert one fill
      byte when the word would begin at page offset $FF. */
   if (((cfg->trampoline_offset + next_offset + pointer_offset) & 0x00FFu) == 0x00FFu)
      next_offset++;
   next_end = (uint32_t)next_offset + entry_size;
   if (next_end > cfg->trampoline_size) {
      fprintf(stderr,
              "vcsc-ld: common trampoline corridor $%03X-$%03X is exhausted while adding %s target '%s' at $%04X (%s); %zu entries already consume $%03X bytes and this entry needs %u bytes\n",
              cfg->trampoline_offset,
              (uint16_t)(cfg->trampoline_offset + cfg->trampoline_size - 1u),
              kind == BANK_TRAMPOLINE_JSR ? "JSR" : "JMP",
              target->name, target->address, destination_bank->name,
              layout->bank_trampoline_entry_count,
              layout->bank_trampoline_used, entry_size);
      exit(1);
   }

   layout->bank_trampoline_entries = (bank_trampoline_entry_t *)xrealloc(
      layout->bank_trampoline_entries,
      (layout->bank_trampoline_entry_count + 1) * sizeof(*layout->bank_trampoline_entries));
   entry = &layout->bank_trampoline_entries[layout->bank_trampoline_entry_count++];
   memset(entry, 0, sizeof(*entry));
   entry->kind = kind;
   entry->target_addr = target->address;
   entry->table_offset = next_offset;
   entry->source_hotspot = source_bank ? source_bank->hotspot : 0;
   entry->destination_hotspot = destination_bank->hotspot;
   entry->target_name = xstrdup(target->name);
   if (source_bank) {
      snprintf(entry->source_bank, sizeof(entry->source_bank), "%s",
               source_bank->name);
   }
   snprintf(entry->destination_bank, sizeof(entry->destination_bank), "%s",
            destination_bank->name);
   layout->bank_trampoline_used = (uint16_t)next_end;
   return entry;
}

//! @brief Return true when a relocation targets one of a shared split-address RAM region's aliases.
static int relocation_targets_shared_split_memory(const linker_config_t *cfg,
                                                  const resolved_reloc_target_t *target)
{
   size_t i;

   if (!cfg || !target ||
       (target->segid != O26_SEG_DATA &&
        target->segid != O26_SEG_BSS &&
        target->segid != O26_SEG_ZP))
      return 0;

   for (i = 0; i < cfg->mem_count; ++i) {
      const memory_region_t *mem = &cfg->mem[i];
      uint32_t read_end;
      uint32_t write_end;
      int owner_in_read;
      int target_in_read;
      int target_in_write;

      if (!mem->has_write_start || mem->bank_name[0] || !str_ieq(mem->type, "rw"))
         continue;
      read_end = (uint32_t)mem->start + mem->size;
      write_end = (uint32_t)mem->write_start + mem->size;
      owner_in_read = target->owner_address >= mem->start &&
                      (uint32_t)target->owner_address < read_end;
      target_in_read = target->address >= mem->start &&
                       (uint32_t)target->address < read_end;
      target_in_write = target->address >= mem->write_start &&
                        (uint32_t)target->address < write_end;
      if (owner_in_read && (target_in_read || target_in_write))
         return 1;
   }
   return 0;
}

//! @brief Validate or rewrite one resolved relocation at a full-window bank boundary.
static uint16_t rewrite_banked_relocation(const linker_config_t *cfg,
                                          const object_file_t *obj,
                                          uint8_t image_segid,
                                          const reloc_t *r,
                                          const resolved_reloc_target_t *target,
                                          layout_t *layout)
{
   const object_layout_t *source_layout;
   const cartridge_bank_t *source_bank;
   const cartridge_bank_t *owner_bank;
   const cartridge_bank_t *final_bank;
   const cartridge_bank_t *different_bank = NULL;
   uint16_t source_address;
   uint8_t control;

   if (!cfg || !cfg->cartridge_banked)
      return target->address;

   source_layout = find_layout_for_image_offset(obj, image_segid, r->offset);
   if (!source_layout) {
      fprintf(stderr,
              "vcsc-ld: could not identify source layout for relocation offset $%04X in %s\n",
              (unsigned)r->offset, obj->origin);
      exit(1);
   }
   source_address = (uint16_t)(source_layout->load_addr +
      (uint16_t)(r->offset - source_layout->image_base));
   source_bank = cartridge_bank_for_address(cfg, source_address);
   if (!source_bank)
      return target->address;

   /* A split-address RAM region shares both aliases across every physical ROM
      bank.  Its addresses overlap the cartridge window, so classifying them by
      numeric address alone would falsely turn ordinary RAM accesses into
      cross-bank ROM references. */
   if (relocation_targets_shared_split_memory(cfg, target))
      return target->address;

   owner_bank = cartridge_bank_for_address(cfg, target->owner_address);
   final_bank = cartridge_bank_for_address(cfg, target->address);
   if (owner_bank && owner_bank != source_bank)
      different_bank = owner_bank;
   else if (final_bank && final_bank != source_bank)
      different_bank = final_bank;
   if (!different_bank)
      return target->address;

   control = r->type & O26_RTYPE_CONTROL_MASK;
   if (control == O26_RTYPE_CONTROL_JSR) {
      bank_trampoline_entry_t *entry;
      uint32_t address;
      if (!final_bank || final_bank == source_bank) {
         fprintf(stderr,
                 "vcsc-ld: cross-bank JSR in %s layout '%s' at $%04X (%s) targets '%s' at $%04X, which does not resolve inside the destination bank\n",
                 obj->origin, source_layout->name, source_address, source_bank->name,
                 target->name, target->address);
         exit(1);
      }
      if ((r->type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD)) !=
          O26_RTYPE_WORD) {
         fprintf(stderr,
                 "vcsc-ld: direct cross-bank JSR relocation in %s is not a 16-bit operand\n",
                 obj->origin);
         exit(1);
      }
      entry = find_or_add_bank_trampoline_entry(layout, cfg, target,
                                                source_bank, final_bank,
                                                BANK_TRAMPOLINE_JSR);
      address = (uint32_t)source_bank->start + cfg->trampoline_offset +
                entry->table_offset;
      if (address > 0xFFFFu) {
         fprintf(stderr, "vcsc-ld: generated JSR trampoline address overflow\n");
         exit(1);
      }
      return (uint16_t)address;
   }
   if (control == O26_RTYPE_CONTROL_JMP) {
      bank_trampoline_entry_t *entry;
      uint32_t address;
      if (!final_bank || final_bank == source_bank) {
         fprintf(stderr,
                 "vcsc-ld: cross-bank JMP in %s layout '%s' at $%04X (%s) targets '%s' at $%04X, which does not resolve inside the destination bank\n",
                 obj->origin, source_layout->name, source_address, source_bank->name,
                 target->name, target->address);
         exit(1);
      }
      if ((r->type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD)) !=
          O26_RTYPE_WORD) {
         fprintf(stderr,
                 "vcsc-ld: direct cross-bank JMP relocation in %s is not a 16-bit operand\n",
                 obj->origin);
         exit(1);
      }
      entry = find_or_add_bank_trampoline_entry(layout, cfg, target,
                                                source_bank, final_bank,
                                                BANK_TRAMPOLINE_JMP);
      address = (uint32_t)source_bank->start + cfg->trampoline_offset +
                entry->table_offset;
      if (address > 0xFFFFu) {
         fprintf(stderr, "vcsc-ld: generated JMP trampoline address overflow\n");
         exit(1);
      }
      return (uint16_t)address;
   }
   if (control == O26_RTYPE_CONTROL_BRANCH) {
      fprintf(stderr,
              "vcsc-ld: cross-bank conditional branch in %s layout '%s' at $%04X (%s) targets '%s' at $%04X (%s); conditional branches may not cross banks\n",
              obj->origin, source_layout->name, source_address, source_bank->name,
              target->name, target->address, different_bank->name);
      exit(1);
   }

   fprintf(stderr,
           "vcsc-ld: cross-bank ROM %s relocation in %s layout '%s' at $%04X (%s) targets '%s' at $%04X (%s); cross-bank ROM data references are not allowed%s\n",
           relocation_width_name(r->type), obj->origin, source_layout->name,
           source_address, source_bank->name, target->name, target->address,
           different_bank->name,
           (r->type & O26_RTYPE_INDIRECT_JMP) ?
              " (the indirect-JMP vector is a data reference)" : "");
   exit(1);
}

//! @brief Handle apply segment relocs logic for linker layout and image writer.
static void apply_segment_relocs(object_file_t *obj, o26_segment_t *seg,
                                 layout_t *layout,
                                 const linker_config_t *cfg,
                                 uint8_t image_segid,
                                 const char *seg_name)
{
   size_t i;
   for (i = 0; i < seg->reloc_count; ++i) {
      reloc_t *r = &seg->relocs[i];
      uint16_t current_word;
      resolved_reloc_target_t target;
      uint16_t resolved_address;
      const char *who = obj->origin;
      (void)seg_name;

      if (r->offset >= seg->length) {
         fprintf(stderr, "vcsc-ld: relocation offset out of range in %s\n", who);
         exit(1);
      }

      switch (r->type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD)) {
         case O26_RTYPE_WORD:
            if (r->offset + 1 >= seg->length) {
               fprintf(stderr, "vcsc-ld: relocation word offset out of range in %s\n", who);
               exit(1);
            }
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

      target = resolve_reloc_target(obj, r, current_word, layout);
      resolved_address = rewrite_banked_relocation(cfg, obj, image_segid, r,
                                                   &target, layout);

      if ((r->type & O26_RTYPE_INDIRECT_JMP) && (resolved_address & 0xffu) == 0xffu) {
         fprintf(stderr,
                 "vcsc-ld: indirect JMP vector at $%04X in %s triggers the NMOS 6502/6507 page-wrap bug\n",
                 resolved_address, who);
         exit(1);
      }

      switch (r->type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD)) {
         case O26_RTYPE_LOW:
            patch_u8(seg->data, seg->length, r->offset, (uint8_t)(resolved_address & 0xFFu), who);
            break;
         case O26_RTYPE_HIGH:
            patch_u8(seg->data, seg->length, r->offset, (uint8_t)((resolved_address >> 8) & 0xFFu), who);
            break;
         case O26_RTYPE_WORD:
            patch_u16(seg->data, seg->length, r->offset, resolved_address, who);
            break;
         default:
            fprintf(stderr, "vcsc-ld: unsupported relocation type 0x%02x in %s\n", r->type, who);
            exit(1);
      }
   }
}

//! @brief Compute all and update linker layout and image writer state once prerequisite pass data is available.
static void resolve_all(input_set_t *in, layout_t *layout,
                        const linker_config_t *cfg)
{
   size_t i;
   for (i = 0; i < in->object_count; ++i) {
      apply_segment_relocs(&in->objects[i], &in->objects[i].text, layout, cfg,
                           O26_SEG_TEXT, "text");
      apply_segment_relocs(&in->objects[i], &in->objects[i].data, layout, cfg,
                           O26_SEG_DATA, "data");
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

//! @brief Write linker-generated fixed bytes without overwriting placed material.
static void image_write_generated(uint8_t *image, uint8_t *used, uint16_t addr,
                                  const uint8_t *src, size_t len,
                                  const char *who)
{
   size_t i;
   for (i = 0; i < len; ++i) {
      uint32_t a = (uint32_t)addr + i;
      if (a > 0xFFFFu) {
         fprintf(stderr, "vcsc-ld: image write overflow from %s\n", who);
         exit(1);
      }
      if (used[a]) {
         fprintf(stderr,
                 "vcsc-ld: linker-generated %s overlaps placed byte at $%04X\n",
                 who, (unsigned)a);
         exit(1);
      }
   }
   image_write(image, used, addr, src, len, who);
}

//! @brief Encode one common BIT-hotspot/JMP-handler vector bridge entry.
static void encode_vector_bridge_entry(uint8_t *table, size_t offset,
                                       uint16_t bank0_hotspot,
                                       uint16_t handler)
{
   table[offset + 0u] = 0x2Cu; /* BIT absolute */
   table[offset + 1u] = (uint8_t)(bank0_hotspot & 0xFFu);
   table[offset + 2u] = (uint8_t)((bank0_hotspot >> 8) & 0xFFu);
   table[offset + 3u] = 0x4Cu; /* JMP absolute */
   table[offset + 4u] = (uint8_t)(handler & 0xFFu);
   table[offset + 5u] = (uint8_t)((handler >> 8) & 0xFFu);
}

//! @brief Encode one state-preserving inline-pointer JMP entry for the common table.
static void encode_bank_jump_entry(uint8_t *table, size_t offset,
                                   const bank_trampoline_entry_t *entry,
                                   uint16_t canonical_pointer)
{
   table[offset + 0u] = 0x8Du; /* STA destination hotspot; preserves A and flags. */
   table[offset + 1u] = (uint8_t)(entry->destination_hotspot & 0xFFu);
   table[offset + 2u] = (uint8_t)((entry->destination_hotspot >> 8) & 0xFFu);
   table[offset + 3u] = 0x6Cu; /* JMP through the inline target word. */
   table[offset + 4u] = (uint8_t)(canonical_pointer & 0xFFu);
   table[offset + 5u] = (uint8_t)((canonical_pointer >> 8) & 0xFFu);
   table[offset + 6u] = (uint8_t)(entry->target_addr & 0xFFu);
   table[offset + 7u] = (uint8_t)((entry->target_addr >> 8) & 0xFFu);
}

//! @brief Encode one state-preserving JSR-to-indirect-JMP entry.
static void encode_bank_jsr_entry(uint8_t *table, size_t offset,
                                  const bank_trampoline_entry_t *entry,
                                  uint16_t canonical_entry,
                                  uint16_t canonical_pointer)
{
   uint16_t body = (uint16_t)(canonical_entry + 7u);

   /* The first JSR creates the synthetic return address without touching any
      register or processor flag.  The target's RTS returns to the embedded
      source-bank restore stub, whose final RTS consumes the call site's
      original return address. */
   table[offset + 0u] = 0x20u; /* JSR absolute to the entry body. */
   table[offset + 1u] = (uint8_t)(body & 0xFFu);
   table[offset + 2u] = (uint8_t)((body >> 8) & 0xFFu);
   table[offset + 3u] = 0x8Du; /* STA source hotspot; preserves A and flags. */
   table[offset + 4u] = (uint8_t)(entry->source_hotspot & 0xFFu);
   table[offset + 5u] = (uint8_t)((entry->source_hotspot >> 8) & 0xFFu);
   table[offset + 6u] = 0x60u; /* RTS through the original caller return. */
   table[offset + 7u] = 0x8Du; /* STA destination hotspot. */
   table[offset + 8u] = (uint8_t)(entry->destination_hotspot & 0xFFu);
   table[offset + 9u] = (uint8_t)((entry->destination_hotspot >> 8) & 0xFFu);
   table[offset + 10u] = 0x6Cu; /* JMP through the inline target word. */
   table[offset + 11u] = (uint8_t)(canonical_pointer & 0xFFu);
   table[offset + 12u] = (uint8_t)((canonical_pointer >> 8) & 0xFFu);
   table[offset + 13u] = (uint8_t)(entry->target_addr & 0xFFu);
   table[offset + 14u] = (uint8_t)((entry->target_addr >> 8) & 0xFFu);
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
   if (!cfg->cartridge_banked && !rom) {
      fprintf(stderr, "vcsc-ld: ROM memory region not found\n");
      exit(1);
   }
   memset(image, cfg->cartridge_fill_value, 65536);
   memset(used, 0, 65536);

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      size_t j;
      for (j = 0; j < obj->layout_count; ++j) {
         const object_layout_t *lay = &obj->layouts[j];
         const uint8_t *src;
         size_t image_len;

         if (lay->size == 0)
            continue;
         if (lay->image_segid == O26_SEG_TEXT) {
            image_len = obj->text.length;
            if ((uint32_t)lay->image_base + lay->size > image_len) {
               fprintf(stderr, "vcsc-ld: text image layout %s exceeds packed image in %s\n",
                       lay->name, obj->origin);
               exit(1);
            }
            src = obj->text.data + lay->image_base;
         } else if (lay->image_segid == O26_SEG_DATA) {
            image_len = obj->data.length;
            if ((uint32_t)lay->image_base + lay->size > image_len) {
               fprintf(stderr, "vcsc-ld: data image layout %s exceeds packed image in %s\n",
                       lay->name, obj->origin);
               exit(1);
            }
            src = obj->data.data + lay->image_base;
         } else {
            continue;
         }
         image_write(image, used, lay->load_addr, src, lay->size, obj->origin);
      }
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

   if (cfg->cartridge_banked) {
      const cartridge_bank_t *startup = NULL;
      uint8_t bridge[VECTOR_BRIDGE_SIZE];
      uint8_t vectors[6];
      uint16_t bridge_base;
      uint16_t bank0_hotspot;
      uint32_t startup_end;

      for (i = 0; i < cfg->bank_count; ++i) {
         if (cfg->banks[i].startup) {
            startup = &cfg->banks[i];
            break;
         }
      }
      if (!startup) {
         fprintf(stderr, "vcsc-ld: banked configuration has no startup bank\n");
         exit(1);
      }
      startup_end = (uint32_t)startup->start + startup->size;
      if (reset < startup->start || reset >= startup_end ||
          nmi < startup->start || nmi >= startup_end ||
          irqbrk < startup->start || irqbrk >= startup_end) {
         fprintf(stderr,
                 "vcsc-ld: __reset, __nmi, and __irqbrk must all reside in startup bank %s\n",
                 startup->name);
         exit(1);
      }

      if (layout->bank_trampoline_used > 0) {
         uint8_t *trampoline;
         size_t j;
         trampoline = (uint8_t *)xmalloc(layout->bank_trampoline_used);
         memset(trampoline, cfg->cartridge_fill_value, layout->bank_trampoline_used);
         for (j = 0; j < layout->bank_trampoline_entry_count; ++j) {
            const bank_trampoline_entry_t *entry = &layout->bank_trampoline_entries[j];
            uint16_t pointer_offset = bank_trampoline_pointer_offset(entry->kind);
            uint16_t canonical_entry = (uint16_t)(startup->start +
               cfg->trampoline_offset + entry->table_offset);
            uint16_t canonical_pointer = (uint16_t)(startup->start +
               cfg->trampoline_offset + entry->table_offset + pointer_offset);
            if ((canonical_pointer & 0x00FFu) == 0x00FFu) {
               fprintf(stderr,
                       "vcsc-ld: generated inline JMP target pointer at $%04X triggers the NMOS page-wrap bug\n",
                       canonical_pointer);
               exit(1);
            }
            if (entry->kind == BANK_TRAMPOLINE_JSR) {
               encode_bank_jsr_entry(trampoline, entry->table_offset, entry,
                                     canonical_entry, canonical_pointer);
            }
            else {
               encode_bank_jump_entry(trampoline, entry->table_offset, entry,
                                      canonical_pointer);
            }
         }
         for (j = 0; j < cfg->bank_count; ++j) {
            uint16_t bank_trampoline =
               (uint16_t)(cfg->banks[j].start + cfg->trampoline_offset);
            image_write_generated(image, used, bank_trampoline, trampoline,
                                  layout->bank_trampoline_used,
                                  "common bank trampoline table");
         }
         free(trampoline);
      }

      bridge_base = (uint16_t)(startup->start + cfg->vector_bridge_offset);
      bank0_hotspot = startup->hotspot;
      encode_vector_bridge_entry(bridge, VECTOR_BRIDGE_NMI_OFFSET,
                                 bank0_hotspot, nmi);
      encode_vector_bridge_entry(bridge, VECTOR_BRIDGE_RESET_OFFSET,
                                 bank0_hotspot, reset);
      encode_vector_bridge_entry(bridge, VECTOR_BRIDGE_IRQBRK_OFFSET,
                                 bank0_hotspot, irqbrk);

      /* Every bank receives the exact same bridge bytes and vector words. The
         vectors use BANK0's logical mirror. Whichever physical bank is active
         therefore fetches the same low-twelve-bit bridge offset, which selects
         BANK0 before jumping to the ordinary runtime handler. Identical bytes
         also make F4's NMI-vector/hotspot overlap deterministic. */
      vectors[0] = (uint8_t)((bridge_base + VECTOR_BRIDGE_NMI_OFFSET) & 0xFFu);
      vectors[1] = (uint8_t)(((bridge_base + VECTOR_BRIDGE_NMI_OFFSET) >> 8) & 0xFFu);
      vectors[2] = (uint8_t)((bridge_base + VECTOR_BRIDGE_RESET_OFFSET) & 0xFFu);
      vectors[3] = (uint8_t)(((bridge_base + VECTOR_BRIDGE_RESET_OFFSET) >> 8) & 0xFFu);
      vectors[4] = (uint8_t)((bridge_base + VECTOR_BRIDGE_IRQBRK_OFFSET) & 0xFFu);
      vectors[5] = (uint8_t)(((bridge_base + VECTOR_BRIDGE_IRQBRK_OFFSET) >> 8) & 0xFFu);

      for (i = 0; i < cfg->bank_count; ++i) {
         uint16_t bank_bridge =
            (uint16_t)(cfg->banks[i].start + cfg->vector_bridge_offset);
         uint16_t bank_vectors =
            (uint16_t)(cfg->banks[i].start + cfg->banks[i].size - 6u);
         image_write_generated(image, used, bank_bridge, bridge,
                               sizeof(bridge), "vector bridge");
         image_write_generated(image, used, bank_vectors, vectors,
                               sizeof(vectors), "vectors");
      }
   } else {
      uint16_t vector_base = 0xFFFAu;
      image[vector_base + 0u] = (uint8_t)(nmi & 0xFFu);
      image[vector_base + 1u] = (uint8_t)((nmi >> 8) & 0xFFu);
      image[vector_base + 2u] = (uint8_t)(reset & 0xFFu);
      image[vector_base + 3u] = (uint8_t)((reset >> 8) & 0xFFu);
      image[vector_base + 4u] = (uint8_t)(irqbrk & 0xFFu);
      image[vector_base + 5u] = (uint8_t)((irqbrk >> 8) & 0xFFu);
      used[vector_base + 0u] = used[vector_base + 1u] =
         used[vector_base + 2u] = used[vector_base + 3u] =
         used[vector_base + 4u] = used[vector_base + 5u] = 1;
   }
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

//! @brief Compare cartridge-bank pointers by ascending logical start address.
static int compare_cartridge_bank_start(const void *lhs, const void *rhs)
{
   const cartridge_bank_t *const *a = (const cartridge_bank_t *const *)lhs;
   const cartridge_bank_t *const *b = (const cartridge_bank_t *const *)rhs;
   if ((*a)->start < (*b)->start)
      return -1;
   if ((*a)->start > (*b)->start)
      return 1;
   return strcmp((*a)->name, (*b)->name);
}

//! @brief Return one bank's physical file offset in ascending logical order.
static uint32_t cartridge_bank_file_offset(const linker_config_t *cfg,
                                           const cartridge_bank_t *bank)
{
   uint32_t offset = 0;
   size_t i;
   if (!cfg || !bank)
      return 0;
   for (i = 0; i < cfg->bank_count; ++i) {
      if (cfg->banks[i].start < bank->start)
         offset += cfg->banks[i].size;
   }
   return offset;
}

//! @brief Write one byte and terminate with a useful diagnostic on failure.
static void write_binary_byte(FILE *fp, const char *path, uint8_t byte)
{
   if (fwrite(&byte, 1, 1, fp) != 1) {
      fprintf(stderr, "vcsc-ld: write failed for '%s': %s\n", path, strerror(errno));
      fclose(fp);
      exit(1);
   }
}

//! @brief Write a flat binary in unbanked address-span or banked physical order.
static void write_flat_binary(const char *path, const linker_config_t *cfg,
                              const uint8_t *image, const uint8_t *used)
{
   FILE *fp;
   uint32_t addr;

   fp = fopen(path, "wb");
   if (!fp) {
      fprintf(stderr, "vcsc-ld: cannot create '%s': %s\n", path, strerror(errno));
      exit(1);
   }

   if (cfg->cartridge_banked) {
      const cartridge_bank_t **order;
      size_t i;
      order = (const cartridge_bank_t **)xmalloc(
         cfg->bank_count * sizeof(*order));
      for (i = 0; i < cfg->bank_count; ++i)
         order[i] = &cfg->banks[i];
      qsort(order, cfg->bank_count, sizeof(*order),
            compare_cartridge_bank_start);

      for (i = 0; i < cfg->bank_count; ++i) {
         const cartridge_bank_t *bank = order[i];
         uint32_t end = (uint32_t)bank->start + bank->size;
         for (addr = bank->start; addr < end; ++addr) {
            uint8_t byte = used[addr] ? image[addr] : cfg->cartridge_fill_value;
            write_binary_byte(fp, path, byte);
         }
      }
      free(order);
   } else {
      uint32_t first = 0;
      uint32_t last = 65535u;

      while (first < 65536u && !used[first])
         first++;
      while (last > first && !used[last])
         last--;
      if (first >= 65536u) {
         fprintf(stderr, "vcsc-ld: cannot write empty flat binary '%s'\n", path);
         fclose(fp);
         exit(1);
      }

      for (addr = first; addr <= last; ++addr) {
         uint8_t byte = used[addr] ? image[addr] : 0xFFu;
         write_binary_byte(fp, path, byte);
      }
   }

   if (fclose(fp) != 0) {
      fprintf(stderr, "vcsc-ld: close failed for '%s': %s\n", path, strerror(errno));
      exit(1);
   }
}


//! @brief Describe one object's page-containment result for the linker map.
static const char *page_placement_name(uint16_t addr, uint16_t size, int hard)
{
   if (hard)
      return "hard";
   if (size > 0x0100u)
      return "crossing";
   return range_fits_one_page(addr, size) ? "preferred" : "crossing";
}

//! @brief Return the conventional mnemonic for an NMOS 6502 relative-branch opcode.
static const char *branch_opcode_name(uint8_t opcode)
{
   switch (opcode) {
      case 0x10: return "BPL";
      case 0x30: return "BMI";
      case 0x50: return "BVC";
      case 0x70: return "BVS";
      case 0x90: return "BCC";
      case 0xB0: return "BCS";
      case 0xD0: return "BNE";
      case 0xF0: return "BEQ";
      default:   return "BR?";
   }
}

//! @brief Return the map spelling for a branch-page policy.
static const char *branch_page_policy_name(uint8_t policy)
{
   switch (policy) {
      case BRANCH_PAGE_SAME:  return "same";
      case BRANCH_PAGE_CROSS: return "cross";
      case BRANCH_PAGE_FLEX:
      default:                return "flex";
   }
}

//! @brief Return whether a taken relative branch incurs the NMOS page-cross cycle.
static int taken_branch_crosses_page(uint16_t source, uint16_t target)
{
   uint16_t next_pc = (uint16_t)(source + 2u);
   return (next_pc & 0xff00u) != (target & 0xff00u);
}

//! @brief Reject retained relative branches whose final source and target occupy different banks.
static void enforce_branch_bank_contracts(const linker_config_t *cfg,
                                          const input_set_t *in)
{
   size_t i;

   if (!cfg || !cfg->cartridge_banked)
      return;

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      size_t j;

      for (j = 0; j < obj->branch_count; ++j) {
         const branch_t *branch = &obj->branches[j];
         uint16_t source = object_runtime_addr_for_value(obj, branch->segid,
                                                         branch->source);
         uint16_t target = object_runtime_addr_for_value(obj, branch->segid,
                                                         branch->target);
         const cartridge_bank_t *source_bank =
            cartridge_bank_for_address(cfg, source);
         const cartridge_bank_t *target_bank =
            cartridge_bank_for_address(cfg, target);

         if (source_bank && target_bank && source_bank != target_bank) {
            fprintf(stderr,
                    "vcsc-ld: cross-bank conditional branch in %s at $%04X (%s) targets $%04X (%s); conditional branches may not cross banks\n",
                    obj->origin, source, source_bank->name, target,
                    target_bank->name);
            exit(1);
         }
      }
   }
}

//! @brief Verify all hard branch-page contracts after final layout.
static void enforce_branch_page_contracts(const input_set_t *in)
{
   size_t i;

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      size_t j;

      for (j = 0; j < obj->branch_count; ++j) {
         const branch_t *branch = &obj->branches[j];
         uint16_t source;
         uint16_t target;
         int crosses;

         if (branch->page_policy == BRANCH_PAGE_FLEX)
            continue;
         source = object_runtime_addr_for_value(obj, branch->segid, branch->source);
         target = object_runtime_addr_for_value(obj, branch->segid, branch->target);
         crosses = taken_branch_crosses_page(source, target);
         if ((branch->page_policy == BRANCH_PAGE_SAME && crosses) ||
             (branch->page_policy == BRANCH_PAGE_CROSS && !crosses)) {
            fprintf(stderr,
                    "vcsc-ld: branch-page contract %s failed in %s at $%04X -> $%04X\n",
                    branch_page_policy_name(branch->page_policy), obj->origin,
                    source, target);
            exit(1);
         }
      }
   }
}

//! @brief Return whether a MEMORY region holds cartridge output bytes.
static int memory_region_is_cartridge_rom(const linker_config_t *cfg,
                                           const memory_region_t *mem)
{
   size_t i;

   if (cfg == NULL || mem == NULL)
      return 0;
   if (str_ieq(mem->type, "ro"))
      return 1;
   for (i = 0; i < cfg->seg_count; ++i) {
      const segment_rule_t *seg = &cfg->seg[i];
      if (!str_ieq(seg->load_name, mem->name))
         continue;
      if (str_ieq(seg->type, "ro") || str_ieq(seg->type, "data"))
         return 1;
   }
   return 0;
}

//! @brief Return whether a MEMORY region represents writable runtime RAM.
static int memory_region_is_writable_ram(const memory_region_t *mem)
{
   return mem != NULL && str_ieq(mem->type, "rw");
}

//! @brief Find the writable runtime region containing one placed object.
static const memory_region_t *find_runtime_memory_for_range(const linker_config_t *cfg,
                                                            uint16_t addr,
                                                            uint16_t size)
{
   size_t i;
   uint32_t end = (uint32_t)addr + size;

   for (i = 0; cfg && i < cfg->mem_count; ++i) {
      const memory_region_t *mem = &cfg->mem[i];
      if (!memory_region_is_writable_ram(mem))
         continue;
      if (addr >= mem->start && end <= (uint32_t)mem->start + mem->size)
         return mem;
   }
   return NULL;
}

//! @brief Count occupied output bytes inside one MEMORY region.
static uint32_t memory_region_used_bytes(const memory_region_t *mem, const uint8_t *used)
{
   uint32_t count = 0;
   uint32_t start;
   uint32_t end;
   uint32_t addr;

   if (mem == NULL || used == NULL)
      return 0;
   start = mem->start;
   end = start + mem->size;
   if (end > 0x10000u)
      end = 0x10000u;
   for (addr = start; addr < end; ++addr) {
      if (used[addr])
         count++;
   }
   return count;
}

//! @brief Write cartridge-ROM usage lines to the selected stream.
static void write_cartridge_rom_usage(FILE *fp, const linker_config_t *cfg,
                                      const uint8_t *used, const char *indent)
{
   size_t i;

   for (i = 0; i < cfg->mem_count; ++i) {
      const memory_region_t *mem = &cfg->mem[i];
      uint32_t used_bytes;
      uint32_t free_bytes;
      double used_percent;
      double free_percent;

      if (!memory_region_is_cartridge_rom(cfg, mem))
         continue;
      used_bytes = memory_region_used_bytes(mem, used);
      free_bytes = (uint32_t)mem->size - used_bytes;
      used_percent = mem->size ? (100.0 * (double)used_bytes / (double)mem->size) : 0.0;
      free_percent = mem->size ? (100.0 - used_percent) : 0.0;
      fprintf(fp, "%s%-10s used=%" PRIu32 " bytes (%.2f%%) free=%" PRIu32 " bytes (%.2f%%)\n",
              indent, mem->name, used_bytes, used_percent, free_bytes, free_percent);
   }
}

//! @brief Count unique runtime object bytes in one writable-RAM region.
static uint32_t memory_region_runtime_used_bytes(const memory_region_t *mem,
                                                 const input_set_t *in)
{
   uint8_t *occupied;
   uint32_t count = 0;
   uint32_t start;
   uint32_t end;
   size_t i;

   if (mem == NULL || in == NULL)
      return 0;
   occupied = (uint8_t *)xmalloc(65536);
   memset(occupied, 0, 65536);
   start = mem->start;
   end = start + (mem->physical_size ? mem->physical_size : mem->size);
   if (end > 0x10000u)
      end = 0x10000u;
   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      size_t j;
      for (j = 0; j < obj->layout_count; ++j) {
         const object_layout_t *lay = &obj->layouts[j];
         uint32_t lay_start;
         uint32_t lay_end;
         uint32_t addr;
         if (lay->segid != O26_SEG_DATA && lay->segid != O26_SEG_BSS &&
             lay->segid != O26_SEG_ZP)
            continue;
         lay_start = lay->run_addr;
         lay_end = lay_start + lay->size;
         if (lay_start < start)
            lay_start = start;
         if (lay_end > end)
            lay_end = end;
         for (addr = lay_start; addr < lay_end; ++addr)
            occupied[addr] = 1;
      }
   }
   for (; start < end; ++start) {
      if (occupied[start])
         count++;
   }
   free(occupied);
   return count;
}

static void write_ram_usage(FILE *fp, const linker_config_t *cfg,
                            const input_set_t *in, const layout_t *layout,
                            const char *indent)
{
   size_t i;

   for (i = 0; i < cfg->mem_count; ++i) {
      const memory_region_t *mem = &cfg->mem[i];
      uint32_t object_bytes;
      uint32_t stack_bytes = 0;
      uint32_t total_bytes;
      uint32_t used_bytes;
      uint32_t free_bytes;
      double used_percent;
      double free_percent;

      if (!memory_region_is_writable_ram(mem))
         continue;
      object_bytes = memory_region_runtime_used_bytes(mem, in);
      if (layout->call_stack_enabled && !strcmp(cfg->call_stack_region, mem->name))
         stack_bytes = layout->call_stack_size;
      total_bytes = mem->physical_size ? mem->physical_size : mem->size + stack_bytes;
      used_bytes = object_bytes + stack_bytes;
      free_bytes = total_bytes >= used_bytes ? total_bytes - used_bytes : 0;
      used_percent = total_bytes ? (100.0 * (double)used_bytes / (double)total_bytes) : 0.0;
      free_percent = total_bytes ? (100.0 - used_percent) : 0.0;
      fprintf(fp,
              "%s%-10s used=%" PRIu32 " bytes (%.2f%%) free=%" PRIu32
              " bytes (%.2f%%) objects=%" PRIu32 " bytes hardware-stack=%" PRIu32 " bytes\n",
              indent, mem->name, used_bytes, used_percent, free_bytes, free_percent,
              object_bytes, stack_bytes);
   }
}

//! @brief Write map file using the on-disk format expected by linker layout and image writer.
static void write_map_file(const char *path, const linker_config_t *cfg, const input_set_t *in,
                           const layout_t *layout, const uint8_t *used)
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

   if (cfg->cartridge_banked) {
      uint32_t output_size = 0;
      fprintf(fp, "CARTRIDGE\n");
      for (i = 0; i < cfg->bank_count; ++i)
         output_size += cfg->banks[i].size;
      fprintf(fp,
              "  mapper=%s output-size=$%08" PRIX32
              " fill=$%02X trampoline=$%03X size=$%03X"
              " vectorbridge=$%03X size=$%02X\n",
              cfg->mapper, output_size, cfg->cartridge_fill_value,
              cfg->trampoline_offset, cfg->trampoline_size,
              cfg->vector_bridge_offset, VECTOR_BRIDGE_SIZE);
      fprintf(fp, "\nBANKS\n");
      for (i = 0; i < cfg->bank_count; ++i) {
         const cartridge_bank_t *bank = &cfg->banks[i];
         fprintf(fp,
                 "  %-10s start=$%04X size=$%04X hotspot=$%04X file=$%08" PRIX32 "%s\n",
                 bank->name, bank->start, bank->size, bank->hotspot,
                 cartridge_bank_file_offset(cfg, bank),
                 bank->startup ? " startup=yes" : "");
      }
      fprintf(fp, "\n");
   }

   fprintf(fp, "MEMORY\n");
   for (i = 0; i < cfg->mem_count; ++i) {
      if (cfg->mem[i].has_write_start) {
         fprintf(fp, "  %-10s read_start=$%04X write_start=$%04X size=$%04X type=%s shared=yes",
            cfg->mem[i].name, cfg->mem[i].start, cfg->mem[i].write_start,
            cfg->mem[i].size, cfg->mem[i].type);
      }
      else {
         fprintf(fp, "  %-10s start=$%04X size=$%04X type=%s",
            cfg->mem[i].name, cfg->mem[i].start, cfg->mem[i].size, cfg->mem[i].type);
      }
      if (cfg->mem[i].bank_name[0])
         fprintf(fp, " bank=%s", cfg->mem[i].bank_name);
      fputc('\n', fp);
   }

   fprintf(fp, "\nMEMORY USAGE\n");
   write_cartridge_rom_usage(fp, cfg, used, "  ");
   write_ram_usage(fp, cfg, in, layout, "  ");

   if (cfg->cartridge_banked) {
      uint16_t max_component = 0;
      int have_component = 0;
      fprintf(fp, "\nBANK PLACEMENT\n");
      for (i = 0; i < in->object_count; ++i) {
         const object_file_t *obj = &in->objects[i];
         size_t j;
         for (j = 0; j < obj->layout_count; ++j) {
            const object_layout_t *lay = &obj->layouts[j];
            if (!lay->placement_bank[0])
               continue;
            have_component = 1;
            if (lay->placement_component > max_component)
               max_component = lay->placement_component;
         }
      }
      if (!have_component) {
         fprintf(fp, "  <no movable ROM layouts>\n");
      }
      else {
         uint16_t component;
         for (component = 0; component <= max_component; ++component) {
            const object_layout_t *representative = NULL;
            size_t oi;
            for (oi = 0; oi < in->object_count && !representative; ++oi) {
               const object_file_t *obj = &in->objects[oi];
               size_t lj;
               for (lj = 0; lj < obj->layout_count; ++lj) {
                  const object_layout_t *lay = &obj->layouts[lj];
                  if (lay->placement_bank[0] &&
                      lay->placement_component == component) {
                     representative = lay;
                     break;
                  }
               }
            }
            if (!representative)
               continue;
            fprintf(fp,
                    "  component=%u assignment=%s bank=%s bytes=$%04" PRIX32
                    " cut-weight=$%04" PRIX32 "\n",
                    component,
                    representative->placement_component_pinned ? "pinned" : "automatic",
                    representative->placement_bank,
                    representative->placement_component_bytes,
                    representative->placement_cut_weight);
            for (oi = 0; oi < in->object_count; ++oi) {
               const object_file_t *obj = &in->objects[oi];
               size_t lj;
               for (lj = 0; lj < obj->layout_count; ++lj) {
                  const object_layout_t *lay = &obj->layouts[lj];
                  if (!lay->placement_bank[0] ||
                      lay->placement_component != component)
                     continue;
                  fprintf(fp,
                          "     %-9s %-28s region=%-12s size=$%04X object=%s\n",
                          lay->placement_mode == BANK_PLACEMENT_PINNED
                             ? "pinned" : "automatic",
                          lay->name, lay->placement_memory, lay->size,
                          obj->origin);
               }
            }
         }
      }

      size_t jmp_count = 0;
      size_t jsr_count = 0;
      for (i = 0; i < layout->bank_trampoline_entry_count; ++i) {
         if (layout->bank_trampoline_entries[i].kind == BANK_TRAMPOLINE_JSR)
            jsr_count++;
         else
            jmp_count++;
      }
      fprintf(fp, "\nTRAMPOLINES\n");
      fprintf(fp,
              "  common-offset=$%03X reserved=$%03X used=$%03X replicated=$%08" PRIX32
              " target-passing=inline entries=%zu jmp=%zu jsr=%zu jmp-size=$%02X jsr-size=$%02X\n",
              cfg->trampoline_offset, cfg->trampoline_size,
              layout->bank_trampoline_used,
              (uint32_t)layout->bank_trampoline_used * (uint32_t)cfg->bank_count,
              layout->bank_trampoline_entry_count, jmp_count, jsr_count,
              BANK_JMP_ENTRY_SIZE, BANK_JSR_ENTRY_SIZE);
      for (i = 0; i < layout->bank_trampoline_entry_count; ++i) {
         const bank_trampoline_entry_t *entry = &layout->bank_trampoline_entries[i];
         uint16_t entry_size = bank_trampoline_entry_size(entry->kind);
         if (entry->kind == BANK_TRAMPOLINE_JSR) {
            fprintf(fp,
                    "  JSR entry=%zu offset=$%03X target=$%04X %-20s source=%s hotspot=$%04X destination=%s hotspot=$%04X replicated-bytes=$%08" PRIX32 "\n",
                    i, (uint16_t)(cfg->trampoline_offset + entry->table_offset),
                    entry->target_addr, entry->target_name,
                    entry->source_bank, entry->source_hotspot,
                    entry->destination_bank, entry->destination_hotspot,
                    (uint32_t)entry_size * (uint32_t)cfg->bank_count);
         }
         else {
            fprintf(fp,
                    "  JMP entry=%zu offset=$%03X target=$%04X %-20s destination=%s hotspot=$%04X replicated-bytes=$%08" PRIX32 "\n",
                    i, (uint16_t)(cfg->trampoline_offset + entry->table_offset),
                    entry->target_addr, entry->target_name,
                    entry->destination_bank, entry->destination_hotspot,
                    (uint32_t)entry_size * (uint32_t)cfg->bank_count);
         }
      }
   }

   fprintf(fp, "\nOBJECTS\n");
   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *o = &in->objects[i];
      size_t j;
      fprintf(fp, "  %s\n", o->origin);
      for (j = 0; j < o->layout_count; ++j) {
         const object_layout_t *lay = &o->layouts[j];
         if (lay->segid == O26_SEG_TEXT) {
            fprintf(fp, "     %-16s load=$%04X size=$%04X page=%s",
                    lay->name, lay->load_addr, lay->size,
                    page_placement_name(lay->load_addr, lay->size,
                       (lay->flags & O26_LAYOUT_PAGE_CONTAINED) != 0));
            if (lay->placement_bank[0])
               fprintf(fp, " bank=%s region=%s placement=%s component=%u",
                       lay->placement_bank, lay->placement_memory,
                       lay->placement_mode == BANK_PLACEMENT_PINNED
                          ? "pinned" : "automatic",
                       lay->placement_component);
            fputc('\n', fp);
         }
         else if (lay->segid == O26_SEG_DATA) {
            const memory_region_t *runtime_mem =
               find_runtime_memory_for_range(cfg, lay->run_addr, lay->size);
            fprintf(fp, "     %-16s load=$%04X run=$%04X",
                    lay->name, lay->load_addr, lay->run_addr);
            if (runtime_mem && runtime_mem->has_write_start)
               fprintf(fp, " write=$%04X",
                       memory_runtime_write_address(cfg, runtime_mem->name,
                                                    lay->run_addr, lay->size));
            fprintf(fp, " size=$%04X load-page=%s run-page=%s\n",
                    lay->size, page_placement_name(lay->load_addr, lay->size, 0),
                    page_placement_name(lay->run_addr, lay->size,
                       (lay->flags & O26_LAYOUT_PAGE_CONTAINED) != 0));
         }
         else {
            const memory_region_t *runtime_mem =
               find_runtime_memory_for_range(cfg, lay->run_addr, lay->size);
            fprintf(fp, "     %-16s run=$%04X", lay->name, lay->run_addr);
            if (runtime_mem && runtime_mem->has_write_start)
               fprintf(fp, " write=$%04X",
                       memory_runtime_write_address(cfg, runtime_mem->name,
                                                    lay->run_addr, lay->size));
            fprintf(fp, " size=$%04X page=%s\n", lay->size,
                    page_placement_name(lay->run_addr, lay->size,
                       (lay->flags & O26_LAYOUT_PAGE_CONTAINED) != 0));
         }
      }
   }

   fprintf(fp, "\nBRANCHES\n");
   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *o = &in->objects[i];
      size_t j;
      if (!o->branch_count)
         continue;
      fprintf(fp, "  %s\n", o->origin);
      for (j = 0; j < o->branch_count; ++j) {
         const branch_t *branch = &o->branches[j];
         uint16_t source = object_runtime_addr_for_value(o, branch->segid, branch->source);
         uint16_t target = object_runtime_addr_for_value(o, branch->segid, branch->target);
         fprintf(fp, "     $%04X -> $%04X %-3s opcode=$%02X taken-page=%s policy=%s\n",
                 source, target, branch_opcode_name(branch->opcode), branch->opcode,
                 taken_branch_crosses_page(source, target) ? "crossing" : "same",
                 branch_page_policy_name(branch->page_policy));
      }
   }

   fprintf(fp, "\nINDEXED RANGES\n");
   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *o = &in->objects[i];
      size_t j;
      int wrote_origin = 0;
      for (j = 0; j < o->layout_count; ++j) {
         const object_layout_t *lay = &o->layouts[j];
         uint16_t base;
         uint32_t effective_start;
         uint32_t effective_end;
         if (!(lay->flags & O26_LAYOUT_INDEX_RANGE))
            continue;
         if (!wrote_origin) {
            fprintf(fp, "  %s\n", o->origin);
            wrote_origin = 1;
         }
         base = lay->segid == O26_SEG_TEXT ? lay->load_addr : lay->run_addr;
         effective_start = (uint32_t)base + lay->index_range_start;
         effective_end = effective_start + lay->index_range_max;
         fprintf(fp, "     %-16s base=$%04X offset=$%04X max=$%02X effective=$%04X-$%04X page=%s\n",
                 lay->name, base, lay->index_range_start, lay->index_range_max,
                 (unsigned)effective_start, (unsigned)effective_end,
                 ((effective_start & 0xff00u) == (effective_end & 0xff00u)) ? "same" : "crossing");
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
      fprintf(fp, "  region=%s depth=%u bytes=$%04X physical=$%04X-$%04X extra=$%04X weighted-depth=%u bank-extra-slots=%u\n",
              cfg->call_stack_region,
              (unsigned)layout->call_stack_depth,
              layout->call_stack_size,
              layout->call_stack_start,
              layout->call_stack_top,
              layout->call_stack_extra,
              (unsigned)layout->call_stack_weighted_depth,
              (unsigned)layout->call_stack_bank_extra_slots);
   }

   fprintf(fp, "\nSYMBOLS\n");
   for (i = 0; i < layout->global_count; ++i) {
      fprintf(fp, "  $%04X  %-20s  %s\n",
         layout->globals[i].addr, layout->globals[i].name, layout->globals[i].source);
   }

   fclose(fp);
}

//! @brief Compare global-symbol pointers alphabetically for Stella/DASM output.
static int compare_global_symbol_names(const void *lhs, const void *rhs)
{
   const global_symbol_t *const *a = (const global_symbol_t *const *)lhs;
   const global_symbol_t *const *b = (const global_symbol_t *const *)rhs;
   return strcmp((*a)->name, (*b)->name);
}

//! @brief Write the simple two-column DASM symbol format accepted by Stella.
static void write_stella_symbol_file(const char *path, const layout_t *layout)
{
   const global_symbol_t **symbols;
   FILE *fp;
   size_t i;

   if (!path)
      return;
   fp = fopen(path, "w");
   if (!fp) {
      fprintf(stderr, "vcsc-ld: cannot create '%s': %s\n", path, strerror(errno));
      exit(1);
   }

   symbols = (const global_symbol_t **)xmalloc(
      (layout->global_count ? layout->global_count : 1) * sizeof(*symbols));
   for (i = 0; i < layout->global_count; ++i)
      symbols[i] = &layout->globals[i];
   qsort(symbols, layout->global_count, sizeof(*symbols), compare_global_symbol_names);

   fprintf(fp, "--- Symbol List (sorted by symbol)\n");
   for (i = 0; i < layout->global_count; ++i)
      fprintf(fp, "%-32s %04x\n", symbols[i]->name, symbols[i]->addr);
   fprintf(fp, "--- End of Symbol List.\n");

   free(symbols);
   if (fclose(fp) != 0) {
      fprintf(stderr, "vcsc-ld: close failed for '%s': %s\n", path, strerror(errno));
      exit(1);
   }
}

//! @brief Return the first linked symbol at an address for human-readable list annotations.
static const char *symbol_at_address(const layout_t *layout, uint16_t addr)
{
   size_t i;
   for (i = 0; i < layout->global_count; ++i) {
      if (layout->globals[i].addr == addr)
         return layout->globals[i].name;
   }
   return NULL;
}

//! @brief Write a DASM-shaped linked-byte listing accepted by Stella's list loader.
static void write_stella_list_file(const char *path,
                                   const layout_t *layout,
                                   const uint8_t *image,
                                   const uint8_t *used)
{
   FILE *fp;
   unsigned line = 1;
   size_t i;
   uint32_t addr = 0;

   if (!path)
      return;
   fp = fopen(path, "w");
   if (!fp) {
      fprintf(stderr, "vcsc-ld: cannot create '%s': %s\n", path, strerror(errno));
      exit(1);
   }

   fprintf(fp, "------- VCSC linked image listing\n");
   fprintf(fp, "------- RAM symbols use DASM constant rows; ROM rows show final bytes.\n");

   /* Stella's DASM-list parser recognizes RAM constants from columns beginning
      at offset 20 in the form "high low NAME =". */
   for (i = 0; i < layout->global_count; ++i) {
      const global_symbol_t *symbol = &layout->globals[i];
      if ((symbol->addr & 0x1000u) != 0)
         continue;
      fprintf(fp, "%5u %04x          %02x %02x %s =\n",
              line++, symbol->addr,
              (unsigned)((symbol->addr >> 8) & 0xffu),
              (unsigned)(symbol->addr & 0xffu),
              symbol->name);
   }

   while (addr < 65536u) {
      unsigned count = 0;
      const char *label;
      uint32_t start;

      while (addr < 65536u && !used[addr])
         addr++;
      if (addr >= 65536u)
         break;
      start = addr;
      fprintf(fp, "%5u %04x ", line++, (unsigned)start);
      while (addr < 65536u && used[addr] && count < 8) {
         fprintf(fp, "%02x ", image[addr]);
         addr++;
         count++;
      }
      while (count++ < 8)
         fputs("   ", fp);
      label = symbol_at_address(layout, (uint16_t)start);
      if (label)
         fprintf(fp, "; %s", label);
      fputc('\n', fp);
   }

   if (fclose(fp) != 0) {
      fprintf(stderr, "vcsc-ld: close failed for '%s': %s\n", path, strerror(errno));
      exit(1);
   }
}

//! @brief Return whether a segment spelling denotes executable bytes.
static int segment_name_is_code(const char *name)
{
   char upper[MAX_NAME];
   size_t i;

   if (!name)
      return 0;
   for (i = 0; name[i] && i + 1 < sizeof(upper); ++i)
      upper[i] = (char)toupper((unsigned char)name[i]);
   upper[i] = '\0';
   if (strstr(upper, "RODATA") || strstr(upper, "VECTOR") || strstr(upper, "DATA"))
      return 0;
   return strstr(upper, "CODE") != NULL || strstr(upper, "STARTUP") != NULL;
}

//! @brief Classify one ROM-resident object layout for a generated DiStella config.
static int layout_image_is_code(const linker_config_t *cfg, const object_layout_t *layout)
{
   const segment_rule_t *rule = find_layout_segment_rule(cfg, layout->name, NULL);

   if (segment_name_is_code(layout->name))
      return 1;
   if (rule && segment_name_is_code(rule->name))
      return 1;
   if (rule && (str_ieq(rule->name, "RODATA") || str_ieq(rule->name, "VECTORS") ||
                str_ieq(rule->name, "DATA")))
      return 0;
   return layout->segid == O26_SEG_TEXT && layout->image_segid == O26_SEG_TEXT;
}

//! @brief Write CODE/DATA ranges for Stella's DiStella disassembler.
static void write_stella_config_file(const char *path,
                                     const linker_config_t *cfg,
                                     const input_set_t *in,
                                     const uint8_t *used)
{
   uint8_t *kind;
   FILE *fp;
   size_t i;
   uint32_t addr;

   if (!path)
      return;
   fp = fopen(path, "w");
   if (!fp) {
      fprintf(stderr, "vcsc-ld: cannot create '%s': %s\n", path, strerror(errno));
      exit(1);
   }

   kind = (uint8_t *)xcalloc(65536, 1);
   for (addr = 0; addr < 65536u; ++addr) {
      if (used[addr])
         kind[addr] = 2; /* DATA is the safe fallback for generated tables/vectors. */
   }
   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      size_t j;
      for (j = 0; j < obj->layout_count; ++j) {
         const object_layout_t *layout = &obj->layouts[j];
         uint32_t end;
         uint8_t value;

         if (!layout->size ||
             (layout->image_segid != O26_SEG_TEXT && layout->image_segid != O26_SEG_DATA))
            continue;
         end = (uint32_t)layout->load_addr + layout->size;
         value = layout_image_is_code(cfg, layout) ? 1 : 2;
         for (addr = layout->load_addr; addr < end && addr < 65536u; ++addr) {
            if (used[addr])
               kind[addr] = value;
         }
      }
   }

   fputs("// Generated by vcsc-ld. Refine GFX/COL/AUD ranges in Stella if needed.\n", fp);
   addr = 0;
   while (addr < 65536u) {
      uint8_t value;
      uint32_t start;
      uint32_t end;

      while (addr < 65536u && kind[addr] == 0)
         addr++;
      if (addr >= 65536u)
         break;
      start = addr;
      value = kind[addr];
      while (addr + 1 < 65536u && kind[addr + 1] == value)
         addr++;
      end = addr;
      fprintf(fp, "%s %04x %04x\n", value == 1 ? "CODE" : "DATA",
              (unsigned)start, (unsigned)end);
      addr++;
   }

   free(kind);
   if (fclose(fp) != 0) {
      fprintf(stderr, "vcsc-ld: close failed for '%s': %s\n", path, strerror(errno));
      exit(1);
   }
}

//! @brief Reject output-name collisions which would overwrite the ROM or another sidecar.
static void validate_sidecar_paths(const char *output,
                                   const char *linker_cfg,
                                   sidecar_option_t *map,
                                   sidecar_option_t *sym,
                                   sidecar_option_t *list,
                                   sidecar_option_t *cfg)
{
   sidecar_option_t *options[] = { map, sym, list, cfg };
   const char *names[] = { "map", "symbol", "list", "config" };
   size_t i, j;

   /* A same-stem linker script can legitimately occupy the default .cfg name.
      Never destroy it. An explicit collision is instead a command-line error. */
   if (cfg->enabled && cfg->path && linker_cfg && strcmp(cfg->path, linker_cfg) == 0) {
      if (cfg->explicit_path) {
         fprintf(stderr, "vcsc-ld: Stella config output '%s' would overwrite linker script/config\n",
                 cfg->path);
         exit(1);
      }
      cfg->enabled = 0;
      cfg->path = NULL;
   }

   for (i = 0; i < ARRAY_LEN(options); ++i) {
      if (!options[i]->enabled || !options[i]->path)
         continue;
      if (strcmp(options[i]->path, output) == 0) {
         fprintf(stderr, "vcsc-ld: %s output '%s' would overwrite primary output\n",
                 names[i], options[i]->path);
         exit(1);
      }
      for (j = i + 1; j < ARRAY_LEN(options); ++j) {
         if (!options[j]->enabled || !options[j]->path)
            continue;
         if (strcmp(options[i]->path, options[j]->path) == 0) {
            fprintf(stderr, "vcsc-ld: %s and %s outputs both name '%s'\n",
                    names[i], names[j], options[i]->path);
            exit(1);
         }
      }
   }
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
   sidecar_option_t map_output = { NULL, 1, 0, NULL };
   sidecar_option_t sym_output = { NULL, 1, 0, NULL };
   sidecar_option_t list_output = { NULL, 1, 0, NULL };
   sidecar_option_t cfg_output = { NULL, 1, 0, NULL };
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
            set_sidecar_path(&map_output, argv[argi]);
            continue;
         }
         if (strncmp(arg, "-Map=", 5) == 0) {
            set_sidecar_path(&map_output, arg + 5);
            continue;
         }
         if (strcmp(arg, "--map") == 0) {
            if (++argi >= argc) {
               fprintf(stderr, "vcsc-ld: missing argument for --map\n");
               return 1;
            }
            set_sidecar_path(&map_output, argv[argi]);
            continue;
         }
         if (strncmp(arg, "--map=", 6) == 0) {
            set_sidecar_path(&map_output, arg + 6);
            continue;
         }
         if (strcmp(arg, "-Sym") == 0 || strcmp(arg, "--sym") == 0) {
            if (++argi >= argc) {
               fprintf(stderr, "vcsc-ld: missing argument for %s\n", arg);
               return 1;
            }
            set_sidecar_path(&sym_output, argv[argi]);
            continue;
         }
         if (strncmp(arg, "-Sym=", 5) == 0) {
            set_sidecar_path(&sym_output, arg + 5);
            continue;
         }
         if (strncmp(arg, "--sym=", 6) == 0) {
            set_sidecar_path(&sym_output, arg + 6);
            continue;
         }
         if (strcmp(arg, "-List") == 0 || strcmp(arg, "--list") == 0) {
            if (++argi >= argc) {
               fprintf(stderr, "vcsc-ld: missing argument for %s\n", arg);
               return 1;
            }
            set_sidecar_path(&list_output, argv[argi]);
            continue;
         }
         if (strncmp(arg, "-List=", 6) == 0) {
            set_sidecar_path(&list_output, arg + 6);
            continue;
         }
         if (strncmp(arg, "--list=", 7) == 0) {
            set_sidecar_path(&list_output, arg + 7);
            continue;
         }
         if (strcmp(arg, "-Cfg") == 0 || strcmp(arg, "--cfg") == 0) {
            if (++argi >= argc) {
               fprintf(stderr, "vcsc-ld: missing argument for %s\n", arg);
               return 1;
            }
            set_sidecar_path(&cfg_output, argv[argi]);
            continue;
         }
         if (strncmp(arg, "-Cfg=", 5) == 0) {
            set_sidecar_path(&cfg_output, arg + 5);
            continue;
         }
         if (strncmp(arg, "--cfg=", 6) == 0) {
            set_sidecar_path(&cfg_output, arg + 6);
            continue;
         }
         if (strcmp(arg, "--no-map") == 0) {
            disable_sidecar(&map_output);
            continue;
         }
         if (strcmp(arg, "--no-sym") == 0) {
            disable_sidecar(&sym_output);
            continue;
         }
         if (strcmp(arg, "--no-list") == 0) {
            disable_sidecar(&list_output);
            continue;
         }
         if (strcmp(arg, "--no-cfg") == 0) {
            disable_sidecar(&cfg_output);
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

      if (compat_hex_path != NULL && !map_output.explicit_path) {
         set_sidecar_path(&map_output, arg);
         continue;
      }

      fprintf(stderr, "vcsc-ld: cannot classify input '%s'\n", arg);
      return 1;
   }

   if (compat_hex_path != NULL)
      hex_path = compat_hex_path;

   finalize_sidecar_option(&map_output, hex_path, ".map");
   finalize_sidecar_option(&sym_output, hex_path, ".sym");
   finalize_sidecar_option(&list_output, hex_path, ".lst");
   finalize_sidecar_option(&cfg_output, hex_path, ".cfg");
   validate_sidecar_paths(hex_path, cfg_path,
                          &map_output, &sym_output, &list_output, &cfg_output);

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
   if (cfg.cartridge_banked && !ends_with(hex_path, ".bin")) {
      fprintf(stderr,
              "vcsc-ld: banked cartridge profiles require a flat .bin output\n");
      return 1;
   }

   select_needed_objects(&inputs);
   validate_abi_metadata(&inputs);
   validate_mem_region_metadata(&cfg, &inputs);
   assign_automatic_bank_placements(&cfg, &inputs);
   {
      uint16_t weighted_call_depth = 0;
      uint16_t call_depth = enforce_symbol_backed_call_graph(
         &inputs, &cfg, &weighted_call_depth);
      size_t init_count = count_init_functions_in_input(&inputs);
      reserve_call_stack_from_call_graph(&cfg, call_depth,
                                         weighted_call_depth, init_count);
   }
   warn_unused_cmdline_objects(&inputs);
   layout_objects(&cfg, &inputs, &layout);
   enforce_branch_bank_contracts(&cfg, &inputs);
   enforce_branch_page_contracts(&inputs);
   add_generated_symbols(&layout);
   resolve_all(&inputs, &layout, &cfg);
   enforce_declaration_use_contracts(&inputs);

   image = (uint8_t *)xmalloc(65536);
   used = (uint8_t *)xmalloc(65536);
   build_rom_image(&cfg, &inputs, &layout, image, used);
   if (ends_with(hex_path, ".bin"))
      write_flat_binary(hex_path, &cfg, image, used);
   else
      write_intel_hex(hex_path, image, used);
   write_map_file(map_output.enabled ? map_output.path : NULL,
                  &cfg, &inputs, &layout, used);
   write_stella_symbol_file(sym_output.enabled ? sym_output.path : NULL, &layout);
   write_stella_list_file(list_output.enabled ? list_output.path : NULL,
                          &layout, image, used);
   write_stella_config_file(cfg_output.enabled ? cfg_output.path : NULL,
                            &cfg, &inputs, used);
   puts("MEMORY USAGE");
   write_cartridge_rom_usage(stdout, &cfg, used, "  ");
   write_ram_usage(stdout, &cfg, &inputs, &layout, "  ");

   free(image);
   free(used);
   free(map_output.owned_default);
   free(sym_output.owned_default);
   free(list_output.owned_default);
   free(cfg_output.owned_default);

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
   for (i = 0; i < layout.bank_trampoline_entry_count; ++i)
      free(layout.bank_trampoline_entries[i].target_name);
   free(layout.bank_trampoline_entries);
   for (i = 0; i < layout.cursor_count; ++i)
      free(layout.cursors[i].holes);
   free(layout.cursors);
   free(cfg.mem);
   free(cfg.seg);
   free(cfg.banks);

   return 0;
}
