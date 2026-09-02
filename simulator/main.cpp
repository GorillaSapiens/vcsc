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
   cartridge_bank_t banks[256];
   size_t bank_count;
   size_t auxiliary_image_bytes;
   char mapper[16];
   int cartridge_banked;
   int cartridge_direct_multi;
   int superchip_mapper;
   int e0_mapper;
   int wd_mapper;
   int fe_mapper;
   int threef_mapper;
   int threee_mapper;
   int dpc_mapper;
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
   const char *map_path;
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
static int g_fe_waiting_data = 0;
static uint8_t g_wd_config = 0;
static int g_wd_pending = 0;
static uint8_t g_wd_pending_config = 0;
static uint64_t g_wd_pending_cycle = 0;
static const uint8_t g_wd_bank_org[8][4] = {
   {0,0,1,3}, {0,1,2,3}, {4,5,6,7}, {7,4,2,3},
   {0,0,6,7}, {0,1,7,6}, {2,3,4,5}, {6,0,5,1}
};
static uint8_t g_3e_ram[32][1024] = {};
static uint8_t g_dpc_display[2048] = {};
static uint8_t g_dpc_poly_image[255] = {};
static uint8_t g_dpc_tops[8] = {};
static uint8_t g_dpc_bottoms[8] = {};
static uint16_t g_dpc_counters[8] = {};
static uint8_t g_dpc_flags[8] = {};
static uint8_t g_dpc_music_mode[3] = {};
static uint8_t g_dpc_random = 1;
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
      "  --map=FILE           Use linker map FILE for C26 cartridge topology\n"
      "  --script=FILE        Same as -T FILE\n"
      "  --start-bank=N       Begin in physical/file bank N (banked topology only)\n"
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
      if (!n.ok || n.value > 255u) {
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

//! @brief Validate and classify one parsed simulator topology.
static void finalize_simulator_config(simulator_config_t *cfg) {
   size_t startup_count = 0;
   int any_hotspot = 0;

   cfg->cartridge_direct_multi = str_ieq(cfg->mapper, "OMNI");
   cfg->superchip_mapper = str_ieq(cfg->mapper, "4KSC") ||
                           str_ieq(cfg->mapper, "F8SC") ||
                           str_ieq(cfg->mapper, "F6SC") ||
                           str_ieq(cfg->mapper, "F4SC");
   cfg->e0_mapper = str_ieq(cfg->mapper, "E0");
   cfg->wd_mapper = str_ieq(cfg->mapper, "WD");
   cfg->fe_mapper = str_ieq(cfg->mapper, "FE");
   cfg->threef_mapper = str_ieq(cfg->mapper, "3F");
   cfg->threee_mapper = str_ieq(cfg->mapper, "3E");
   cfg->dpc_mapper = str_ieq(cfg->mapper, "DPC");

   for (size_t i = 0; i < cfg->bank_count; ++i)
      if (cfg->banks[i].hotspot)
         any_hotspot = 1;
   cfg->cartridge_banked = !cfg->cartridge_direct_multi &&
      (cfg->bank_count > 1u || any_hotspot || cfg->e0_mapper || cfg->wd_mapper ||
       cfg->fe_mapper || cfg->threef_mapper || cfg->threee_mapper || cfg->dpc_mapper);

   if (cfg->bank_count == 0)
      return;

   if (cfg->cartridge_banked || cfg->cartridge_direct_multi) {
      if (!(str_ieq(cfg->mapper, "F8") || str_ieq(cfg->mapper, "F6") ||
            str_ieq(cfg->mapper, "F4") || str_ieq(cfg->mapper, "FA") ||
            str_ieq(cfg->mapper, "FA2") ||
            str_ieq(cfg->mapper, "OMNI") || str_ieq(cfg->mapper, "JANE") ||
            str_ieq(cfg->mapper, "0840") || str_ieq(cfg->mapper, "UA") ||
            str_ieq(cfg->mapper, "UASW") || str_ieq(cfg->mapper, "0FA0") ||
            cfg->e0_mapper || cfg->wd_mapper || cfg->fe_mapper ||
            cfg->threef_mapper || cfg->threee_mapper || cfg->dpc_mapper ||
            cfg->superchip_mapper)) {
         fprintf(stderr, "vcsc-sim: unsupported mapper '%s'\n", cfg->mapper);
         exit(1);
      }
      if (cfg->e0_mapper && cfg->bank_count != 8u) {
         fprintf(stderr, "vcsc-sim: E0 requires exactly eight physical 1K banks\n");
         exit(1);
      }
      if (cfg->wd_mapper && cfg->bank_count != 2u) {
         fprintf(stderr, "vcsc-sim: WD C26 topology requires two logical 4K banks (hardware states 1 and 2)\n");
         exit(1);
      }
      if (cfg->fe_mapper && cfg->bank_count != 2u) {
         fprintf(stderr, "vcsc-sim: FE requires exactly two physical 4K banks\n");
         exit(1);
      }
      if (cfg->dpc_mapper && cfg->bank_count != 2u) {
         fprintf(stderr, "vcsc-sim: DPC requires exactly two physical 4K program banks\n");
         exit(1);
      }
   }

   for (size_t i = 0; i < cfg->bank_count; ++i) {
      size_t file_index = 0;
      uint16_t wanted_size = cfg->e0_mapper ? 0x0400u :
                             (cfg->threef_mapper || cfg->threee_mapper) ? 0x0800u : 0x1000u;
      if ((cfg->cartridge_banked || cfg->cartridge_direct_multi) &&
          !cfg->cartridge_direct_multi && cfg->banks[i].size != wanted_size) {
         fprintf(stderr, "vcsc-sim: %s bank '%s' is not %s\n",
                 cfg->mapper, cfg->banks[i].name,
                 cfg->e0_mapper ? "1K" :
                 (cfg->threef_mapper || cfg->threee_mapper) ? "2K" : "4K");
         exit(1);
      }
      if ((cfg->e0_mapper || cfg->wd_mapper || cfg->fe_mapper || cfg->dpc_mapper ||
           str_ieq(cfg->mapper, "FA2")) && !cfg->banks[i].has_file_index) {
         fprintf(stderr, "vcsc-sim: %s bank '%s' requires an explicit fileindex\n",
                 cfg->mapper, cfg->banks[i].name);
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
   if ((cfg->cartridge_banked || cfg->cartridge_direct_multi) && startup_count != 1) {
      fprintf(stderr, "vcsc-sim: multi-region topology must name exactly one startup bank\n");
      exit(1);
   }
   if (cfg->e0_mapper && cfg->banks[cfg->startup_bank].file_index != 7u) {
      fprintf(stderr, "vcsc-sim: E0 startup bank must be fixed physical/file bank 7\n");
      exit(1);
   }
   if (cfg->wd_mapper && cfg->banks[cfg->startup_bank].file_index != 0u) {
      fprintf(stderr, "vcsc-sim: WD startup bank must be logical/file bank 0 (hardware state 1)\n");
      exit(1);
   }
   if (cfg->fe_mapper && cfg->banks[cfg->startup_bank].file_index != 0u) {
      fprintf(stderr, "vcsc-sim: FE startup bank must be physical/file bank 0\n");
      exit(1);
   }
   if (cfg->dpc_mapper && cfg->banks[cfg->startup_bank].file_index != 1u) {
      fprintf(stderr, "vcsc-sim: DPC startup bank must be physical/file bank 1\n");
      exit(1);
   }
   if ((cfg->threef_mapper || cfg->threee_mapper) &&
       cfg->banks[cfg->startup_bank].file_index != cfg->bank_count - 1u) {
      fprintf(stderr, "vcsc-sim: 3F/3E startup bank must be the fixed final physical/file bank\n");
      exit(1);
   }

   for (size_t i = 0; i < cfg->mem_count; ++i) {
      memory_region_t *mem_region = &cfg->mem[i];
      if (!mem_region->has_write_start)
         continue;
      if (!str_ieq(mem_region->type, "rw")) {
         fprintf(stderr, "vcsc-sim: split-address MEMORY region '%s' is not type=rw\n",
                 mem_region->name);
         exit(1);
      }
      if (mem_region->bank_name[0]) {
         fprintf(stderr, "vcsc-sim: split-address MEMORY region '%s' must be shared\n",
                 mem_region->name);
         exit(1);
      }
      if (mem_region->size == 0 ||
          (uint32_t)mem_region->start + mem_region->size > 0x10000u ||
          (uint32_t)mem_region->write_start + mem_region->size > 0x10000u) {
         fprintf(stderr, "vcsc-sim: split-address MEMORY region '%s' has an invalid window\n",
                 mem_region->name);
         exit(1);
      }
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

   finalize_simulator_config(cfg);

}


static bool map_token_value(const std::string& line, const char *key, std::string *value) {
   const std::string needle = std::string(key) + "=";
   size_t pos = line.find(needle);
   if (pos == std::string::npos)
      return false;
   pos += needle.size();
   if (pos < line.size() && line[pos] == '"') {
      const size_t end = line.find('"', pos + 1);
      if (end == std::string::npos)
         return false;
      *value = line.substr(pos + 1, end - pos - 1);
      return true;
   }
   size_t end = pos;
   while (end < line.size() && !isspace((unsigned char)line[end]))
      ++end;
   *value = line.substr(pos, end - pos);
   return !value->empty();
}

static bool map_number_value(const std::string& line, const char *key, uint32_t *value) {
   std::string text;
   if (!map_token_value(line, key, &text))
      return false;
   parse_result_t parsed = parse_number(text.c_str());
   if (!parsed.ok || parsed.pos != text.size())
      return false;
   *value = parsed.value;
   return true;
}

static std::string map_first_word(const std::string& line) {
   size_t start = 0;
   while (start < line.size() && isspace((unsigned char)line[start]))
      ++start;
   size_t end = start;
   while (end < line.size() && !isspace((unsigned char)line[end]))
      ++end;
   return line.substr(start, end - start);
}

static std::string c26_signature_mapper(const std::string& signature) {
   std::string mapper;
   for (size_t i = 0; i < signature.size();) {
      if (signature[i] == '\\' && i + 1 < signature.size() && signature[i + 1] == '0')
         break;
      mapper.push_back(signature[i++]);
   }
   return mapper;
}

//! @brief Parse resolved C26 cartridge/memory topology from a linker map.
static void parse_c26_map_file(simulator_config_t *cfg, const char *path) {
   std::ifstream in(path);
   if (!in) {
      fprintf(stderr, "vcsc-sim: cannot open map '%s': %s\n", path, strerror(errno));
      exit(1);
   }

   memset(cfg, 0, sizeof(*cfg));
   std::string line;
   bool in_c26 = false;
   bool saw_c26 = false;
   bool in_memory = false;
   uint32_t output_size = 0;
   size_t program_image_bytes = 0;

   while (std::getline(in, line)) {
      if (line == "C26 CARTRIDGE TOPOLOGY") {
         in_c26 = true;
         in_memory = false;
         saw_c26 = true;
         continue;
      }
      if (line == "MEMORY") {
         in_c26 = false;
         in_memory = true;
         continue;
      }
      if (!line.empty() && !isspace((unsigned char)line[0])) {
         in_c26 = false;
         if (line != "MEMORY")
            in_memory = false;
      }

      if (in_c26) {
         const std::string first = map_first_word(line);
         if (first.empty())
            continue;
         if (first.find("output-size=") == 0) {
            std::string signature;
            if (!map_number_value(line, "output-size", &output_size)) {
               fprintf(stderr, "vcsc-sim: malformed C26 output-size in '%s'\n", path);
               exit(1);
            }
            if (map_token_value(line, "signature", &signature)) {
               const std::string mapper = c26_signature_mapper(signature);
               snprintf(cfg->mapper, sizeof(cfg->mapper), "%s", mapper.c_str());
            }
            continue;
         }

         std::string mode;
         uint32_t image_size = 0;
         if (!map_token_value(line, "mode", &mode) ||
             !map_number_value(line, "image-size", &image_size))
            continue;
         if (mode == "data-only") {
            cfg->auxiliary_image_bytes += image_size;
            continue;
         }
         if (cfg->bank_count >= sizeof(cfg->banks) / sizeof(cfg->banks[0])) {
            fprintf(stderr, "vcsc-sim: too many C26 cartridge banks in '%s'\n", path);
            exit(1);
         }

         uint32_t file_index = 0, image_offset = 0, link = 0, hotspot = 0;
         if (!map_number_value(line, "file-index", &file_index) || file_index > 255u ||
             !map_number_value(line, "image-offset", &image_offset) ||
             !map_number_value(line, "link", &link) || link > 0xffffu ||
             image_size == 0 || image_size > 0xffffu || image_offset > link) {
            fprintf(stderr, "vcsc-sim: malformed C26 bank topology in '%s': %s\n",
                    path, line.c_str());
            exit(1);
         }
         cartridge_bank_t *bank = &cfg->banks[cfg->bank_count++];
         memset(bank, 0, sizeof(*bank));
         snprintf(bank->name, sizeof(bank->name), "%s", first.c_str());
         bank->start = (uint16_t)(link - image_offset);
         bank->size = (uint16_t)image_size;
         bank->file_index = file_index;
         bank->has_file_index = 1;
         if (map_number_value(line, "select-access", &hotspot)) {
            if (hotspot > 0xffffu) {
               fprintf(stderr, "vcsc-sim: bad C26 selector in '%s'\n", path);
               exit(1);
            }
            bank->hotspot = (uint16_t)hotspot;
         }
         std::string startup;
         bank->startup = map_token_value(line, "startup", &startup) && startup == "yes";
         program_image_bytes += image_size;
         continue;
      }

      if (in_memory) {
         const std::string first = map_first_word(line);
         if (first.empty()) {
            in_memory = false;
            continue;
         }
         std::string type, output_bank;
         if (!map_token_value(line, "type", &type))
            continue;
         const bool split = line.find("write_start=") != std::string::npos;
         const bool shared = !map_token_value(line, "output-bank", &output_bank) || output_bank == "<none>";
         if (!split && !shared)
            continue;
         if (cfg->mem_count >= sizeof(cfg->mem) / sizeof(cfg->mem[0])) {
            fprintf(stderr, "vcsc-sim: too many shared MEMORY entries in '%s'\n", path);
            exit(1);
         }
         memory_region_t *mem_region = &cfg->mem[cfg->mem_count++];
         memset(mem_region, 0, sizeof(*mem_region));
         snprintf(mem_region->name, sizeof(mem_region->name), "%s", first.c_str());
         snprintf(mem_region->type, sizeof(mem_region->type), "%s", type.c_str());

         uint32_t n = 0;
         if (map_number_value(line, "read_start", &n) || map_number_value(line, "start", &n)) {
            if (n > 0xffffu) {
               fprintf(stderr, "vcsc-sim: bad map MEMORY start in '%s'\n", path);
               exit(1);
            }
            mem_region->start = (uint16_t)n;
         }
         if (map_number_value(line, "write_start", &n)) {
            if (n > 0xffffu) {
               fprintf(stderr, "vcsc-sim: bad map MEMORY write_start in '%s'\n", path);
               exit(1);
            }
            mem_region->write_start = (uint16_t)n;
            mem_region->has_write_start = 1;
         }
         if (!map_number_value(line, "size", &n) || n == 0 || n > 0xffffu) {
            fprintf(stderr, "vcsc-sim: bad map MEMORY size in '%s': %s\n", path, line.c_str());
            exit(1);
         }
         mem_region->size = (uint16_t)n;
      }
   }

   if (!saw_c26) {
      fprintf(stderr, "vcsc-sim: map '%s' contains no C26 cartridge topology\n", path);
      exit(1);
   }
   if (output_size != 0 && program_image_bytes + cfg->auxiliary_image_bytes != output_size) {
      fprintf(stderr,
              "vcsc-sim: C26 map image accounting mismatch in '%s' (%zu + %zu != %u)\n",
              path, program_image_bytes, cfg->auxiliary_image_bytes, output_size);
      exit(1);
   }
   finalize_simulator_config(cfg);
}

static bool file_readable(const std::string& path) {
   std::ifstream in(path);
   return in.good();
}

static std::string same_stem_map_path(const char *image_path) {
   std::string path(image_path);
   const size_t slash = path.find_last_of("/\\");
   const size_t dot = path.find_last_of('.');
   if (dot != std::string::npos && (slash == std::string::npos || dot > slash))
      path.erase(dot);
   path += ".map";
   return path;
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
      else if (strncmp(arg, "--map=", 6) == 0) {
         opts->map_path = arg + 6;
      }
      else if (strcmp(arg, "--map") == 0) {
         const char *value;
         assign_option_value(&value, "", &argi, argc, argv, "--map");
         opts->map_path = value;
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
   if (opts->cfg_path != nullptr && opts->map_path != nullptr) {
      fprintf(stderr, "vcsc-sim: use either --config/-T or --map, not both\n");
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

static void dpc_clock_random(void) {
   static const uint8_t feedback[16] = {
      1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1
   };
   uint8_t index = (uint8_t)(((g_dpc_random >> 3) & 0x07u) |
                             ((g_dpc_random & 0x80u) ? 0x08u : 0x00u));
   g_dpc_random = (uint8_t)((g_dpc_random << 1) | feedback[index]);
}

static int dpc_register_address(uint16_t addr) {
   uint16_t canonical = (uint16_t)(addr & 0x1fffu);
   return g_cfg_loaded && g_cfg.dpc_mapper &&
          canonical >= 0x1000u && canonical < 0x1080u;
}

static int dpc_rng_clocked_access(uint16_t addr) {
   uint16_t canonical = (uint16_t)(addr & 0x1fffu);
   return g_cfg_loaded && g_cfg.dpc_mapper &&
          ((canonical >= 0x1000u && canonical < 0x1080u) ||
           canonical == 0x1ff8u || canonical == 0x1ff9u);
}

static uint8_t dpc_read_register(uint16_t addr) {
   uint16_t address = (uint16_t)(addr & 0x0fffu);
   uint8_t index = (uint8_t)(address & 0x07u);
   uint8_t function = (uint8_t)((address >> 3) & 0x07u);
   uint8_t result = 0;

   if ((g_dpc_counters[index] & 0x00ffu) == g_dpc_tops[index])
      g_dpc_flags[index] = 0xffu;
   else if ((g_dpc_counters[index] & 0x00ffu) == g_dpc_bottoms[index])
      g_dpc_flags[index] = 0x00u;

   switch (function) {
      case 0x00:
         if (index < 4u) {
            result = g_dpc_random;
         } else {
            static const uint8_t music_amplitudes[8] = {
               0x00, 0x04, 0x05, 0x09, 0x06, 0x0a, 0x0b, 0x0f
            };
            uint8_t music = 0;
            if (g_dpc_music_mode[0] && g_dpc_flags[5]) music |= 0x01u;
            if (g_dpc_music_mode[1] && g_dpc_flags[6]) music |= 0x02u;
            if (g_dpc_music_mode[2] && g_dpc_flags[7]) music |= 0x04u;
            result = music_amplitudes[music];
         }
         break;
      case 0x01:
         result = g_dpc_display[2047u - (g_dpc_counters[index] & 0x07ffu)];
         break;
      case 0x02:
         result = (uint8_t)(g_dpc_display[2047u - (g_dpc_counters[index] & 0x07ffu)] &
                            g_dpc_flags[index]);
         break;
      case 0x07:
         result = g_dpc_flags[index];
         break;
      default:
         result = 0;
         break;
   }

   if (index < 5u || !g_dpc_music_mode[index - 5u])
      g_dpc_counters[index] = (uint16_t)((g_dpc_counters[index] - 1u) & 0x07ffu);
   return result;
}

static void dpc_write_register(uint16_t addr, uint8_t value) {
   uint16_t address = (uint16_t)(addr & 0x0fffu);
   if (address < 0x0040u)
      return;
   uint8_t index = (uint8_t)(address & 0x07u);
   uint8_t function = (uint8_t)((address >> 3) & 0x07u);

   switch (function) {
      case 0x00:
         g_dpc_tops[index] = value;
         g_dpc_flags[index] = 0x00u;
         break;
      case 0x01:
         g_dpc_bottoms[index] = value;
         break;
      case 0x02:
         if (index >= 5u && g_dpc_music_mode[index - 5u])
            g_dpc_counters[index] = (uint16_t)((g_dpc_counters[index] & 0x0700u) |
                                               g_dpc_tops[index]);
         else
            g_dpc_counters[index] = (uint16_t)((g_dpc_counters[index] & 0x0700u) | value);
         break;
      case 0x03:
         g_dpc_counters[index] = (uint16_t)(((uint16_t)(value & 0x07u) << 8) |
                                            (g_dpc_counters[index] & 0x00ffu));
         if (index >= 5u)
            g_dpc_music_mode[index - 5u] = (value & 0x10u) ? 1u : 0u;
         break;
      case 0x06:
         g_dpc_random = 1u;
         break;
      default:
         break;
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

static size_t fe_bank_from_data(uint8_t value) {
   return (size_t)(((value >> 5) ^ 0x07u) & 1u);
}

static void fe_observe_access(uint16_t addr, uint8_t value) {
   if (!g_cfg_loaded || !g_cfg.fe_mapper)
      return;
   const uint16_t bus = (uint16_t)(addr & 0x1fffu);
   const int was_waiting = g_fe_waiting_data;
   if (was_waiting) {
      const size_t file_bank = fe_bank_from_data(value);
      g_selected_bank = bank_index_for_file_index(file_bank);
      g_fe_waiting_data = 0;
   }
   if (bus == 0x01feu)
      g_fe_waiting_data = 1;
}

static void wd_note_selector_read(uint16_t addr) {
   if (!g_cfg_loaded || !g_cfg.wd_mapper) return;
   const uint16_t bus = (uint16_t)(addr & 0x1fffu);
   if (bus >= 0x0030u && bus <= 0x003fu) {
      g_wd_pending = 1;
      g_wd_pending_config = (uint8_t)(bus & 7u);
      g_wd_pending_cycle = counter;
   }
}

static void wd_commit_after_instruction(void) {
   if (g_cfg_loaded && g_cfg.wd_mapper && g_wd_pending &&
       counter > g_wd_pending_cycle + 3u) {
      g_wd_config = g_wd_pending_config;
      g_wd_pending = 0;
   }
}

static int bank_index_for_hotspot(uint16_t addr, size_t *bank_index) {
   uint16_t canonical = (uint16_t)(addr & 0x1FFFu);
   if (!g_cfg_loaded || !g_cfg.cartridge_banked)
      return 0;
   if (g_cfg.fe_mapper || g_cfg.wd_mapper)
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
      if (g_cfg.banks[i].hotspot != 0 &&
          (g_cfg.banks[i].hotspot & 0x1FFFu) == canonical) {
         *bank_index = i;
         return 1;
      }
   }
   return 0;
}

static uint8_t wd_physical_chunk_for_address(uint16_t addr) {
   uint16_t canonical = (uint16_t)(addr & 0x1fffu);
   size_t segment;
   if (canonical < 0x1000u)
      return 3u;
   segment = (size_t)((canonical - 0x1000u) >> 10);
   if (segment > 3u) segment = 3u;
   return g_wd_bank_org[g_wd_config & 7u][segment];
}

static size_t selected_bank_index_for_address(uint16_t addr) {
   uint16_t canonical = (uint16_t)(addr & 0x1fffu);
   if (g_cfg.wd_mapper) {
      uint8_t physical_chunk = wd_physical_chunk_for_address(addr);
      return bank_index_for_file_index((size_t)(physical_chunk >> 2));
   }
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
   if (g_cfg.wd_mapper) {
      uint8_t physical_chunk = wd_physical_chunk_for_address(addr);
      uint16_t window_base = (uint16_t)(0x1000u + ((canonical - 0x1000u) & 0x0c00u));
      uint16_t chunk_offset = (uint16_t)(((physical_chunk & 3u) << 10) +
                                         (canonical - window_base));
      return (uint16_t)(bank->start + chunk_offset);
   }
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
   if (g_cfg.dpc_mapper) {
      if (bytes.size() != expected + 0x0800u + 0x00ffu)
         throw std::runtime_error("Raw DPC cartridge must be exactly 10495 bytes");
      memcpy(g_dpc_display, bytes.data() + expected, sizeof(g_dpc_display));
      memcpy(g_dpc_poly_image, bytes.data() + expected + sizeof(g_dpc_display),
             sizeof(g_dpc_poly_image));
   }
   else if (bytes.size() != expected)
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

   /* DPC clocks its LFSR before DPC-register and F8-hotspot accesses, matching
      Stella's optimized hardware model.  The $1040-$107F register window is
      cartridge I/O, not writable ROM. */
   if (dpc_rng_clocked_access(addr))
      dpc_clock_random();
   if (dpc_register_address(addr)) {
      dpc_write_register(addr, val);
      return;
   }

   /* FE commits any previously armed latch from this cycle's data bus and
      arms again when the current address is $01FE.  Writes can be observed
      before the ordinary device side effect because FE changes only the ROM
      bank mapping. */
   fe_observe_access(addr, val);

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
   uint8_t value;
   if (dpc_rng_clocked_access(addr))
      dpc_clock_random();
   if (dpc_register_address(addr) && (addr & 0x0fffu) < 0x0040u)
      value = dpc_read_register(addr);
   else
      value = peek_mem(addr);
   wd_note_selector_read(addr);
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
   /* FE must see the value returned by the old mapping on this bus cycle; the
      selected bank changes only after that value has been sampled. */
   fe_observe_access(addr, value);
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

   std::string discovered_map;
   if (opts.cfg_path != nullptr) {
      parse_cfg_file(&g_cfg, opts.cfg_path);
      g_cfg_loaded = 1;
   }
   else if (opts.map_path != nullptr) {
      parse_c26_map_file(&g_cfg, opts.map_path);
      g_cfg_loaded = 1;
   }
   else if (ends_with(opts.image_path, ".bin")) {
      discovered_map = same_stem_map_path(opts.image_path);
      if (file_readable(discovered_map)) {
         parse_c26_map_file(&g_cfg, discovered_map.c_str());
         g_cfg_loaded = 1;
      }
   }

   memset(mem, 0xFF, 65536);

   if (ends_with(opts.image_path, ".bin"))
      load_raw_binary(opts.image_path);
   else
      load_intel_hex(opts.image_path);

   initialize_split_memory(opts.split_fill_set ? opts.split_fill : 0);

   if (g_cfg_loaded && g_cfg.cartridge_banked) {
      if (g_cfg.wd_mapper) {
         if (opts.start_bank_set) {
            fprintf(stderr,
                    "vcsc-sim: --start-bank is not meaningful for WD's four-segment arrangements\n");
            return 1;
         }
         g_wd_config = 0u;
         g_wd_pending = 0;
         g_selected_bank = g_cfg.startup_bank;
      }
      else if (g_cfg.e0_mapper) {
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
      fprintf(stderr, "vcsc-sim: --start-bank requires banked cartridge topology\n");
      return 1;
   }

   cpu = new mos6502(read_cb, write_cb, clock_cb);

   g_fe_waiting_data = 0;
   if (g_cfg_loaded && g_cfg.dpc_mapper) {
      memset(g_dpc_tops, 0, sizeof(g_dpc_tops));
      memset(g_dpc_bottoms, 0, sizeof(g_dpc_bottoms));
      memset(g_dpc_counters, 0, sizeof(g_dpc_counters));
      memset(g_dpc_flags, 0, sizeof(g_dpc_flags));
      memset(g_dpc_music_mode, 0, sizeof(g_dpc_music_mode));
      g_dpc_random = 1u;
   }
   cpu->Reset();

   int reset_on_pc_done = 0;
   while (1) {
      gpc = cpu->GetPC();
      if (opts.reset_on_pc_set && !reset_on_pc_done && gpc == opts.reset_on_pc) {
         if (g_cfg_loaded && g_cfg.fe_mapper) {
            g_selected_bank = g_cfg.startup_bank;
            g_fe_waiting_data = 0;
         }
         if (g_cfg_loaded && g_cfg.wd_mapper) {
            g_wd_config = 0u;
            g_wd_pending = 0;
         }
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
      wd_commit_after_instruction();
      if ((!g_cfg_loaded || !g_cfg.cartridge_banked) && cpu->GetPC() == 0xFFFF) {

         uint8_t op = cpu->GetA();
         uint16_t arg = ((uint16_t)cpu->GetY()) << 8 | cpu->GetX();
         dispatch(op, arg);

         uint8_t tmp = mem[0xFFFF]; // remember original value
         store_mem(0xFFFF, 0x60, 1); // insert an RTS there

         cpu->Run(1, counter, mos6502::INST_COUNT);
      wd_commit_after_instruction();

         store_mem(0xFFFF, tmp, 1); // restore original value
      }
   }

   return 0;
}
