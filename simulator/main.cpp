#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <inttypes.h>
#include <ctype.h>
#include <errno.h>
#include <stdlib.h>

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "mos6502/mos6502.h"
#include "version.h"

mos6502 *cpu = NULL;
uint16_t gpc = 0xffff;
uint16_t trace_ops = 0;
#define TRACE_OP_READS    (1 << 0)
#define TRACE_OP_WRITES   (1 << 1)
#define TRACE_OP_REGS     (1 << 2)
#define TRACE_OP_DISASM   (1 << 3)
#define TRACE_OP_CYCLES   (1 << 4)
#define TRACE_OP_DISPATCH (1 << 5)

uint64_t counter = 0;
uint8_t mem[65536];

static constexpr size_t MAX_NAME = 128;

struct memory_region_t {
   uint16_t start;
   uint16_t write_start;
   uint16_t size;
   int has_write_start;
   char type[8];
   int define_yes;
   char name[MAX_NAME];
   char bank_name[MAX_NAME];
};

struct cartridge_bank_t {
   uint16_t start;
   uint16_t size;
   uint16_t hotspot;
   int startup;
   size_t file_index;
   int has_file_index;
   char name[MAX_NAME];
};

struct simulator_config_t {
   memory_region_t mem[64];
   size_t mem_count;
   cartridge_bank_t banks[8];
   size_t bank_count;
   char mapper[16];
   int cartridge_banked;
   int cartridge_direct_multi;
   int superchip_mapper;
   int e0_mapper;
   int threef_mapper;
   int threee_mapper;
   size_t startup_bank;
};

struct parse_result_t {
   uint32_t value;
   size_t pos;
   int ok;
};

struct simulator_options_t {
   const char *image_path;
   const char *cfg_path;
   uint16_t trace;
   int trace_set;
   size_t start_bank;
   int start_bank_set;
   uint16_t stop_pc;
   int stop_pc_set;
   uint16_t reset_on_pc;
   int reset_on_pc_set;
   uint8_t split_fill;
   int split_fill_set;
   int dump_on_stop;
};

static simulator_config_t g_cfg = {};
static int g_cfg_loaded = 0;
static size_t g_selected_bank = 0;
static size_t g_e0_segment_bank[3] = {0, 0, 0};
static int g_3e_ram_selected = 0;
static uint8_t g_3e_ram_bank = 0;
static uint8_t g_3e_ram[32][1024] = {};
static std::vector<std::vector<uint8_t>> g_split_memory;

void trace_regs(void);
void trace_disasm(uint16_t pc);

static void usage(FILE *fp) {
   fprintf(fp,
      "Usage:\n"
      "  vcsc-sim [options] file.hex|file.bin\n"
      "\n"
      "Options:\n"
      "  -t MASK              Enable trace bitmask MASK\n"
      "  --trace=MASK         Same as -t MASK\n"
      "  -T FILE              Use FILE as simulator linker-style config\n"
      "  --config=FILE        Same as -T FILE\n"
      "  --script=FILE        Same as -T FILE\n"
      "  --start-bank=N       Begin in physical/file bank N (banked cfg only)\n"
      "  --stop-pc=ADDR       Exit successfully before executing ADDR\n"
      "  --reset-on-pc=ADDR   Reset once before executing ADDR, preserving RAM\n"
      "  --split-fill=BYTE    Pre-fill split-address memory before CPU reset\n"
      "  --dump-on-stop       Dump memory as Intel HEX when --stop-pc fires\n"
      "  -h, --help           Show this help text\n"
      "  -V, --version        Show version information\n"
      "\n"
      "Compatibility:\n"
      "  vcsc-sim file.hex [trace]\n"
      "  vcsc-sim [layout.cfg] [trace] file.hex\n");
}

static int ends_with(const char *s, const char *suffix) {
   size_t slen = strlen(s);
   size_t tlen = strlen(suffix);
   if (slen < tlen)
      return 0;
   return strcmp(s + slen - tlen, suffix) == 0;
}

static int str_ieq(const char *a, const char *b) {
   while (*a && *b) {
      int ca = toupper((unsigned char)*a++);
      int cb = toupper((unsigned char)*b++);
      if (ca != cb)
         return 0;
   }
   return *a == '\0' && *b == '\0';
}

static char *trim(char *s) {
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

static parse_result_t parse_number(const char *s) {
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
   }
   else {
      r.value = strtoul(s, &end, 0);
      if (end && end != s)
         r.ok = 1;
   }

   if (r.ok)
      r.pos = (size_t)(end - s);
   return r;
}

static void parse_memory_property(memory_region_t *mem_region, const char *key, const char *value) {
   parse_result_t n;

   if (str_ieq(key, "start") || str_ieq(key, "read_start")) {
      n = parse_number(value);
      if (!n.ok || n.value > 0xFFFFu) {
         fprintf(stderr, "vcsc-sim: bad memory read start '%s'\n", value);
         exit(1);
      }
      mem_region->start = (uint16_t)n.value;
   }
   else if (str_ieq(key, "write_start")) {
      n = parse_number(value);
      if (!n.ok || n.value > 0xFFFFu) {
         fprintf(stderr, "vcsc-sim: bad memory write start '%s'\n", value);
         exit(1);
      }
      mem_region->write_start = (uint16_t)n.value;
      mem_region->has_write_start = 1;
   }
   else if (str_ieq(key, "size")) {
      n = parse_number(value);
      if (!n.ok || n.value > 0xFFFFu) {
         fprintf(stderr, "vcsc-sim: bad memory size '%s'\n", value);
         exit(1);
      }
      mem_region->size = (uint16_t)n.value;
   }
   else if (str_ieq(key, "type")) {
      snprintf(mem_region->type, sizeof(mem_region->type), "%s", trim((char *)value));
   }
   else if (str_ieq(key, "define")) {
      mem_region->define_yes = str_ieq(trim((char *)value), "yes");
   }
   else if (str_ieq(key, "bank")) {
      snprintf(mem_region->bank_name, sizeof(mem_region->bank_name), "%s", trim((char *)value));
   }
}

