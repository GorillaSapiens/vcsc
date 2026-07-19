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
   uint16_t size;
   char type[8];
   int define_yes;
   char name[MAX_NAME];
};

struct simulator_config_t {
   memory_region_t mem[16];
   size_t mem_count;
};

struct parse_result_t {
   uint32_t value;
   size_t pos;
   int ok;
};

struct simulator_options_t {
   const char *hex_path;
   const char *cfg_path;
   uint16_t trace;
   int trace_set;
};

static simulator_config_t g_cfg = {};
static int g_cfg_loaded = 0;

void trace_regs(void);
void trace_disasm(uint16_t pc);

static void usage(FILE *fp) {
   fprintf(fp,
      "Usage:\n"
      "  vcsc-sim [options] file.hex\n"
      "\n"
      "Options:\n"
      "  -t MASK              Enable trace bitmask MASK\n"
      "  --trace=MASK         Same as -t MASK\n"
      "  -T FILE              Use FILE as simulator linker-style config\n"
      "  --config=FILE        Same as -T FILE\n"
      "  --script=FILE        Same as -T FILE\n"
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

   if (str_ieq(key, "start")) {
      n = parse_number(value);
      if (!n.ok || n.value > 0xFFFFu) {
         fprintf(stderr, "vcsc-sim: bad memory start '%s'\n", value);
         exit(1);
      }
      mem_region->start = (uint16_t)n.value;
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
}

static void parse_cfg_file(simulator_config_t *cfg, const char *path) {
   FILE *fp = fopen(path, "r");
   char line[1024];
   enum { NONE, MEMORY, SKIP_BLOCK } block = NONE;

   if (!fp) {
      fprintf(stderr, "vcsc-sim: cannot open '%s': %s\n", path, strerror(errno));
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
      if (ends_with(s, "{") || ends_with(s, "{")) {
         block = SKIP_BLOCK;
         continue;
      }
      if (strcmp(s, "}") == 0) {
         block = NONE;
         continue;
      }
      if (block != MEMORY)
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

         if (cfg->mem_count >= (sizeof(cfg->mem) / sizeof(cfg->mem[0]))) {
            fprintf(stderr, "vcsc-sim: too many MEMORY entries\n");
            exit(1);
         }

         memory_region_t *mem_region = &cfg->mem[cfg->mem_count++];
         memset(mem_region, 0, sizeof(*mem_region));
         snprintf(mem_region->name, sizeof(mem_region->name), "%s", s);
         tok = strtok(brace, ",");
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

   fclose(fp);
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
      else if (arg[0] == '-') {
         fprintf(stderr, "vcsc-sim: unknown option '%s'\n", arg);
         usage(stderr);
         exit(1);
      }
      else if (ends_with(arg, ".cfg") && opts->cfg_path == nullptr) {
         opts->cfg_path = arg;
      }
      else if (ends_with(arg, ".hex") && opts->hex_path == nullptr) {
         opts->hex_path = arg;
      }
      else {
         parse_result_t parsed = parse_number(arg);
         if (parsed.ok && arg[parsed.pos] == '\0' && parsed.value <= 0xFFFFu && !opts->trace_set) {
            opts->trace = (uint16_t)parsed.value;
            opts->trace_set = 1;
         }
         else if (opts->hex_path == nullptr) {
            opts->hex_path = arg;
         }
         else {
            fprintf(stderr, "vcsc-sim: unexpected argument '%s'\n", arg);
            usage(stderr);
            exit(1);
         }
      }
   }

   if (opts->hex_path == nullptr) {
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

void write_cb(uint16_t addr, uint8_t val) {
   if (trace_ops & TRACE_OP_WRITES) {
      printf("write $%02x -> $%04x\n", val, addr);
   }
   store_mem(addr, val, 0);
}

uint8_t read_cb(uint16_t addr) {
   if (trace_ops & TRACE_OP_READS) {
      printf("read $%04x -> $%02x\n", addr, mem[addr]);
   }
   return mem[addr];
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
   const char *code = cpu->GetCode(mem[pc]);
   const char *addr = cpu->GetAddr(mem[pc]);

   switch (addr[0]) {
      case 'A':
         switch(addr[2]) {
            case 'I':
               // ABI
               printf("ASM: $%04x: %s.i ($%04x)    ; %02x %02x %02x\n", pc, code, mem[pc+1] | (mem[pc+2] << 8), mem[pc], mem[pc+1], mem[pc+2]);
               break;
            case 'S':
               // ABS
               printf("ASM: $%04x: %s.a $%04x      ; %02x %02x %02x\n", pc, code, mem[pc+1] | (mem[pc+2] << 8), mem[pc], mem[pc+1], mem[pc+2]);
               break;
            case 'X':
               // ABX
               printf("ASM: $%04x: %s.ax $%04x,X   ; %02x %02x %02x\n", pc, code, mem[pc+1] | (mem[pc+2] << 8), mem[pc], mem[pc+1], mem[pc+2]);
               break;
            case 'Y':
               // ABY
               printf("ASM: $%04x: %s.ay $%04x,Y   ; %02x %02x %02x\n", pc, code, mem[pc+1] | (mem[pc+2] << 8), mem[pc], mem[pc+1], mem[pc+2]);
               break;
            case 'C':
               // ACC
               printf("ASM: $%04x: %s A            ; %02x\n", pc, code, mem[pc]);
               break;
         }
         break;
      case  'I':
         switch(addr[2]) {
            case 'M':
               // IMM
               printf("ASM: $%04x: %s #$%02x       ; %02x %02x\n", pc, code, mem[pc+1], mem[pc], mem[pc+1]);
               break;
            case 'P':
               // IMP
               printf("ASM: $%04x: %s              ; %02x\n", pc, code, mem[pc]);
               break;
            case 'X':
               // INX
               printf("ASM: $%04x: %s.ix ($%02x,X) ; %02x %02x\n", pc, code, mem[pc+1], mem[pc], mem[pc+1]);
               break;
            case 'Y':
               // INY
               printf("ASM: $%04x: %s.iy ($%02x),Y ; %02x %02x\n", pc, code, mem[pc+1], mem[pc], mem[pc+1]);
               break;
         }
         break;
      case 'R':
         // REL
               printf("ASM: $%04x: %s $%02x        ; %02x %02x\n", pc, code, mem[pc+1], mem[pc], mem[pc+1]);
         break;
      case 'Z':
         switch(addr[2]) {
            case 'R':
               // ZER
               printf("ASM: $%04x: %s.z $%02x      ; %02x %02x\n", pc, code, mem[pc+1], mem[pc], mem[pc+1]);
               break;
            case 'X':
               // ZEX
               printf("ASM: $%04x: %s.zx $%02x,X   ; %02x %02x\n", pc, code, mem[pc+1], mem[pc], mem[pc+1]);
               break;
            case 'Y':
               // ZEY
               printf("ASM: $%04x: %s.zy $%02x,Y   ; %02x %02x\n", pc, code, mem[pc+1], mem[pc], mem[pc+1]);
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

   load_intel_hex(opts.hex_path);

   cpu = new mos6502(read_cb, write_cb, clock_cb);

   cpu->Reset();

   while (1) {
      gpc = cpu->GetPC();
      if (trace_ops & TRACE_OP_REGS) {
         trace_regs();
      }
      if (trace_ops & TRACE_OP_DISASM) {
         trace_disasm(gpc);
      }
      cpu->Run(1, counter, mos6502::INST_COUNT);
      if (cpu->GetPC() == 0xFFFF) {

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