static void parse_bank_property(cartridge_bank_t *bank, const char *key, const char *value) {
   parse_result_t n;
   if (str_ieq(key, "start")) {
      n = parse_number(value);
      if (!n.ok || n.value > 0xFFFFu) {
         fprintf(stderr, "vcsc-sim: bad bank start '%s'\n", value);
         exit(1);
      }
      bank->start = (uint16_t)n.value;
   }
   else if (str_ieq(key, "size")) {
      n = parse_number(value);
      if (!n.ok || n.value == 0 || n.value > 0xFFFFu) {
         fprintf(stderr, "vcsc-sim: bad bank size '%s'\n", value);
         exit(1);
      }
      bank->size = (uint16_t)n.value;
   }
   else if (str_ieq(key, "fileindex")) {
      n = parse_number(value);
      if (!n.ok || n.value > 7u) {
         fprintf(stderr, "vcsc-sim: bad bank file index '%s'\n", value);
         exit(1);
      }
      bank->file_index = (size_t)n.value;
      bank->has_file_index = 1;
   }
   else if (str_ieq(key, "hotspot")) {
      n = parse_number(value);
      if (!n.ok || n.value > 0xFFFFu) {
         fprintf(stderr, "vcsc-sim: bad bank hotspot '%s'\n", value);
         exit(1);
      }
      bank->hotspot = (uint16_t)n.value;
   }
   else if (str_ieq(key, "startup")) {
      bank->startup = str_ieq(trim((char *)value), "yes");
   }
}

static void parse_cartridge_property(simulator_config_t *cfg, const char *key, const char *value) {
   if (str_ieq(key, "mapper"))
      snprintf(cfg->mapper, sizeof(cfg->mapper), "%s", trim((char *)value));
}

static void parse_cfg_file(simulator_config_t *cfg, const char *path) {
   FILE *fp = fopen(path, "r");
   char line[1024];
   enum { NONE, CARTRIDGE, BANKS, MEMORY, SKIP_BLOCK } block = NONE;

   if (!fp) {
      fprintf(stderr, "vcsc-sim: cannot open '%s': %s\n", path, strerror(errno));
      exit(1);
   }

   memset(cfg, 0, sizeof(*cfg));

   while (fgets(line, sizeof(line), fp)) {
      char *s = line;
      char *colon;
      char *comment = strchr(s, '#');
      if (comment)
         *comment = '\0';
      s = trim(s);
      if (*s == '\0')
         continue;

      if (str_ieq(s, "CARTRIDGE {") || str_ieq(s, "CARTRIDGE{")) {
         block = CARTRIDGE;
         continue;
      }
      if (str_ieq(s, "BANKS {") || str_ieq(s, "BANKS{")) {
         block = BANKS;
         continue;
      }
      if (str_ieq(s, "MEMORY {") || str_ieq(s, "MEMORY{")) {
         block = MEMORY;
         continue;
      }
      if (ends_with(s, "{")) {
         block = SKIP_BLOCK;
         continue;
      }
      if (strcmp(s, "}") == 0) {
         block = NONE;
         continue;
      }

      if (block == CARTRIDGE) {
         char *semi = strrchr(s, ';');
         char *eq;
         if (semi)
            *semi = '\0';
         eq = strchr(s, '=');
         if (eq) {
            *eq++ = '\0';
            parse_cartridge_property(cfg, trim(s), trim(eq));
         }
         continue;
      }
      if (block != BANKS && block != MEMORY)
         continue;

      colon = strchr(s, ':');
      if (!colon)
         continue;
      *colon++ = '\0';
      s = trim(s);
      colon = trim(colon);
      {
         char *semi = strrchr(colon, ';');
         char *tok;
         if (semi)
            *semi = '\0';

         if (block == BANKS) {
            if (cfg->bank_count >= (sizeof(cfg->banks) / sizeof(cfg->banks[0]))) {
               fprintf(stderr, "vcsc-sim: too many BANKS entries\n");
               exit(1);
            }
            cartridge_bank_t *bank = &cfg->banks[cfg->bank_count++];
            memset(bank, 0, sizeof(*bank));
            snprintf(bank->name, sizeof(bank->name), "%s", s);
            tok = strtok(colon, ",");
            while (tok) {
               char *eq = strchr(tok, '=');
               if (eq) {
                  *eq++ = '\0';
                  parse_bank_property(bank, trim(tok), trim(eq));
               }
               tok = strtok(NULL, ",");
            }
         }
         else {
            if (cfg->mem_count >= (sizeof(cfg->mem) / sizeof(cfg->mem[0]))) {
               fprintf(stderr, "vcsc-sim: too many MEMORY entries\n");
               exit(1);
            }
            memory_region_t *mem_region = &cfg->mem[cfg->mem_count++];
            memset(mem_region, 0, sizeof(*mem_region));
            snprintf(mem_region->name, sizeof(mem_region->name), "%s", s);
            tok = strtok(colon, ",");
            while (tok) {
               char *eq = strchr(tok, '=');
               if (eq) {
                  *eq++ = '\0';
                  parse_memory_property(mem_region, trim(tok), trim(eq));
               }
               tok = strtok(NULL, ",");
            }
         }
      }
   }

   fclose(fp);

   if (cfg->bank_count != 0) {
      size_t startup_count = 0;
      cfg->cartridge_direct_multi = str_ieq(cfg->mapper, "OMNI");
      cfg->cartridge_banked = !cfg->cartridge_direct_multi;
      cfg->superchip_mapper = str_ieq(cfg->mapper, "F8SC") ||
                              str_ieq(cfg->mapper, "F6SC") ||
                              str_ieq(cfg->mapper, "F4SC");
      cfg->e0_mapper = str_ieq(cfg->mapper, "E0");
      cfg->threef_mapper = str_ieq(cfg->mapper, "3F");
      cfg->threee_mapper = str_ieq(cfg->mapper, "3E");
      if (!(str_ieq(cfg->mapper, "F8") || str_ieq(cfg->mapper, "F6") ||
            str_ieq(cfg->mapper, "F4") || str_ieq(cfg->mapper, "FA") ||
            str_ieq(cfg->mapper, "OMNI") || str_ieq(cfg->mapper, "JANE") ||
            str_ieq(cfg->mapper, "0840") || str_ieq(cfg->mapper, "UA") ||
            str_ieq(cfg->mapper, "UASW") || str_ieq(cfg->mapper, "0FA0") ||
            cfg->e0_mapper || cfg->threef_mapper || cfg->threee_mapper ||
            cfg->superchip_mapper)) {
         fprintf(stderr, "vcsc-sim: unsupported mapper '%s'\n", cfg->mapper);
         exit(1);
      }
      if (cfg->e0_mapper && cfg->bank_count != 8u) {
         fprintf(stderr, "vcsc-sim: E0 requires exactly eight physical 1K banks\n");
         exit(1);
      }
      for (size_t i = 0; i < cfg->bank_count; ++i) {
         size_t file_index = 0;
         uint16_t wanted_size = cfg->e0_mapper ? 0x0400u :
                                (cfg->threef_mapper || cfg->threee_mapper) ? 0x0800u : 0x1000u;
         if (cfg->banks[i].size != wanted_size) {
            fprintf(stderr, "vcsc-sim: %s bank '%s' is not %s\n",
                    cfg->mapper, cfg->banks[i].name, cfg->e0_mapper ? "1K" :
                    (cfg->threef_mapper || cfg->threee_mapper) ? "2K" : "4K");
            exit(1);
         }
         if (cfg->e0_mapper && !cfg->banks[i].has_file_index) {
            fprintf(stderr, "vcsc-sim: E0 bank '%s' requires an explicit fileindex\n",
                    cfg->banks[i].name);
            exit(1);
         }
         if (!cfg->banks[i].has_file_index) {
            for (size_t j = 0; j < cfg->bank_count; ++j)
               if (cfg->banks[j].start < cfg->banks[i].start)
                  file_index++;
            cfg->banks[i].file_index = file_index;
         }
         if (cfg->banks[i].startup) {
            cfg->startup_bank = i;
            startup_count++;
         }
      }
      for (size_t i = 0; i < cfg->bank_count; ++i) {
         if (cfg->banks[i].file_index >= cfg->bank_count) {
            fprintf(stderr, "vcsc-sim: bank '%s' file index %zu is out of range\n",
                    cfg->banks[i].name, cfg->banks[i].file_index);
            exit(1);
         }
         for (size_t j = i + 1; j < cfg->bank_count; ++j) {
            if (cfg->banks[i].file_index == cfg->banks[j].file_index) {
               fprintf(stderr, "vcsc-sim: duplicate physical/file bank index %zu\n",
                       cfg->banks[i].file_index);
               exit(1);
            }
         }
      }
      if (startup_count != 1) {
         fprintf(stderr, "vcsc-sim: multi-region config must name exactly one startup bank\n");
         exit(1);
      }
      if (cfg->e0_mapper && cfg->banks[cfg->startup_bank].file_index != 7u) {
         fprintf(stderr, "vcsc-sim: E0 startup bank must be fixed physical/file bank 7\n");
         exit(1);
      }
      if ((cfg->threef_mapper || cfg->threee_mapper) &&
          cfg->banks[cfg->startup_bank].file_index != cfg->bank_count - 1u) {
         fprintf(stderr, "vcsc-sim: 3F/3E startup bank must be the fixed final physical/file bank\n");
         exit(1);
      }
   }

   for (size_t i = 0; i < cfg->mem_count; ++i) {
      memory_region_t *mem_region = &cfg->mem[i];
      if (!mem_region->has_write_start)
         continue;
      if (!str_ieq(mem_region->type, "rw")) {
         fprintf(stderr,
                 "vcsc-sim: split-address MEMORY region '%s' is not type=rw\n",
                 mem_region->name);
         exit(1);
      }
      if (mem_region->bank_name[0]) {
         fprintf(stderr,
                 "vcsc-sim: split-address MEMORY region '%s' must be shared\n",
                 mem_region->name);
         exit(1);
      }
      if (mem_region->size == 0 ||
          (uint32_t)mem_region->start + mem_region->size > 0x10000u ||
          (uint32_t)mem_region->write_start + mem_region->size > 0x10000u) {
         fprintf(stderr,
                 "vcsc-sim: split-address MEMORY region '%s' has an invalid window\n",
                 mem_region->name);
         exit(1);
      }
   }
}

static int address_is_read_only(uint16_t addr) {
   if (!g_cfg_loaded)
      return 0;

   for (size_t i = 0; i < g_cfg.mem_count; ++i) {
      const memory_region_t *mem_region = &g_cfg.mem[i];
      uint32_t start = mem_region->start;
      uint32_t end = start + mem_region->size;

      if (mem_region->size == 0)
         continue;
      if (!str_ieq(mem_region->type, "ro"))
         continue;
      if (addr >= start && addr < end)
         return 1;
   }

   return 0;
}

static void store_mem(uint16_t addr, uint8_t val, int allow_ro_write) {
   if (!allow_ro_write && address_is_read_only(addr)) {
      fprintf(stderr, "vcsc-sim: write to read-only memory at $%04X\n", addr);
      trace_regs();
      trace_disasm(gpc);
      exit(1);
   }
   mem[addr] = val;
}

static int assign_option_value(const char **out, const char *current, int *argi, int argc, char **argv, const char *label) {
   if (current[0] != '\0') {
      *out = current;
      return 1;
   }
   if (*argi + 1 >= argc) {
      fprintf(stderr, "vcsc-sim: missing argument for %s\n", label);
      exit(1);
   }
   *out = argv[++(*argi)];
   return 1;
}

static void parse_args(simulator_options_t *opts, int argc, char **argv) {
   memset(opts, 0, sizeof(*opts));

   for (int argi = 1; argi < argc; ++argi) {
      const char *arg = argv[argi];

      if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
         usage(stdout);
         exit(0);
      }
      else if (strcmp(arg, "-V") == 0 || strcmp(arg, "--version") == 0) {
         puts(VERSION);
         exit(0);
      }
      else if (strcmp(arg, "-t") == 0) {
         const char *value;
         assign_option_value(&value, "", &argi, argc, argv, "-t");
         parse_result_t parsed = parse_number(value);
         if (!parsed.ok || value[parsed.pos] != '\0' || parsed.value > 0xFFFFu) {
            fprintf(stderr, "vcsc-sim: bad trace mask '%s'\n", value);
            exit(1);
         }
         opts->trace = (uint16_t)parsed.value;
         opts->trace_set = 1;
      }
      else if (strncmp(arg, "--trace=", 8) == 0) {
         const char *value = arg + 8;
         parse_result_t parsed = parse_number(value);
         if (!parsed.ok || value[parsed.pos] != '\0' || parsed.value > 0xFFFFu) {
            fprintf(stderr, "vcsc-sim: bad trace mask '%s'\n", value);
            exit(1);
         }
         opts->trace = (uint16_t)parsed.value;
         opts->trace_set = 1;
      }
      else if (strcmp(arg, "--trace") == 0) {
         const char *value;
         assign_option_value(&value, "", &argi, argc, argv, "--trace");
         parse_result_t parsed = parse_number(value);
         if (!parsed.ok || value[parsed.pos] != '\0' || parsed.value > 0xFFFFu) {
            fprintf(stderr, "vcsc-sim: bad trace mask '%s'\n", value);
            exit(1);
         }
         opts->trace = (uint16_t)parsed.value;
         opts->trace_set = 1;
      }
      else if (strcmp(arg, "-T") == 0) {
         const char *value;
         assign_option_value(&value, "", &argi, argc, argv, "-T");
         opts->cfg_path = value;
      }
      else if (strncmp(arg, "--config=", 9) == 0) {
         opts->cfg_path = arg + 9;
      }
      else if (strcmp(arg, "--config") == 0) {
         const char *value;
         assign_option_value(&value, "", &argi, argc, argv, "--config");
         opts->cfg_path = value;
      }
      else if (strncmp(arg, "--script=", 9) == 0) {
         opts->cfg_path = arg + 9;
      }
      else if (strcmp(arg, "--script") == 0) {
         const char *value;
         assign_option_value(&value, "", &argi, argc, argv, "--script");
         opts->cfg_path = value;
      }
      else if (strncmp(arg, "--start-bank=", 13) == 0) {
         const char *value = arg + 13;
         parse_result_t parsed = parse_number(value);
         if (!parsed.ok || value[parsed.pos] != '\0') {
            fprintf(stderr, "vcsc-sim: bad start bank '%s'\n", value);
            exit(1);
         }
         opts->start_bank = parsed.value;
         opts->start_bank_set = 1;
      }
      else if (strcmp(arg, "--start-bank") == 0) {
         const char *value;
         assign_option_value(&value, "", &argi, argc, argv, "--start-bank");
         parse_result_t parsed = parse_number(value);
         if (!parsed.ok || value[parsed.pos] != '\0') {
            fprintf(stderr, "vcsc-sim: bad start bank '%s'\n", value);
            exit(1);
         }
         opts->start_bank = parsed.value;
         opts->start_bank_set = 1;
      }
      else if (strncmp(arg, "--stop-pc=", 10) == 0) {
         const char *value = arg + 10;
         parse_result_t parsed = parse_number(value);
         if (!parsed.ok || value[parsed.pos] != '\0' || parsed.value > 0xFFFFu) {
            fprintf(stderr, "vcsc-sim: bad stop PC '%s'\n", value);
            exit(1);
         }
         opts->stop_pc = (uint16_t)parsed.value;
         opts->stop_pc_set = 1;
      }
      else if (strcmp(arg, "--stop-pc") == 0) {
         const char *value;
         assign_option_value(&value, "", &argi, argc, argv, "--stop-pc");
         parse_result_t parsed = parse_number(value);
         if (!parsed.ok || value[parsed.pos] != '\0' || parsed.value > 0xFFFFu) {
            fprintf(stderr, "vcsc-sim: bad stop PC '%s'\n", value);
            exit(1);
         }
         opts->stop_pc = (uint16_t)parsed.value;
         opts->stop_pc_set = 1;
      }
      else if (strncmp(arg, "--reset-on-pc=", 14) == 0) {
         const char *value = arg + 14;
         parse_result_t parsed = parse_number(value);
         if (!parsed.ok || value[parsed.pos] != '\0' || parsed.value > 0xFFFFu) {
            fprintf(stderr, "vcsc-sim: bad reset PC '%s'\n", value);
            exit(1);
         }
         opts->reset_on_pc = (uint16_t)parsed.value;
         opts->reset_on_pc_set = 1;
      }
      else if (strcmp(arg, "--reset-on-pc") == 0) {
         const char *value;
         assign_option_value(&value, "", &argi, argc, argv, "--reset-on-pc");
         parse_result_t parsed = parse_number(value);
         if (!parsed.ok || value[parsed.pos] != '\0' || parsed.value > 0xFFFFu) {
            fprintf(stderr, "vcsc-sim: bad reset PC '%s'\n", value);
            exit(1);
         }
         opts->reset_on_pc = (uint16_t)parsed.value;
         opts->reset_on_pc_set = 1;
      }
      else if (strncmp(arg, "--split-fill=", 13) == 0) {
         const char *value = arg + 13;
         parse_result_t parsed = parse_number(value);
         if (!parsed.ok || value[parsed.pos] != '\0' || parsed.value > 0xFFu) {
            fprintf(stderr, "vcsc-sim: bad split-memory fill byte '%s'\n", value);
            exit(1);
         }
         opts->split_fill = (uint8_t)parsed.value;
         opts->split_fill_set = 1;
      }
      else if (strcmp(arg, "--split-fill") == 0) {
         const char *value;
         assign_option_value(&value, "", &argi, argc, argv, "--split-fill");
         parse_result_t parsed = parse_number(value);
         if (!parsed.ok || value[parsed.pos] != '\0' || parsed.value > 0xFFu) {
            fprintf(stderr, "vcsc-sim: bad split-memory fill byte '%s'\n", value);
            exit(1);
         }
         opts->split_fill = (uint8_t)parsed.value;
         opts->split_fill_set = 1;
      }
      else if (strcmp(arg, "--dump-on-stop") == 0) {
         opts->dump_on_stop = 1;
      }
      else if (arg[0] == '-') {
         fprintf(stderr, "vcsc-sim: unsupported option '%s'\n", arg);
         fprintf(stderr, "Try '%s --help' for a list of supported options.\n", argv[0]);
         exit(1);
      }
      else if (ends_with(arg, ".cfg") && opts->cfg_path == nullptr) {
         opts->cfg_path = arg;
      }
      else if ((ends_with(arg, ".hex") || ends_with(arg, ".bin")) && opts->image_path == nullptr) {
         opts->image_path = arg;
      }
      else {
         parse_result_t parsed = parse_number(arg);
         if (parsed.ok && arg[parsed.pos] == '\0' && parsed.value <= 0xFFFFu && !opts->trace_set) {
            opts->trace = (uint16_t)parsed.value;
            opts->trace_set = 1;
         }
         else if (opts->image_path == nullptr) {
            opts->image_path = arg;
         }
         else {
            fprintf(stderr, "vcsc-sim: unexpected argument '%s'\n", arg);
            usage(stderr);
            exit(1);
         }
      }
   }

   if (opts->image_path == nullptr) {
      usage(stderr);
      exit(1);
   }
}

static uint8_t ihex_checksum(const uint8_t *bytes, size_t n) {
   uint32_t sum = 0;

   for (size_t i = 0; i < n; i++) {
      sum += bytes[i];
   }

   return static_cast<uint8_t>((-static_cast<int32_t>(sum)) & 0xFF);
}

static void emit_ihex_record(uint8_t count,
                             uint16_t addr,
                             uint8_t rectype,
                             const uint8_t *data) {
   uint8_t hdr[4] = {
      count,
      static_cast<uint8_t>((addr >> 8) & 0xFF),
      static_cast<uint8_t>(addr & 0xFF),
      rectype,
   };
   uint8_t csum = ihex_checksum(hdr, sizeof(hdr));

   printf(":%02X%04X%02X", count, addr, rectype);
   for (uint8_t i = 0; i < count; i++) {
      printf("%02X", data[i]);
      csum = static_cast<uint8_t>(csum - data[i]);
   }
   printf("%02X\n", csum);
}

void dump_mem_as_intel_hex(void) {
   printf("---8<--- BEGIN MEMORY DUMP ---8<---\n");

   for (uint32_t addr = 0; addr < 65536; addr += 16) {
      emit_ihex_record(16, static_cast<uint16_t>(addr), 0x00, mem + addr);
   }

   emit_ihex_record(0, 0, 0x01, nullptr);

   printf("---8<---  END MEMORY DUMP  ---8<---\n");
}

static uint8_t hex_byte(const std::string &s, size_t pos) {
   return static_cast<uint8_t>(std::stoul(s.substr(pos, 2), nullptr, 16));
}

void load_intel_hex(const char *filename) {
   std::ifstream in(filename);
   if (!in)
      throw std::runtime_error("Failed to open Intel HEX file");

   std::string line;
   uint32_t base = 0;

   while (std::getline(in, line))
   {
      if (line.empty())
         continue;
      if (line[0] != ':')
         throw std::runtime_error("Invalid Intel HEX record");

      if (line.size() < 11)
         throw std::runtime_error("Record too short");

      uint8_t count = hex_byte(line, 1);
      uint16_t addr = (static_cast<uint16_t>(hex_byte(line, 3)) << 8) | hex_byte(line, 5);
      uint8_t type = hex_byte(line, 7);

      if (line.size() != (std::size_t) (11 + count * 2))
         throw std::runtime_error("Record length mismatch");

      uint8_t sum = count + (addr >> 8) + (addr & 0xFF) + type;
      for (uint8_t i = 0; i < count; i++)
         sum += hex_byte(line, 9 + i * 2);
      sum += hex_byte(line, 9 + count * 2);

      if (sum != 0)
         throw std::runtime_error("Checksum error");

      if (type == 0x00)   // data
      {
         uint32_t full_addr = base + addr;
         for (uint8_t i = 0; i < count; i++)
         {
            if (full_addr + i >= 65536)
               throw std::runtime_error("Address out of range for 64K memory");
            store_mem(static_cast<uint16_t>(full_addr + i), hex_byte(line, 9 + i * 2), 1);
         }
      }
      else if (type == 0x01)   // EOF
      {
         break;
      }
      else if (type == 0x02)   // extended segment address
      {
         if (count != 2)
            throw std::runtime_error("Bad extended segment address record");
         base = ((static_cast<uint32_t>(hex_byte(line, 9)) << 8) |
                 static_cast<uint32_t>(hex_byte(line, 11))) << 4;
      }
      else if (type == 0x04)   // extended linear address
      {
         if (count != 2)
            throw std::runtime_error("Bad extended linear address record");
         base = ((static_cast<uint32_t>(hex_byte(line, 9)) << 8) |
                 static_cast<uint32_t>(hex_byte(line, 11))) << 16;
      }
   }
}

static uint16_t split_window_address(uint16_t addr) {
   return g_cfg.cartridge_banked ? (uint16_t)(addr & 0x1FFFu) : addr;
}

static int split_memory_offset(uint16_t addr,
                               int write_window,
                               size_t *region_index,
                               uint16_t *offset) {
   uint16_t canonical;

   if (!g_cfg_loaded)
      return 0;
   canonical = split_window_address(addr);
   for (size_t i = 0; i < g_cfg.mem_count; ++i) {
      const memory_region_t *mem_region = &g_cfg.mem[i];
      uint16_t base;
      uint32_t end;

      if (!mem_region->has_write_start)
         continue;
      base = write_window ? mem_region->write_start : mem_region->start;
      base = split_window_address(base);
      end = (uint32_t)base + mem_region->size;
      if (canonical < base || (uint32_t)canonical >= end)
         continue;
      *region_index = i;
      *offset = (uint16_t)(canonical - base);
      return 1;
   }
   return 0;
}

static void mirror_split_byte(size_t region_index, uint16_t offset, uint8_t value) {
   const memory_region_t *mem_region = &g_cfg.mem[region_index];
   uint32_t read_addr = (uint32_t)mem_region->start + offset;
   uint32_t write_addr = (uint32_t)mem_region->write_start + offset;

   g_split_memory[region_index][offset] = value;
   mem[read_addr] = value;
   mem[write_addr] = value;
}

static void initialize_split_memory(uint8_t fill) {
   g_split_memory.clear();
   g_split_memory.resize(g_cfg.mem_count);
   if (!g_cfg_loaded)
      return;
   for (size_t i = 0; i < g_cfg.mem_count; ++i) {
      const memory_region_t *mem_region = &g_cfg.mem[i];
      if (!mem_region->has_write_start)
         continue;
      g_split_memory[i].assign(mem_region->size, fill);
      for (uint16_t offset = 0; offset < mem_region->size; ++offset)
         mirror_split_byte(i, offset, fill);
   }
}

static int cartridge_window_address(uint16_t addr) {
   return g_cfg_loaded && g_cfg.cartridge_banked && ((addr & 0x1FFFu) >= 0x1000u);
}

static size_t bank_index_for_file_index(size_t file_index) {
   for (size_t i = 0; i < g_cfg.bank_count; ++i)
      if (g_cfg.banks[i].file_index == file_index)
         return i;
   fprintf(stderr, "vcsc-sim: no bank for physical/file index %zu\n", file_index);
   exit(1);
}

static int bank_index_for_hotspot(uint16_t addr, size_t *bank_index) {
   uint16_t canonical = (uint16_t)(addr & 0x1FFFu);
   if (!g_cfg_loaded || !g_cfg.cartridge_banked)
      return 0;

   /* Parker Brothers E0 uses three groups of eight selectors in the fixed
      top 1K.  The low three selector bits choose the physical bank and the
      selector group chooses one of the three independently mapped windows. */
   if (g_cfg.e0_mapper && canonical >= 0x1fe0u && canonical <= 0x1ff7u) {
      uint16_t selector = (uint16_t)(canonical - 0x1fe0u);
      size_t segment = (size_t)(selector >> 3);
      size_t file_bank = (size_t)(selector & 7u);
      *bank_index = bank_index_for_file_index(file_bank);
      g_e0_segment_bank[segment] = *bank_index;
      return 1;
   }

   /* 0840/EconoBanking decodes A11 and A6 below the cartridge window; the
      remaining low address bits are aliases.  Keep the cfg's exact $0800/$0840
      selector declarations as the canonical bank identities. */
   if (str_ieq(g_cfg.mapper, "0840")) {
      uint16_t decoded = (uint16_t)(canonical & 0x1840u);
      uint16_t wanted = decoded == 0x0800u ? 0x0800u :
                        decoded == 0x0840u ? 0x0840u : 0xffffu;
      if (wanted != 0xffffu) {
         for (size_t i = 0; i < g_cfg.bank_count; ++i) {
            if ((g_cfg.banks[i].hotspot & 0x1fffu) == wanted) {
               *bank_index = i;
               return 1;
            }
         }
      }
      return 0;
   }

   /* UA Limited hardware qualifies only A12, A9, A6 and A5.  A11/A10/A8/A7
      plus A4-A0 are aliases, yielding the classic $0220/$0240 families and
      Brazilian $02A0/$02C0 aliases. UASW uses the same decoder but reverses
      the selector-to-file-bank association in the cfg. */
   if (str_ieq(g_cfg.mapper, "UA") || str_ieq(g_cfg.mapper, "UASW")) {
      uint16_t decoded = (uint16_t)(canonical & 0x1260u);
      uint16_t wanted = decoded == 0x0220u ? 0x0220u :
                        decoded == 0x0240u ? 0x0240u : 0xffffu;
      if (wanted != 0xffffu) {
         for (size_t i = 0; i < g_cfg.bank_count; ++i) {
            if ((g_cfg.banks[i].hotspot & 0x1fffu) == wanted) {
               *bank_index = i;
               return 1;
            }
         }
      }
      return 0;
   }

   /* 0FA0/Fotomania qualifies A12, A10, A9, A7, A6 and A5 after
      the 6507's 13-bit bus mirror is applied.  Stella's implementation uses
      (A & $16E0)==$06A0 for physical bank 0 and ==$06C0 for physical bank 1;
      A11, A8 and A4-A0 are aliases.  Canonical VCSC selectors are the familiar
      below-window $0FA0/$0FC0 pair, whose low-memory access still reaches the
      underlying console device. */
   if (str_ieq(g_cfg.mapper, "0FA0")) {
      uint16_t decoded = (uint16_t)(canonical & 0x16e0u);
      uint16_t wanted = decoded == 0x06a0u ? 0x0fa0u :
                        decoded == 0x06c0u ? 0x0fc0u : 0xffffu;
      if (wanted != 0xffffu) {
         for (size_t i = 0; i < g_cfg.bank_count; ++i) {
            if ((g_cfg.banks[i].hotspot & 0x1fffu) == wanted) {
               *bank_index = i;
               return 1;
            }
         }
      }
      return 0;
   }

   for (size_t i = 0; i < g_cfg.bank_count; ++i) {
      if ((g_cfg.banks[i].hotspot & 0x1FFFu) == canonical) {
         *bank_index = i;
         return 1;
      }
   }
   return 0;
}

static size_t selected_bank_index_for_address(uint16_t addr) {
   uint16_t canonical = (uint16_t)(addr & 0x1fffu);
   if (g_cfg.threef_mapper || g_cfg.threee_mapper) {
      if (canonical >= 0x1800u)
         return bank_index_for_file_index(g_cfg.bank_count - 1u);
      return g_selected_bank;
   }
   if (!g_cfg.e0_mapper)
      return g_selected_bank;
   if (canonical < 0x1400u)
      return g_e0_segment_bank[0];
   if (canonical < 0x1800u)
      return g_e0_segment_bank[1];
   if (canonical < 0x1c00u)
      return g_e0_segment_bank[2];
   return bank_index_for_file_index(7u);
}

static uint16_t selected_bank_address(uint16_t addr) {
   uint16_t canonical = (uint16_t)(addr & 0x1fffu);
   size_t bank_index = selected_bank_index_for_address(addr);
   const cartridge_bank_t *bank = &g_cfg.banks[bank_index];
   if (g_cfg.threef_mapper || g_cfg.threee_mapper) {
      uint16_t window_base = canonical < 0x1800u ? 0x1000u : 0x1800u;
      return (uint16_t)(bank->start + (canonical - window_base));
   }
   if (g_cfg.e0_mapper) {
      uint16_t window_base = canonical < 0x1400u ? 0x1000u :
                             canonical < 0x1800u ? 0x1400u :
                             canonical < 0x1c00u ? 0x1800u : 0x1c00u;
      return (uint16_t)(bank->start + (canonical - window_base));
   }
   return (uint16_t)(bank->start + (addr & 0x0FFFu));
}

static uint8_t peek_mem(uint16_t addr) {
   size_t region_index;
   uint16_t offset;
   uint16_t canonical = (uint16_t)(addr & 0x1fffu);
   if (g_cfg.threee_mapper && g_3e_ram_selected &&
       canonical >= 0x1000u && canonical < 0x1400u)
      return g_3e_ram[g_3e_ram_bank][canonical - 0x1000u];
   if (split_memory_offset(addr, 0, &region_index, &offset))
      return g_split_memory[region_index][offset];
   if (cartridge_window_address(addr))
      return mem[selected_bank_address(addr)];
   return mem[addr];
}

static void load_raw_binary(const char *filename) {
   std::ifstream in(filename, std::ios::binary);
   if (!in)
      throw std::runtime_error("Failed to open raw binary file");
   std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)),
                              std::istreambuf_iterator<char>());
   if (g_cfg_loaded && g_cfg.cartridge_direct_multi) {
      size_t expected = 0;
      for (size_t i = 0; i < g_cfg.bank_count; ++i)
         expected += g_cfg.banks[i].size;
      if (bytes.size() != expected)
         throw std::runtime_error("Raw direct-multi cartridge size does not match config");
      for (size_t file_index = 0; file_index < g_cfg.bank_count; ++file_index) {
         size_t bank_index = bank_index_for_file_index(file_index);
         const cartridge_bank_t *bank = &g_cfg.banks[bank_index];
         memcpy(mem + bank->start, bytes.data() + file_index * bank->size, bank->size);
      }
      return;
   }
   if (!g_cfg_loaded || !g_cfg.cartridge_banked) {
      // Conventional unbanked VCS images have an unambiguous placement in the
      // 4K cartridge window.  Supporting them directly also lets logical cfgs
      // such as 4KSC supply split-address cartridge RAM semantics without
      // pretending that the cartridge is bank-switched.
      if (bytes.size() == 2048u) {
         memcpy(mem + 0xF800u, bytes.data(), bytes.size());
         return;
      }
      if (bytes.size() == 4096u) {
         memcpy(mem + 0xF000u, bytes.data(), bytes.size());
         return;
      }
      throw std::runtime_error("Raw unbanked cartridge must be exactly 2K or 4K");
   }
   size_t expected = 0;
   for (size_t i = 0; i < g_cfg.bank_count; ++i)
      expected += g_cfg.banks[i].size;
   if (bytes.size() != expected)
      throw std::runtime_error("Raw cartridge size does not match banked config");
   for (size_t file_index = 0; file_index < g_cfg.bank_count; ++file_index) {
      size_t bank_index = bank_index_for_file_index(file_index);
      const cartridge_bank_t *bank = &g_cfg.banks[bank_index];
      memcpy(mem + bank->start, bytes.data() + file_index * bank->size, bank->size);
   }
}

void write_cb(uint16_t addr, uint8_t val) {
   size_t selected;
   size_t region_index;
   uint16_t offset;
   if (trace_ops & TRACE_OP_WRITES)
      printf("write $%02x -> $%04x\n", val, addr);

   {
      uint16_t canonical = (uint16_t)(addr & 0x1fffu);
      if (g_cfg.threef_mapper && canonical <= 0x003fu) {
         g_selected_bank = bank_index_for_file_index((size_t)val % g_cfg.bank_count);
      }
      else if (g_cfg.threee_mapper && canonical == 0x003fu) {
         g_selected_bank = bank_index_for_file_index((size_t)val % g_cfg.bank_count);
         g_3e_ram_selected = 0;
      }
      else if (g_cfg.threee_mapper && canonical == 0x003eu) {
         g_3e_ram_bank = (uint8_t)(val & 31u);
         g_3e_ram_selected = 1;
      }
      if (g_cfg.threee_mapper && g_3e_ram_selected &&
          canonical >= 0x1000u && canonical < 0x1800u) {
         if (canonical < 0x1400u) {
            fprintf(stderr, "vcsc-sim: write to 3E RAM read alias at $%04X\n", addr);
            trace_regs(); trace_disasm(gpc); exit(1);
         }
         g_3e_ram[g_3e_ram_bank][canonical - 0x1400u] = val;
         return;
      }
   }

   if (bank_index_for_hotspot(addr, &selected)) {
      g_selected_bank = selected;
      /* ROM-window hotspot writes target the cartridge and stop here.  A
         below-window selector such as 0840, UA, or 0FA0 overlays a console device, so the
         underlying write must still reach the ordinary memory/TIA model. */
      if ((addr & 0x1fffu) >= 0x1000u)
         return;
   }
   if (split_memory_offset(addr, 1, &region_index, &offset)) {
      mirror_split_byte(region_index, offset, val);
      return;
   }
   if (split_memory_offset(addr, 0, &region_index, &offset)) {
      fprintf(stderr,
              "vcsc-sim: write to read alias of split-address MEMORY region '%s' at $%04X\n",
              g_cfg.mem[region_index].name, addr);
      trace_regs();
      trace_disasm(gpc);
      exit(1);
   }
   if (cartridge_window_address(addr)) {
      fprintf(stderr, "vcsc-sim: write to read-only cartridge memory at $%04X\n", addr);
      trace_regs();
      trace_disasm(gpc);
      exit(1);
   }
   store_mem(addr, val, 0);
}

uint8_t read_cb(uint16_t addr) {
   size_t selected;
   size_t write_region_index;
   size_t read_region_index;
   uint16_t write_offset;
   uint16_t read_offset;
   {
      uint16_t canonical = (uint16_t)(addr & 0x1fffu);
      if (g_cfg.threee_mapper && g_3e_ram_selected &&
          canonical >= 0x1400u && canonical < 0x1800u) {
         fprintf(stderr, "vcsc-sim: read from 3E RAM write alias at $%04X\n", addr);
         trace_regs(); trace_disasm(gpc); exit(1);
      }
   }
   if (split_memory_offset(addr, 1, &write_region_index, &write_offset) &&
       !split_memory_offset(addr, 0, &read_region_index, &read_offset)) {
      fprintf(stderr,
              "vcsc-sim: read from write alias of split-address MEMORY region '%s' at $%04X\n",
              g_cfg.mem[write_region_index].name, addr);
      trace_regs();
      trace_disasm(gpc);
      exit(1);
   }
   uint8_t value = peek_mem(addr);
   if (trace_ops & TRACE_OP_READS) {
      if (cartridge_window_address(addr)) {
         size_t selected_for_addr = selected_bank_index_for_address(addr);
         printf("read $%04x [file-bank=%zu %s] -> $%02x\n", addr,
                g_cfg.banks[selected_for_addr].file_index,
                g_cfg.banks[selected_for_addr].name, value);
      }
      else
         printf("read $%04x -> $%02x\n", addr, value);
   }
   if (bank_index_for_hotspot(addr, &selected))
      g_selected_bank = selected;
   return value;
}

void clock_cb(mos6502* unused) {
   (void) unused; // unused parameter
   if (trace_ops & TRACE_OP_CYCLES) {
      printf("cycle %" PRId64 "\n", counter);
   }
}

void dispatch(uint8_t op, uint16_t arg) {
   if (trace_ops & TRACE_OP_DISPATCH) {
      printf("dispatch %02x %04X\n", op, arg);
   }
   switch(op) {
      case 0:
         printf("%s", mem+arg);
         fflush(stdout);
         break;
      case 0xfd:
         trace_ops = arg;
         break;
      case 0xfe:
         dump_mem_as_intel_hex();
         break;
      case 0xff:
         exit(arg);
         break;
      default:
         fprintf(stderr, "unknown dispatch op %02x\n", op);
         break;
   }
}

void trace_regs(void) {
   uint8_t p = cpu->GetP();
   printf("A:$%02x X:$%02x Y:$%02x P:$%02x(%c%c%c%c%c%c%c%c) SP:$%02x PC:$%04x\n",
      cpu->GetA(),
      cpu->GetX(),
      cpu->GetY(),
      p,
      (p & 0x80) ? 'N' : 'n',
      (p & 0x40) ? 'V' : 'v',
      (p & 0x20) ? '-' : '?',
      (p & 0x10) ? 'B' : 'b',
      (p & 0x08) ? 'D' : 'd',
      (p & 0x04) ? 'I' : 'i',
      (p & 0x02) ? 'Z' : 'z',
      (p & 0x01) ? 'C' : 'c',
      cpu->GetS(),
      cpu->GetPC());
}

void trace_disasm(uint16_t pc) {
   const char *code = cpu->GetCode(peek_mem(pc));
   const char *addr = cpu->GetAddr(peek_mem(pc));

   switch (addr[0]) {
      case 'A':
         switch(addr[2]) {
            case 'I':
               // ABI
               printf("ASM: $%04x: %s.i ($%04x)    ; %02x %02x %02x\n", pc, code, peek_mem(pc+1) | (peek_mem(pc+2) << 8), peek_mem(pc), peek_mem(pc+1), peek_mem(pc+2));
               break;
            case 'S':
               // ABS
               printf("ASM: $%04x: %s.a $%04x      ; %02x %02x %02x\n", pc, code, peek_mem(pc+1) | (peek_mem(pc+2) << 8), peek_mem(pc), peek_mem(pc+1), peek_mem(pc+2));
               break;
            case 'X':
               // ABX
               printf("ASM: $%04x: %s.ax $%04x,X   ; %02x %02x %02x\n", pc, code, peek_mem(pc+1) | (peek_mem(pc+2) << 8), peek_mem(pc), peek_mem(pc+1), peek_mem(pc+2));
               break;
            case 'Y':
               // ABY
               printf("ASM: $%04x: %s.ay $%04x,Y   ; %02x %02x %02x\n", pc, code, peek_mem(pc+1) | (peek_mem(pc+2) << 8), peek_mem(pc), peek_mem(pc+1), peek_mem(pc+2));
               break;
            case 'C':
               // ACC
               printf("ASM: $%04x: %s A            ; %02x\n", pc, code, peek_mem(pc));
               break;
         }
         break;
      case  'I':
         switch(addr[2]) {
            case 'M':
               // IMM
               printf("ASM: $%04x: %s #$%02x       ; %02x %02x\n", pc, code, peek_mem(pc+1), peek_mem(pc), peek_mem(pc+1));
               break;
            case 'P':
               // IMP
               printf("ASM: $%04x: %s              ; %02x\n", pc, code, peek_mem(pc));
               break;
            case 'X':
               // INX
               printf("ASM: $%04x: %s.ix ($%02x,X) ; %02x %02x\n", pc, code, peek_mem(pc+1), peek_mem(pc), peek_mem(pc+1));
               break;
            case 'Y':
               // INY
               printf("ASM: $%04x: %s.iy ($%02x),Y ; %02x %02x\n", pc, code, peek_mem(pc+1), peek_mem(pc), peek_mem(pc+1));
               break;
         }
         break;
      case 'R':
         // REL
               printf("ASM: $%04x: %s $%02x        ; %02x %02x\n", pc, code, peek_mem(pc+1), peek_mem(pc), peek_mem(pc+1));
         break;
      case 'Z':
         switch(addr[2]) {
            case 'R':
               // ZER
               printf("ASM: $%04x: %s.z $%02x      ; %02x %02x\n", pc, code, peek_mem(pc+1), peek_mem(pc), peek_mem(pc+1));
               break;
            case 'X':
               // ZEX
               printf("ASM: $%04x: %s.zx $%02x,X   ; %02x %02x\n", pc, code, peek_mem(pc+1), peek_mem(pc), peek_mem(pc+1));
               break;
            case 'Y':
               // ZEY
               printf("ASM: $%04x: %s.zy $%02x,Y   ; %02x %02x\n", pc, code, peek_mem(pc+1), peek_mem(pc), peek_mem(pc+1));
               break;
         }
         break;
   }
}

int main (int argc, char **argv) {
   simulator_options_t opts;

   parse_args(&opts, argc, argv);

   if (opts.trace_set) {
      trace_ops = opts.trace;
   }

   if (opts.cfg_path != nullptr) {
      parse_cfg_file(&g_cfg, opts.cfg_path);
      g_cfg_loaded = 1;
   }

   memset(mem, 0xFF, 65536);

   if (ends_with(opts.image_path, ".bin"))
      load_raw_binary(opts.image_path);
   else
      load_intel_hex(opts.image_path);

   initialize_split_memory(opts.split_fill_set ? opts.split_fill : 0);

   if (g_cfg_loaded && g_cfg.cartridge_banked) {
      if (g_cfg.e0_mapper) {
         if (opts.start_bank_set) {
            fprintf(stderr,
                    "vcsc-sim: --start-bank is not meaningful for E0's three independent windows\n");
            return 1;
         }
         g_e0_segment_bank[0] = bank_index_for_file_index(4u);
         g_e0_segment_bank[1] = bank_index_for_file_index(5u);
         g_e0_segment_bank[2] = bank_index_for_file_index(6u);
         g_selected_bank = g_cfg.startup_bank;
      }
      else if (g_cfg.threef_mapper || g_cfg.threee_mapper) {
         g_3e_ram_selected = 0;
         if (opts.start_bank_set) {
            if (opts.start_bank >= g_cfg.bank_count) {
               fprintf(stderr, "vcsc-sim: start bank %zu is outside 0..%zu\n",
                       opts.start_bank, g_cfg.bank_count - 1);
               return 1;
            }
            g_selected_bank = bank_index_for_file_index(opts.start_bank);
         } else {
            g_selected_bank = bank_index_for_file_index(0u);
         }
      }
      else if (opts.start_bank_set) {
         if (opts.start_bank >= g_cfg.bank_count) {
            fprintf(stderr, "vcsc-sim: start bank %zu is outside 0..%zu\n",
                    opts.start_bank, g_cfg.bank_count - 1);
            return 1;
         }
         g_selected_bank = bank_index_for_file_index(opts.start_bank);
      }
      else {
         g_selected_bank = g_cfg.startup_bank;
      }
   }
   else if (opts.start_bank_set) {
      fprintf(stderr, "vcsc-sim: --start-bank requires a banked config\n");
      return 1;
   }

   cpu = new mos6502(read_cb, write_cb, clock_cb);

   cpu->Reset();

   int reset_on_pc_done = 0;
   while (1) {
      gpc = cpu->GetPC();
      if (opts.reset_on_pc_set && !reset_on_pc_done && gpc == opts.reset_on_pc) {
         cpu->Reset();
         reset_on_pc_done = 1;
         continue;
      }
      if (opts.stop_pc_set && gpc == opts.stop_pc) {
         if (opts.dump_on_stop)
            dump_mem_as_intel_hex();
         return 0;
      }
      if (trace_ops & TRACE_OP_REGS) {
         trace_regs();
      }
      if (trace_ops & TRACE_OP_DISASM) {
         trace_disasm(gpc);
      }
      cpu->Run(1, counter, mos6502::INST_COUNT);
      if ((!g_cfg_loaded || !g_cfg.cartridge_banked) && cpu->GetPC() == 0xFFFF) {

         uint8_t op = cpu->GetA();
         uint16_t arg = ((uint16_t)cpu->GetY()) << 8 | cpu->GetX();
         dispatch(op, arg);

         uint8_t tmp = mem[0xFFFF]; // remember original value
         store_mem(0xFFFF, 0x60, 1); // insert an RTS there

         cpu->Run(1, counter, mos6502::INST_COUNT);

         store_mem(0xFFFF, tmp, 1); // restore original value
      }
   }

   return 0;
}
