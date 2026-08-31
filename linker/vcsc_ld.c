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
#ifdef _WIN32
#define strcasecmp _stricmp
#define strncasecmp _strnicmp
#else
#include <strings.h>
#endif

#include "vcsc_ld_internal.h"
#include "vcsc_ld_input.h"
#include "vcsc_ld_abi.h"
#include "version.h"
#include "generic_bankcall_template.h"

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
   BANK_JSR_ENTRY_SIZE = 15,
   BANK_GENERIC_JSR_SIZE = VCSC_GENERIC_BANKCALL_RESERVED_SIZE
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
      "  --bank-placement=MODE\n"
      "                       Use optimized (default) or simple bank placement\n"
      "  --explain-bank-placement\n"
      "                       Explain every bank-placement decision on stderr\n"
      "  --trial              Internal driver mode: suppress diagnostics/usage\n"
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

typedef enum {
   NMOS_IMP = 0,
   NMOS_ACC,
   NMOS_IMM,
   NMOS_ZP,
   NMOS_ZPX,
   NMOS_ZPY,
   NMOS_ABS,
   NMOS_ABSX,
   NMOS_ABSY,
   NMOS_IND,
   NMOS_INDX,
   NMOS_INDY,
   NMOS_REL
} nmos_addr_mode_t;

typedef enum {
   NMOS_ACCESS_NONE = 0,
   NMOS_ACCESS_READ,
   NMOS_ACCESS_WRITE,
   NMOS_ACCESS_RMW
} nmos_access_t;

typedef struct {
   const memory_region_t *memory;
   uint16_t address;
   const char *cycle;
   uint8_t index;
   int has_index;
} read_hazard_hit_t;

/* Generated from assembler/default.cfg's operand-shape table.  Keep all 256
   entries explicit: raw opXX assembly is intentionally first-class VCSC input. */
static const uint8_t nmos6502_addr_mode[256] = {
   NMOS_IMP, NMOS_INDX, NMOS_IMP, NMOS_INDX, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_IMP, NMOS_IMM, NMOS_ACC, NMOS_IMM, NMOS_ABS, NMOS_ABS, NMOS_ABS, NMOS_ABS,
   NMOS_REL, NMOS_INDY, NMOS_IMP, NMOS_INDY, NMOS_ZPX, NMOS_ZPX, NMOS_ZPX, NMOS_ZPX, NMOS_IMP, NMOS_ABSY, NMOS_IMP, NMOS_ABSY, NMOS_ABSX, NMOS_ABSX, NMOS_ABSX, NMOS_ABSX,
   NMOS_ABS, NMOS_INDX, NMOS_IMP, NMOS_INDX, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_IMP, NMOS_IMM, NMOS_ACC, NMOS_IMM, NMOS_ABS, NMOS_ABS, NMOS_ABS, NMOS_ABS,
   NMOS_REL, NMOS_INDY, NMOS_IMP, NMOS_INDY, NMOS_ZPX, NMOS_ZPX, NMOS_ZPX, NMOS_ZPX, NMOS_IMP, NMOS_ABSY, NMOS_IMP, NMOS_ABSY, NMOS_ABSX, NMOS_ABSX, NMOS_ABSX, NMOS_ABSX,
   NMOS_IMP, NMOS_INDX, NMOS_IMP, NMOS_INDX, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_IMP, NMOS_IMM, NMOS_ACC, NMOS_IMM, NMOS_ABS, NMOS_ABS, NMOS_ABS, NMOS_ABS,
   NMOS_REL, NMOS_INDY, NMOS_IMP, NMOS_INDY, NMOS_ZPX, NMOS_ZPX, NMOS_ZPX, NMOS_ZPX, NMOS_IMP, NMOS_ABSY, NMOS_IMP, NMOS_ABSY, NMOS_ABSX, NMOS_ABSX, NMOS_ABSX, NMOS_ABSX,
   NMOS_IMP, NMOS_INDX, NMOS_IMP, NMOS_INDX, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_IMP, NMOS_IMM, NMOS_ACC, NMOS_IMM, NMOS_IND, NMOS_ABS, NMOS_ABS, NMOS_ABS,
   NMOS_REL, NMOS_INDY, NMOS_IMP, NMOS_INDY, NMOS_ZPX, NMOS_ZPX, NMOS_ZPX, NMOS_ZPX, NMOS_IMP, NMOS_ABSY, NMOS_IMP, NMOS_ABSY, NMOS_ABSX, NMOS_ABSX, NMOS_ABSX, NMOS_ABSX,
   NMOS_IMM, NMOS_INDX, NMOS_IMM, NMOS_INDX, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_IMP, NMOS_IMM, NMOS_IMP, NMOS_IMM, NMOS_ABS, NMOS_ABS, NMOS_ABS, NMOS_ABS,
   NMOS_REL, NMOS_INDY, NMOS_IMP, NMOS_INDY, NMOS_ZPX, NMOS_ZPX, NMOS_ZPY, NMOS_ZPY, NMOS_IMP, NMOS_ABSY, NMOS_IMP, NMOS_ABSY, NMOS_ABSX, NMOS_ABSX, NMOS_ABSY, NMOS_ABSY,
   NMOS_IMM, NMOS_INDX, NMOS_IMM, NMOS_INDX, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_IMP, NMOS_IMM, NMOS_IMP, NMOS_IMM, NMOS_ABS, NMOS_ABS, NMOS_ABS, NMOS_ABS,
   NMOS_REL, NMOS_INDY, NMOS_IMP, NMOS_INDY, NMOS_ZPX, NMOS_ZPX, NMOS_ZPY, NMOS_ZPY, NMOS_IMP, NMOS_ABSY, NMOS_IMP, NMOS_ABSY, NMOS_ABSX, NMOS_ABSX, NMOS_ABSY, NMOS_ABSY,
   NMOS_IMM, NMOS_INDX, NMOS_IMM, NMOS_INDX, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_IMP, NMOS_IMM, NMOS_IMP, NMOS_IMM, NMOS_ABS, NMOS_ABS, NMOS_ABS, NMOS_ABS,
   NMOS_REL, NMOS_INDY, NMOS_IMP, NMOS_INDY, NMOS_ZPX, NMOS_ZPX, NMOS_ZPX, NMOS_ZPX, NMOS_IMP, NMOS_ABSY, NMOS_IMP, NMOS_ABSY, NMOS_ABSX, NMOS_ABSX, NMOS_ABSX, NMOS_ABSX,
   NMOS_IMM, NMOS_INDX, NMOS_IMM, NMOS_INDX, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_ZP, NMOS_IMP, NMOS_IMM, NMOS_IMP, NMOS_IMM, NMOS_ABS, NMOS_ABS, NMOS_ABS, NMOS_ABS,
   NMOS_REL, NMOS_INDY, NMOS_IMP, NMOS_INDY, NMOS_ZPX, NMOS_ZPX, NMOS_ZPX, NMOS_ZPX, NMOS_IMP, NMOS_ABSY, NMOS_IMP, NMOS_ABSY, NMOS_ABSX, NMOS_ABSX, NMOS_ABSX, NMOS_ABSX
};

static uint8_t nmos6502_instruction_size(uint8_t opcode)
{
   switch ((nmos_addr_mode_t)nmos6502_addr_mode[opcode]) {
      case NMOS_IMP:
      case NMOS_ACC:
         return 1;
      case NMOS_IMM:
      case NMOS_ZP:
      case NMOS_ZPX:
      case NMOS_ZPY:
      case NMOS_INDX:
      case NMOS_INDY:
      case NMOS_REL:
         return 2;
      case NMOS_ABS:
      case NMOS_ABSX:
      case NMOS_ABSY:
      case NMOS_IND:
         return 3;
   }
   return 1;
}

static int nmos6502_is_kil(uint8_t opcode)
{
   switch (opcode) {
      case 0x02: case 0x12: case 0x22: case 0x32:
      case 0x42: case 0x52: case 0x62: case 0x72:
      case 0x92: case 0xB2: case 0xD2: case 0xF2:
         return 1;
   }
   return 0;
}

static int nmos6502_is_branch(uint8_t opcode)
{
   return (opcode & 0x1Fu) == 0x10u;
}

static int nmos6502_is_store(uint8_t opcode)
{
   switch (opcode) {
      case 0x81: case 0x83: case 0x84: case 0x85: case 0x86: case 0x87:
      case 0x8C: case 0x8D: case 0x8E: case 0x8F:
      case 0x91: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97:
      case 0x99: case 0x9B: case 0x9C: case 0x9D: case 0x9E: case 0x9F:
         return 1;
   }
   return 0;
}

static int nmos6502_is_rmw(uint8_t opcode)
{
   switch (opcode) {
      case 0x03: case 0x06: case 0x07: case 0x0E: case 0x0F:
      case 0x13: case 0x16: case 0x17: case 0x1B: case 0x1E: case 0x1F:
      case 0x23: case 0x26: case 0x27: case 0x2E: case 0x2F:
      case 0x33: case 0x36: case 0x37: case 0x3B: case 0x3E: case 0x3F:
      case 0x43: case 0x46: case 0x47: case 0x4E: case 0x4F:
      case 0x53: case 0x56: case 0x57: case 0x5B: case 0x5E: case 0x5F:
      case 0x63: case 0x66: case 0x67: case 0x6E: case 0x6F:
      case 0x73: case 0x76: case 0x77: case 0x7B: case 0x7E: case 0x7F:
      case 0xC3: case 0xC6: case 0xC7: case 0xCE: case 0xCF:
      case 0xD3: case 0xD6: case 0xD7: case 0xDB: case 0xDE: case 0xDF:
      case 0xE3: case 0xE6: case 0xE7: case 0xEE: case 0xEF:
      case 0xF3: case 0xF6: case 0xF7: case 0xFB: case 0xFE: case 0xFF:
         return 1;
   }
   return 0;
}

static int nmos6502_is_stable_indexed_store(uint8_t opcode)
{
   return opcode == 0x99u || opcode == 0x9Du;
}

static int nmos6502_is_stack_push(uint8_t opcode)
{
   return opcode == 0x08u || opcode == 0x48u;
}

static int nmos6502_is_stack_pull(uint8_t opcode)
{
   return opcode == 0x28u || opcode == 0x68u;
}

static nmos_access_t nmos6502_access_kind(uint8_t opcode)
{
   nmos_addr_mode_t mode = (nmos_addr_mode_t)nmos6502_addr_mode[opcode];
   if (nmos6502_is_store(opcode))
      return NMOS_ACCESS_WRITE;
   if (nmos6502_is_rmw(opcode))
      return NMOS_ACCESS_RMW;
   if (opcode == 0x20u || opcode == 0x4Cu || opcode == 0x6Cu ||
       opcode == 0x00u || nmos6502_is_branch(opcode) || nmos6502_is_kil(opcode))
      return NMOS_ACCESS_NONE;
   switch (mode) {
      case NMOS_ZP: case NMOS_ZPX: case NMOS_ZPY:
      case NMOS_ABS: case NMOS_ABSX: case NMOS_ABSY:
      case NMOS_INDX: case NMOS_INDY:
         return NMOS_ACCESS_READ;
      default:
         return NMOS_ACCESS_NONE;
   }
}

static const memory_region_t *read_hazard_at(const linker_config_t *cfg,
                                             uint16_t address)
{
   size_t i;
   if (!cfg)
      return NULL;
   for (i = 0; i < cfg->mem_count; ++i) {
      const memory_region_t *mem = &cfg->mem[i];
      uint32_t start;
      uint32_t end;
      if (!mem->read_hazard || mem->size == 0)
         continue;
      start = mem->has_write_start ? mem->write_start : mem->start;
      end = start + mem->size;
      if (address >= start && (uint32_t)address < end)
         return mem;
   }
   return NULL;
}

static int read_hazard_range_overlap(const linker_config_t *cfg,
                                     uint16_t start, uint16_t end,
                                     read_hazard_hit_t *hit,
                                     const char *cycle)
{
   uint32_t a;
   for (a = start; a <= end; ++a) {
      const memory_region_t *mem = read_hazard_at(cfg, (uint16_t)a);
      if (mem) {
         if (hit) {
            memset(hit, 0, sizeof(*hit));
            hit->memory = mem;
            hit->address = (uint16_t)a;
            hit->cycle = cycle;
         }
         return 1;
      }
   }
   return 0;
}

static int record_read_hazard(const linker_config_t *cfg, uint16_t address,
                              const char *cycle, uint8_t index, int has_index,
                              read_hazard_hit_t *hit)
{
   const memory_region_t *mem = read_hazard_at(cfg, address);
   if (!mem)
      return 0;
   if (hit) {
      memset(hit, 0, sizeof(*hit));
      hit->memory = mem;
      hit->address = address;
      hit->cycle = cycle;
      hit->index = index;
      hit->has_index = has_index;
   }
   return 1;
}

/* Check reads implied by an operand.  Runtime-computed indirect effective
   addresses are intentionally not guessed, but all statically knowable dummy,
   pointer, direct, indexed, and RMW reads are modeled. */
static int nmos6502_operand_read_hazard_range(const linker_config_t *cfg,
                                              uint8_t opcode, uint16_t operand,
                                              uint8_t index_min, uint8_t index_max,
                                              read_hazard_hit_t *hit)
{
   nmos_addr_mode_t mode = (nmos_addr_mode_t)nmos6502_addr_mode[opcode];
   nmos_access_t access = nmos6502_access_kind(opcode);
   unsigned int i;

   switch (mode) {
      case NMOS_ZP:
         if ((access == NMOS_ACCESS_READ || access == NMOS_ACCESS_RMW) &&
             record_read_hazard(cfg, (uint8_t)operand,
                                "architectural zero-page read", 0, 0, hit))
            return 1;
         break;

      case NMOS_ZPX:
      case NMOS_ZPY:
         if (record_read_hazard(cfg, (uint8_t)operand,
                                "zero-page indexed dummy read", 0, 0, hit))
            return 1;
         if (access == NMOS_ACCESS_READ || access == NMOS_ACCESS_RMW) {
            for (i = index_min; i <= (unsigned int)index_max; ++i) {
               if (record_read_hazard(cfg, (uint8_t)(operand + i),
                                      "zero-page indexed architectural read",
                                      (uint8_t)i, 1, hit))
                  return 1;
            }
         }
         break;

      case NMOS_ABS:
         if ((access == NMOS_ACCESS_READ || access == NMOS_ACCESS_RMW) &&
             record_read_hazard(cfg, operand, "architectural absolute read",
                                0, 0, hit))
            return 1;
         break;

      case NMOS_ABSX:
      case NMOS_ABSY:
         for (i = index_min; i <= (unsigned int)index_max; ++i) {
            uint16_t final = (uint16_t)(operand + i);
            uint16_t dummy = (uint16_t)((operand & 0xFF00u) | (final & 0x00FFu));
            int crossed = ((unsigned int)(operand & 0x00FFu) + i) > 0xFFu;
            const memory_region_t *dummy_mem;

            if ((access == NMOS_ACCESS_WRITE || access == NMOS_ACCESS_RMW ||
                 (access == NMOS_ACCESS_READ && crossed)) &&
                (dummy_mem = read_hazard_at(cfg, dummy)) != NULL) {
               /* An indexed STA pre-read of the exact write-port byte which is
                  immediately overwritten by that same STA cannot leave RAM
                  corruption.  Do not extend this exception to unstable
                  unofficial stores whose page-cross write address is silicon-
                  dependent. */
               if (!(access == NMOS_ACCESS_WRITE &&
                     nmos6502_is_stable_indexed_store(opcode) &&
                     dummy == final && dummy_mem->has_write_start)) {
                  if (hit) {
                     memset(hit, 0, sizeof(*hit));
                     hit->memory = dummy_mem;
                     hit->address = dummy;
                     hit->cycle = access == NMOS_ACCESS_READ
                        ? "absolute indexed page-cross dummy read"
                        : "absolute indexed pre-write/RMW dummy read";
                     hit->index = (uint8_t)i;
                     hit->has_index = 1;
                  }
                  return 1;
               }
            }
            if ((access == NMOS_ACCESS_READ || access == NMOS_ACCESS_RMW) &&
                record_read_hazard(cfg, final,
                                   "absolute indexed architectural read",
                                   (uint8_t)i, 1, hit))
               return 1;
         }
         break;

      case NMOS_INDX:
         if (record_read_hazard(cfg, (uint8_t)operand,
                                "(zp,X) unindexed dummy read", 0, 0, hit))
            return 1;
         if (read_hazard_range_overlap(cfg, 0x0000u, 0x00FFu, hit,
                                       "(zp,X) runtime-indexed pointer read"))
            return 1;
         break;

      case NMOS_INDY:
         if (record_read_hazard(cfg, (uint8_t)operand,
                                "(zp),Y pointer low read", 0, 0, hit) ||
             record_read_hazard(cfg, (uint8_t)(operand + 1u),
                                "(zp),Y pointer high read", 0, 0, hit))
            return 1;
         break;

      case NMOS_IND: {
         uint16_t hi = (uint16_t)((operand & 0xFF00u) |
                                  ((operand + 1u) & 0x00FFu));
         if (record_read_hazard(cfg, operand, "JMP indirect vector low read",
                                0, 0, hit) ||
             record_read_hazard(cfg, hi, "JMP indirect vector high read",
                                0, 0, hit))
            return 1;
         break;
      }

      default:
         break;
   }
   return 0;
}

static int nmos6502_instruction_read_hazard_range(const linker_config_t *cfg,
                                                  uint8_t opcode, uint16_t pc,
                                                  uint16_t operand,
                                                  uint8_t index_min, uint8_t index_max,
                                                  read_hazard_hit_t *hit)
{
   uint8_t size = nmos6502_instruction_size(opcode);
   unsigned int i;

   for (i = 0; i < size; ++i) {
      if (record_read_hazard(cfg, (uint16_t)(pc + i),
                             "instruction/operand fetch", 0, 0, hit))
         return 1;
   }

   if (opcode == 0x00u) {
      if (record_read_hazard(cfg, (uint16_t)(pc + 1u),
                             "BRK padding-byte read", 0, 0, hit) ||
          record_read_hazard(cfg, 0xFFFEu, "BRK vector low read", 0, 0, hit) ||
          record_read_hazard(cfg, 0xFFFFu, "BRK vector high read", 0, 0, hit))
         return 1;
      return 0;
   }

   if (nmos6502_is_branch(opcode)) {
      uint16_t next = (uint16_t)(pc + 2u);
      uint16_t target = (uint16_t)(next + (int8_t)(operand & 0xFFu));
      if (record_read_hazard(cfg, next, "taken-branch next-PC dummy read",
                             0, 0, hit))
         return 1;
      if ((next & 0xFF00u) != (target & 0xFF00u)) {
         uint16_t dummy = (uint16_t)((next & 0xFF00u) | (target & 0x00FFu));
         if (record_read_hazard(cfg, dummy,
                                "taken page-cross branch dummy read", 0, 0, hit))
            return 1;
      }
      return 0;
   }

   if (opcode == 0x6Cu) {
      uint16_t hi = (uint16_t)((operand & 0xFF00u) |
                               ((operand + 1u) & 0x00FFu));
      if (record_read_hazard(cfg, operand, "JMP indirect vector low read",
                             0, 0, hit) ||
          record_read_hazard(cfg, hi, "JMP indirect vector high read",
                             0, 0, hit))
         return 1;
      return 0;
   }

   if (opcode == 0x20u) {
      if (read_hazard_range_overlap(cfg, 0x0100u, 0x01FFu, hit,
                                    "JSR stack-page dummy read"))
         return 1;
      return 0;
   }

   if (nmos6502_is_stack_pull(opcode) || opcode == 0x40u || opcode == 0x60u) {
      if (record_read_hazard(cfg, (uint16_t)(pc + 1u),
                             "stack instruction next-PC dummy read", 0, 0, hit) ||
          read_hazard_range_overlap(cfg, 0x0100u, 0x01FFu, hit,
                                    "runtime stack-page read"))
         return 1;
      return 0;
   }

   if (nmos6502_is_stack_push(opcode) || nmos6502_is_kil(opcode)) {
      if (record_read_hazard(cfg, (uint16_t)(pc + 1u),
                             nmos6502_is_kil(opcode)
                                ? "KIL/JAM next-PC bus read"
                                : "stack push next-PC dummy read",
                             0, 0, hit))
         return 1;
      return 0;
   }

   if (nmos6502_addr_mode[opcode] == NMOS_IMP ||
       nmos6502_addr_mode[opcode] == NMOS_ACC) {
      if (record_read_hazard(cfg, (uint16_t)(pc + 1u),
                             "implied/accumulator next-PC dummy read",
                             0, 0, hit))
         return 1;
      return 0;
   }

   return nmos6502_operand_read_hazard_range(cfg, opcode, operand,
                                             index_min, index_max, hit);
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
static int topology_metadata_has_prefix(const char *name)
{
   return name &&
      (strncmp(name, CARTRIDGE_TOPOLOGY_META_PREFIX,
               sizeof(CARTRIDGE_TOPOLOGY_META_PREFIX) - 1) == 0 ||
       strncmp(name, CARTRIDGE_TOPOLOGY_META_PREFIX_V1,
               sizeof(CARTRIDGE_TOPOLOGY_META_PREFIX_V1) - 1) == 0 ||
       strncmp(name, BANK_TOPOLOGY_META_PREFIX,
               sizeof(BANK_TOPOLOGY_META_PREFIX) - 1) == 0 ||
       strncmp(name, BANK_TOPOLOGY_META_PREFIX_V1,
               sizeof(BANK_TOPOLOGY_META_PREFIX_V1) - 1) == 0);
}

static int mem_region_metadata_has_prefix(const char *name)
{
   return name &&
      (strncmp(name, MEM_REGION_META_PREFIX, sizeof(MEM_REGION_META_PREFIX) - 1) == 0 ||
       strncmp(name, MEM_REGION_SPLIT_META_PREFIX, sizeof(MEM_REGION_SPLIT_META_PREFIX) - 1) == 0);
}

static int mem_declaration_metadata_has_prefix(const char *name)
{
   return name &&
      (strncmp(name, MEM_DECL_META_PREFIX,
               sizeof(MEM_DECL_META_PREFIX) - 1) == 0 ||
       strncmp(name, MEM_DECL_META_PREFIX_V1,
               sizeof(MEM_DECL_META_PREFIX_V1) - 1) == 0);
}

//! @brief Return whether immutable ROM-replication metadata has its reserved prefix.
static int replica_metadata_has_prefix(const char *name)
{
   return name && strncmp(name, REPLICA_META_PREFIX,
      sizeof(REPLICA_META_PREFIX) - 1) == 0;
}

//! @brief Return whether return-local coalescing metadata has its reserved prefix.
static int return_coalesce_metadata_has_prefix(const char *name)
{
   return name && strncmp(name, RETURN_COALESCE_META_PREFIX,
      sizeof(RETURN_COALESCE_META_PREFIX) - 1) == 0;
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

//! @brief Return whether frame-phase object-use metadata has its reserved prefix.
static int phase_use_metadata_has_prefix(const char *name)
{
   return name && strncmp(name, PHASE_USE_META_PREFIX,
      sizeof(PHASE_USE_META_PREFIX) - 1) == 0;
}

//! @brief Return whether explicit frame-phase workspace metadata has its reserved prefix.
static int phase_workspace_metadata_has_prefix(const char *name)
{
   return name && strncmp(name, PHASE_WORKSPACE_META_PREFIX,
      sizeof(PHASE_WORKSPACE_META_PREFIX) - 1) == 0;
}

//! @brief Parse one explicit frame-phase workspace eligibility symbol.
static int phase_workspace_metadata_parse(const char *name, const char **symbol_out)
{
   const char *p;
   if (!phase_workspace_metadata_has_prefix(name))
      return 0;
   p = name + sizeof(PHASE_WORKSPACE_META_PREFIX) - 1;
   if (!*p)
      return 0;
   if (symbol_out)
      *symbol_out = p;
   return 1;
}

//! @brief Parse one frame-phase object-use metadata symbol.
static int phase_use_metadata_parse(const char *name, uint8_t *mask_out,
                                    const char **symbol_out)
{
   const char *p;
   char hexbuf[3];
   char *end = NULL;
   unsigned long mask;

   if (!phase_use_metadata_has_prefix(name))
      return 0;
   p = name + sizeof(PHASE_USE_META_PREFIX) - 1;
   if (p[0] != 'M' || !isxdigit((unsigned char)p[1]) ||
       !isxdigit((unsigned char)p[2]) || p[3] != '$' || !p[4])
      return 0;
   hexbuf[0] = p[1];
   hexbuf[1] = p[2];
   hexbuf[2] = '\0';
   mask = strtoul(hexbuf, &end, 16);
   if (!end || *end || mask > 0x0Fu)
      return 0;
   if (mask_out)
      *mask_out = (uint8_t)mask;
   if (symbol_out)
      *symbol_out = p + 4;
   return 1;
}

//! @brief Return whether component-placement metadata has its reserved prefix.
static int component_constraint_metadata_has_prefix(const char *name)
{
   return name && strncmp(name, COMPONENT_CONSTRAINT_META_PREFIX,
      sizeof(COMPONENT_CONSTRAINT_META_PREFIX) - 1) == 0;
}

//! @brief Return whether reserved metadata has prefix in linker layout and image writer.
static int reserved_metadata_has_prefix(const char *name)
{
   return symbol_backed_metadata_has_prefix(name) || abi_metadata_has_prefix(name) ||
          mem_region_metadata_has_prefix(name) || mem_declaration_metadata_has_prefix(name) ||
          topology_metadata_has_prefix(name) ||
          replica_metadata_has_prefix(name) ||
          return_coalesce_metadata_has_prefix(name) ||
          component_constraint_metadata_has_prefix(name) ||
          phase_use_metadata_has_prefix(name) ||
          phase_workspace_metadata_has_prefix(name) ||
          contract_metadata_has_prefix(name) || semantic_use_metadata_has_prefix(name);
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

//! @brief Parse one activation-only lifetime edge emitted for optimizer inlining.
static int symbol_backed_metadata_parse_activation_edge(const char *name, char **caller_out, char **callee_out)
{
   const char *p;
   const char *sep;
   size_t caller_len;

   if (!symbol_backed_metadata_has_prefix(name))
      return 0;
   p = name + sizeof(SYMBOL_BACKED_META_PREFIX) - 1;
   if (strncmp(p, "I$", 2) != 0)
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

static int parse_topology_source_suffix(const char *suffix, char *out, size_t out_size);
static cartridge_bank_t *append_cartridge_bank(linker_config_t *cfg);
static memory_region_t *append_memory_region(linker_config_t *cfg);
static segment_rule_t *append_segment_rule(linker_config_t *cfg);

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

//! @brief Decode an optional compiler-emitted C26 declaration location.
static int parse_topology_source_suffix(const char *suffix, char *out, size_t out_size)
{
   const char *line_mark;
   const char *col_mark;
   size_t hex_len;
   size_t file_len;
   unsigned int line;
   unsigned int column;
   size_t i;
   char file[MAX_PATH];

   if (!out || out_size == 0)
      return 0;
   out[0] = '\0';
   if (!suffix || !*suffix)
      return 1;
   if (strncmp(suffix, "$Q", 2))
      return 0;
   line_mark = strstr(suffix + 2, "$N");
   if (!line_mark)
      return 0;
   col_mark = strstr(line_mark + 2, "$C");
   if (!col_mark || col_mark != line_mark + 10 || strlen(col_mark + 2) != 8)
      return 0;
   hex_len = (size_t)(line_mark - (suffix + 2));
   if (hex_len & 1u)
      return 0;
   file_len = hex_len / 2u;
   if (file_len >= sizeof(file))
      return 0;
   for (i = 0; i < file_len; ++i) {
      unsigned int byte;
      if (sscanf(suffix + 2 + 2u * i, "%2X", &byte) != 1)
         return 0;
      file[i] = (char)byte;
   }
   file[file_len] = '\0';
   if (sscanf(line_mark + 2, "%8X", &line) != 1 ||
       sscanf(col_mark + 2, "%8X", &column) != 1)
      return 0;
   snprintf(out, out_size, "%s:%u.%u", file, line, column);
   return 1;
}

//! @brief Parse one compiler-emitted authoritative C26 mem declaration.
static int parse_mem_declaration_metadata(const char *symbol, memory_region_t *out)
{
   const char *p;
   const char *mark;
   const char *suffix;
   size_t name_len;
   unsigned int read_start, write_start, size, split, priority, read_hazard = 0;
   unsigned int data_only = 0;
   char type_code;
   int consumed = 0;
   int version;

   if (!symbol || !out)
      return 0;
   if (strncmp(symbol, MEM_DECL_META_PREFIX,
               sizeof(MEM_DECL_META_PREFIX) - 1) == 0) {
      version = 2;
      p = symbol + sizeof(MEM_DECL_META_PREFIX) - 1;
   }
   else if (strncmp(symbol, MEM_DECL_META_PREFIX_V1,
                    sizeof(MEM_DECL_META_PREFIX_V1) - 1) == 0) {
      version = 1;
      p = symbol + sizeof(MEM_DECL_META_PREFIX_V1) - 1;
   }
   else
      return 0;
   mark = strstr(p, "$R");
   if (!mark || mark == p)
      return -1;
   name_len = (size_t)(mark - p);
   if (name_len >= sizeof(out->name))
      return -1;
   if (version == 2) {
      if (sscanf(mark, "$R%4X$W%4X$Z%4X$X%1X$T%c$P%8X$H%1X$D%1X$B%n",
                 &read_start, &write_start, &size, &split, &type_code,
                 &priority, &read_hazard, &data_only, &consumed) != 8)
         return -1;
      suffix = strstr(mark + consumed, "$Q");
      if (!suffix)
         return -1;
   }
   else {
      if (sscanf(mark, "$R%4X$W%4X$Z%4X$X%1X$T%c$P%8X$H%1X%n",
                 &read_start, &write_start, &size, &split, &type_code,
                 &priority, &read_hazard, &consumed) != 7) {
         read_hazard = 0;
         consumed = 0;
         if (sscanf(mark, "$R%4X$W%4X$Z%4X$X%1X$T%c$P%8X%n",
                    &read_start, &write_start, &size, &split, &type_code,
                    &priority, &consumed) != 6)
            return -1;
      }
      suffix = mark + consumed;
   }
   if (split > 1u || read_hazard > 1u || data_only > 1u ||
       (type_code != 'W' && type_code != 'O'))
      return -1;

   memset(out, 0, sizeof(*out));
   memcpy(out->name, p, name_len);
   out->name[name_len] = '\0';
   out->start = (uint16_t)read_start;
   out->write_start = (uint16_t)write_start;
   out->has_write_start = (int)split;
   out->read_hazard = (int)read_hazard;
   out->size = (uint16_t)size;
   out->physical_size = (uint16_t)size;
   snprintf(out->type, sizeof(out->type), "%s", type_code == 'W' ? "rw" : "ro");
   out->priority = (int32_t)priority;
   out->compiler_declared = 1;
   out->define_yes = 1;
   if (version == 2) {
      size_t bank_len = (size_t)(suffix - (mark + consumed));
      if ((data_only && bank_len == 0) || (!data_only && bank_len != 0) ||
          bank_len >= sizeof(out->data_bank_name))
         return -1;
      if (bank_len) {
         memcpy(out->data_bank_name, mark + consumed, bank_len);
         out->data_bank_name[bank_len] = '\0';
      }
   }
   if (!parse_topology_source_suffix(suffix, out->declaration,
                                     sizeof(out->declaration)))
      return -1;
   return 1;
}

static int mem_declaration_equal(const memory_region_t *a,
                                 const memory_region_t *b)
{
   return a->start == b->start &&
          a->write_start == b->write_start &&
          a->has_write_start == b->has_write_start &&
          a->read_hazard == b->read_hazard &&
          a->size == b->size &&
          str_ieq(a->type, b->type) &&
          !strcmp(a->data_bank_name, b->data_bank_name) &&
          a->priority == b->priority;
}

//! @brief Parse one compiler-emitted cartridge topology declaration.
static int parse_cartridge_topology_metadata(const char *name,
                                             topology_cartridge_t *out)
{
   const char *p;
   unsigned int mask, fill, to, ts, bo, bs, vo, vs, g0, g1, g2, g3;
   int consumed = 0;
   int version;
   if (!name || !out)
      return 0;
   if (strncmp(name, CARTRIDGE_TOPOLOGY_META_PREFIX,
               sizeof(CARTRIDGE_TOPOLOGY_META_PREFIX) - 1) == 0) {
      version = 2;
      p = name + sizeof(CARTRIDGE_TOPOLOGY_META_PREFIX) - 1;
   } else if (strncmp(name, CARTRIDGE_TOPOLOGY_META_PREFIX_V1,
                      sizeof(CARTRIDGE_TOPOLOGY_META_PREFIX_V1) - 1) == 0) {
      version = 1;
      p = name + sizeof(CARTRIDGE_TOPOLOGY_META_PREFIX_V1) - 1;
   } else {
      return 0;
   }
   g0 = g1 = g2 = g3 = 0;
   if (version == 2) {
      if (sscanf(p, "P%2X$F%2X$T%4X$Z%4X$B%4X$Y%4X$V%4X$W%4X$G%2X%2X%2X%2X%n",
                 &mask, &fill, &to, &ts, &bo, &bs, &vo, &vs,
                 &g0, &g1, &g2, &g3, &consumed) != 12)
         return -1;
   } else if (sscanf(p, "P%2X$F%2X$T%4X$Z%4X$B%4X$Y%4X$V%4X$W%4X%n",
                     &mask, &fill, &to, &ts, &bo, &bs, &vo, &vs,
                     &consumed) != 8) {
      return -1;
   }
   memset(out, 0, sizeof(*out));
   if (!parse_topology_source_suffix(p + consumed, out->declaration,
                                     sizeof(out->declaration)))
      return -1;
   out->present = 1;
   out->present_mask = (uint8_t)mask;
   out->fill_value = (uint8_t)fill;
   out->trampoline_offset = (uint16_t)to;
   out->trampoline_size = (uint16_t)ts;
   out->vector_bridge_offset = (uint16_t)bo;
   out->vector_bridge_size = (uint16_t)bs;
   out->vectors_offset = (uint16_t)vo;
   out->vectors_size = (uint16_t)vs;
   out->signature[0] = (uint8_t)g0;
   out->signature[1] = (uint8_t)g1;
   out->signature[2] = (uint8_t)g2;
   out->signature[3] = (uint8_t)g3;
   return 1;
}

//! @brief Parse one compiler-emitted bank topology declaration.
static int parse_bank_topology_metadata(const char *symbol, topology_bank_t *out)
{
   const char *p;
   const char *mark;
   size_t name_len;
   unsigned int iz, fi, io, ls, cs, ms, sp, sa, su, data_only = 0;
   int consumed = 0;
   int version;
   if (!symbol || !out)
      return 0;
   if (strncmp(symbol, BANK_TOPOLOGY_META_PREFIX,
               sizeof(BANK_TOPOLOGY_META_PREFIX) - 1) == 0) {
      version = 2;
      p = symbol + sizeof(BANK_TOPOLOGY_META_PREFIX) - 1;
   }
   else if (strncmp(symbol, BANK_TOPOLOGY_META_PREFIX_V1,
                    sizeof(BANK_TOPOLOGY_META_PREFIX_V1) - 1) == 0) {
      version = 1;
      p = symbol + sizeof(BANK_TOPOLOGY_META_PREFIX_V1) - 1;
   }
   else
      return 0;
   mark = strstr(p, "$I");
   if (!mark || mark == p)
      return -1;
   name_len = (size_t)(mark - p);
   if (name_len >= sizeof(out->name))
      return -1;
   if (version == 2) {
      if (sscanf(mark, "$I%4X$F%4X$O%4X$L%4X$C%4X$M%4X$P%1X$S%4X$U%1X$D%1X%n",
                 &iz, &fi, &io, &ls, &cs, &ms, &sp, &sa, &su,
                 &data_only, &consumed) != 10)
         return -1;
   }
   else if (sscanf(mark, "$I%4X$F%4X$O%4X$L%4X$C%4X$M%4X$P%1X$S%4X$U%1X%n",
                   &iz, &fi, &io, &ls, &cs, &ms, &sp, &sa, &su,
                   &consumed) != 9)
      return -1;
   if (sp > 1u || su > 1u || data_only > 1u)
      return -1;
   memset(out, 0, sizeof(*out));
   if (!parse_topology_source_suffix(mark + consumed, out->declaration,
                                     sizeof(out->declaration)))
      return -1;
   memcpy(out->name, p, name_len);
   out->name[name_len] = '\0';
   out->image_size = (uint16_t)iz;
   out->file_index = (uint16_t)fi;
   out->image_offset = (uint16_t)io;
   out->link_start = (uint16_t)ls;
   out->cpu_start = (uint16_t)cs;
   out->map_size = (uint16_t)ms;
   out->has_selector = (int)sp;
   out->select_access = (uint16_t)sa;
   out->startup = (int)su;
   out->data_only = (int)data_only;
   return 1;
}

static int topology_cartridge_equal(const topology_cartridge_t *a,
                                    const topology_cartridge_t *b)
{
   return a->present_mask == b->present_mask &&
          a->fill_value == b->fill_value &&
          a->trampoline_offset == b->trampoline_offset &&
          a->trampoline_size == b->trampoline_size &&
          a->vector_bridge_offset == b->vector_bridge_offset &&
          a->vector_bridge_size == b->vector_bridge_size &&
          a->vectors_offset == b->vectors_offset &&
          a->vectors_size == b->vectors_size &&
          memcmp(a->signature, b->signature, sizeof(a->signature)) == 0;
}

static int topology_bank_equal(const topology_bank_t *a, const topology_bank_t *b)
{
   return a->image_size == b->image_size &&
          a->file_index == b->file_index &&
          a->image_offset == b->image_offset &&
          a->link_start == b->link_start &&
          a->cpu_start == b->cpu_start &&
          a->map_size == b->map_size &&
          a->has_selector == b->has_selector &&
          a->select_access == b->select_access &&
          a->startup == b->startup &&
          a->data_only == b->data_only;
}

//! @brief Merge selected objects' C26 cartridge/bank declarations.
static void collect_c26_topology(linker_config_t *cfg, const input_set_t *in)
{
   size_t i;
   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      size_t j;
      for (j = 0; j < obj->export_count; ++j) {
         const char *symbol = obj->exports[j].name;
         topology_cartridge_t cart;
         topology_bank_t bank;
         int parsed = parse_cartridge_topology_metadata(symbol, &cart);
         if (parsed < 0) {
            fprintf(stderr, "vcsc-ld: malformed cartridge topology metadata in %s\n",
                    obj->origin);
            exit(1);
         }
         if (parsed > 0) {
            snprintf(cart.source, sizeof(cart.source), "%s", obj->origin);
            if (!cfg->topology_cartridge.present)
               cfg->topology_cartridge = cart;
            else if (!topology_cartridge_equal(&cfg->topology_cartridge, &cart)) {
               fprintf(stderr,
                       "vcsc-ld: conflicting cartridge declarations at %s (%s) and %s (%s)\n",
                       cfg->topology_cartridge.declaration[0] ? cfg->topology_cartridge.declaration : "<unknown>",
                       cfg->topology_cartridge.source,
                       cart.declaration[0] ? cart.declaration : "<unknown>", obj->origin);
               exit(1);
            }
            continue;
         }
         parsed = parse_bank_topology_metadata(symbol, &bank);
         if (parsed < 0) {
            fprintf(stderr, "vcsc-ld: malformed bank topology metadata in %s\n",
                    obj->origin);
            exit(1);
         }
         if (parsed > 0) {
            topology_bank_t *existing = NULL;
            size_t k;
            snprintf(bank.source, sizeof(bank.source), "%s", obj->origin);
            for (k = 0; k < cfg->topology_bank_count; ++k) {
               if (!strcmp(cfg->topology_banks[k].name, bank.name)) {
                  existing = &cfg->topology_banks[k];
                  break;
               }
            }
            if (existing) {
               if (!topology_bank_equal(existing, &bank)) {
                  fprintf(stderr,
                          "vcsc-ld: conflicting bank declaration '%s' at %s (%s) and %s (%s)\n",
                          bank.name,
                          existing->declaration[0] ? existing->declaration : "<unknown>", existing->source,
                          bank.declaration[0] ? bank.declaration : "<unknown>", obj->origin);
                  exit(1);
               }
            }
            else {
               cfg->topology_banks = (topology_bank_t *)xrealloc(
                  cfg->topology_banks,
                  (cfg->topology_bank_count + 1u) * sizeof(*cfg->topology_banks));
               cfg->topology_banks[cfg->topology_bank_count++] = bank;
            }
         }
      }
   }
}

//! @brief Return mutable MEMORY entry by name.
static memory_region_t *find_memory_mutable(linker_config_t *cfg, const char *name)
{
   size_t i;
   for (i = 0; cfg && name && i < cfg->mem_count; ++i)
      if (str_ieq(cfg->mem[i].name, name))
         return &cfg->mem[i];
   return NULL;
}

//! @brief Merge authoritative C26 mem declarations into the parsed cfg table.
static void collect_c26_mem_declarations(linker_config_t *cfg, const input_set_t *in)
{
   size_t i;
   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      size_t j;
      for (j = 0; j < obj->export_count; ++j) {
         memory_region_t decl;
         memory_region_t *mem;
         int parsed = parse_mem_declaration_metadata(obj->exports[j].name, &decl);
         if (parsed < 0) {
            fprintf(stderr, "vcsc-ld: malformed C26 mem declaration metadata in %s\n",
                    obj->origin);
            exit(1);
         }
         if (!parsed)
            continue;
         snprintf(decl.source, sizeof(decl.source), "%s", obj->origin);
         mem = find_memory_mutable(cfg, decl.name);
         if (mem && mem->compiler_declared) {
            if (!mem_declaration_equal(mem, &decl)) {
               fprintf(stderr,
                       "vcsc-ld: conflicting mem declaration '%s' at %s (%s) and %s (%s)\n",
                       decl.name,
                       mem->declaration[0] ? mem->declaration : "<unknown>",
                       mem->source[0] ? mem->source : "<unknown>",
                       decl.declaration[0] ? decl.declaration : "<unknown>",
                       obj->origin);
               exit(1);
            }
            continue;
         }
         if (mem) {
            int callstack_callgraph = mem->callstack_callgraph;
            uint16_t callstack_extra = mem->callstack_extra;
            int cfg_read_hazard = mem->read_hazard;
            char file[MAX_PATH];
            char bank_name[MAX_NAME];
            int fill_yes = mem->fill_yes;
            uint8_t fill_value = mem->fill_value;
            int has_fill_value = mem->has_fill_value;
            snprintf(file, sizeof(file), "%s", mem->file);
            snprintf(bank_name, sizeof(bank_name), "%s", mem->bank_name);
            *mem = decl;
            mem->define_yes = 1;
            mem->callstack_callgraph = callstack_callgraph;
            mem->callstack_extra = callstack_extra;
            mem->read_hazard = mem->read_hazard || cfg_read_hazard;
            snprintf(mem->file, sizeof(mem->file), "%s", file);
            snprintf(mem->bank_name, sizeof(mem->bank_name), "%s", bank_name);
            mem->fill_yes = fill_yes;
            mem->fill_value = fill_value;
            mem->has_fill_value = has_fill_value;
         }
         else {
            mem = append_memory_region(cfg);
            *mem = decl;
         }
      }
   }
}

//! @brief Infer output owner from unique containment in synthetic topology ranges.
static void infer_c26_mem_output_ownership(linker_config_t *cfg)
{
   size_t i;
   if (cfg->topology_bank_count == 0) {
      for (i = 0; i < cfg->mem_count; ++i) {
         memory_region_t *mem = &cfg->mem[i];
         if (!mem->compiler_declared)
            continue;
         mem->output_bank_name[0] = '\0';
         mem->output_mode = MEM_OUTPUT_SHARED;
         if (mem->has_write_start || !str_ieq(mem->type, "ro")) {
            mem->bank_name[0] = '\0';
            continue;
         }
         if (!mem->bank_name[0])
            continue;
         snprintf(mem->output_bank_name, sizeof(mem->output_bank_name), "%s",
                  mem->bank_name);
         mem->output_mode = MEM_OUTPUT_SWITCHED;
      }
      return;
   }
   for (i = 0; i < cfg->mem_count; ++i) {
      memory_region_t *mem = &cfg->mem[i];
      const topology_bank_t *owner = NULL;
      size_t matches = 0;
      size_t j;
      uint32_t mem_end;

      if (!mem->compiler_declared)
         continue;
      mem->bank_name[0] = '\0';
      mem->output_bank_name[0] = '\0';
      mem->output_mode = MEM_OUTPUT_SHARED;
      if (mem->data_bank_name[0]) {
         for (j = 0; j < cfg->topology_bank_count; ++j) {
            if (!strcmp(cfg->topology_banks[j].name, mem->data_bank_name)) {
               owner = &cfg->topology_banks[j];
               matches++;
            }
         }
         if (matches != 1 || !owner || !owner->data_only) {
            fprintf(stderr,
                    "vcsc-ld: data-only mem region '%s' names unknown or CPU-mapped data bank '%s'\n",
                    mem->name, mem->data_bank_name);
            exit(1);
         }
         if (mem->size > owner->image_size) {
            fprintf(stderr,
                    "vcsc-ld: data-only mem region '%s' size $%04X exceeds bank '%s' image size $%04X\n",
                    mem->name, mem->size, owner->name, owner->image_size);
            exit(1);
         }
         snprintf(mem->output_bank_name, sizeof(mem->output_bank_name), "%s",
                  owner->name);
         mem->output_mode = MEM_OUTPUT_DATA_ONLY;
         continue;
      }
      mem_end = (uint32_t)mem->start + mem->size;
      for (j = 0; j < cfg->topology_bank_count; ++j) {
         const topology_bank_t *bank = &cfg->topology_banks[j];
         uint32_t bank_end = (uint32_t)bank->link_start + bank->map_size;
         if (mem->start >= bank->link_start && mem_end <= bank_end) {
            owner = bank;
            matches++;
         }
      }
      if (matches > 1) {
         int first = 1;
         fprintf(stderr,
                 "vcsc-ld: mem region '%s' at $%04X-$%04X is contained by multiple output banks: ",
                 mem->name, mem->start, (uint16_t)(mem_end - 1u));
         for (j = 0; j < cfg->topology_bank_count; ++j) {
            const topology_bank_t *bank = &cfg->topology_banks[j];
            uint32_t bank_end = (uint32_t)bank->link_start + bank->map_size;
            if (mem->start >= bank->link_start && mem_end <= bank_end) {
               fprintf(stderr, "%s%s", first ? "" : ", ", bank->name);
               first = 0;
            }
         }
         fputc('\n', stderr);
         exit(1);
      }
      if (matches == 1) {
         snprintf(mem->output_bank_name, sizeof(mem->output_bank_name), "%s",
                  owner->name);
         mem->output_mode = owner->has_selector ? MEM_OUTPUT_SWITCHED
                                                : MEM_OUTPUT_DIRECT;
         if (owner->has_selector)
            snprintf(mem->bank_name, sizeof(mem->bank_name), "%s", owner->name);
      }
   }
}

static int memory_region_is_zeropage_range(const memory_region_t *mem)
{
   return mem && !mem->data_bank_name[0] && !mem->has_write_start &&
          (uint32_t)mem->start + mem->size <= 0x100u;
}

static int memory_is_in_startup_topology_bank(const linker_config_t *cfg,
                                              const memory_region_t *mem)
{
   size_t i;
   if (!cfg || !mem || !mem->output_bank_name[0])
      return 0;
   for (i = 0; i < cfg->topology_bank_count; ++i)
      if (cfg->topology_banks[i].startup &&
          !strcmp(cfg->topology_banks[i].name, mem->output_bank_name))
         return 1;
   return 0;
}

//! @brief Select a deterministic highest-priority compiler-declared region.
static const memory_region_t *select_default_declared_memory(const linker_config_t *cfg,
                                                             const char *type,
                                                             int zeropage_only,
                                                             int startup_only)
{
   const memory_region_t *best = NULL;
   size_t i;
   for (i = 0; i < cfg->mem_count; ++i) {
      const memory_region_t *mem = &cfg->mem[i];
      if (!mem->compiler_declared || !str_ieq(mem->type, type))
         continue;
      if (mem->output_mode == MEM_OUTPUT_DATA_ONLY || mem->data_bank_name[0])
         continue;
      if (zeropage_only && !memory_region_is_zeropage_range(mem))
         continue;
      if (startup_only && !memory_is_in_startup_topology_bank(cfg, mem))
         continue;
      if (!best || mem->priority > best->priority ||
          (mem->priority == best->priority && strcmp(mem->name, best->name) < 0))
         best = mem;
   }
   return best;
}

static segment_rule_t *find_segment_rule_mutable(linker_config_t *cfg,
                                                  const char *name)
{
   size_t i;
   for (i = 0; cfg && name && i < cfg->seg_count; ++i)
      if (str_ieq(cfg->seg[i].name, name))
         return &cfg->seg[i];
   return NULL;
}

//! @brief Create or authoritatively reroute one ordinary segment rule.
static void synthesize_segment_rule(linker_config_t *cfg, const char *name,
                                    const char *load, const char *run,
                                    const char *type)
{
   segment_rule_t *seg;
   if (!name || !load || !type)
      return;
   seg = find_segment_rule_mutable(cfg, name);
   if (!seg) {
      seg = append_segment_rule(cfg);
      snprintf(seg->name, sizeof(seg->name), "%s", name);
   }
   snprintf(seg->load_name, sizeof(seg->load_name), "%s", load);
   if (run && *run)
      snprintf(seg->run_name, sizeof(seg->run_name), "%s", run);
   else
      seg->run_name[0] = '\0';
   snprintf(seg->type, sizeof(seg->type), "%s", type);
   seg->define_yes = 1;
}

//! @brief Synthesize ordinary placement routes from authoritative C26 mem data.
static void synthesize_c26_segment_rules(linker_config_t *cfg)
{
   const memory_region_t *default_ro;
   const memory_region_t *default_rw;
   const memory_region_t *default_zp;
   int have_startup_topology = 0;
   size_t i;

   for (i = 0; i < cfg->topology_bank_count; ++i)
      if (cfg->topology_banks[i].startup)
         have_startup_topology = 1;
   default_ro = have_startup_topology
      ? select_default_declared_memory(cfg, "ro", 0, 1) : NULL;
   if (!default_ro)
      default_ro = select_default_declared_memory(cfg, "ro", 0, 0);
   default_rw = select_default_declared_memory(cfg, "rw", 0, 0);
   default_zp = select_default_declared_memory(cfg, "rw", 1, 0);

   if (default_ro) {
      synthesize_segment_rule(cfg, "STARTUP", default_ro->name, NULL, "ro");
      synthesize_segment_rule(cfg, "CODE", default_ro->name, NULL, "ro");
      synthesize_segment_rule(cfg, "RODATA", default_ro->name, NULL, "ro");
   }
   if (default_rw) {
      synthesize_segment_rule(cfg, "BSS", default_rw->name, NULL, "bss");
      if (default_ro)
         synthesize_segment_rule(cfg, "DATA", default_ro->name,
                                 default_rw->name, "data");
   }
   if (default_zp && default_ro)
      synthesize_segment_rule(cfg, "ZEROPAGE", default_ro->name,
                              default_zp->name, "zp");

   for (i = 0; i < cfg->mem_count; ++i) {
      const memory_region_t *mem = &cfg->mem[i];
      char name[2 * MAX_NAME];
      if (!mem->compiler_declared)
         continue;
      if (str_ieq(mem->type, "ro")) {
         if (mem->output_mode != MEM_OUTPUT_DATA_ONLY) {
            snprintf(name, sizeof(name), "CODE.%s", mem->name);
            synthesize_segment_rule(cfg, name, mem->name, NULL, "ro");
         }
         snprintf(name, sizeof(name), "RODATA.%s", mem->name);
         synthesize_segment_rule(cfg, name, mem->name, NULL, "ro");
      }
      else if (str_ieq(mem->type, "rw")) {
         snprintf(name, sizeof(name), "BSS.%s", mem->name);
         synthesize_segment_rule(cfg, name, mem->name, NULL, "bss");
         if (default_ro) {
            snprintf(name, sizeof(name), "DATA.%s", mem->name);
            synthesize_segment_rule(cfg, name, default_ro->name,
                                    mem->name, "data");
            if (memory_region_is_zeropage_range(mem)) {
               snprintf(name, sizeof(name), "ZEROPAGE.%s", mem->name);
               synthesize_segment_rule(cfg, name, default_ro->name,
                                       mem->name, "zp");
            }
         }
      }
   }
}

static int ranges_overlap_u32(uint32_t a, uint32_t as, uint32_t b, uint32_t bs)
{
   return as && bs && a < b + bs && b < a + as;
}

//! @brief Drop legacy cfg bank-only corridors superseded by authoritative C26 topology.
static void discard_legacy_banked_cfg_regions(linker_config_t *cfg)
{
   char (*removed)[MAX_NAME] = NULL;
   size_t removed_count = 0;
   size_t read_index, write_index;

   if (!cfg || cfg->topology_bank_count == 0)
      return;

   if (cfg->mem_count) {
      removed = calloc(cfg->mem_count, sizeof(*removed));
      if (!removed) {
         fprintf(stderr, "vcsc-ld: out of memory while replacing legacy bank regions\n");
         exit(1);
      }
   }

   write_index = 0;
   for (read_index = 0; read_index < cfg->mem_count; ++read_index) {
      memory_region_t *mem = &cfg->mem[read_index];
      if (!mem->compiler_declared && mem->bank_name[0]) {
         snprintf(removed[removed_count++], MAX_NAME, "%s", mem->name);
         continue;
      }
      if (write_index != read_index)
         cfg->mem[write_index] = cfg->mem[read_index];
      write_index++;
   }
   cfg->mem_count = write_index;

   write_index = 0;
   for (read_index = 0; read_index < cfg->seg_count; ++read_index) {
      segment_rule_t *seg = &cfg->seg[read_index];
      size_t i;
      int discard = 0;
      for (i = 0; i < removed_count; ++i) {
         if ((seg->load_name[0] && strcasecmp(seg->load_name, removed[i]) == 0) ||
             (seg->run_name[0] && strcasecmp(seg->run_name, removed[i]) == 0)) {
            discard = 1;
            break;
         }
      }
      if (discard)
         continue;
      if (write_index != read_index)
         cfg->seg[write_index] = cfg->seg[read_index];
      write_index++;
   }
   cfg->seg_count = write_index;
   free(removed);
}

//! @brief Build the linker's full-window selector machinery from C26 topology.
static void apply_c26_topology_to_linker_config(linker_config_t *cfg)
{
   size_t i;
   size_t selector_count = 0;

   if (!cfg || cfg->topology_bank_count == 0)
      return;

   discard_legacy_banked_cfg_regions(cfg);

   for (i = 0; i < cfg->topology_bank_count; ++i)
      selector_count += cfg->topology_banks[i].has_selector ? 1u : 0u;

   free(cfg->banks);
   cfg->banks = NULL;
   cfg->bank_count = 0;
   cfg->mapper[0] = '\0';
   cfg->cartridge_banked = selector_count != 0;
   cfg->cartridge_fill_value = cfg->topology_cartridge.fill_value;

   if (selector_count) {
      snprintf(cfg->mapper, sizeof(cfg->mapper), "%s", "C26");
      cfg->trampoline_offset = cfg->topology_cartridge.trampoline_offset;
      cfg->trampoline_size = cfg->topology_cartridge.trampoline_size;
      cfg->vector_bridge_offset = cfg->topology_cartridge.vector_bridge_offset;
      cfg->has_trampoline_offset = 1;
      cfg->has_trampoline_size = 1;
      cfg->has_vector_bridge_offset = 1;
   }

   /* Keep one logical placement record for every CPU-mapped C26 output region,
      including selector-free direct mappings. Data-only file banks are emitted
      separately and deliberately have no 6502 placement record. */
   for (i = 0; i < cfg->topology_bank_count; ++i) {
      const topology_bank_t *top = &cfg->topology_banks[i];
      if (top->data_only)
         continue;
      cartridge_bank_t *bank = append_cartridge_bank(cfg);
      snprintf(bank->name, sizeof(bank->name), "%s", top->name);
      bank->start = (uint16_t)(top->link_start - top->image_offset);
      bank->size = top->image_size;
      bank->hotspot = top->has_selector ? top->select_access : 0;
      bank->startup = top->startup;
   }
}

//! @brief Return whether the C26 topology is the Parker Brothers E0 profile.
static int c26_topology_is_e0(const linker_config_t *cfg)
{
   const topology_cartridge_t *cart;
   if (!cfg || cfg->topology_bank_count != 8u)
      return 0;
   cart = &cfg->topology_cartridge;
   return (cart->present_mask & 0x80u) &&
          cart->signature[0] == 'E' && cart->signature[1] == '0' &&
          cart->signature[2] == 0 && cart->signature[3] == 0;
}

//! @brief Return whether the C26 topology is Wickstead Design WD.
static int c26_topology_is_wd(const linker_config_t *cfg)
{
   const topology_cartridge_t *cart;
   if (!cfg || cfg->topology_bank_count != 8u)
      return 0;
   cart = &cfg->topology_cartridge;
   return (cart->present_mask & 0x80u) &&
          cart->signature[0] == 'W' && cart->signature[1] == 'D' &&
          cart->signature[2] == 0 && cart->signature[3] == 0;
}

//! @brief Return whether the C26 topology is Activision/SCABS FE.
static int c26_topology_is_fe(const linker_config_t *cfg)
{
   const topology_cartridge_t *cart;
   if (!cfg || cfg->topology_bank_count != 2u)
      return 0;
   cart = &cfg->topology_cartridge;
   return (cart->present_mask & 0x80u) &&
          cart->signature[0] == 'F' && cart->signature[1] == 'E' &&
          cart->signature[2] == 0 && cart->signature[3] == 0;
}

//! @brief Return whether the C26 topology is the classic Pitfall II DPC image.
static int c26_topology_is_dpc(const linker_config_t *cfg)
{
   const topology_cartridge_t *cart;
   if (!cfg || cfg->topology_bank_count != 4u)
      return 0;
   cart = &cfg->topology_cartridge;
   return (cart->present_mask & 0x80u) &&
          cart->signature[0] == 'D' && cart->signature[1] == 'P' &&
          cart->signature[2] == 'C' && cart->signature[3] == 0;
}

//! @brief Return one physical topology unit by dense file index.
static const topology_bank_t *c26_topology_bank_by_file_index(const linker_config_t *cfg,
                                                              size_t file_index)
{
   size_t i;
   if (!cfg)
      return NULL;
   for (i = 0; i < cfg->topology_bank_count; ++i)
      if (cfg->topology_banks[i].file_index == file_index)
         return &cfg->topology_banks[i];
   return NULL;
}

//! @brief Validate F8 program ROM plus 2K display and 255-byte DPC data banks.
static void validate_c26_dpc_topology(const linker_config_t *cfg)
{
   const topology_bank_t *program0 = c26_topology_bank_by_file_index(cfg, 0u);
   const topology_bank_t *program1 = c26_topology_bank_by_file_index(cfg, 1u);
   const topology_bank_t *display = c26_topology_bank_by_file_index(cfg, 2u);
   const topology_bank_t *poly = c26_topology_bank_by_file_index(cfg, 3u);
   const topology_bank_t *program[2] = { program0, program1 };
   size_t i;

   if (!program0 || !program1 || !display || !poly) {
      fprintf(stderr, "vcsc-ld: DPC topology requires dense file banks 0-3\n");
      exit(1);
   }
   for (i = 0; i < 2u; ++i) {
      const topology_bank_t *bank = program[i];
      uint16_t expected_link = (uint16_t)(i == 0u ? 0xd080u : 0xf080u);
      uint16_t expected_selector = (uint16_t)(0x1ff8u + i);
      if (bank->data_only || bank->image_size != 0x1000u ||
          bank->image_offset != 0x0080u || bank->link_start != expected_link ||
          bank->cpu_start != 0xf080u || bank->map_size != 0x0f80u ||
          !bank->has_selector || bank->select_access != expected_selector) {
         fprintf(stderr,
                 "vcsc-ld: DPC program file bank %zu must be an F8 4K image with hidden $80 register prefix and selector $%04X\n",
                 i, expected_selector);
         exit(1);
      }
      if ((i == 1u) != (bank->startup != 0)) {
         fprintf(stderr,
                 "vcsc-ld: DPC startup/home marker must be on program file bank 1\n");
         exit(1);
      }
   }
   if (!display->data_only || display->image_size != 0x0800u ||
       display->image_offset || display->link_start || display->cpu_start ||
       display->map_size || display->has_selector || display->startup) {
      fprintf(stderr,
              "vcsc-ld: DPC file bank 2 must be one unmapped 2K $data_only display-data bank\n");
      exit(1);
   }
   if (!poly->data_only || poly->image_size != 0x00ffu ||
       poly->image_offset || poly->link_start || poly->cpu_start ||
       poly->map_size || poly->has_selector || poly->startup) {
      fprintf(stderr,
              "vcsc-ld: DPC file bank 3 must be one unmapped 255-byte $data_only RNG/poly bank\n");
      exit(1);
   }
}

//! @brief Return whether the C26 topology is Harmony FA2.
static int c26_topology_is_fa2(const linker_config_t *cfg)
{
   const topology_cartridge_t *cart;
   if (!cfg || (cfg->topology_bank_count != 6u && cfg->topology_bank_count != 7u))
      return 0;
   cart = &cfg->topology_cartridge;
   return (cart->present_mask & 0x80u) &&
          cart->signature[0] == 'F' && cart->signature[1] == 'A' &&
          cart->signature[2] == '2' && cart->signature[3] == 0;
}

//! @brief Validate the six/seven-bank Harmony FA2 topology.
static void validate_c26_fa2_topology(const linker_config_t *cfg)
{
   size_t i;
   size_t startup_count = 0;
   for (i = 0; i < cfg->topology_bank_count; ++i) {
      const topology_bank_t *bank = c26_topology_bank_by_file_index(cfg, i);
      uint16_t expected_link = (uint16_t)(0xf200u - (uint16_t)(i * 0x2000u));
      uint16_t expected_selector = (uint16_t)(0x1ff5u + i);
      if (!bank) {
         fprintf(stderr, "vcsc-ld: FA2 topology requires dense file banks 0-%zu\n",
                 cfg->topology_bank_count - 1u);
         exit(1);
      }
      if (bank->data_only || bank->image_size != 0x1000u ||
          bank->image_offset != 0x0200u || bank->link_start != expected_link ||
          bank->cpu_start != 0xf200u || bank->map_size != 0x0e00u ||
          !bank->has_selector || bank->select_access != expected_selector) {
         fprintf(stderr,
                 "vcsc-ld: FA2 physical/file bank %zu must be a 4K image with hidden $200 RAM-port prefix, logical start $%04X, and selector $%04X\n",
                 i, expected_link, expected_selector);
         exit(1);
      }
      if (bank->startup) {
         startup_count++;
         if (i != 0u) {
            fprintf(stderr, "vcsc-ld: FA2 startup/home marker must be on physical/file bank 0\n");
            exit(1);
         }
      }
   }
   if (startup_count != 1u) {
      fprintf(stderr, "vcsc-ld: FA2 topology requires physical/file bank 0 as the single startup/home bank\n");
      exit(1);
   }
}

//! @brief Return whether the C26 topology is classic Tigervision 3F or 3E.
static int c26_topology_is_3f_family(const linker_config_t *cfg)
{
   const topology_cartridge_t *cart;
   if (!cfg || cfg->topology_bank_count < 3u || cfg->topology_bank_count > 8u)
      return 0;
   cart = &cfg->topology_cartridge;
   if (!(cart->present_mask & 0x80u) || cart->signature[2] != 0 ||
       cart->signature[3] != 0)
      return 0;
   return cart->signature[0] == '3' &&
          (cart->signature[1] == 'F' || cart->signature[1] == 'E');
}

//! @brief Validate classic Tigervision lower-2K/fixed-final-2K topology.
static void validate_c26_3f_family_topology(const linker_config_t *cfg)
{
   size_t i;
   size_t startup_count = 0;
   size_t final_index = cfg->topology_bank_count - 1u;

   for (i = 0; i < cfg->topology_bank_count; ++i) {
      const topology_bank_t *bank = &cfg->topology_banks[i];
      uint16_t canonical_link = (uint16_t)(bank->link_start & 0x1fffu);
      if (bank->image_size != 0x0800u || bank->image_offset != 0 ||
          bank->map_size != 0x0800u) {
         fprintf(stderr,
                 "vcsc-ld: 3F/3E bank '%s' must be one fully mapped 2K physical chunk\n",
                 bank->name);
         exit(1);
      }
      if (bank->has_selector) {
         fprintf(stderr,
                 "vcsc-ld: 3F/3E bank '%s' must not use address-only $select_access metadata; selection is value-written TIA state\n",
                 bank->name);
         exit(1);
      }
      if (canonical_link != (uint16_t)(bank->cpu_start & 0x1fffu)) {
         fprintf(stderr,
                 "vcsc-ld: 3F/3E bank '%s' link address $%04X is not a 6507 alias of CPU window $%04X\n",
                 bank->name, bank->link_start, bank->cpu_start);
         exit(1);
      }
      if (bank->file_index == final_index) {
         if (bank->cpu_start != 0x1800u) {
            fprintf(stderr,
                    "vcsc-ld: 3F/3E final physical bank must use fixed $1800-$1FFF CPU window\n");
            exit(1);
         }
      } else if (bank->cpu_start != 0x1000u) {
         fprintf(stderr,
                 "vcsc-ld: 3F/3E selectable bank '%s' must use lower $1000-$17FF CPU window\n",
                 bank->name);
         exit(1);
      }
      if (bank->startup) {
         startup_count++;
         if (bank->file_index != final_index) {
            fprintf(stderr,
                    "vcsc-ld: 3F/3E startup/home marker must be on the fixed final physical bank\n");
            exit(1);
         }
      }
   }
   if (startup_count != 1u) {
      fprintf(stderr,
              "vcsc-ld: 3F/3E topology requires the fixed final 2K as the single startup/home bank\n");
      exit(1);
   }
}

//! @brief Validate the segmented 8x1K Parker Brothers E0 output profile.
static void validate_c26_e0_topology(const linker_config_t *cfg)
{
   size_t i;
   size_t startup_count = 0;
   for (i = 0; i < cfg->topology_bank_count; ++i) {
      const topology_bank_t *bank = &cfg->topology_banks[i];
      uint16_t canonical_link = (uint16_t)(bank->link_start & 0x1fffu);
      if (bank->image_size != 0x0400u || bank->image_offset != 0 ||
          bank->map_size != 0x0400u) {
         fprintf(stderr,
                 "vcsc-ld: E0 bank '%s' must be one fully mapped 1K physical chunk\n",
                 bank->name);
         exit(1);
      }
      if (bank->has_selector) {
         fprintf(stderr,
                 "vcsc-ld: E0 bank '%s' must not use one-bank $select_access metadata; E0 selectors are segment-specific\n",
                 bank->name);
         exit(1);
      }
      if (canonical_link != (uint16_t)(bank->cpu_start & 0x1fffu)) {
         fprintf(stderr,
                 "vcsc-ld: E0 bank '%s' link address $%04X is not a 6507 alias of CPU window $%04X\n",
                 bank->name, bank->link_start, bank->cpu_start);
         exit(1);
      }
      if (bank->file_index == 7u) {
         if (bank->cpu_start != 0x1c00u) {
            fprintf(stderr,
                    "vcsc-ld: E0 physical bank 7 must use the fixed $1C00-$1FFF CPU window\n");
            exit(1);
         }
      } else if (bank->cpu_start != 0x1000u &&
                 bank->cpu_start != 0x1400u &&
                 bank->cpu_start != 0x1800u) {
         fprintf(stderr,
                 "vcsc-ld: E0 switchable bank '%s' must choose $1000, $1400, or $1800 as its canonical compile window\n",
                 bank->name);
         exit(1);
      }
      if (bank->startup) {
         startup_count++;
         if (bank->file_index != 7u) {
            fprintf(stderr,
                    "vcsc-ld: E0 startup/home marker must be on fixed physical bank 7\n");
            exit(1);
         }
      }
   }
   if (startup_count != 1u) {
      fprintf(stderr,
              "vcsc-ld: E0 topology requires fixed physical bank 7 as the single startup/home bank\n");
      exit(1);
   }
}

//! @brief Validate the segmented 8x1K Wickstead Design output profile.
static void validate_c26_wd_topology(const linker_config_t *cfg)
{
   size_t i;
   size_t startup_count = 0;
   for (i = 0; i < cfg->topology_bank_count; ++i) {
      const topology_bank_t *bank = &cfg->topology_banks[i];
      uint16_t canonical_link = (uint16_t)(bank->link_start & 0x1fffu);
      if (bank->image_size != 0x0400u || bank->image_offset != 0u ||
          bank->map_size != 0x0400u) {
         fprintf(stderr,
                 "vcsc-ld: WD bank '%s' must be one fully mapped 1K physical chunk\n",
                 bank->name);
         exit(1);
      }
      if (bank->has_selector) {
         fprintf(stderr,
                 "vcsc-ld: WD bank '%s' must not use one-bank $select_access metadata; WD selects complete four-segment arrangements from TIA $30-$3F reads\n",
                 bank->name);
         exit(1);
      }
      if (canonical_link != (uint16_t)(bank->cpu_start & 0x1fffu) ||
          (bank->cpu_start != 0x1000u && bank->cpu_start != 0x1400u &&
           bank->cpu_start != 0x1800u && bank->cpu_start != 0x1c00u)) {
         fprintf(stderr,
                 "vcsc-ld: WD bank '%s' link address $%04X must alias one 1K CPU segment at $1000/$1400/$1800/$1C00\n",
                 bank->name, bank->link_start);
         exit(1);
      }
      if (bank->startup) {
         startup_count++;
         if (bank->file_index != 3u || bank->cpu_start != 0x1c00u ||
             bank->link_start != 0xfc00u) {
            fprintf(stderr,
                    "vcsc-ld: WD startup/home bank must be physical/file chunk 3 at logical $FC00 / CPU $1C00\n");
            exit(1);
         }
      }
   }
   if (startup_count != 1u) {
      fprintf(stderr,
              "vcsc-ld: WD topology requires physical/file chunk 3 as the single startup/home bank\n");
      exit(1);
   }
}

//! @brief Validate the two-bank delayed-latch Activision/SCABS FE topology.
static void validate_c26_fe_topology(const linker_config_t *cfg)
{
   size_t i;
   size_t startup_count = 0;

   for (i = 0; i < cfg->topology_bank_count; ++i) {
      const topology_bank_t *bank = &cfg->topology_banks[i];
      uint16_t expected_link = bank->file_index == 0u ? 0xf000u : 0xd000u;
      if (bank->image_size != 0x1000u || bank->image_offset != 0u ||
          bank->map_size != 0x1000u) {
         fprintf(stderr,
                 "vcsc-ld: FE bank '%s' must be one fully mapped 4K physical chunk\n",
                 bank->name);
         exit(1);
      }
      if (bank->has_selector) {
         fprintf(stderr,
                 "vcsc-ld: FE bank '%s' must not use $select_access; FE switches from the delayed $01FE data-bus latch\n",
                 bank->name);
         exit(1);
      }
      if (bank->file_index > 1u || bank->link_start != expected_link ||
          bank->cpu_start != expected_link) {
         fprintf(stderr,
                 "vcsc-ld: FE physical bank %u must use logical/cpu window $%04X-$%04X\n",
                 (unsigned)bank->file_index, expected_link,
                 (uint16_t)(expected_link + 0x0fffu));
         exit(1);
      }
      if (bank->startup) {
         startup_count++;
         if (bank->file_index != 0u) {
            fprintf(stderr,
                    "vcsc-ld: FE startup/home marker must be on physical/file bank 0\n");
            exit(1);
         }
      }
   }
   if (startup_count != 1u) {
      fprintf(stderr,
              "vcsc-ld: FE topology requires physical/file bank 0 as the single startup/home bank\n");
      exit(1);
   }
}

//! @brief Validate generic C26 topology independently of legacy cfg topology.
static void validate_c26_topology(linker_config_t *cfg)
{
   size_t i, j;
   size_t selector_count = 0;
   size_t startup_count = 0;
   size_t mapped_bank_count = 0;
   const unsigned int complete_generated_mask = 0x7fu;
   int e0_profile;
   int wd_profile;
   int fe_profile;
   int dpc_profile;
   int fa2_profile;
   int threef_family;

   if (cfg->topology_bank_count == 0) {
      if (cfg->topology_cartridge.present) {
         fprintf(stderr, "vcsc-ld: cartridge declaration requires at least one bank declaration\n");
         exit(1);
      }
      return;
   }
   if (!cfg->topology_cartridge.present) {
      fprintf(stderr, "vcsc-ld: C26 bank declarations require one cartridge declaration\n");
      exit(1);
   }
   e0_profile = c26_topology_is_e0(cfg);
   wd_profile = c26_topology_is_wd(cfg);
   fe_profile = c26_topology_is_fe(cfg);
   dpc_profile = c26_topology_is_dpc(cfg);
   fa2_profile = c26_topology_is_fa2(cfg);
   threef_family = c26_topology_is_3f_family(cfg);

   for (i = 0; i < cfg->topology_bank_count; ++i) {
      topology_bank_t *bank = &cfg->topology_banks[i];
      uint32_t link_end = (uint32_t)bank->link_start + bank->map_size;
      uint32_t cpu_end = (uint32_t)bank->cpu_start + bank->map_size;
      uint32_t image_end = (uint32_t)bank->image_offset + bank->map_size;
      if (!bank->image_size) {
         fprintf(stderr, "vcsc-ld: bank '%s' has zero image size\n", bank->name);
         exit(1);
      }
      if (bank->data_only) {
         if (bank->image_offset || bank->link_start || bank->cpu_start ||
             bank->map_size || bank->has_selector || bank->startup) {
            fprintf(stderr,
                    "vcsc-ld: data-only bank '%s' must not declare mapping, selector, or startup state\n",
                    bank->name);
            exit(1);
         }
      }
      else {
         mapped_bank_count++;
         if (!bank->map_size || image_end > bank->image_size ||
             link_end > 0x10000u || cpu_end > 0x10000u) {
            fprintf(stderr, "vcsc-ld: bank '%s' has a mapped range outside its image or 6502 address space\n",
                    bank->name);
            exit(1);
         }
      }
      if (bank->file_index >= cfg->topology_bank_count) {
         fprintf(stderr, "vcsc-ld: bank '%s' file index %u is outside dense range 0-%zu\n",
                 bank->name, (unsigned)bank->file_index,
                 cfg->topology_bank_count - 1u);
         exit(1);
      }
      selector_count += (!bank->data_only && bank->has_selector) ? 1u : 0u;
      startup_count += (!bank->data_only && bank->startup) ? 1u : 0u;
      if (bank->has_selector && bank->select_access > 0x1fffu) {
         fprintf(stderr, "vcsc-ld: bank '%s' selector $%04X is outside the 6507 $0000-$1FFF bus\n",
                 bank->name, bank->select_access);
         exit(1);
      }
      for (j = i + 1; j < cfg->topology_bank_count; ++j) {
         topology_bank_t *other = &cfg->topology_banks[j];
         if (bank->file_index == other->file_index) {
            fprintf(stderr, "vcsc-ld: banks '%s' and '%s' duplicate file index %u\n",
                    bank->name, other->name, (unsigned)bank->file_index);
            exit(1);
         }
         if (bank->data_only || other->data_only)
            continue;
         if (ranges_overlap_u32(bank->link_start, bank->map_size,
                                other->link_start, other->map_size)) {
            fprintf(stderr, "vcsc-ld: bank link mappings '%s' and '%s' overlap\n",
                    bank->name, other->name);
            exit(1);
         }
         if (!e0_profile && !wd_profile && !fe_profile && !threef_family && !bank->has_selector && !other->has_selector &&
             ranges_overlap_u32(bank->cpu_start, bank->map_size,
                                other->cpu_start, other->map_size)) {
            fprintf(stderr, "vcsc-ld: directly mapped CPU ranges '%s' and '%s' overlap\n",
                    bank->name, other->name);
            exit(1);
         }
         if (bank->has_selector && other->has_selector &&
             bank->select_access == other->select_access) {
            fprintf(stderr, "vcsc-ld: banks '%s' and '%s' duplicate selector $%04X\n",
                    bank->name, other->name, bank->select_access);
            exit(1);
         }
      }
   }

   if (e0_profile)
      validate_c26_e0_topology(cfg);
   if (wd_profile)
      validate_c26_wd_topology(cfg);
   if (fe_profile)
      validate_c26_fe_topology(cfg);
   if (dpc_profile)
      validate_c26_dpc_topology(cfg);
   if (fa2_profile)
      validate_c26_fa2_topology(cfg);
   if (threef_family)
      validate_c26_3f_family_topology(cfg);

   if (selector_count && selector_count != mapped_bank_count) {
      fprintf(stderr, "vcsc-ld: mixed direct and selector-controlled banks require a future window/device model\n");
      exit(1);
   }
   if (selector_count) {
      if (startup_count != 1u) {
         fprintf(stderr, "vcsc-ld: selector-controlled topology requires exactly one startup bank\n");
         exit(1);
      }
      if ((cfg->topology_cartridge.present_mask & complete_generated_mask) !=
          complete_generated_mask) {
         fprintf(stderr, "vcsc-ld: selector-controlled topology requires all trampoline, vector-bridge, and vector ranges\n");
         exit(1);
      }
      for (i = 0; i < cfg->topology_bank_count; ++i) {
         const topology_bank_t *bank = &cfg->topology_banks[i];
         if (bank->data_only)
            continue;
         if (bank->image_size != 0x1000u ||
             bank->image_offset > 0x0200u ||
             bank->map_size != (uint16_t)(0x1000u - bank->image_offset) ||
             bank->cpu_start != (uint16_t)(0xf000u + bank->image_offset) ||
             bank->link_start < bank->image_offset ||
             ((uint16_t)(bank->link_start - bank->image_offset) & 0x0fffu) != 0) {
            fprintf(stderr, "vcsc-ld: selector-controlled bank '%s' is not a supported full-window 4K mapping\n",
                    bank->name);
            exit(1);
         }
      }
      {
         const topology_bank_t *a = NULL;
         for (i = 0; i < cfg->topology_bank_count; ++i)
            if (!cfg->topology_banks[i].data_only) {
               a = &cfg->topology_banks[i];
               break;
            }
         for (i = 0; a && i < cfg->topology_bank_count; ++i) {
            const topology_bank_t *b = &cfg->topology_banks[i];
            if (b == a || b->data_only)
               continue;
         if (a->image_size != b->image_size || a->image_offset != b->image_offset ||
             a->cpu_start != b->cpu_start || a->map_size != b->map_size) {
            fprintf(stderr, "vcsc-ld: selector-controlled banks must share one full-window image/mapping shape\n");
            exit(1);
         }
         }
      }
   }
   else if (startup_count > 1u) {
      fprintf(stderr, "vcsc-ld: directly mapped topology may mark at most one startup/home bank\n");
      exit(1);
   }

   if (cfg->topology_cartridge.present_mask & 0x80u) {
      const topology_bank_t *last = NULL;
      for (i = 0; i < cfg->topology_bank_count; ++i)
         if (!cfg->topology_banks[i].data_only &&
             (!last || cfg->topology_banks[i].file_index > last->file_index))
            last = &cfg->topology_banks[i];
      if (!last || last->image_size < 8u) {
         fprintf(stderr,
                 "vcsc-ld: cartridge signature requires at least eight bytes in the final CPU-mapped physical bank\n");
         exit(1);
      }
   }

   /* A nonzero image_offset means physical bytes at the beginning of a bank
    * are hidden by cartridge hardware rather than mapped ROM.  This applies
    * equally to selector-controlled FA/SC banks and to direct 4KSC.  Reject
    * only compiler-declared read-only regions that actually try to occupy that
    * hidden prefix; broad unused compatibility fallbacks remain harmless. */
   for (i = 0; i < cfg->mem_count; ++i) {
      const memory_region_t *mem = &cfg->mem[i];
      uint32_t mem_end;
      size_t k;
      if (!mem->compiler_declared || !str_ieq(mem->type, "ro") ||
          mem->output_bank_name[0])
         continue;
      mem_end = (uint32_t)mem->start + mem->size;
      for (k = 0; k < cfg->topology_bank_count; ++k) {
         const topology_bank_t *bank = &cfg->topology_banks[k];
         uint16_t full_start;
         uint32_t full_end;
         uint32_t hidden_end;
         if (!bank->image_offset)
            continue;
         full_start = (uint16_t)(bank->link_start - bank->image_offset);
         full_end = (uint32_t)full_start + bank->image_size;
         hidden_end = (uint32_t)full_start + bank->image_offset;
         if (mem->start >= full_start && mem_end <= full_end &&
             mem->start < hidden_end && mem_end > full_start) {
            fprintf(stderr,
                    "vcsc-ld: read-only region '%s' at $%04X-$%04X lies outside every mapped ROM window\n",
                    mem->name, mem->start, (uint16_t)(mem_end - 1u));
            exit(1);
         }
      }
   }

   {
      const topology_cartridge_t *cart = &cfg->topology_cartridge;
      uint32_t ro[3] = { cart->trampoline_offset, cart->vector_bridge_offset,
                         cart->vectors_offset };
      uint32_t rz[3] = { cart->trampoline_size, cart->vector_bridge_size,
                         cart->vectors_size };
      unsigned int bits[3] = { 0x06u, 0x18u, 0x60u };
      for (i = 0; i < 3; ++i) {
         if (!(cart->present_mask & bits[i]))
            continue;
         for (j = 0; j < cfg->topology_bank_count; ++j) {
            const topology_bank_t *bank = &cfg->topology_banks[j];
            if (bank->data_only)
               continue;
            if (ro[i] + rz[i] > bank->image_size) {
               fprintf(stderr, "vcsc-ld: generated cartridge range exceeds bank '%s' image size\n",
                       bank->name);
               exit(1);
            }
            if (selector_count &&
                (ro[i] < bank->image_offset ||
                 ro[i] + rz[i] > (uint32_t)bank->image_offset + bank->map_size)) {
               fprintf(stderr, "vcsc-ld: generated cartridge range lies outside bank '%s' mapped image window\n",
                       bank->name);
               exit(1);
            }
         }
         for (j = i + 1; j < 3; ++j) {
            if ((cart->present_mask & bits[j]) &&
                ranges_overlap_u32(ro[i], rz[i], ro[j], rz[j])) {
               fprintf(stderr, "vcsc-ld: generated cartridge ranges overlap\n");
               exit(1);
            }
         }
      }
   }


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
      ".__vcsc_function$", ".__vcsc_object$", ".__vcsc_activation$", ".__vcsc_page$", NULL
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

static int component_hex_value(int ch)
{
   if (ch >= '0' && ch <= '9') return ch - '0';
   if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
   if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
   return -1;
}

static int component_hex_decode_field(const char *text, size_t len,
                                      char *out, size_t out_size)
{
   size_t i;
   if ((len & 1u) != 0 || len / 2u + 1u > out_size)
      return 0;
   for (i = 0; i < len; i += 2) {
      int hi = component_hex_value((unsigned char)text[i]);
      int lo = component_hex_value((unsigned char)text[i + 1]);
      if (hi < 0 || lo < 0)
         return 0;
      out[i / 2u] = (char)((hi << 4) | lo);
      if (out[i / 2u] == '\0')
         return 0;
   }
   out[len / 2u] = '\0';
   return 1;
}

static object_layout_t *component_find_layout(object_file_t *obj,
                                               const char *name)
{
   size_t i;
   for (i = 0; obj && i < obj->layout_count; ++i)
      if (!strcmp(obj->layouts[i].name, name))
         return &obj->layouts[i];
   return NULL;
}

static const char *component_resolve_memory_name(const linker_config_t *cfg,
                                                 const object_layout_t *lay,
                                                 const char *fallback)
{
   if (!lay || !lay->component_memory[0])
      return fallback;
   if (!strcmp(lay->component_memory, "@startup")) {
      const segment_rule_t *code = find_segment_rule(cfg, "CODE");
      return code && code->load_name[0] ? code->load_name : fallback;
   }
   return lay->component_memory;
}

//! @brief Apply assembler-component placement and hidden-stack metadata.
static void apply_component_constraints(linker_config_t *cfg, input_set_t *in)
{
   size_t i, j;
   uint32_t stack_total = 0;
   size_t stack_record_count = 0;

   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->export_count; ++j) {
         const char *name = obj->exports[j].name;
         const char *p;
         if (!component_constraint_metadata_has_prefix(name))
            continue;
         p = name + sizeof(COMPONENT_CONSTRAINT_META_PREFIX) - 1;
         if (p[0] == 'S' && p[1] == '$') {
            char *end = NULL;
            unsigned long value = strtoul(p + 2, &end, 10);
            if (!end || *end || value > 0xffffu) {
               fprintf(stderr, "vcsc-ld: malformed component hidden-stack metadata in %s\n",
                       obj->origin);
               exit(1);
            }
            stack_total += value;
            if (stack_total > 0xffffu) {
               fprintf(stderr, "vcsc-ld: component hidden-stack requirements exceed 65535 bytes\n");
               exit(1);
            }
            stack_record_count++;
            continue;
         }
         if (p[0] == 'L' && p[1] == '$') {
            const char *seg_start = p + 2;
            const char *sep1 = strchr(seg_start, '$');
            const char *region_start;
            const char *sep2;
            const char *align_start;
            const char *sep3;
            const char *sep4;
            char segment[MAX_NAME];
            char region[MAX_NAME];
            char *end = NULL;
            unsigned long alignment;
            unsigned long private_route;
            unsigned long phase = 0;
            object_layout_t *lay;
            const char *resolved;
            const memory_region_t *memory;
            const segment_rule_t *exact_rule;
            if (!sep1) goto malformed_layout;
            region_start = sep1 + 1;
            sep2 = strchr(region_start, '$');
            if (!sep2) goto malformed_layout;
            align_start = sep2 + 1;
            sep3 = strchr(align_start, '$');
            if (!sep3) goto malformed_layout;
            if (!component_hex_decode_field(seg_start, (size_t)(sep1 - seg_start),
                                            segment, sizeof(segment)) ||
                !component_hex_decode_field(region_start, (size_t)(sep2 - region_start),
                                            region, sizeof(region)))
               goto malformed_layout;
            alignment = strtoul(align_start, &end, 10);
            if (!end || end != sep3 || alignment > 32768u ||
                (alignment && (alignment & (alignment - 1u))))
               goto malformed_layout;
            sep4 = strchr(sep3 + 1, '$');
            private_route = strtoul(sep3 + 1, &end, 10);
            if (!end || (sep4 ? end != sep4 : *end) || private_route > 1u)
               goto malformed_layout;
            if (sep4) {
               phase = strtoul(sep4 + 1, &end, 10);
               if (!end || *end || (alignment && phase >= alignment) ||
                   (!alignment && phase != 0))
                  goto malformed_layout;
            }
            lay = component_find_layout(obj, segment);
            if (!lay) {
               fprintf(stderr,
                  "vcsc-ld: component metadata in %s names missing segment '%s'\n",
                  obj->origin, segment);
               exit(1);
            }
            if (lay->component_memory[0] && strcmp(lay->component_memory, region)) {
               fprintf(stderr,
                  "vcsc-ld: conflicting component memory requirements for segment '%s' in %s\n",
                  segment, obj->origin);
               exit(1);
            }
            if (lay->component_alignment &&
                (lay->component_alignment != alignment ||
                 lay->component_phase != phase)) {
               fprintf(stderr,
                  "vcsc-ld: conflicting component alignment requirements for segment '%s' in %s\n",
                  segment, obj->origin);
               exit(1);
            }
            snprintf(lay->component_memory, sizeof(lay->component_memory), "%s", region);
            lay->component_alignment = (uint16_t)alignment;
            lay->component_phase = (uint16_t)phase;
            lay->component_private = (uint8_t)private_route;
            resolved = component_resolve_memory_name(cfg, lay, NULL);
            if (lay->component_memory[0] && (!resolved || !*resolved)) {
               fprintf(stderr,
                  "vcsc-ld: component segment '%s' in %s requires a startup read-only memory region, but none exists\n",
                  segment, obj->origin);
               exit(1);
            }
            if (resolved && *resolved) {
               memory = find_memory(cfg, resolved);
               if (!memory) {
                  fprintf(stderr,
                     "vcsc-ld: component segment '%s' in %s requires unknown MEMORY region '%s'\n",
                     segment, obj->origin, resolved);
                  exit(1);
               }
               if (lay->segid == O26_SEG_TEXT && memory->compiler_declared &&
                   !str_ieq(memory->type, "ro")) {
                  fprintf(stderr,
                     "vcsc-ld: component text segment '%s' in %s requires non-read-only MEMORY region '%s'\n",
                     segment, obj->origin, resolved);
                  exit(1);
               }
            }
            exact_rule = find_segment_rule(cfg, segment);
            if (exact_rule && resolved && exact_rule->load_name[0] &&
                !str_ieq(exact_rule->load_name, resolved)) {
               fprintf(stderr,
                  "vcsc-ld: component segment '%s' in %s requires MEMORY region '%s' but cfg routes it to '%s'\n",
                  segment, obj->origin, resolved, exact_rule->load_name);
               exit(1);
            }
            if (exact_rule && alignment && exact_rule->align &&
                exact_rule->align != alignment) {
               fprintf(stderr,
                  "vcsc-ld: component segment '%s' in %s requires alignment $%04lX but cfg requires $%04X\n",
                  segment, obj->origin, alignment, exact_rule->align);
               exit(1);
            }
            continue;
malformed_layout:
            fprintf(stderr, "vcsc-ld: malformed component layout metadata in %s\n",
                    obj->origin);
            exit(1);
         }
         fprintf(stderr, "vcsc-ld: unknown component metadata record in %s\n",
                 obj->origin);
         exit(1);
      }
   }

   if (stack_record_count) {
      memory_region_t *target = NULL;
      for (i = 0; i < cfg->mem_count; ++i) {
         memory_region_t *mem = &cfg->mem[i];
         if (!mem->callstack_callgraph)
            continue;
         if (target) {
            fprintf(stderr,
               "vcsc-ld: component hidden-stack metadata requires exactly one callgraph MEMORY region\n");
            exit(1);
         }
         target = mem;
      }
      if (!target) {
         fprintf(stderr,
            "vcsc-ld: component hidden-stack metadata requires a MEMORY region with callstack=callgraph\n");
         exit(1);
      }
      if (target->callstack_extra && target->callstack_extra != stack_total) {
         fprintf(stderr,
            "vcsc-ld: component hidden-stack requirement $%04X conflicts with cfg callstack_extra $%04X in MEMORY region '%s'\n",
            (unsigned)stack_total, target->callstack_extra, target->name);
         exit(1);
      }
      target->callstack_extra = (uint16_t)stack_total;
   }
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
   } else if (str_ieq(key, "read_hazard")) {
      mem->read_hazard = parse_yes_no("memory read_hazard", value);
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

   /* C26 direct topologies also populate cfg->banks so the whole-layout
      allocator can treat each directly addressed island as a placement
      region.  They deliberately do not acquire selector/trampoline semantics. */
   if (cfg->topology_bank_count && !cfg->cartridge_banked)
      return;

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
      if (bank->hotspot > 0x1fffu) {
         fprintf(stderr,
                 "vcsc-ld: BANKS entry '%s' hotspot $%04X is outside the 6507 $0000-$1FFF bus\n",
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

   if (cfg->topology_bank_count == 0) {
      size_t expected_count = 0;
      uint16_t first_file_hotspot = 0;
      uint16_t reserved_prefix = 0;
      if (str_ieq(cfg->mapper, "F8") || str_ieq(cfg->mapper, "F8SC")) {
         expected_count = 2;
         first_file_hotspot = 0x1FF8u;
         reserved_prefix = str_ieq(cfg->mapper, "F8SC") ? 0x0100u : 0;
      } else if (str_ieq(cfg->mapper, "FA")) {
         expected_count = 3;
         first_file_hotspot = 0x1FF8u;
         reserved_prefix = 0x0200u;
      } else if (str_ieq(cfg->mapper, "F6") || str_ieq(cfg->mapper, "F6SC")) {
         expected_count = 4;
         first_file_hotspot = 0x1FF6u;
         reserved_prefix = str_ieq(cfg->mapper, "F6SC") ? 0x0100u : 0;
      } else if (str_ieq(cfg->mapper, "F4") || str_ieq(cfg->mapper, "F4SC")) {
         expected_count = 8;
         first_file_hotspot = 0x1FF4u;
         reserved_prefix = str_ieq(cfg->mapper, "F4SC") ? 0x0100u : 0;
      } else {
         fprintf(stderr,
                 "vcsc-ld: unsupported full-window mapper '%s'; expected F8/F6/F4/FA or an SC variant\n",
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

      if (reserved_prefix) {
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
            if (region->start < (uint16_t)(bank->start + reserved_prefix) &&
                end > bank->start) {
               fprintf(stderr,
                       "vcsc-ld: %s read-only region '%s' overlaps the cartridge RAM-port prefix $%04X-$%04X\n",
                       cfg->mapper, region->name, bank->start,
                       (uint16_t)(bank->start + reserved_prefix - 1u));
               exit(1);
            }
         }
      }
   }

   for (i = 0; i < cfg->bank_count; ++i) {
      uint16_t selector_offset;
      if ((cfg->banks[i].hotspot & 0x1000u) == 0)
         continue;
      selector_offset = (uint16_t)(cfg->banks[i].hotspot & 0x0FFFu);
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
         if (cartridge_output && !mem->compiler_declared) {
            fprintf(stderr,
                    "vcsc-ld: banked cartridge cfg-only MEMORY region '%s' must name bank=...\n",
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
            uint16_t logical_hotspot;
            if ((cfg->banks[j].hotspot & 0x1000u) == 0)
               continue;
            logical_hotspot =
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
                                           call_graph_edge_t **edges, size_t *edge_count,
                                           int include_activation_edges)
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

      if (symbol_backed_metadata_parse_edge(name, &caller, &callee) ||
          (include_activation_edges &&
           symbol_backed_metadata_parse_activation_edge(name, &caller, &callee))) {
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
   {
      const char *memory_name = component_resolve_memory_name(cfg, layout,
         (rule && rule->load_name[0]) ? rule->load_name : NULL);
      if (!memory_name || !*memory_name)
         return NULL;
      memory = find_memory(cfg, memory_name);
   }
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

//! @brief Return whether the selected stock startup tail-enters main.
static int selected_startup_tail_enters_main(const input_set_t *in)
{
   return selected_objects_have_export(in, "__vcsc_startup_simple") ||
          selected_objects_have_export(in, "__vcsc_startup_full");
}

//! @brief Validate symbol backed call graph invariants and return its maximum function depth.
static uint16_t enforce_symbol_backed_call_graph(const input_set_t *in,
                                                 const linker_config_t *cfg,
                                                 uint16_t *weighted_depth_out,
                                                 int tail_main)
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
      call_graph_collect_from_object(&in->objects[i], &nodes, &node_count, &edges, &edge_count, 0);

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
   /* Stack reservation is rooted only at actual language entry paths. main is
      tail-entered by startup, so its first function owns no JSR return address;
      runtime initializer roots are called and therefore retain their first slot. */
   for (i = 0; i < node_count; ++i) {
      const char *display = display_function_symbol(nodes[i].name);
      int depth;
      int weighted_depth;
      int main_root = !strcmp(display, "main");
      int init_root = symbol_is_init_function(display);

      if (!main_root && !init_root)
         continue;
      depth = call_graph_longest_depth_visit((int)i, edges, edge_count, depth_memo);
      weighted_depth = call_graph_longest_weighted_depth_visit(
         (int)i, edges, edge_count, node_banks, weighted_depth_memo);
      if (main_root && tail_main) {
         if (depth > 0)
            depth--;
         if (weighted_depth > 0)
            weighted_depth--;
      }
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
                                     &edges, &edge_count, 0);
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
            fprintf(stderr, "  instantiation: %s\n", contract->invoke);
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
                                               size_t init_count,
                                               int full_startup)
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

   /* depth/weighted_depth already count active hardware return addresses from
      the actual startup roots: main contributes no entry slot because startup
      tail-jumps to it, while a runtime initializer contributes its real JSR.
      A cross-bank edge contributes one additional two-byte return address for
      the JSR inside the common trampoline entry. The stock startup also
      preserves its two-byte init-table cursor while an init function runs.
      Full generic startup also has a real two-byte transient stack requirement
      during table-driven initialization. callstack_extra reserves a configuration-declared
      number of additional top-of-RAM bytes for stack use hidden inside included
      or separately assembled routines. */
   if (weighted_depth < depth)
      weighted_depth = depth;
   bytes = (uint32_t)weighted_depth * 2u;
   /* Full startup has a real two-byte transient hardware-stack requirement
      while copying/zeroing through generic pointers.  This replaces the old
      accidental coverage supplied by main's impossible JSR return slot. */
   if (full_startup)
      bytes += 2u;
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
   if (layout->copy_table_size)
      add_global(layout, "__copy_table", layout->copy_table_addr, O26_SEG_ABS, "<linker>");
   if (layout->zero_table_size)
      add_global(layout, "__zero_table", layout->zero_table_addr, O26_SEG_ABS, "<linker>");
   if (layout->init_table_size)
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

//! @brief Return whether one compiler-owned layout belongs to a named object symbol.
static int phase_layout_matches_symbol(const object_layout_t *lay, const char *symbol)
{
   const char *marker;

   if (!lay || !lay->name || !symbol || !*symbol)
      return 0;
   marker = strstr(lay->name, ".__vcsc_object$");
   if (!marker)
      return 0;
   marker += sizeof(".__vcsc_object$") - 1;
   return strcmp(marker, symbol) == 0;
}

//! @brief Find a phase-use target layout, preferring the metadata-owning object.
static object_layout_t *find_phase_use_layout(input_set_t *in,
                                              object_file_t *source,
                                              const char *symbol)
{
   size_t i, j;

   if (!in || !symbol || !*symbol)
      return NULL;
   if (source) {
      for (j = 0; j < source->layout_count; ++j) {
         if (phase_layout_matches_symbol(&source->layouts[j], symbol))
            return &source->layouts[j];
      }
   }
   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      if (obj == source)
         continue;
      for (j = 0; j < obj->layout_count; ++j) {
         if (phase_layout_matches_symbol(&obj->layouts[j], symbol))
            return &obj->layouts[j];
      }
   }
   return NULL;
}

//! @brief Apply explicit eligibility for writable storage that may be reused outside its inferred phase lifetime.
static void apply_phase_workspace_metadata(input_set_t *in)
{
   size_t i, j;

   if (!in)
      return;
   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->export_count; ++j) {
         const char *symbol;
         object_layout_t *lay;

         if (!phase_workspace_metadata_parse(obj->exports[j].name, &symbol))
            continue;
         lay = find_phase_use_layout(in, obj, symbol);
         if (lay)
            lay->phase_overlay_eligible = 1;
      }
   }
}

//! @brief Expand phase accesses to the conservative contiguous lifetime interval they span.
static uint8_t phase_mask_interval_closure(uint8_t mask)
{
   int lo = -1;
   int hi = -1;
   int bit;

   mask &= 0x0Fu;
   for (bit = 0; bit < 4; ++bit) {
      if (mask & (1u << bit)) {
         if (lo < 0)
            lo = bit;
         hi = bit;
      }
   }
   if (lo < 0)
      return 0;
   mask = 0;
   for (bit = lo; bit <= hi; ++bit)
      mask |= (uint8_t)(1u << bit);
   return mask;
}

//! @brief Accumulate compiler-emitted frame-phase uses onto writable object layouts.
static void apply_phase_use_metadata(input_set_t *in)
{
   size_t i, j;

   if (!in)
      return;
   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->export_count; ++j) {
         uint8_t mask;
         const char *symbol;
         object_layout_t *lay;

         if (!phase_use_metadata_parse(obj->exports[j].name, &mask, &symbol))
            continue;
         lay = find_phase_use_layout(in, obj, symbol);
         if (!lay)
            continue;
         lay->phase_use_seen = 1;
         if (mask == 0) {
            lay->phase_unscoped_use = 1;
            lay->phase_mask = 0;
         }
         else if (!lay->phase_unscoped_use) {
            lay->phase_mask |= mask;
         }
      }
   }
   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->layout_count; ++j) {
         object_layout_t *lay = &obj->layouts[j];
         if (lay->phase_use_seen && !lay->phase_unscoped_use)
            lay->phase_mask = phase_mask_interval_closure(lay->phase_mask);
      }
   }
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
          (branch->page_policy == BRANCH_PAGE_CROSS && !crosses)) {
         return 0;
      }
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
//! @brief Round upward to one power-of-two alignment residue.
static uint32_t align_up_phase_u32(uint32_t value, uint16_t alignment,
                                   uint16_t phase)
{
   uint32_t mask;
   uint32_t residue;
   uint32_t delta;

   if (alignment <= 1)
      return value;
   mask = (uint32_t)alignment - 1u;
   residue = value & mask;
   delta = ((uint32_t)phase - residue) & mask;
   return value + delta;
}

//! @brief Return the required placement phase for this exact component alignment.
static uint16_t component_alignment_phase(const object_layout_t *constraints,
                                          uint16_t alignment)
{
   if (constraints && constraints->component_alignment == alignment && alignment > 1)
      return constraints->component_phase;
   return 0;
}

//! @brief Return whether all hard page constraints for one object hold at an address.
static int object_page_constraints_hold(const linker_config_t *cfg,
                                        const object_layout_t *lay, uint32_t addr)
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
   for (size_t i = 0; i < lay->read_hazard_constraint_count; ++i) {
      const read_hazard_constraint_t *constraint = &lay->read_hazard_constraints[i];
      uint16_t operand = (uint16_t)(addr + constraint->operand_delta);
      if (nmos6502_operand_read_hazard_range(cfg, constraint->opcode, operand,
                                             0, 255, NULL))
         return 0;
   }
   return 1;
}

//! @brief Consume the earliest hole satisfying alignment and page constraints.
static int cursor_take_hole(memory_cursor_t *cursor, const linker_config_t *cfg,
                            uint16_t size, uint16_t alignment, uint16_t phase,
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
      uint32_t addr = align_up_phase_u32(hole.start, alignment, phase);

      while (addr + size <= hole.end && addr <= 0xffffu) {
         if (object_page_constraints_hold(cfg, constraints, addr) &&
             (!prefer_whole_page || range_fits_one_page(addr, size)))
            break;
         addr = align_up_phase_u32(addr + 1u, alignment, phase);
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
      (constraints->flags & (O26_LAYOUT_PAGE_CONTAINED | O26_LAYOUT_INDEX_RANGE) ||
       constraints->read_hazard_constraint_count != 0);
   uint16_t phase = component_alignment_phase(constraints, alignment);

   if (size == 0)
      return cursor->cur;
   if (hard_page && size > 0x0100u) {
      fprintf(stderr, "vcsc-ld: hard page containment impossible for %s from %s: size $%04X exceeds 256 bytes\n",
              what, origin, size);
      exit(1);
   }
   if ((wants_page || has_hard_constraint) &&
       cursor_take_hole(cursor, cfg, size, alignment, phase, wants_page, constraints, &hole_addr))
      return hole_addr;

   addr = align_up_phase_u32(cursor->cur, alignment, phase);
   while (!object_page_constraints_hold(cfg, constraints, addr)) {
      addr = align_up_phase_u32(addr + 1u, alignment, phase);
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

//! @brief Simulate one ROM allocation without emitting diagnostics or terminating.
//!
//! Automatic multi-region placement uses this dry-run allocator to test the exact
//! page/alignment behavior that the final layout pass will apply.  Keeping the
//! simulation on the same cursor/hole model prevents raw-byte bank budgets from
//! accepting a placement that later overflows because of unavoidable low-byte
//! phase or page constraints.
static int simulate_alloc_from_region_policy(layout_t *layout,
   const linker_config_t *cfg, const char *mem_name, uint16_t size,
   uint16_t alignment, const object_layout_t *constraints)
{
   memory_cursor_t *cursor = ensure_cursor(layout, cfg, mem_name);
   uint16_t hole_addr;
   uint32_t addr;
   uint32_t end;
   int wants_page = size > 0 && size <= 0x0100u;
   int hard_page = constraints &&
      (constraints->flags & O26_LAYOUT_PAGE_CONTAINED);
   int has_hard_constraint = constraints &&
      (constraints->flags & (O26_LAYOUT_PAGE_CONTAINED | O26_LAYOUT_INDEX_RANGE) ||
       constraints->read_hazard_constraint_count != 0);
   uint16_t phase = component_alignment_phase(constraints, alignment);

   if (size == 0)
      return 1;
   if (hard_page && size > 0x0100u)
      return 0;
   if ((wants_page || has_hard_constraint) &&
       cursor_take_hole(cursor, cfg, size, alignment, phase, wants_page,
                        constraints, &hole_addr))
      return 1;

   addr = align_up_phase_u32(cursor->cur, alignment, phase);
   while (!object_page_constraints_hold(cfg, constraints, addr)) {
      addr = align_up_phase_u32(addr + 1u, alignment, phase);
      if (constraints && constraints->segid == O26_SEG_ZP && addr >= 0x0100u)
         return 0;
   }
   end = addr + size;
   if (end > 0x10000u || end > cursor->end ||
       (str_ieq(mem_name, "ROM") && end > 0xFFFAu))
      return 0;
   cursor_add_hole(cursor, cursor->cur, addr);
   cursor->cur = (uint16_t)end;
   return 1;
}

//! @brief Simulate branch-aware ROM placement using the production scoring rules.
static int simulate_alloc_code_branch_aware(layout_t *layout,
   const linker_config_t *cfg, const char *mem_name, const object_file_t *obj,
   const object_layout_t *lay, uint16_t alignment)
{
   memory_cursor_t *cursor;
   uint32_t limit;
   uint32_t addr;
   uint32_t tail_last;
   uint32_t step = alignment > 1 ? alignment : 1;
   uint16_t phase = component_alignment_phase(lay, alignment);
   size_t i;
   int found = 0;
   int best_from_hole = 0;
   size_t best_hole = 0;
   uint32_t best_addr = 0;
   uint32_t best_growth = 0;
   size_t best_crossings = 0;
   int best_page_penalty = 0;

   if (!layout_has_branches(obj, lay))
      return simulate_alloc_from_region_policy(layout, cfg, mem_name, lay->size,
                                               alignment, lay);

   cursor = ensure_cursor(layout, cfg, mem_name);
   if (lay->size == 0)
      return 1;
   if ((lay->flags & O26_LAYOUT_PAGE_CONTAINED) && lay->size > 0x0100u)
      return 0;
   limit = cursor->end;
   if (str_ieq(mem_name, "ROM") && limit > 0xFFFAu)
      limit = 0xFFFAu;

#define CONSIDER_SIM_BRANCH_CANDIDATE(candidate_, growth_, from_hole_, hole_) do { \
      uint32_t candidate_value__ = (candidate_); \
      size_t crossings__; \
      int page_penalty__; \
      uint32_t growth_value__ = (growth_); \
      if (!layout_branch_contracts_hold_at(obj, lay, (uint16_t)candidate_value__)) \
         break; \
      crossings__ = layout_branch_crossings_at(obj, lay, (uint16_t)candidate_value__); \
      page_penalty__ = range_fits_one_page(candidate_value__, lay->size) ? 0 : 1; \
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

   for (i = 0; i < cursor->hole_count; ++i) {
      const memory_hole_t hole = cursor->holes[i];
      addr = align_up_phase_u32(hole.start, alignment, phase);
      while (addr + lay->size <= hole.end && addr + lay->size <= limit) {
         if (object_page_constraints_hold(cfg, lay, addr))
            CONSIDER_SIM_BRANCH_CANDIDATE(addr, 0, 1, i);
         if (addr > 0xffffu - step)
            break;
         addr += step;
      }
   }

   addr = align_up_phase_u32(cursor->cur, alignment, phase);
   tail_last = (uint32_t)cursor->cur + 0xffu;
   if (tail_last > 0xffffu)
      tail_last = 0xffffu;
   while (addr <= tail_last && addr + lay->size <= limit) {
      if (object_page_constraints_hold(cfg, lay, addr))
         CONSIDER_SIM_BRANCH_CANDIDATE(addr, addr + lay->size - cursor->cur, 0, 0);
      if (addr > 0xffffu - step)
         break;
      addr += step;
   }

#undef CONSIDER_SIM_BRANCH_CANDIDATE

   if (!found)
      return 0;
   if (best_from_hole)
      cursor_consume_hole_range(cursor, best_hole, best_addr, lay->size);
   else {
      cursor_add_hole(cursor, cursor->cur, best_addr);
      cursor->cur = (uint16_t)(best_addr + lay->size);
   }
   return 1;
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
   uint16_t phase = component_alignment_phase(lay, alignment);
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
      addr = align_up_phase_u32(hole.start, alignment, phase);
      while (addr + lay->size <= hole.end && addr + lay->size <= limit) {
         if (object_page_constraints_hold(cfg, lay, addr))
            CONSIDER_BRANCH_CANDIDATE(addr, 0, 1, i);
         if (addr > 0xffffu - step)
            break;
         addr += step;
      }
   }

   /* At the high-water mark, one 256-byte sweep covers every useful low-byte
      placement. A farther candidate repeats an already tested branch phase
      while growing the image by at least one unnecessary page. */
   addr = align_up_phase_u32(cursor->cur, alignment, phase);
   tail_last = (uint32_t)cursor->cur + 0xffu;
   if (tail_last > 0xffffu)
      tail_last = 0xffffu;
   while (addr <= tail_last && addr + lay->size <= limit) {
      if (object_page_constraints_hold(cfg, lay, addr))
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
static void add_copy_record(layout_t *layout, const char *name, uint16_t load_addr,
                            uint16_t read_addr, uint16_t write_addr, uint16_t size)
{
   if (size == 0)
      return;
   layout->copy_records = (copy_record_t *)xrealloc(layout->copy_records,
      (layout->copy_record_count + 1) * sizeof(*layout->copy_records));
   layout->copy_records[layout->copy_record_count].name = xstrdup(name ? name : "DATA");
   layout->copy_records[layout->copy_record_count].load_addr = load_addr;
   layout->copy_records[layout->copy_record_count].read_addr = read_addr;
   layout->copy_records[layout->copy_record_count].write_addr = write_addr;
   layout->copy_records[layout->copy_record_count].size = size;
   layout->copy_record_count++;
}

//! @brief Add zero record to linker layout and image writer state, growing storage or preserving uniqueness as needed.
static void add_zero_record(layout_t *layout, const char *name,
                            uint16_t read_addr, uint16_t write_addr, uint16_t size)
{
   if (size == 0)
      return;
   layout->zero_records = (zero_record_t *)xrealloc(layout->zero_records,
      (layout->zero_record_count + 1) * sizeof(*layout->zero_records));
   layout->zero_records[layout->zero_record_count].name = xstrdup(name ? name : "BSS");
   layout->zero_records[layout->zero_record_count].read_addr = read_addr;
   layout->zero_records[layout->zero_record_count].write_addr = write_addr;
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

   if (!cfg || (!cfg->cartridge_banked && !c26_topology_is_fe(cfg)))
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

//! @brief Decode one QXX-escaped metadata field emitted by the compiler.
static char *replica_meta_decode(const char *text, size_t length)
{
   char *decoded = (char *)xmalloc(length + 1);
   size_t out = 0;
   size_t i;

   for (i = 0; i < length; ++i) {
      if (text[i] == 'Q' && i + 2 < length &&
          isxdigit((unsigned char)text[i + 1]) &&
          isxdigit((unsigned char)text[i + 2])) {
         char hex[3];
         hex[0] = text[i + 1];
         hex[1] = text[i + 2];
         hex[2] = '\0';
         decoded[out++] = (char)strtoul(hex, NULL, 16);
         i += 2;
      }
      else {
         decoded[out++] = text[i];
      }
   }
   decoded[out] = '\0';
   return decoded;
}


//! @brief Parse one compiler-emitted return-local coalescing record.
static int return_coalesce_metadata_parse(const char *name,
                                          char **function_out,
                                          char **local_out,
                                          char **return_out,
                                          char **region_out,
                                          int *size_out)
{
   const char *p;
   const char *sep1;
   const char *sep2;
   const char *sep3;
   const char *sep4;
   char *end = NULL;
   long size;

   if (!return_coalesce_metadata_has_prefix(name))
      return 0;
   p = name + sizeof(RETURN_COALESCE_META_PREFIX) - 1;
   sep1 = strchr(p, '$');
   sep2 = sep1 ? strchr(sep1 + 1, '$') : NULL;
   sep3 = sep2 ? strchr(sep2 + 1, '$') : NULL;
   sep4 = sep3 ? strchr(sep3 + 1, '$') : NULL;
   if (!sep1 || sep1 == p || !sep2 || sep2 == sep1 + 1 ||
       !sep3 || sep3 == sep2 + 1 || !sep4 || !sep4[1] ||
       strchr(sep4 + 1, '$'))
      return 0;
   size = strtol(sep4 + 1, &end, 10);
   if (!end || *end || size <= 0 || size > 0x7fff)
      return 0;
   if (function_out)
      *function_out = replica_meta_decode(p, (size_t)(sep1 - p));
   if (local_out)
      *local_out = replica_meta_decode(sep1 + 1, (size_t)(sep2 - sep1 - 1));
   if (return_out)
      *return_out = replica_meta_decode(sep2 + 1, (size_t)(sep3 - sep2 - 1));
   if (region_out)
      *region_out = replica_meta_decode(sep3 + 1, (size_t)(sep4 - sep3 - 1));
   if (size_out)
      *size_out = (int)size;
   return 1;
}

//! @brief Parse one compiler-emitted immutable ROM-replication record.
static int replica_metadata_parse(const char *name, char *kind_out,
                                  char **symbol_out, char **region_out)
{
   const char *p;
   const char *sep;
   char kind;

   if (!replica_metadata_has_prefix(name))
      return 0;
   p = name + sizeof(REPLICA_META_PREFIX) - 1;
   kind = *p++;
   if ((kind != 'F' && kind != 'O') || *p++ != '$')
      return 0;
   sep = strchr(p, '$');
   if (!sep || sep == p || !sep[1] || strchr(sep + 1, '$'))
      return 0;
   if (kind_out)
      *kind_out = kind;
   if (symbol_out)
      *symbol_out = replica_meta_decode(p, (size_t)(sep - p));
   if (region_out)
      *region_out = replica_meta_decode(sep + 1, strlen(sep + 1));
   return 1;
}

//! @brief Compare one pair of replica region names for deterministic emission.
static int compare_replica_regions(const void *a, const void *b)
{
   const char *const *aname = (const char *const *)a;
   const char *const *bname = (const char *const *)b;
   return strcmp(*aname, *bname);
}

//! @brief Find one replication group owned by one selected input object.
static replica_group_t *find_replica_group_in_object(input_set_t *in,
                                                      object_file_t *obj,
                                                      char kind,
                                                      const char *symbol)
{
   size_t i;
   for (i = 0; i < in->replica_count; ++i) {
      replica_group_t *group = &in->replicas[i];
      if (group->obj == obj && group->kind == kind &&
          strcmp(group->symbol, symbol) == 0)
         return group;
   }
   return NULL;
}

//! @brief Find an externally visible replication group by logical symbol.
static const replica_group_t *find_replica_group_by_symbol(const input_set_t *in,
                                                            const char *symbol)
{
   char *weak;
   size_t pass;
   size_t i;

   if (!in || !symbol)
      return NULL;
   weak = make_weak_name(symbol);
   for (pass = 0; pass < 2; ++pass) {
      const char *wanted = pass == 0 ? symbol : weak;
      for (i = 0; i < in->replica_count; ++i) {
         const replica_group_t *group = &in->replicas[i];
         if (group->externally_visible && strcmp(group->symbol, wanted) == 0) {
            free(weak);
            return group;
         }
      }
   }
   free(weak);
   return NULL;
}

//! @brief Find a replication group containing one exact object layout.
static const replica_group_t *find_replica_group_by_layout(const input_set_t *in,
                                                            const object_file_t *obj,
                                                            uint16_t layout_index,
                                                            size_t *copy_index_out)
{
   size_t i, j;
   if (copy_index_out)
      *copy_index_out = 0;
   if (!in || !obj)
      return NULL;
   for (i = 0; i < in->replica_count; ++i) {
      const replica_group_t *group = &in->replicas[i];
      if (group->obj != obj)
         continue;
      for (j = 0; j < group->copy_count; ++j) {
         if (group->layout_indices[j] == layout_index) {
            if (copy_index_out)
               *copy_index_out = j;
            return group;
         }
      }
   }
   return NULL;
}

//! @brief Find the copy index for one source region name.
static int replica_copy_index_for_region(const replica_group_t *group,
                                         const char *region)
{
   size_t i;
   if (!group || !region)
      return -1;
   for (i = 0; i < group->copy_count; ++i) {
      if (strcmp(group->regions[i], region) == 0)
         return (int)i;
   }
   return -1;
}

//! @brief Find the logical cartridge bank containing one replica copy.
static const cartridge_bank_t *replica_copy_bank(const linker_config_t *cfg,
                                                  const replica_group_t *group,
                                                  size_t copy_index)
{
   const memory_region_t *memory;
   if (!cfg || !group || copy_index >= group->copy_count)
      return NULL;
   memory = find_memory(cfg, group->regions[copy_index]);
   if (!memory || !memory->bank_name[0])
      return NULL;
   return find_cartridge_bank(cfg, memory->bank_name);
}

//! @brief Find the copy whose declared region belongs to one logical bank.
static int replica_copy_index_for_bank(const linker_config_t *cfg,
                                       const replica_group_t *group,
                                       const cartridge_bank_t *bank)
{
   size_t i;
   if (!cfg || !group || !bank)
      return -1;
   for (i = 0; i < group->copy_count; ++i) {
      if (replica_copy_bank(cfg, group, i) == bank)
         return (int)i;
   }
   return -1;
}

//! @brief Return the bit mask of banks containing declared copies.
static uint64_t replica_bank_mask(const linker_config_t *cfg,
                                  const replica_group_t *group)
{
   uint64_t mask = 0;
   size_t i, j;
   if (!cfg || !group || cfg->bank_count > 64)
      return 0;
   for (i = 0; i < group->copy_count; ++i) {
      const cartridge_bank_t *bank = replica_copy_bank(cfg, group, i);
      if (!bank)
         continue;
      for (j = 0; j < cfg->bank_count; ++j) {
         if (&cfg->banks[j] == bank) {
            mask |= UINT64_C(1) << j;
            break;
         }
      }
   }
   return mask;
}

//! @brief Return the layout index for an exact layout pointer.
static uint16_t replica_layout_index(const object_file_t *obj,
                                     const object_layout_t *layout)
{
   ptrdiff_t index;
   if (!obj || !layout)
      return UINT16_MAX;
   index = layout - obj->layouts;
   if (index < 0 || (size_t)index >= obj->layout_count || index > UINT16_MAX)
      return UINT16_MAX;
   return (uint16_t)index;
}

//! @brief Locate the original compiler-emitted private layout for one group.
static int locate_replica_original_layout(replica_group_t *group)
{
   object_file_t *obj = group->obj;
   const char *marker = group->kind == 'F'
      ? ".__vcsc_function$" : ".__vcsc_object$";
   size_t marker_len = strlen(marker);
   size_t i;

   group->externally_visible = 0;
   group->symbol_offset = 0;
   for (i = 0; i < obj->export_count; ++i) {
      const symbol_t *sym = &obj->exports[i];
      const object_layout_t *layout;
      if (strcmp(sym->name, group->symbol) != 0 || sym->segid != O26_SEG_TEXT)
         continue;
      layout = find_layout_for_value(obj, sym->segid, sym->value);
      if (!layout)
         continue;
      group->original_layout_index = replica_layout_index(obj, layout);
      group->symbol_offset = (uint16_t)(sym->value - layout->packed_base);
      group->externally_visible = 1;
      return 1;
   }
   for (i = 0; i < obj->layout_count; ++i) {
      const object_layout_t *layout = &obj->layouts[i];
      const char *suffix = strstr(layout->name, marker);
      if (suffix && strcmp(suffix + marker_len, group->symbol) == 0) {
         group->original_layout_index = (uint16_t)i;
         return 1;
      }
   }
   return 0;
}

//! @brief Construct the private layout name for one physical replica.
static char *replica_layout_name(const object_layout_t *original,
                                 const char *region)
{
   const char *marker;
   const char *dot;
   size_t root_len;
   size_t need;
   char *name;

   marker = strstr(original->name, ".__vcsc_function$");
   if (!marker)
      marker = strstr(original->name, ".__vcsc_object$");
   if (!marker)
      marker = strstr(original->name, ".__vcsc_page$");
   if (!marker)
      return NULL;
   dot = strchr(original->name, '.');
   root_len = dot ? (size_t)(dot - original->name) : (size_t)(marker - original->name);
   need = root_len + 1 + strlen(region) + strlen(marker) + 1;
   name = (char *)xmalloc(need);
   snprintf(name, need, "%.*s.%s%s", (int)root_len, original->name, region, marker);
   return name;
}

//! @brief Return the next nonoverlapping packed base for one object segment.
static uint16_t replica_next_packed_base(const object_file_t *obj, uint8_t segid,
                                         uint16_t size)
{
   uint32_t end = 0;
   size_t i;
   for (i = 0; i < obj->layout_count; ++i) {
      const object_layout_t *layout = &obj->layouts[i];
      uint32_t candidate;
      if (layout->segid != segid)
         continue;
      candidate = (uint32_t)layout->packed_base + layout->size;
      if (candidate > end)
         end = candidate;
   }
   if (end + size > 0x10000u) {
      fprintf(stderr, "vcsc-ld: replicated layouts exceed the 16-bit packed object range in %s\n",
              obj->origin);
      exit(1);
   }
   return (uint16_t)end;
}

//! @brief Append one physical byte/layout copy and return its new layout index.
static uint16_t append_replica_layout(object_file_t *obj,
                                      uint16_t original_index,
                                      const char *region)
{
   object_layout_t original = obj->layouts[original_index];
   object_layout_t copy = original;
   o26_segment_t *segment;
   size_t new_image_base;
   char *new_name;

   if (original.image_segid == O26_SEG_TEXT)
      segment = &obj->text;
   else if (original.image_segid == O26_SEG_DATA)
      segment = &obj->data;
   else {
      fprintf(stderr, "vcsc-ld: replicated layout '%s' in %s has no ROM image\n",
              original.name, obj->origin);
      exit(1);
   }
   if ((uint32_t)original.image_base + original.size > segment->length) {
      fprintf(stderr, "vcsc-ld: replicated layout '%s' exceeds its packed image in %s\n",
              original.name, obj->origin);
      exit(1);
   }
   new_image_base = segment->length;
   if (new_image_base + original.size > 0x10000u) {
      fprintf(stderr, "vcsc-ld: replicated image exceeds the 16-bit object range in %s\n",
              obj->origin);
      exit(1);
   }
   segment->data = (uint8_t *)xrealloc(segment->data,
      new_image_base + original.size);
   memmove(segment->data + new_image_base,
           segment->data + original.image_base, original.size);
   segment->length = new_image_base + original.size;

   new_name = replica_layout_name(&original, region);
   if (!new_name) {
      fprintf(stderr, "vcsc-ld: cannot replicate non-private layout '%s' in %s\n",
              original.name, obj->origin);
      exit(1);
   }
   copy.name = new_name;
   copy.image_base = (uint16_t)new_image_base;
   copy.packed_base = replica_next_packed_base(obj, original.segid, original.size);
   copy.load_addr = 0;
   copy.run_addr = 0;
   copy.placement_memory[0] = '\0';
   copy.placement_bank[0] = '\0';
   copy.placement_component = 0;
   copy.placement_mode = BANK_PLACEMENT_NONE;
   copy.placement_component_pinned = 0;
   copy.placement_component_bytes = 0;
   copy.placement_cut_weight = 0;

   obj->layouts = (object_layout_t *)xrealloc(obj->layouts,
      (obj->layout_count + 1) * sizeof(*obj->layouts));
   obj->layouts[obj->layout_count] = copy;
   return (uint16_t)obj->layout_count++;
}

//! @brief Read the packed affine value carried by one relocation.
static uint16_t replica_reloc_word(const o26_segment_t *segment,
                                   const reloc_t *reloc)
{
   switch (reloc->type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD)) {
      case O26_RTYPE_WORD:
         return (uint16_t)(segment->data[reloc->offset] |
                           (segment->data[reloc->offset + 1] << 8));
      case O26_RTYPE_LOW:
         return (uint16_t)(segment->data[reloc->offset] |
                           ((reloc->has_aux_low ? reloc->aux_low : 0) << 8));
      case O26_RTYPE_HIGH:
         return (uint16_t)((reloc->has_aux_low ? reloc->aux_low : 0) |
                           (segment->data[reloc->offset] << 8));
   }
   return segment->data[reloc->offset];
}

//! @brief Rewrite one copied relocation's packed affine target.
static void replica_set_reloc_word(o26_segment_t *segment, reloc_t *reloc,
                                   uint16_t value)
{
   switch (reloc->type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD)) {
      case O26_RTYPE_WORD:
         segment->data[reloc->offset] = (uint8_t)(value & 0xffu);
         segment->data[reloc->offset + 1] = (uint8_t)(value >> 8);
         break;
      case O26_RTYPE_LOW:
         segment->data[reloc->offset] = (uint8_t)(value & 0xffu);
         reloc->aux_low = (uint8_t)(value >> 8);
         reloc->has_aux_low = 1;
         break;
      case O26_RTYPE_HIGH:
         reloc->aux_low = (uint8_t)(value & 0xffu);
         reloc->has_aux_low = 1;
         segment->data[reloc->offset] = (uint8_t)(value >> 8);
         break;
   }
}

//! @brief Duplicate all relocations originating inside one replicated layout.
static void duplicate_replica_relocations(input_set_t *in,
                                          replica_group_t *source_group,
                                          size_t source_copy,
                                          size_t original_text_reloc_count,
                                          size_t original_data_reloc_count)
{
   object_file_t *obj = source_group->obj;
   const object_layout_t *source_original =
      &obj->layouts[source_group->original_layout_index];
   const object_layout_t *source_copy_layout =
      &obj->layouts[source_group->layout_indices[source_copy]];
   o26_segment_t *segment = source_original->image_segid == O26_SEG_TEXT
      ? &obj->text : &obj->data;
   size_t original_reloc_count = source_original->image_segid == O26_SEG_TEXT
      ? original_text_reloc_count : original_data_reloc_count;
   uint32_t image_delta = (uint32_t)source_copy_layout->image_base -
                          source_original->image_base;
   size_t i;

   for (i = 0; i < original_reloc_count; ++i) {
      const reloc_t *original_reloc = &segment->relocs[i];
      reloc_t copy;
      const replica_group_t *target_group = NULL;
      uint16_t target_original_index = UINT16_MAX;
      int target_copy = -1;
      uint16_t packed_delta = 0;
      uint16_t word;

      if (original_reloc->offset < source_original->image_base ||
          original_reloc->offset >= (uint32_t)source_original->image_base +
                                    source_original->size)
         continue;
      copy = *original_reloc;
      copy.offset += image_delta;
      word = replica_reloc_word(segment, original_reloc);

      if (copy.has_layout_index) {
         target_original_index = copy.layout_index;
         target_group = find_replica_group_by_layout(in, obj,
            target_original_index, NULL);
      }
      else if (copy.segid == O26_SEG_TEXT) {
         const object_layout_t *target_layout =
            find_layout_for_value(obj, copy.segid, word);
         if (target_layout) {
            target_original_index = replica_layout_index(obj, target_layout);
            target_group = find_replica_group_by_layout(in, obj,
               target_original_index, NULL);
         }
      }
      if (target_group) {
         target_copy = replica_copy_index_for_region(target_group,
            source_group->regions[source_copy]);
         if (target_copy >= 0) {
            const object_layout_t *target_original =
               &obj->layouts[target_group->original_layout_index];
            const object_layout_t *target_copy_layout =
               &obj->layouts[target_group->layout_indices[target_copy]];
            packed_delta = (uint16_t)(target_copy_layout->packed_base -
                                      target_original->packed_base);
            if (copy.has_layout_index)
               copy.layout_index = target_group->layout_indices[target_copy];
            word = (uint16_t)(word + packed_delta);
         }
      }

      segment->relocs = (reloc_t *)xrealloc(segment->relocs,
         (segment->reloc_count + 1) * sizeof(*segment->relocs));
      segment->relocs[segment->reloc_count] = copy;
      replica_set_reloc_word(segment, &segment->relocs[segment->reloc_count], word);
      segment->reloc_count++;
   }
}

//! @brief Duplicate retained branch metadata originating inside one replica.
static void duplicate_replica_branches(input_set_t *in,
                                       replica_group_t *source_group,
                                       size_t source_copy,
                                       size_t original_branch_count)
{
   object_file_t *obj = source_group->obj;
   const object_layout_t *source_original =
      &obj->layouts[source_group->original_layout_index];
   const object_layout_t *source_copy_layout =
      &obj->layouts[source_group->layout_indices[source_copy]];
   uint16_t source_delta = (uint16_t)(source_copy_layout->packed_base -
                                      source_original->packed_base);
   size_t i;

   for (i = 0; i < original_branch_count; ++i) {
      branch_t copy = obj->branches[i];
      const object_layout_t *target_layout;
      const replica_group_t *target_group;
      uint16_t target_index;
      int target_copy;

      if (copy.segid != source_original->segid ||
          copy.source < source_original->packed_base ||
          copy.source >= (uint32_t)source_original->packed_base +
                         source_original->size)
         continue;
      copy.source = (uint16_t)(copy.source + source_delta);
      target_layout = find_layout_for_value(obj, copy.segid, copy.target);
      target_index = replica_layout_index(obj, target_layout);
      target_group = target_index == UINT16_MAX ? NULL :
         find_replica_group_by_layout(in, obj, target_index, NULL);
      if (target_group) {
         target_copy = replica_copy_index_for_region(target_group,
            source_group->regions[source_copy]);
         if (target_copy >= 0) {
            const object_layout_t *target_original =
               &obj->layouts[target_group->original_layout_index];
            const object_layout_t *target_copy_layout =
               &obj->layouts[target_group->layout_indices[target_copy]];
            copy.target = (uint16_t)(copy.target +
               target_copy_layout->packed_base - target_original->packed_base);
         }
      }
      else if (target_layout == source_original) {
         copy.target = (uint16_t)(copy.target + source_delta);
      }
      obj->branches = (branch_t *)xrealloc(obj->branches,
         (obj->branch_count + 1) * sizeof(*obj->branches));
      obj->branches[obj->branch_count++] = copy;
   }
}

//! @brief Parse replication metadata and materialize independent packed copies.
static void prepare_replicated_rom(const linker_config_t *cfg, input_set_t *in)
{
   size_t *original_text_reloc_counts;
   size_t *original_data_reloc_counts;
   size_t *original_branch_counts;
   size_t i, j;

   if (!cfg || !in)
      return;
   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->export_count; ++j) {
         char kind = 0;
         char *symbol = NULL;
         char *region = NULL;
         replica_group_t *group;
         if (!replica_metadata_has_prefix(obj->exports[j].name))
            continue;
         if (!replica_metadata_parse(obj->exports[j].name, &kind,
                                     &symbol, &region)) {
            fprintf(stderr, "vcsc-ld: malformed replication metadata symbol '%s' in %s\n",
                    obj->exports[j].name, obj->origin);
            exit(1);
         }
         group = find_replica_group_in_object(in, obj, kind, symbol);
         if (!group) {
            in->replicas = (replica_group_t *)xrealloc(in->replicas,
               (in->replica_count + 1) * sizeof(*in->replicas));
            group = &in->replicas[in->replica_count++];
            memset(group, 0, sizeof(*group));
            group->kind = kind;
            group->symbol = symbol;
            group->obj = obj;
            symbol = NULL;
         }
         for (size_t r = 0; r < group->copy_count; ++r) {
            if (strcmp(group->regions[r], region) == 0) {
               fprintf(stderr,
                       "vcsc-ld: duplicate replication region '%s' for %s '%s' in %s\n",
                       region, kind == 'F' ? "function" : "object",
                       group->symbol, obj->origin);
               exit(1);
            }
         }
         group->regions = (char **)xrealloc(group->regions,
            (group->copy_count + 1) * sizeof(*group->regions));
         group->regions[group->copy_count++] = region;
         free(symbol);
      }
   }
   if (in->replica_count == 0)
      return;
   if (!cfg->cartridge_banked) {
      fprintf(stderr, "vcsc-ld: replicated ROM objects/functions require a banked cartridge profile\n");
      exit(1);
   }
   if (cfg->bank_count > 64) {
      fprintf(stderr, "vcsc-ld: replicated ROM placement supports at most 64 logical banks\n");
      exit(1);
   }

   for (i = 0; i < in->replica_count; ++i) {
      replica_group_t *group = &in->replicas[i];
      if (group->copy_count < 2) {
         fprintf(stderr, "vcsc-ld: replication metadata for '%s' names fewer than two regions\n",
                 group->symbol);
         exit(1);
      }
      qsort(group->regions, group->copy_count, sizeof(*group->regions),
            compare_replica_regions);
      for (j = 0; j < group->copy_count; ++j) {
         const memory_region_t *memory = find_memory(cfg, group->regions[j]);
         if (!memory) {
            fprintf(stderr, "vcsc-ld: replicated %s '%s' names unknown MEMORY region '%s'\n",
                    group->kind == 'F' ? "function" : "object",
                    group->symbol, group->regions[j]);
            exit(1);
         }
         if (!str_ieq(memory->type, "ro") || !memory->bank_name[0]) {
            fprintf(stderr,
                    "vcsc-ld: replicated %s '%s' region '%s' must be read-only ROM owned by one cartridge bank\n",
                    group->kind == 'F' ? "function" : "object",
                    group->symbol, group->regions[j]);
            exit(1);
         }
      }
      if (!locate_replica_original_layout(group)) {
         fprintf(stderr, "vcsc-ld: cannot locate original private layout for replicated %s '%s' in %s\n",
                 group->kind == 'F' ? "function" : "object",
                 group->symbol, group->obj->origin);
         exit(1);
      }
      group->layout_indices = (uint16_t *)xcalloc(group->copy_count,
                                                   sizeof(*group->layout_indices));
      group->layout_indices[0] = group->original_layout_index;
   }

   original_text_reloc_counts = (size_t *)xcalloc(in->object_count,
                                                   sizeof(*original_text_reloc_counts));
   original_data_reloc_counts = (size_t *)xcalloc(in->object_count,
                                                   sizeof(*original_data_reloc_counts));
   original_branch_counts = (size_t *)xcalloc(in->object_count,
                                               sizeof(*original_branch_counts));
   for (i = 0; i < in->object_count; ++i) {
      original_text_reloc_counts[i] = in->objects[i].text.reloc_count;
      original_data_reloc_counts[i] = in->objects[i].data.reloc_count;
      original_branch_counts[i] = in->objects[i].branch_count;
   }

   for (i = 0; i < in->replica_count; ++i) {
      replica_group_t *group = &in->replicas[i];
      for (j = 1; j < group->copy_count; ++j) {
         group->layout_indices[j] = append_replica_layout(group->obj,
            group->original_layout_index, group->regions[j]);
      }
   }
   for (i = 0; i < in->replica_count; ++i) {
      replica_group_t *group = &in->replicas[i];
      size_t object_index = (size_t)(group->obj - in->objects);
      for (j = 1; j < group->copy_count; ++j) {
         duplicate_replica_relocations(in, group, j,
            original_text_reloc_counts[object_index],
            original_data_reloc_counts[object_index]);
         duplicate_replica_branches(in, group, j,
            original_branch_counts[object_index]);
      }
   }

   free(original_text_reloc_counts);
   free(original_data_reloc_counts);
   free(original_branch_counts);
}

typedef struct {
   object_file_t *obj;
   object_layout_t *layout;
   const memory_region_t *configured_memory;
   const cartridge_bank_t *configured_bank;
   const memory_region_t *pin_memory;
   const cartridge_bank_t *pin_bank;
   size_t stable_order;
   uint64_t allowed_bank_mask;
   int parent;
   int rank;
   int directly_pinned;
} bank_placement_item_t;

typedef struct {
   int first;
   int second;
   uint32_t weight;
   uint32_t cycles;
   uint32_t sites;
   uint32_t jsr_sites;
   uint32_t jmp_sites;
} bank_placement_edge_t;

typedef struct {
   int root;
   uint16_t id;
   size_t stable_order;
   uint32_t bytes;
   uint32_t degree;
   uint32_t cycle_degree;
   uint32_t cut_weight;
   const cartridge_bank_t *bank;
   uint64_t allowed_bank_mask;
   int pinned;
   int assigned;
} bank_placement_component_t;

typedef struct {
   const memory_region_t *memory;
   uint32_t capacity;
   uint32_t used;
} bank_placement_budget_t;

typedef struct {
   uint32_t weight;
   uint32_t cycles;
   uint32_t sites;
   uint32_t jsr_sites;
   uint32_t jmp_sites;
} bank_placement_cost_t;

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
   {
      const char *memory_name = component_resolve_memory_name(cfg, lay,
         (rule && rule->load_name[0]) ? rule->load_name : NULL);
      if (!memory_name || !*memory_name)
         return NULL;
      return find_memory(cfg, memory_name);
   }
}

//! @brief Return the logical placement owner of one ROM MEMORY region.
static const char *bank_placement_memory_owner(const memory_region_t *memory)
{
   if (!memory)
      return NULL;
   if (memory->output_bank_name[0])
      return memory->output_bank_name;
   if (memory->bank_name[0])
      return memory->bank_name;
   return NULL;
}

//! @brief Return the logical placement record owning one ROM MEMORY region.
static const cartridge_bank_t *bank_placement_memory_bank(const linker_config_t *cfg,
                                                          const memory_region_t *memory)
{
   const char *owner = bank_placement_memory_owner(memory);
   return owner ? find_cartridge_bank(cfg, owner) : NULL;
}

//! @brief Split a compiler-private layout name into its source segment prefix.
static int bank_placement_private_base(const char *name, char *base, size_t base_size)
{
   static const char *const markers[] = {
      ".__vcsc_function$", ".__vcsc_object$", ".__vcsc_activation$", ".__vcsc_page$", NULL
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
      const char *owner = bank_placement_memory_owner(mem);
      if (!owner || !str_ieq(owner, bank->name) ||
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
                                    uint32_t weight,
                                    uint32_t cycles,
                                    uint8_t control)
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
         (*edges)[i].cycles += cycles;
         (*edges)[i].sites++;
         if (control == O26_RTYPE_CONTROL_JSR)
            (*edges)[i].jsr_sites++;
         else if (control == O26_RTYPE_CONTROL_JMP)
            (*edges)[i].jmp_sites++;
         return;
      }
   }
   *edges = (bank_placement_edge_t *)xrealloc(*edges,
      (*count + 1) * sizeof(**edges));
   (*edges)[*count].first = first;
   (*edges)[*count].second = second;
   (*edges)[*count].weight = weight;
   (*edges)[*count].cycles = cycles;
   (*edges)[*count].sites = 1;
   (*edges)[*count].jsr_sites = control == O26_RTYPE_CONTROL_JSR ? 1u : 0u;
   (*edges)[*count].jmp_sites = control == O26_RTYPE_CONTROL_JMP ? 1u : 0u;
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
   const replica_group_t *replica;
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
      result.replica = find_replica_group_by_symbol(in,
         obj->undefs[reloc->undef_index]);
      result.layout = bank_placement_export_layout(in,
         obj->undefs[reloc->undef_index], &provider, &symbol);
      if (!result.layout && symbol && symbol->segid == O26_SEG_ABS)
         result.fixed_bank = cartridge_bank_for_address(cfg,
            (uint16_t)(symbol->value + current_word));
      return result;
   }
   if (reloc->has_layout_index) {
      if (reloc->layout_index < obj->layout_count &&
          obj->layouts[reloc->layout_index].segid == O26_SEG_TEXT) {
         result.layout = &obj->layouts[reloc->layout_index];
         result.replica = find_replica_group_by_layout(in, obj,
            reloc->layout_index, NULL);
      }
      return result;
   }
   if (reloc->segid == O26_SEG_TEXT) {
      result.layout = find_layout_for_value(obj, reloc->segid, current_word);
      if (result.layout)
         result.replica = find_replica_group_by_layout(in, obj,
            replica_layout_index(obj, result.layout), NULL);
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


//! @brief Return whether one source listing record represents an instruction.
static int listing_record_is_instruction(const listing_record_t *record,
                                         uint8_t opcode)
{
   const char *p;
   if (!record || record->size != nmos6502_instruction_size(opcode) ||
       !record->asm_text)
      return 0;
   p = record->asm_text;
   while (isspace((unsigned char)*p))
      ++p;
   if (strncasecmp(p, "asm ", 4) == 0) {
      p += 4;
      while (isspace((unsigned char)*p))
         ++p;
   }
   while (*p) {
      const char *colon = strchr(p, ':');
      const char *space = strpbrk(p, " \t");
      if (!colon || (space && space < colon))
         break;
      p = colon + 1;
      while (isspace((unsigned char)*p))
         ++p;
   }
   return *p != '\0' && *p != '.' && *p != ';' &&
      (isalpha((unsigned char)*p) || *p == '_');
}

//! @brief Find the selected definition of an imported symbol and its owning layout.
static object_layout_t *read_hazard_export_layout(input_set_t *in,
                                                  const char *name,
                                                  const symbol_t **symbol_out)
{
   char *weak;
   size_t pass, i, j;
   if (symbol_out)
      *symbol_out = NULL;
   if (!in || !name)
      return NULL;
   weak = make_weak_name(name);
   for (pass = 0; pass < 2; ++pass) {
      const char *wanted = pass == 0 ? name : weak;
      for (i = 0; i < in->object_count; ++i) {
         object_file_t *obj = &in->objects[i];
         for (j = 0; j < obj->export_count; ++j) {
            const symbol_t *sym = &obj->exports[j];
            const object_layout_t *found;
            if (strcmp(sym->name, wanted) != 0 || sym->segid == O26_SEG_ABS)
               continue;
            found = find_layout_for_value(obj, sym->segid, sym->value);
            if (found) {
               if (symbol_out)
                  *symbol_out = sym;
               free(weak);
               return &obj->layouts[(size_t)(found - obj->layouts)];
            }
         }
      }
   }
   free(weak);
   return NULL;
}

//! @brief Resolve one pre-layout relocation to a movable ROM layout and operand delta.
static object_layout_t *read_hazard_reloc_target(input_set_t *in,
                                                 object_file_t *obj,
                                                 const reloc_t *reloc,
                                                 uint16_t current_word,
                                                 uint16_t *delta_out,
                                                 const char **name_out)
{
   object_layout_t *target = NULL;
   uint16_t target_value = current_word;
   const char *name = NULL;

   if (reloc->segid == O26_SEG_UNDEF) {
      const symbol_t *sym = NULL;
      if (reloc->undef_index >= obj->undef_count)
         return NULL;
      target = read_hazard_export_layout(in, obj->undefs[reloc->undef_index], &sym);
      if (!target || !sym)
         return NULL;
      target_value = (uint16_t)(sym->value + current_word);
      name = obj->undefs[reloc->undef_index];
   } else if (reloc->has_layout_index) {
      if (reloc->layout_index >= obj->layout_count)
         return NULL;
      target = &obj->layouts[reloc->layout_index];
      target_value = current_word;
      name = target->name;
   } else if (reloc->segid != O26_SEG_ABS) {
      const object_layout_t *found = find_layout_for_value(obj, reloc->segid,
                                                           current_word);
      if (!found)
         return NULL;
      target = &obj->layouts[(size_t)(found - obj->layouts)];
      target_value = current_word;
      name = target->name;
   }

   /* Load-address operands are movable before ROM placement.  Runtime RAM
      layouts have separate load/run placement and are left to final validation
      rather than incorrectly constraining their ROM initializer image. */
   if (!target || target->segid != O26_SEG_TEXT)
      return NULL;
   if (delta_out)
      *delta_out = (uint16_t)(target_value - target->packed_base);
   if (name_out)
      *name_out = name ? name : target->name;
   return target;
}

//! @brief Add one unique destructive-read placement constraint to a ROM layout.
static void add_read_hazard_constraint(object_layout_t *target, uint8_t opcode,
                                       uint16_t operand_delta,
                                       const listing_record_t *record,
                                       const char *referenced_name)
{
   size_t i;
   read_hazard_constraint_t *constraint;
   for (i = 0; i < target->read_hazard_constraint_count; ++i) {
      constraint = &target->read_hazard_constraints[i];
      if (constraint->opcode == opcode &&
          constraint->operand_delta == operand_delta &&
          constraint->source_line == record->source_line &&
          strcmp(constraint->source_file ? constraint->source_file : "",
                 record->source_file ? record->source_file : "") == 0)
         return;
   }
   target->read_hazard_constraints = (read_hazard_constraint_t *)xrealloc(
      target->read_hazard_constraints,
      (target->read_hazard_constraint_count + 1) * sizeof(*target->read_hazard_constraints));
   constraint = &target->read_hazard_constraints[target->read_hazard_constraint_count++];
   memset(constraint, 0, sizeof(*constraint));
   constraint->opcode = opcode;
   constraint->operand_delta = operand_delta;
   constraint->source_file = record->source_file;
   constraint->source_line = record->source_line;
   constraint->asm_text = record->asm_text;
   constraint->referenced_name = referenced_name ? referenced_name : target->name;
}

//! @brief Discover relocatable operands whose final placement must avoid destructive reads.
static void prepare_read_hazard_constraints(const linker_config_t *cfg,
                                            input_set_t *in)
{
   size_t i, j, k;
   if (!cfg || !in)
      return;
   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->listing_count; ++j) {
         const listing_record_t *record = &obj->listing[j];
         object_layout_t *source_layout;
         const o26_segment_t *segment;
         size_t statement_offset;
         uint8_t opcode;
         nmos_addr_mode_t mode;

         if (record->layout_index >= obj->layout_count || record->size < 2)
            continue;
         source_layout = &obj->layouts[record->layout_index];
         if (source_layout->image_segid == O26_SEG_TEXT)
            segment = &obj->text;
         else if (source_layout->image_segid == O26_SEG_DATA)
            segment = &obj->data;
         else
            continue;
         statement_offset = (size_t)source_layout->image_base + record->offset;
         if (statement_offset >= segment->length)
            continue;
         opcode = segment->data[statement_offset];
         if (!listing_record_is_instruction(record, opcode))
            continue;
         mode = (nmos_addr_mode_t)nmos6502_addr_mode[opcode];
         if (mode != NMOS_ABS && mode != NMOS_ABSX &&
             mode != NMOS_ABSY && mode != NMOS_IND)
            continue;

         for (k = 0; k < segment->reloc_count; ++k) {
            const reloc_t *reloc = &segment->relocs[k];
            uint16_t current_word;
            uint16_t delta;
            const char *referenced_name = NULL;
            object_layout_t *target;
            uint8_t shape = reloc->type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD);
            if (shape == 0)
               continue;
            if (reloc->offset != statement_offset + 1u &&
                reloc->offset != statement_offset + 2u)
               continue;
            current_word = bank_placement_current_word(segment, reloc);
            target = read_hazard_reloc_target(in, obj, reloc, current_word,
                                              &delta, &referenced_name);
            if (!target)
               continue;
            add_read_hazard_constraint(target, opcode, delta, record,
                                       referenced_name);
            break;
         }
      }
   }
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

//! @brief Find a compact placement component by its union-find root.
static size_t bank_placement_component_index(const bank_placement_component_t *components,
                                             size_t component_count,
                                             int root)
{
   size_t i;
   for (i = 0; i < component_count; ++i) {
      if (components[i].root == root)
         return i;
   }
   fprintf(stderr, "vcsc-ld: internal error: bank-placement component root %d is missing\n",
           root);
   exit(1);
}

//! @brief Return the cut cost incident to one component at a candidate bank.
static bank_placement_cost_t bank_placement_component_cost(
                                      bank_placement_item_t *items,
                                      const bank_placement_edge_t *edges,
                                      size_t edge_count,
                                      const bank_placement_component_t *components,
                                      size_t component_count,
                                      const bank_placement_component_t *component,
                                      const cartridge_bank_t *candidate,
                                      int assigned_only)
{
   bank_placement_cost_t cost;
   size_t i;

   memset(&cost, 0, sizeof(cost));
   for (i = 0; i < edge_count; ++i) {
      int first_root = bank_placement_root(items, edges[i].first);
      int second_root = bank_placement_root(items, edges[i].second);
      int other_root = -1;
      size_t other_index;
      const bank_placement_component_t *other;

      if (first_root == component->root)
         other_root = second_root;
      else if (second_root == component->root)
         other_root = first_root;
      if (other_root < 0 || other_root == component->root)
         continue;
      other_index = bank_placement_component_index(components, component_count,
                                                   other_root);
      other = &components[other_index];
      if (assigned_only && !other->assigned)
         continue;
      if (!other->assigned || other->bank == candidate)
         continue;
      cost.weight += edges[i].weight;
      cost.cycles += edges[i].cycles;
      cost.sites += edges[i].sites;
      cost.jsr_sites += edges[i].jsr_sites;
      cost.jmp_sites += edges[i].jmp_sites;
   }
   return cost;
}

//! @brief Return the complete cut cost, counting each soft edge once.
static bank_placement_cost_t bank_placement_total_cost(
                                      bank_placement_item_t *items,
                                      const bank_placement_edge_t *edges,
                                      size_t edge_count,
                                      const bank_placement_component_t *components,
                                      size_t component_count)
{
   bank_placement_cost_t cost;
   size_t i;

   memset(&cost, 0, sizeof(cost));
   for (i = 0; i < edge_count; ++i) {
      int first_root = bank_placement_root(items, edges[i].first);
      int second_root = bank_placement_root(items, edges[i].second);
      size_t first_index;
      size_t second_index;
      if (first_root == second_root)
         continue;
      first_index = bank_placement_component_index(components, component_count,
                                                   first_root);
      second_index = bank_placement_component_index(components, component_count,
                                                    second_root);
      if (!components[first_index].assigned || !components[second_index].assigned ||
          components[first_index].bank == components[second_index].bank)
         continue;
      cost.weight += edges[i].weight;
      cost.cycles += edges[i].cycles;
      cost.sites += edges[i].sites;
      cost.jsr_sites += edges[i].jsr_sites;
      cost.jmp_sites += edges[i].jmp_sites;
   }
   return cost;
}

//! @brief Return whether one placement cost is strictly better than another.
static int bank_placement_cost_precedes(bank_placement_cost_t a,
                                        bank_placement_cost_t b)
{
   if (a.weight != b.weight)
      return a.weight < b.weight;
   if (a.cycles != b.cycles)
      return a.cycles < b.cycles;
   return a.sites < b.sites;
}

//! @brief Return whether two placement costs are identical.
static int bank_placement_cost_equal(bank_placement_cost_t a,
                                     bank_placement_cost_t b)
{
   return a.weight == b.weight && a.cycles == b.cycles && a.sites == b.sites;
}

//! @brief Return one bank's bit in a validated at-most-64-bank profile.
static uint64_t bank_placement_bank_bit(const linker_config_t *cfg,
                                        const cartridge_bank_t *bank)
{
   size_t i;
   if (!cfg || !bank || cfg->bank_count > 64)
      return 0;
   for (i = 0; i < cfg->bank_count; ++i) {
      if (&cfg->banks[i] == bank)
         return UINT64_C(1) << i;
   }
   return 0;
}

//! @brief Print the declared region set for a replicated symbol diagnostic.
static void bank_placement_print_replica_regions(const replica_group_t *group)
{
   size_t i;
   fputc('[', stderr);
   for (i = 0; group && i < group->copy_count; ++i)
      fprintf(stderr, "%s%s", i ? "," : "", group->regions[i]);
   fputc(']', stderr);
}

//! @brief Restrict one movable source to banks that contain a target replica.
static void bank_placement_restrict_to_replica(const linker_config_t *cfg,
                                               bank_placement_item_t *item,
                                               const replica_group_t *group)
{
   uint64_t mask;
   if (!item || !group)
      return;
   mask = replica_bank_mask(cfg, group);
   item->allowed_bank_mask &= mask;
   if (item->allowed_bank_mask == 0) {
      fprintf(stderr,
              "vcsc-ld: layout %s from %s has no bank in common with replicated %s '%s' declared in regions ",
              item->layout->name, item->obj->origin,
              group->kind == 'F' ? "function" : "object", group->symbol);
      bank_placement_print_replica_regions(group);
      fputc('\n', stderr);
      exit(1);
   }
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
   if (table_memory && !selected_objects_have_export(in, "__vcsc_startup_simple")) {
      uint32_t table_bytes = (uint32_t)(copy_count + 1u) * 6u +
                             (uint32_t)(zero_count + 1u) * 4u +
                             (uint32_t)(count_init_functions_in_input(in) + 1u) * 2u;
      bank_placement_consume(budgets, budget_count, table_memory, table_bytes,
                             "linker startup tables", "<linker>");
   }
}

//! @brief Return the hypothetical ROM MEMORY for one layout during a placement trial.
static const memory_region_t *bank_placement_trial_memory(
   const linker_config_t *cfg, bank_placement_item_t *items, size_t item_count,
   const object_layout_t *lay, const bank_placement_component_t *trial_component,
   const cartridge_bank_t *trial_bank)
{
   int item_index = bank_placement_find_item(items, item_count, lay);
   bank_placement_item_t *item;

   if (item_index < 0)
      return NULL;
   item = &items[item_index];
   if (trial_component &&
       bank_placement_root(items, item_index) == trial_component->root) {
      if (item->pin_memory)
         return item->pin_memory;
      return bank_placement_auto_memory(cfg, trial_bank);
   }
   if (lay->placement_memory[0])
      return find_memory(cfg, lay->placement_memory);
   return NULL;
}

//! @brief Dry-run all currently assigned ROM layouts plus one candidate component.
//!
//! The byte ledger is useful for fast rejection and reporting, but it cannot see
//! holes introduced by page/phase constraints.  This simulation mirrors the ROM
//! portion of layout_objects() in source order and therefore answers the stronger
//! question: can the currently selected layouts actually be placed in their regions?
static int bank_placement_trial_fits(const linker_config_t *cfg,
   const input_set_t *in, bank_placement_item_t *items, size_t item_count,
   const bank_placement_component_t *trial_component,
   const cartridge_bank_t *trial_bank)
{
   layout_t sim;
   const segment_rule_t *code = find_segment_rule(cfg, "CODE");
   const segment_rule_t *data = find_segment_rule(cfg, "DATA");
   const char *code_load_name = code && code->load_name[0] ? code->load_name : "ROM";
   const char *data_load_name = data && data->load_name[0] ? data->load_name : code_load_name;
   size_t copy_count = 0;
   size_t zero_count = 0;
   size_t i, j;
   int ok = 1;

   memset(&sim, 0, sizeof(sim));
   for (i = 0; i < in->object_count && ok; ++i) {
      const object_file_t *obj = &in->objects[i];

      for (j = 0; j < obj->layout_count; ++j) {
         const object_layout_t *lay = &obj->layouts[j];
         const memory_region_t *memory;
         const segment_rule_t *rule;
         uint16_t alignment;

         if (lay->segid != O26_SEG_TEXT || lay->size == 0)
            continue;
         memory = bank_placement_trial_memory(cfg, items, item_count, lay,
                                              trial_component, trial_bank);
         if (!memory)
            continue;
         rule = find_layout_segment_rule(cfg, lay->name, code);
         alignment = lay->component_alignment ? lay->component_alignment
            : (rule && rule->align ? rule->align : 1);
         if (!simulate_alloc_code_branch_aware(&sim, cfg, memory->name, obj, lay,
                                               alignment)) {
            ok = 0;
            break;
         }
      }

      /* Initialized RAM load images are fixed ROM consumers and are placed at
         this point by layout_objects(), between this object's TEXT and the next
         object's TEXT.  Include them so a candidate cannot consume their room. */
      for (j = 0; j < obj->layout_count && ok; ++j) {
         const object_layout_t *lay = &obj->layouts[j];
         const segment_rule_t *rule;
         const char *load_name;
         uint16_t alignment;

         if (lay->segid == O26_SEG_TEXT ||
             (lay->image_segid != O26_SEG_DATA && lay->image_segid != O26_SEG_TEXT))
            continue;
         rule = find_layout_segment_rule(cfg, lay->name, data);
         load_name = component_resolve_memory_name(cfg, lay,
            (rule && rule->load_name[0]) ? rule->load_name : data_load_name);
         alignment = lay->component_alignment ? lay->component_alignment
            : (rule && rule->align ? rule->align : 1);
         if (!simulate_alloc_from_region_policy(&sim, cfg, load_name, lay->size,
                                                alignment, NULL)) {
            ok = 0;
            break;
         }
      }

      for (j = 0; j < obj->layout_count; ++j) {
         const object_layout_t *lay = &obj->layouts[j];
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

   if (ok && !simulate_alloc_from_region_policy(&sim, cfg, data_load_name,
       (uint16_t)((copy_count + 1u) * 6u), 1, NULL))
      ok = 0;
   if (ok && !simulate_alloc_from_region_policy(&sim, cfg, data_load_name,
       (uint16_t)((zero_count + 1u) * 4u), 1, NULL))
      ok = 0;
   if (ok && !simulate_alloc_from_region_policy(&sim, cfg, data_load_name,
       (uint16_t)((count_init_functions_in_input(in) + 1u) * 2u), 1, NULL))
      ok = 0;

   for (i = 0; i < sim.cursor_count; ++i)
      free(sim.cursors[i].holes);
   free(sim.cursors);
   return ok;
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
   uint64_t bank_bit = bank_placement_bank_bit(cfg, bank);
   size_t i;

   if (!bank_bit || !(component->allowed_bank_mask & bank_bit)) {
      fprintf(stderr,
              "vcsc-ld: bank %s does not satisfy replicated-data locality for hard component %u\n",
              bank ? bank->name : "<none>", component->id);
      exit(1);
   }
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
      {
         const char *owner = bank_placement_memory_owner(memory);
         if (!owner || !str_ieq(owner, bank->name)) {
         fprintf(stderr,
                 "vcsc-ld: layout %s from %s is assigned to %s but MEMORY %s belongs to %s\n",
                 items[i].layout->name, items[i].obj->origin, bank->name,
                 memory->name, owner ? owner : "no placement region");
         exit(1);
         }
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

//! @brief Move one already assigned automatic component between ordinary ROM banks.
static void bank_placement_move_component(const linker_config_t *cfg,
                                          bank_placement_item_t *items,
                                          size_t item_count,
                                          bank_placement_component_t *component,
                                          const cartridge_bank_t *bank,
                                          bank_placement_budget_t **budgets,
                                          size_t *budget_count)
{
   const memory_region_t *old_memory;
   const memory_region_t *new_memory;
   bank_placement_budget_t *old_budget;
   bank_placement_budget_t *new_budget;
   size_t i;

   if (!component || !component->assigned || component->pinned || !component->bank ||
       !bank || component->bank == bank)
      return;
   old_memory = bank_placement_auto_memory(cfg, component->bank);
   new_memory = bank_placement_auto_memory(cfg, bank);
   if (!old_memory || !new_memory) {
      fprintf(stderr,
              "vcsc-ld: internal error: automatic bank-placement move lacks an ordinary ROM region\n");
      exit(1);
   }
   old_budget = bank_placement_budget_for(budgets, budget_count, old_memory);
   new_budget = bank_placement_budget_for(budgets, budget_count, new_memory);
   if (old_budget->used < component->bytes ||
       new_budget->capacity - new_budget->used < component->bytes) {
      fprintf(stderr,
              "vcsc-ld: internal error: invalid automatic bank-placement move for component %u\n",
              component->id);
      exit(1);
   }
   old_budget->used -= component->bytes;
   new_budget->used += component->bytes;
   for (i = 0; i < item_count; ++i) {
      if (bank_placement_root(items, (int)i) != component->root)
         continue;
      snprintf(items[i].layout->placement_memory,
               sizeof(items[i].layout->placement_memory), "%s", new_memory->name);
      snprintf(items[i].layout->placement_bank,
               sizeof(items[i].layout->placement_bank), "%s", bank->name);
      items[i].layout->placement_mode = BANK_PLACEMENT_AUTOMATIC;
   }
   component->bank = bank;
}

//! @brief Return the weighted hardware-return depth for the current placement.
static uint16_t bank_placement_weighted_depth(const linker_config_t *cfg,
                                              const input_set_t *in)
{
   uint16_t weighted = 0;
   (void)enforce_symbol_backed_call_graph(in, cfg, &weighted,
                                          selected_startup_tail_enters_main(in));
   return weighted;
}

//! @brief Perform deterministic whole-layout placement across compatible ROM regions.
static void assign_automatic_bank_placements(const linker_config_t *cfg,
                                             input_set_t *in,
                                             uint8_t placement_mode,
                                             int explain)
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
   int fe_profile;
   int wd_profile;
   size_t i, j;

   if (!cfg || cfg->bank_count < 2)
      return;
   if (cfg->bank_count > 64) {
      fprintf(stderr,
              "vcsc-ld: automatic multi-region placement supports at most 64 logical regions\n");
      exit(1);
   }
   startup = bank_placement_startup_bank(cfg);
   fe_profile = c26_topology_is_fe(cfg);
   wd_profile = c26_topology_is_wd(cfg);
   if (!startup) {
      fprintf(stderr,
              "vcsc-ld: automatic multi-region placement requires one startup/home bank\n");
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
         if (!memory || !bank_placement_memory_owner(memory))
            continue;
         bank = bank_placement_memory_bank(cfg, memory);
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
         items[item_count].allowed_bank_mask = cfg->bank_count == 64
            ? UINT64_MAX : ((UINT64_C(1) << cfg->bank_count) - 1u);
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
            if (reserved_runtime && !automatic && bank != startup) {
               fprintf(stderr,
                       "vcsc-ld: startup/runtime function '%s' is explicitly placed in MEMORY region '%s', which belongs to non-startup region '%s'; the configured startup/home region is '%s'\n",
                       function_name, memory->name, bank->name, startup->name);
               exit(1);
            }
            if (reserved_runtime && bank != startup)
               pin_memory = bank_placement_auto_memory(cfg, startup);
            bank_placement_pin_item(&items[item_count], pin_bank,
                                    pin_memory, 1);
         }
         else if (fe_profile || wd_profile) {
            const memory_region_t *pin_memory = bank_placement_auto_memory(cfg, startup);
            if (!pin_memory) {
               fprintf(stderr,
                       "vcsc-ld: %s startup bank '%s' has no ordinary allocatable ROM MEMORY region\n",
                       wd_profile ? "WD" : "FE", startup->name);
               exit(1);
            }
            /* FE requires reviewed direct-JSR transitions and WD requires an
               explicitly selected four-segment arrangement. Keep unqualified
               material in the startup/home chunk; only explicit bank placement
               may create mapper-dependent references. */
            bank_placement_pin_item(&items[item_count], startup, pin_memory, 1);
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

            /* .banktarget is metadata consumed by the paired direct JSR; it is
               intentionally a far logical word and must not create a hard
               same-bank placement edge of its own. */
            if (O26_RTYPE_IS_BANK_TARGET(reloc->type))
               continue;

            if (cfg->cartridge_banked &&
                (control == O26_RTYPE_CONTROL_JSR ||
                 control == O26_RTYPE_CONTROL_JMP) &&
                !(reloc->type & O26_RTYPE_INDIRECT_JMP)) {
               /* A replicated function is a soft preference only.  Runtime
                  relocation selects a source-bank-local copy when present and
                  otherwise uses the primary copy through a trampoline. */
               bank_placement_add_edge(&edges, &edge_count,
                  source_item, target_item,
                  control == O26_RTYPE_CONTROL_JSR ? BANK_JSR_ENTRY_SIZE
                                                   : BANK_JMP_ENTRY_SIZE,
                  control == O26_RTYPE_CONTROL_JSR ? 25u : 6u,
                  control);
               continue;
            }

            /* Directly mapped regions share one flat logical 16-bit address
               space.  Absolute calls, jumps, and data references therefore
               impose no co-location requirement and carry no cut cost. */
            if (!cfg->cartridge_banked)
               continue;

            if (target.replica) {
               if (source_item >= 0) {
                  bank_placement_restrict_to_replica(cfg,
                     &items[source_item], target.replica);
               }
               else {
                  const memory_region_t *source_memory =
                     bank_placement_layout_memory(cfg, source_layout);
                  const cartridge_bank_t *source_bank =
                     bank_placement_memory_bank(cfg, source_memory);
                  if (source_bank &&
                      replica_copy_index_for_bank(cfg, target.replica,
                                                  source_bank) < 0) {
                     fprintf(stderr,
                             "vcsc-ld: layout %s from %s in bank %s references replicated %s '%s' with no local copy; declared regions ",
                             source_layout->name, obj->origin, source_bank->name,
                             target.replica->kind == 'F' ? "function" : "object",
                             target.replica->symbol);
                     bank_placement_print_replica_regions(target.replica);
                     fputc('\n', stderr);
                     exit(1);
                  }
               }
               continue;
            }

            if (source_item >= 0 && target_item >= 0) {
               bank_placement_union(items, source_item, target_item);
            }
            else if (target_item >= 0) {
               const memory_region_t *source_memory =
                  bank_placement_layout_memory(cfg, source_layout);
               const cartridge_bank_t *source_bank =
                  bank_placement_memory_bank(cfg, source_memory);
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
         components[component_count].allowed_bank_mask = cfg->bank_count == 64
            ? UINT64_MAX : ((UINT64_C(1) << cfg->bank_count) - 1u);
         component_count++;
      }
      components[c].allowed_bank_mask &= items[i].allowed_bank_mask;
      if (components[c].allowed_bank_mask == 0) {
         fprintf(stderr,
                 "vcsc-ld: hard bank-placement component %u has no bank satisfying all replicated-data locality requirements\n",
                 components[c].id);
         exit(1);
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
         if (!(components[c].allowed_bank_mask &
               bank_placement_bank_bit(cfg, items[i].pin_bank))) {
            fprintf(stderr,
                    "vcsc-ld: pinned layout %s from %s requires bank %s, which has no local copy for one of its replicated-data references\n",
                    items[i].layout->name, items[i].obj->origin,
                    items[i].pin_bank->name);
            exit(1);
         }
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
      components[first_component].cycle_degree += edges[i].cycles;
      components[second_component].cycle_degree += edges[i].cycles;
   }

   if (explain) {
      fprintf(stderr, "BANK PLACEMENT EXPLANATION mode=%s\n",
              placement_mode == BANK_PLACEMENT_MODE_SIMPLE ? "simple" : "optimized");
      for (i = 0; i < component_count; ++i) {
         size_t k;
         int first_allowed = 1;
         fprintf(stderr,
                 "  component=%u bytes=$%04" PRIX32
                 " degree-bytes=$%04" PRIX32 " degree-cycles=%" PRIu32
                 " assignment=%s allowed=",
                 components[i].id, components[i].bytes, components[i].degree,
                 components[i].cycle_degree,
                 components[i].pinned ? "pinned" : "automatic");
         for (k = 0; k < cfg->bank_count; ++k) {
            if (components[i].allowed_bank_mask & (UINT64_C(1) << k)) {
               fprintf(stderr, "%s%s", first_allowed ? "" : ",",
                       cfg->banks[k].name);
               first_allowed = 0;
            }
         }
         fputc('\n', stderr);
         for (k = 0; k < item_count; ++k) {
            if (bank_placement_root(items, (int)k) != components[i].root)
               continue;
            fprintf(stderr, "     member=%s object=%s%s\n",
                    items[k].layout->name, items[k].obj->origin,
                    items[k].directly_pinned ? " hard-pin=yes" : "");
         }
      }
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
      if (!bank_placement_trial_fits(cfg, in, items, item_count, next, next->bank)) {
         fprintf(stderr,
                 "vcsc-ld: pinned bank-placement component %u cannot satisfy final page/alignment capacity in %s\n",
                 next->id, next->bank->name);
         exit(1);
      }
      bank_placement_assign_component(cfg, items, item_count, next,
                                      next->bank, &budgets, &budget_count);
      if (explain) {
         fprintf(stderr,
                 "  choose component=%u bank=%s reason=hard-pin bytes=$%04" PRIX32 "\n",
                 next->id, next->bank->name, next->bytes);
      }
   }

   /* Simple mode uses stable component order and the ordinary bank preference
      only.  Optimized mode retains size/degree ordering and minimizes the
      incremental weighted cut against already assigned components. */
   for (;;) {
      bank_placement_component_t *next = NULL;
      const cartridge_bank_t *best_bank = NULL;
      bank_placement_cost_t best_cost;
      int have_best = 0;

      memset(&best_cost, 0, sizeof(best_cost));
      for (i = 0; i < component_count; ++i) {
         if (components[i].assigned)
            continue;
         if (placement_mode == BANK_PLACEMENT_MODE_SIMPLE) {
            if (!next || components[i].stable_order < next->stable_order)
               next = &components[i];
         }
         else if (!next || components[i].bytes > next->bytes ||
                  (components[i].bytes == next->bytes &&
                   components[i].degree > next->degree) ||
                  (components[i].bytes == next->bytes &&
                   components[i].degree == next->degree &&
                   components[i].stable_order < next->stable_order)) {
            next = &components[i];
         }
      }
      if (!next)
         break;

      for (i = 0; i < cfg->bank_count; ++i) {
         const cartridge_bank_t *candidate = &cfg->banks[i];
         const memory_region_t *memory = bank_placement_auto_memory(cfg, candidate);
         uint64_t bank_bit = UINT64_C(1) << i;
         uint32_t free_bytes = memory
            ? bank_placement_budget_free(&budgets, &budget_count, memory) : 0;
         bank_placement_cost_t cost;

         memset(&cost, 0, sizeof(cost));
         if (!(next->allowed_bank_mask & bank_bit)) {
            if (explain)
               fprintf(stderr,
                       "     candidate component=%u bank=%s rejected=replica-locality\n",
                       next->id, candidate->name);
            continue;
         }
         if (!memory) {
            if (explain)
               fprintf(stderr,
                       "     candidate component=%u bank=%s rejected=no-ordinary-rom\n",
                       next->id, candidate->name);
            continue;
         }
         if (free_bytes < next->bytes) {
            if (explain)
               fprintf(stderr,
                       "     candidate component=%u bank=%s rejected=capacity free=$%04" PRIX32
                       " need=$%04" PRIX32 "\n",
                       next->id, candidate->name, free_bytes, next->bytes);
            continue;
         }
         if (!bank_placement_trial_fits(cfg, in, items, item_count, next, candidate)) {
            if (explain)
               fprintf(stderr,
                       "     candidate component=%u bank=%s rejected=layout-capacity\n",
                       next->id, candidate->name);
            continue;
         }
         cost = bank_placement_component_cost(items, edges, edge_count,
                                              components, component_count,
                                              next, candidate, 1);
         if (explain) {
            fprintf(stderr,
                    "     candidate component=%u bank=%s free=$%04" PRIX32
                    " cut-byte-weight=$%04" PRIX32 " cut-cycle-weight=%" PRIu32
                    " cut-sites=%" PRIu32 "\n",
                    next->id, candidate->name, free_bytes, cost.weight,
                    cost.cycles, cost.sites);
         }
         if (!have_best ||
             (placement_mode == BANK_PLACEMENT_MODE_SIMPLE
                ? bank_placement_bank_precedes(candidate, best_bank)
                : bank_placement_cost_precedes(cost, best_cost) ||
                  (bank_placement_cost_equal(cost, best_cost) &&
                   bank_placement_bank_precedes(candidate, best_bank)))) {
            best_bank = candidate;
            best_cost = cost;
            have_best = 1;
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
      if (explain) {
         fprintf(stderr,
                 "  choose component=%u bank=%s reason=%s cut-byte-weight=$%04" PRIX32
                 " cut-cycle-weight=%" PRIu32 " cut-sites=%" PRIu32 "\n",
                 next->id, best_bank->name,
                 placement_mode == BANK_PLACEMENT_MODE_SIMPLE
                    ? "stable-first-fit" : "minimum-incremental-cut",
                 best_cost.weight, best_cost.cycles, best_cost.sites);
      }
   }

   /* A deterministic single-component local search repairs decisions made
      before important neighbors were assigned.  Pins, hard components,
      replica-locality masks, and capacity remain absolute.  A move must improve
      cut cost without increasing the weighted hardware-return depth, or leave
      cut cost unchanged while reducing that depth. */
   if (placement_mode == BANK_PLACEMENT_MODE_OPTIMIZED) {
      uint16_t current_depth = bank_placement_weighted_depth(cfg, in);
      int changed;
      do {
         size_t stable;
         changed = 0;
         for (stable = 0; stable < item_count; ++stable) {
            bank_placement_component_t *component = NULL;
            const cartridge_bank_t *old_bank;
            const cartridge_bank_t *best_bank;
            bank_placement_cost_t current_cost;
            bank_placement_cost_t best_cost;
            uint16_t best_depth;

            for (i = 0; i < component_count; ++i) {
               if (components[i].stable_order == stable) {
                  component = &components[i];
                  break;
               }
            }
            if (!component || component->pinned)
               continue;
            old_bank = component->bank;
            best_bank = old_bank;
            current_cost = bank_placement_component_cost(items, edges, edge_count,
                                                         components, component_count,
                                                         component, old_bank, 0);
            best_cost = current_cost;
            best_depth = current_depth;

            for (i = 0; i < cfg->bank_count; ++i) {
               const cartridge_bank_t *candidate = &cfg->banks[i];
               const memory_region_t *memory;
               bank_placement_cost_t candidate_cost;
               uint16_t candidate_depth;
               int improves;

               if (candidate == old_bank)
                  continue;
               if (!(component->allowed_bank_mask & (UINT64_C(1) << i))) {
                  if (explain)
                     fprintf(stderr,
                             "     local-candidate component=%u bank=%s rejected=replica-locality\n",
                             component->id, candidate->name);
                  continue;
               }
               memory = bank_placement_auto_memory(cfg, candidate);
               if (!memory) {
                  if (explain)
                     fprintf(stderr,
                             "     local-candidate component=%u bank=%s rejected=no-ordinary-rom\n",
                             component->id, candidate->name);
                  continue;
               }
               if (bank_placement_budget_free(&budgets, &budget_count, memory) <
                   component->bytes) {
                  if (explain)
                     fprintf(stderr,
                             "     local-candidate component=%u bank=%s rejected=capacity\n",
                             component->id, candidate->name);
                  continue;
               }
               if (!bank_placement_trial_fits(cfg, in, items, item_count,
                                              component, candidate)) {
                  if (explain)
                     fprintf(stderr,
                             "     local-candidate component=%u bank=%s rejected=layout-capacity\n",
                             component->id, candidate->name);
                  continue;
               }
               candidate_cost = bank_placement_component_cost(
                  items, edges, edge_count, components, component_count,
                  component, candidate, 0);
               if (!bank_placement_cost_precedes(candidate_cost, current_cost) &&
                   !bank_placement_cost_equal(candidate_cost, current_cost)) {
                  if (explain)
                     fprintf(stderr,
                             "     local-candidate component=%u bank=%s rejected=no-cut-improvement"
                             " current-byte-weight=$%04" PRIX32
                             " candidate-byte-weight=$%04" PRIX32 "\n",
                             component->id, candidate->name, current_cost.weight,
                             candidate_cost.weight);
                  continue;
               }

               bank_placement_move_component(cfg, items, item_count, component,
                                             candidate, &budgets, &budget_count);
               candidate_depth = bank_placement_weighted_depth(cfg, in);
               bank_placement_move_component(cfg, items, item_count, component,
                                             old_bank, &budgets, &budget_count);

               improves = candidate_depth <= current_depth &&
                  (bank_placement_cost_precedes(candidate_cost, current_cost) ||
                   (bank_placement_cost_equal(candidate_cost, current_cost) &&
                    candidate_depth < current_depth));
               if (!improves) {
                  if (explain)
                     fprintf(stderr,
                             "     local-candidate component=%u bank=%s rejected=%s"
                             " byte-weight=$%04" PRIX32 "->$%04" PRIX32
                             " weighted-depth=%u->%u\n",
                             component->id, candidate->name,
                             candidate_depth > current_depth
                                ? "weighted-depth-increase"
                                : "no-objective-improvement",
                             current_cost.weight, candidate_cost.weight,
                             current_depth, candidate_depth);
                  continue;
               }
               if (explain)
                  fprintf(stderr,
                          "     local-candidate component=%u bank=%s eligible"
                          " byte-weight=$%04" PRIX32 "->$%04" PRIX32
                          " weighted-depth=%u->%u\n",
                          component->id, candidate->name, current_cost.weight,
                          candidate_cost.weight, current_depth, candidate_depth);
               if (best_bank == old_bank ||
                   bank_placement_cost_precedes(candidate_cost, best_cost) ||
                   (bank_placement_cost_equal(candidate_cost, best_cost) &&
                    (candidate_depth < best_depth ||
                     (candidate_depth == best_depth &&
                      bank_placement_bank_precedes(candidate, best_bank))))) {
                  best_bank = candidate;
                  best_cost = candidate_cost;
                  best_depth = candidate_depth;
               }
            }

            if (best_bank != old_bank) {
               bank_placement_move_component(cfg, items, item_count, component,
                                             best_bank, &budgets, &budget_count);
               if (explain) {
                  fprintf(stderr,
                          "  local-move component=%u from=%s to=%s"
                          " cut-byte-weight=$%04" PRIX32 "->$%04" PRIX32
                          " cut-cycle-weight=%" PRIu32 "->%" PRIu32
                          " weighted-depth=%u->%u\n",
                          component->id, old_bank->name, best_bank->name,
                          current_cost.weight, best_cost.weight,
                          current_cost.cycles, best_cost.cycles,
                          current_depth, best_depth);
               }
               current_depth = best_depth;
               changed = 1;
            }
         }
      } while (changed);
   }

   if (explain) {
      bank_placement_cost_t total = bank_placement_total_cost(
         items, edges, edge_count, components, component_count);
      uint16_t weighted_depth = bank_placement_weighted_depth(cfg, in);
      fprintf(stderr,
              "  final cut-byte-weight=$%04" PRIX32 " cut-cycle-weight=%" PRIu32
              " cut-sites=%" PRIu32 " jsr-sites=%" PRIu32
              " jmp-sites=%" PRIu32 " weighted-depth=%u\n",
              total.weight, total.cycles, total.sites, total.jsr_sites,
              total.jmp_sites, weighted_depth);
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

//! @brief Report a reference from a bank that lacks a required local replica.
static void report_missing_local_replica(const object_file_t *obj,
                                         const object_layout_t *source_layout,
                                         const cartridge_bank_t *source_bank,
                                         const replica_group_t *group)
{
   fprintf(stderr,
           "vcsc-ld: layout %s from %s in bank %s references replicated %s '%s' with no local copy; declared regions ",
           source_layout ? source_layout->name : "<unknown>", obj->origin,
           source_bank ? source_bank->name : "<none>",
           group->kind == 'F' ? "function" : "object", group->symbol);
   bank_placement_print_replica_regions(group);
   fputc('\n', stderr);
   exit(1);
}

//! @brief Return whether a missing function copy may use the ordinary trampoline path.
static int replica_relocation_may_trampoline(const replica_group_t *group,
                                             const reloc_t *reloc)
{
   uint8_t control;
   if (!group || group->kind != 'F' || !reloc ||
       (reloc->type & O26_RTYPE_INDIRECT_JMP))
      return 0;
   control = reloc->type & O26_RTYPE_CONTROL_MASK;
   return control == O26_RTYPE_CONTROL_JSR ||
          control == O26_RTYPE_CONTROL_JMP;
}

//! @brief Resolve one relocation while retaining the symbol/layout address used for bank identity.
static resolved_reloc_target_t resolve_reloc_target(const input_set_t *in,
                                                    const linker_config_t *cfg,
                                                    const object_file_t *obj,
                                                    const reloc_t *r,
                                                    uint16_t current_word,
                                                    const layout_t *layout,
                                                    uint8_t image_segid)
{
   resolved_reloc_target_t result;
   const object_layout_t *source_layout =
      find_layout_for_image_offset(obj, image_segid, r->offset);
   const cartridge_bank_t *source_bank = NULL;

   memset(&result, 0, sizeof(result));
   result.name = "<local relocation>";
   if (source_layout)
      source_bank = cartridge_bank_for_address(cfg, source_layout->load_addr);

   if (r->segid == O26_SEG_UNDEF) {
      const global_symbol_t *global;
      const replica_group_t *group;
      int copy_index;
      if (r->undef_index >= obj->undef_count) {
         fprintf(stderr, "vcsc-ld: bad undefined-symbol index in %s\n", obj->origin);
         exit(1);
      }
      group = find_replica_group_by_symbol(in, obj->undefs[r->undef_index]);
      copy_index = source_bank ? replica_copy_index_for_bank(cfg, group, source_bank) : -1;
      if (group && copy_index >= 0) {
         const object_layout_t *copy =
            &group->obj->layouts[group->layout_indices[copy_index]];
         result.address = (uint16_t)(copy->load_addr + group->symbol_offset +
                                     current_word);
         result.owner_address = (uint16_t)(copy->load_addr + group->symbol_offset);
         result.segid = O26_SEG_TEXT;
         result.name = group->symbol;
         result.owner_layout = copy;
         return result;
      }
      if (group && source_bank && !replica_relocation_may_trampoline(group, r))
         report_missing_local_replica(obj, source_layout, source_bank, group);

      global = lookup_global_symbol(layout, obj->undefs[r->undef_index]);
      result.address = (uint16_t)(global->addr + current_word);
      result.owner_address = global->addr;
      result.segid = global->segid;
      result.name = obj->undefs[r->undef_index];
      return result;
   }

   if (r->has_layout_index) {
      const object_layout_t *lay;
      const replica_group_t *group;
      uint16_t base;
      uint16_t offset;
      int copy_index;
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
      group = find_replica_group_by_layout(in, obj, r->layout_index, NULL);
      copy_index = source_bank ? replica_copy_index_for_bank(cfg, group, source_bank) : -1;
      if (group && copy_index >= 0) {
         const object_layout_t *copy =
            &obj->layouts[group->layout_indices[copy_index]];
         if (current_word < lay->packed_base ||
             (uint32_t)(current_word - lay->packed_base) >= lay->size) {
            fprintf(stderr,
                    "vcsc-ld: replicated relocation value $%04X is outside layout '%s' in %s\n",
                    current_word, lay->name, obj->origin);
            exit(1);
         }
         offset = (uint16_t)(current_word - lay->packed_base);
         result.address = (uint16_t)(copy->load_addr + offset);
         result.owner_address = copy->load_addr;
         result.segid = r->segid;
         result.name = group->symbol;
         result.owner_layout = copy;
         return result;
      }
      if (group && source_bank && !replica_relocation_may_trampoline(group, r))
         report_missing_local_replica(obj, source_layout, source_bank, group);

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
   if (r->segid == O26_SEG_TEXT) {
      uint16_t target_index = replica_layout_index(obj, result.owner_layout);
      const replica_group_t *group =
         find_replica_group_by_layout(in, obj, target_index, NULL);
      int copy_index = source_bank
         ? replica_copy_index_for_bank(cfg, group, source_bank) : -1;
      if (group && copy_index >= 0) {
         const object_layout_t *copy =
            &obj->layouts[group->layout_indices[copy_index]];
         uint16_t offset = (uint16_t)(current_word - result.owner_layout->packed_base);
         result.address = (uint16_t)(copy->load_addr + offset);
         result.owner_address = copy->load_addr;
         result.segid = r->segid;
         result.name = group->symbol;
         result.owner_layout = copy;
         return result;
      }
      if (group && source_bank && !replica_relocation_may_trampoline(group, r))
         report_missing_local_replica(obj, source_layout, source_bank, group);
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

//! @brief Return whether one writable MEMORY region is exactly ordinary RIOT RAM.
static int startup_simple_memory_is_riot(const memory_region_t *mem)
{
   uint32_t end;
   if (!mem || !str_ieq(mem->type, "rw") || mem->has_write_start)
      return 0;
   end = (uint32_t)mem->start + (mem->physical_size ? mem->physical_size : mem->size);
   return mem->start >= 0x0080u && end <= 0x0100u;
}

//! @brief Resolve the runtime MEMORY region used by a startup-zeroed layout.
static const memory_region_t *startup_simple_layout_run_memory(
   const linker_config_t *cfg, const object_layout_t *lay)
{
   const segment_rule_t *fallback;
   const segment_rule_t *run_rule;
   char explicit_region[MAX_NAME];
   char suffix_storage[MAX_NAME];
   const char *owner = NULL;
   const char *suffix;
   const char *run_name;

   if (!cfg || !lay)
      return NULL;
   fallback = find_segment_rule(cfg, lay->segid == O26_SEG_ZP ? "ZEROPAGE" : "BSS");
   run_name = rule_run_region_name(fallback);

   if (activation_segment_parse(lay->name, explicit_region,
                                sizeof(explicit_region), &owner)) {
      if (explicit_region[0])
         run_name = explicit_region;
   }
   else {
      suffix = segment_name_suffix(lay->name, suffix_storage, sizeof(suffix_storage));
      if (suffix &&
          ((lay->segid == O26_SEG_BSS && segment_name_matches_prefix(lay->name, "BSS")) ||
           (lay->segid == O26_SEG_ZP &&
            (segment_name_matches_prefix(lay->name, "ZEROPAGE") ||
             segment_name_matches_prefix(lay->name, "ZP") ||
             segment_name_matches_prefix(lay->name, "ZERO")))))
         run_name = suffix;
   }

   run_rule = find_layout_segment_rule(cfg, lay->name, fallback);
   if (run_rule)
      run_name = rule_run_region_name(run_rule);
   run_name = component_resolve_memory_name(cfg, lay, run_name);
   return run_name && *run_name ? find_memory(cfg, run_name) : NULL;
}

//! @brief Return whether the compact reset path can replace generic startup.
static int startup_simple_is_safe(const linker_config_t *cfg, const input_set_t *in)
{
   size_t i, j;

   if (!cfg || !in || count_init_functions_in_input(in) != 0)
      return 0;

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->layout_count; ++j) {
         const object_layout_t *lay = &obj->layouts[j];
         int needs_zero = 0;

         if (lay->size == 0)
            continue;

         /* Any link-time DATA image requires the generic ROM-to-RAM copier. */
         if (lay->segid == O26_SEG_DATA ||
             (lay->segid == O26_SEG_ZP &&
              (lay->image_segid == O26_SEG_DATA || lay->image_segid == O26_SEG_TEXT)))
            return 0;

         if (lay->segid == O26_SEG_BSS &&
             strstr(lay->name, ".__vcsc_object$__vcsc_scratch_") == NULL)
            needs_zero = 1;
         else if (lay->segid == O26_SEG_ZP &&
                  lay->image_segid != O26_SEG_DATA && lay->image_segid != O26_SEG_TEXT &&
                  strstr(lay->name, ".__vcsc_object$") != NULL &&
                  strstr(lay->name, ".__vcsc_object$__vcsc_scratch_") == NULL)
            needs_zero = 1;

         if (needs_zero &&
             !startup_simple_memory_is_riot(startup_simple_layout_run_memory(cfg, lay)))
            return 0;
      }
   }
   return 1;
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
      call_graph_collect_from_object(&in->objects[i], &nodes, &node_count, &edges, &edge_count, 1);

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
                            piece->layout->run_addr,
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
   typedef struct phase_overlay_candidate_t {
      object_file_t *obj;
      object_layout_t *lay;
      char run_name[MAX_NAME];
      size_t group_index;
   } phase_overlay_candidate_t;
   typedef struct phase_overlay_group_t {
      char run_name[MAX_NAME];
      uint16_t size;
      uint16_t alignment;
      uint8_t mask;
      uint8_t has_zp_member;
      uint8_t needs_whole_page;
      size_t leader_candidate;
      size_t member_count;
      uint16_t run_addr;
      int allocated;
   } phase_overlay_group_t;
   phase_overlay_candidate_t *phase_candidates = NULL;
   phase_overlay_group_t *phase_groups = NULL;
   size_t phase_candidate_count = 0;
   size_t phase_candidate_capacity = 0;
   size_t phase_group_count = 0;
   size_t phase_group_capacity = 0;
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

   /* Clear placement state before planning phase overlays. */
   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      obj->place_text_load = 0;
      obj->place_data_load = 0;
      for (j = 0; j < obj->layout_count; ++j) {
         obj->layouts[j].load_addr = 0;
         obj->layouts[j].run_addr = 0;
      }
   }

   /* Gather phase-confined writable objects in their ordinary allocation
      order. Merely having phase metadata does not move an object: only a
      group with two or more mutually disjoint phase-use sets gets a shared
      physical slot. This preserves historical addresses for solitary
      phase-scoped objects while still making grouping independent of member
      size and declaration order. */
   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->layout_count; ++j) {
         object_layout_t *lay = &obj->layouts[j];
         char suffix_storage[MAX_NAME];
         const char *suffix;
         const char *run_name;

         if ((lay->segid != O26_SEG_BSS && lay->segid != O26_SEG_ZP) ||
             !lay->phase_overlay_eligible || !lay->phase_use_seen ||
             lay->phase_unscoped_use || lay->phase_mask == 0 ||
             lay->image_segid == O26_SEG_DATA || lay->image_segid == O26_SEG_TEXT)
            continue;
         if (activation_segment_parse(lay->name, suffix_storage,
                                      sizeof(suffix_storage), NULL))
            continue;
         suffix = segment_name_suffix(lay->name, suffix_storage, sizeof(suffix_storage));
         if (lay->segid == O26_SEG_BSS)
            run_name = (suffix && segment_name_matches_prefix(lay->name, "BSS"))
               ? suffix : bss_run_name;
         else
            run_name = (suffix && (segment_name_matches_prefix(lay->name, "ZEROPAGE") ||
                                   segment_name_matches_prefix(lay->name, "ZP") ||
                                   segment_name_matches_prefix(lay->name, "ZERO")))
               ? suffix : zp_run_name;
         if (phase_candidate_count == phase_candidate_capacity) {
            size_t new_capacity = phase_candidate_capacity ? phase_candidate_capacity * 2 : 16;
            phase_overlay_candidate_t *grown = realloc(phase_candidates,
               new_capacity * sizeof(*grown));
            if (!grown) {
               fprintf(stderr, "vcsc-ld: out of memory collecting phase overlay candidates\n");
               exit(1);
            }
            phase_candidates = grown;
            phase_candidate_capacity = new_capacity;
         }
         phase_candidates[phase_candidate_count].obj = obj;
         phase_candidates[phase_candidate_count].lay = lay;
         snprintf(phase_candidates[phase_candidate_count].run_name,
                  sizeof(phase_candidates[phase_candidate_count].run_name), "%s", run_name);
         phase_candidates[phase_candidate_count].group_index = SIZE_MAX;
         phase_candidate_count++;
      }
   }

   /* Build sharing groups largest-first so a small object declared first can
      still share with a larger later object. The group's leader is always the
      earliest member in ordinary allocation order; the group is allocated
      only when that leader is reached below. */
   if (phase_candidate_count != 0) {
      size_t *order = xmalloc(phase_candidate_count * sizeof(*order));
      for (i = 0; i < phase_candidate_count; ++i)
         order[i] = i;
      for (i = 0; i < phase_candidate_count; ++i) {
         size_t best = i;
         for (j = i + 1; j < phase_candidate_count; ++j) {
            if (phase_candidates[order[j]].lay->size >
                phase_candidates[order[best]].lay->size)
               best = j;
         }
         if (best != i) {
            size_t tmp = order[i];
            order[i] = order[best];
            order[best] = tmp;
         }
      }
      for (i = 0; i < phase_candidate_count; ++i) {
         size_t ci = order[i];
         phase_overlay_candidate_t *candidate = &phase_candidates[ci];
         object_layout_t *lay = candidate->lay;
         size_t chosen = SIZE_MAX;

         for (j = 0; j < phase_group_count; ++j) {
            phase_overlay_group_t *group = &phase_groups[j];
            if (strcmp(group->run_name, candidate->run_name) != 0 ||
                (group->mask & lay->phase_mask) != 0)
               continue;
            chosen = j;
            break;
         }
         if (chosen == SIZE_MAX) {
            if (phase_group_count == phase_group_capacity) {
               size_t new_capacity = phase_group_capacity ? phase_group_capacity * 2 : 8;
               phase_overlay_group_t *grown = realloc(phase_groups,
                  new_capacity * sizeof(*grown));
               if (!grown) {
                  fprintf(stderr, "vcsc-ld: out of memory creating phase overlay groups\n");
                  exit(1);
               }
               phase_groups = grown;
               phase_group_capacity = new_capacity;
            }
            chosen = phase_group_count++;
            memset(&phase_groups[chosen], 0, sizeof(phase_groups[chosen]));
            snprintf(phase_groups[chosen].run_name,
                     sizeof(phase_groups[chosen].run_name), "%s", candidate->run_name);
            phase_groups[chosen].leader_candidate = ci;
         }
         {
            phase_overlay_group_t *group = &phase_groups[chosen];
            candidate->group_index = chosen;
            group->mask |= lay->phase_mask;
            if (lay->size > group->size)
               group->size = lay->size;
            if (lay->component_alignment > group->alignment)
               group->alignment = lay->component_alignment;
            if (lay->segid == O26_SEG_ZP)
               group->has_zp_member = 1;
            if (lay->flags & (O26_LAYOUT_PAGE_CONTAINED | O26_LAYOUT_INDEX_RANGE))
               group->needs_whole_page = 1;
            if (ci < group->leader_candidate)
               group->leader_candidate = ci;
            group->member_count++;
         }
      }
      free(order);
   }

   for (i = 0; i < in->object_count; ++i) {
      object_file_t *obj = &in->objects[i];

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
            : component_resolve_memory_name(cfg, lay,
               (rule && rule->load_name[0]) ? rule->load_name : code_load_name);
         lay->load_addr = alloc_code_branch_aware(layout, cfg, load_name, obj, lay,
            lay->component_alignment ? lay->component_alignment
               : (rule && rule->align ? rule->align : 1),
            lay->name, obj->origin);
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
         load_name = component_resolve_memory_name(cfg, lay,
            (rule && rule->load_name[0]) ? rule->load_name : data_load_name);
         lay->load_addr = alloc_from_region_policy(layout, cfg, load_name, lay->size,
            lay->component_alignment ? lay->component_alignment
               : (rule && rule->align ? rule->align : 1),
            NULL, lay->name, obj->origin);
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
               const segment_rule_t *run_rule = find_layout_segment_rule(cfg, lay->name, data);
               uint16_t run_alignment = lay->component_alignment ? lay->component_alignment
                  : (run_rule && run_rule->align ? run_rule->align : 1);
               lay->run_addr = alloc_from_region_policy(layout, cfg, run_name, lay->size, run_alignment,
                  lay, lay->name, obj->origin);
               add_copy_record(layout, lay->name, lay->load_addr, lay->run_addr,
                               memory_runtime_write_address(cfg, run_name, lay->run_addr, lay->size),
                               lay->size);
               break;
            }

            case O26_SEG_BSS: {
               const char *run_name = (suffix && segment_name_matches_prefix(lay->name, "BSS")) ? suffix : bss_run_name;
               size_t candidate_index = SIZE_MAX;
               size_t group_index = SIZE_MAX;
               for (size_t k = 0; k < phase_candidate_count; ++k) {
                  if (phase_candidates[k].lay == lay) {
                     candidate_index = k;
                     group_index = phase_candidates[k].group_index;
                     break;
                  }
               }
               if (group_index != SIZE_MAX && phase_groups[group_index].member_count > 1) {
                  phase_overlay_group_t *group = &phase_groups[group_index];
                  if (!group->allocated) {
                     object_layout_t constraints = *lay;
                     if (candidate_index != group->leader_candidate) {
                        fprintf(stderr,
                                "vcsc-ld: internal phase-overlay leader ordering failure for %s from %s\n",
                                lay->name, obj->origin);
                        exit(1);
                     }
                     constraints.size = group->size;
                     constraints.component_alignment = group->alignment;
                     if (group->has_zp_member)
                        constraints.segid = O26_SEG_ZP;
                     if (group->needs_whole_page) {
                        constraints.flags |= O26_LAYOUT_PAGE_CONTAINED;
                        constraints.flags &= (uint8_t)~O26_LAYOUT_INDEX_RANGE;
                     }
                     group->run_addr = alloc_from_region_policy(layout, cfg, run_name,
                        group->size, group->alignment ? group->alignment : 1,
                        &constraints, lay->name, obj->origin);
                     for (size_t k = 0; k < phase_candidate_count; ++k) {
                        phase_overlay_candidate_t *member = &phase_candidates[k];
                        if (member->group_index != group_index)
                           continue;
                        if (!object_page_constraints_hold(cfg, member->lay, group->run_addr) ||
                            (member->lay->component_alignment > 1 &&
                             (group->run_addr % member->lay->component_alignment) !=
                                member->lay->component_phase)) {
                           fprintf(stderr,
                                   "vcsc-ld: cannot satisfy phase-overlay placement constraints for %s and %s\n",
                                   lay->name, member->lay->name);
                           exit(1);
                        }
                     }
                     group->allocated = 1;
                  }
                  lay->run_addr = group->run_addr;
               }
               else {
                  const segment_rule_t *run_rule = find_layout_segment_rule(cfg, lay->name, bss);
                  uint16_t run_alignment = lay->component_alignment ? lay->component_alignment
                     : (run_rule && run_rule->align ? run_rule->align : 1);
                  lay->run_addr = alloc_from_region_policy(layout, cfg, run_name, lay->size, run_alignment,
                     lay, lay->name, obj->origin);
               }
               if (strstr(lay->name, ".__vcsc_object$__vcsc_scratch_") == NULL)
                  add_zero_record(layout, lay->name, lay->run_addr,
                                  memory_runtime_write_address(cfg, run_name, lay->run_addr, lay->size),
                                  lay->size);
               break;
            }

            case O26_SEG_ZP: {
               const char *run_name = (suffix && (segment_name_matches_prefix(lay->name, "ZEROPAGE") || segment_name_matches_prefix(lay->name, "ZP") || segment_name_matches_prefix(lay->name, "ZERO"))) ? suffix : zp_run_name;
               size_t candidate_index = SIZE_MAX;
               size_t group_index = SIZE_MAX;
               for (size_t k = 0; k < phase_candidate_count; ++k) {
                  if (phase_candidates[k].lay == lay) {
                     candidate_index = k;
                     group_index = phase_candidates[k].group_index;
                     break;
                  }
               }
               if (group_index != SIZE_MAX && phase_groups[group_index].member_count > 1) {
                  phase_overlay_group_t *group = &phase_groups[group_index];
                  if (!group->allocated) {
                     object_layout_t constraints = *lay;
                     if (candidate_index != group->leader_candidate) {
                        fprintf(stderr,
                                "vcsc-ld: internal phase-overlay leader ordering failure for %s from %s\n",
                                lay->name, obj->origin);
                        exit(1);
                     }
                     constraints.size = group->size;
                     constraints.component_alignment = group->alignment;
                     constraints.segid = O26_SEG_ZP;
                     if (group->needs_whole_page) {
                        constraints.flags |= O26_LAYOUT_PAGE_CONTAINED;
                        constraints.flags &= (uint8_t)~O26_LAYOUT_INDEX_RANGE;
                     }
                     group->run_addr = alloc_from_region_policy(layout, cfg, run_name,
                        group->size, group->alignment ? group->alignment : 1,
                        &constraints, lay->name, obj->origin);
                     for (size_t k = 0; k < phase_candidate_count; ++k) {
                        phase_overlay_candidate_t *member = &phase_candidates[k];
                        if (member->group_index != group_index)
                           continue;
                        if (!object_page_constraints_hold(cfg, member->lay, group->run_addr) ||
                            (member->lay->component_alignment > 1 &&
                             (group->run_addr % member->lay->component_alignment) !=
                                member->lay->component_phase)) {
                           fprintf(stderr,
                                   "vcsc-ld: cannot satisfy phase-overlay placement constraints for %s and %s\n",
                                   lay->name, member->lay->name);
                           exit(1);
                        }
                     }
                     group->allocated = 1;
                  }
                  lay->run_addr = group->run_addr;
               }
               else {
                  const segment_rule_t *run_rule = find_layout_segment_rule(cfg, lay->name, zp);
                  uint16_t run_alignment = lay->component_alignment ? lay->component_alignment
                     : (run_rule && run_rule->align ? run_rule->align : 1);
                  lay->run_addr = alloc_from_region_policy(layout, cfg, run_name, lay->size, run_alignment,
                     lay, lay->name, obj->origin);
               }
               if (lay->image_segid == O26_SEG_DATA || lay->image_segid == O26_SEG_TEXT)
                  add_copy_record(layout, lay->name, lay->load_addr, lay->run_addr,
                                  memory_runtime_write_address(cfg, run_name, lay->run_addr, lay->size),
                                  lay->size);
               else if (strstr(lay->name, ".__vcsc_object$") != NULL &&
                        strstr(lay->name, ".__vcsc_object$__vcsc_scratch_") == NULL)
                  add_zero_record(layout, lay->name, lay->run_addr,
                                  memory_runtime_write_address(cfg, run_name, lay->run_addr, lay->size),
                                  lay->size);
               break;
            }
         }
      }
   }

   free(phase_candidates);
   free(phase_groups);
   phase_candidates = NULL;
   phase_groups = NULL;

   layout_activation_segments(cfg, in, layout, bss_run_name, zp_run_name);

   if (!selected_objects_have_export(in, "__vcsc_startup_simple")) {
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
   }

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

//! @brief Return whether a relocation is the inline logical target word for a generic bank call.
static int relocation_is_bank_target(const reloc_t *r)
{
   return r && O26_RTYPE_IS_BANK_TARGET(r->type);
}

//! @brief Return the segment containing one relocation image id.
static const o26_segment_t *object_image_segment(const object_file_t *obj, uint8_t image_segid)
{
   if (!obj) return NULL;
   if (image_segid == O26_SEG_TEXT) return &obj->text;
   if (image_segid == O26_SEG_DATA) return &obj->data;
   return NULL;
}

//! @brief Return whether a direct JSR relocation owns the immediately following .banktarget word.
static int jsr_has_inline_bank_target(const object_file_t *obj, uint8_t image_segid,
                                      const reloc_t *jsr)
{
   const o26_segment_t *seg = object_image_segment(obj, image_segid);
   size_t i;
   if (!seg || !jsr || (jsr->type & O26_RTYPE_CONTROL_MASK) != O26_RTYPE_CONTROL_JSR)
      return 0;
   for (i = 0; i < seg->reloc_count; ++i) {
      const reloc_t *r = &seg->relocs[i];
      if (relocation_is_bank_target(r) && r->offset == jsr->offset + 2u &&
          r->segid == jsr->segid && r->undef_index == jsr->undef_index &&
          r->has_layout_index == jsr->has_layout_index &&
          (!r->has_layout_index || r->layout_index == jsr->layout_index))
         return 1;
   }
   return 0;
}

//! @brief Validate selector geometry and return the base indexed by logical PC high bits.
static uint16_t generic_bankcall_selector_base(const linker_config_t *cfg)
{
   size_t i;
   uint16_t base = 0;
   int have_base = 0;
   if (!cfg || (cfg->bank_count != 2u && cfg->bank_count != 3u && cfg->bank_count != 4u && cfg->bank_count != 8u)) {
      fprintf(stderr, "vcsc-ld: generic inline-target bank calls currently require 2, 3, 4, or 8 selector-controlled banks\n");
      exit(1);
   }
   for (i = 0; i < cfg->bank_count; ++i) {
      uint8_t logical_index;
      uint16_t candidate;
      if (!cfg->banks[i].hotspot) {
         fprintf(stderr, "vcsc-ld: generic inline-target bank calls require a selector on every bank\n");
         exit(1);
      }
      /* The pilot profiles deliberately use distinct logical ORGs whose top
         three PC bits encode the selector offset directly: Fxxx=>7,
         Dxxx=>6, ..., 1xxx=>0.  The 6507 drops those high address bits on
         the external bus, but JSR/RTS preserve them on the hardware stack. */
      logical_index = (uint8_t)((cfg->banks[i].start >> 13) & 7u);
      if (cfg->banks[i].hotspot < logical_index) {
         fprintf(stderr, "vcsc-ld: generic inline-target bank-call selector geometry underflows for bank '%s'\n",
                 cfg->banks[i].name);
         exit(1);
      }
      candidate = (uint16_t)(cfg->banks[i].hotspot - logical_index);
      if (!have_base) {
         base = candidate;
         have_base = 1;
      }
      else if (candidate != base) {
         fprintf(stderr,
                 "vcsc-ld: generic inline-target bank calls require selectors addressable as one base plus logical-PC bits\n");
         exit(1);
      }
   }
   if (!have_base || (uint32_t)base + 7u > 0x1fffu) {
      fprintf(stderr, "vcsc-ld: generic inline-target bank-call selector base is invalid\n");
      exit(1);
   }
   return base;
}

//! @brief Reserve the fixed generic bank-call block before variable JMP/legacy entries are allocated.
static void prepare_generic_bankcall_corridor(const linker_config_t *cfg,
                                               const input_set_t *in,
                                               layout_t *layout)
{
   size_t i, j;
   int found = 0;
   if (!cfg || !in || !layout || !cfg->cartridge_banked)
      return;
   for (i = 0; i < in->object_count && !found; ++i) {
      const o26_segment_t *segments[2] = { &in->objects[i].text, &in->objects[i].data };
      for (j = 0; j < 2u && !found; ++j) {
         size_t r;
         for (r = 0; r < segments[j]->reloc_count; ++r) {
            if (relocation_is_bank_target(&segments[j]->relocs[r])) {
               found = 1;
               break;
            }
         }
      }
   }
   if (!found) return;
   (void)generic_bankcall_selector_base(cfg);
   if (BANK_GENERIC_JSR_SIZE > cfg->trampoline_size) {
      fprintf(stderr, "vcsc-ld: generic inline-target bank-call block needs $%02X bytes but trampoline corridor has only $%03X\n",
              BANK_GENERIC_JSR_SIZE, cfg->trampoline_size);
      exit(1);
   }
   layout->bank_generic_jsr_used = 1;
   layout->bank_trampoline_used = BANK_GENERIC_JSR_SIZE;
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

   if (!cfg || (!cfg->cartridge_banked && !c26_topology_is_fe(cfg)))
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

   if (c26_topology_is_fe(cfg)) {
      if (control == O26_RTYPE_CONTROL_JSR) {
         const char *caller = call_graph_layout_function_name(source_layout);
         const char *display = caller ? display_function_symbol(caller) : NULL;
         if (!display || strcmp(display, "main") != 0) {
            fprintf(stderr,
                    "vcsc-ld: FE cross-bank JSR in %s layout '%s' at $%04X (%s) targets '%s' at $%04X (%s), but FE direct switching requires a top-level main call with S=$FF\n",
                    obj->origin, source_layout->name, source_address, source_bank->name,
                    target->name, target->address, different_bank->name);
            exit(1);
         }
         if ((r->type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD)) !=
             O26_RTYPE_WORD) {
            fprintf(stderr,
                    "vcsc-ld: direct FE cross-bank JSR relocation in %s is not a 16-bit operand\n",
                    obj->origin);
            exit(1);
         }
         /* Released FE/SCABS carts intentionally execute this JSR directly.
            With S=$FF its low return-address push hits $01FE; the following
            target-high fetch selects D/C -> physical bank 1 or E/F -> bank 0.
            RTS later reads $01FE and the caller-high byte restores the source
            bank automatically. */
         return target->address;
      }
      if (control == O26_RTYPE_CONTROL_JMP) {
         fprintf(stderr,
                 "vcsc-ld: FE cross-bank JMP in %s layout '%s' at $%04X (%s) targets '%s' at $%04X (%s); FE has no address hotspot, use the reviewed top-level JSR/RTS switching idiom\n",
                 obj->origin, source_layout->name, source_address, source_bank->name,
                 target->name, target->address, different_bank->name);
         exit(1);
      }
      if (control == O26_RTYPE_CONTROL_BRANCH) {
         fprintf(stderr,
                 "vcsc-ld: FE cross-bank conditional branch in %s layout '%s' at $%04X (%s) targets '%s' at $%04X (%s); conditional branches may not cross banks\n",
                 obj->origin, source_layout->name, source_address, source_bank->name,
                 target->name, target->address, different_bank->name);
         exit(1);
      }
      fprintf(stderr,
              "vcsc-ld: FE cross-bank ROM %s relocation in %s layout '%s' at $%04X (%s) targets '%s' at $%04X (%s); FE data references do not switch banks\n",
              relocation_width_name(r->type), obj->origin, source_layout->name,
              source_address, source_bank->name, target->name, target->address,
              different_bank->name);
      exit(1);
   }

   if (relocation_is_bank_target(r)) {
      /* The two inline bytes are deliberately a logical far target.  They are
         consumed by __bankcall while the source bank is still mapped and are
         not an ordinary CPU data reference. */
      if (!final_bank || final_bank == source_bank) {
         fprintf(stderr,
                 "vcsc-ld: inline .banktarget in %s at $%04X does not resolve to a different destination bank\n",
                 obj->origin, source_address);
         exit(1);
      }
      return target->address;
   }

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
      if (jsr_has_inline_bank_target(obj, image_segid, r)) {
         if (!layout->bank_generic_jsr_used) {
            fprintf(stderr, "vcsc-ld: internal error: inline bank target reached without reserved generic bank-call block\n");
            exit(1);
         }
         address = (uint32_t)source_bank->start + cfg->trampoline_offset;
         if (address > 0xFFFFu) {
            fprintf(stderr, "vcsc-ld: generated generic JSR trampoline address overflow\n");
            exit(1);
         }
         return (uint16_t)address;
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
static void apply_segment_relocs(const input_set_t *in,
                                 object_file_t *obj, o26_segment_t *seg,
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

      target = resolve_reloc_target(in, cfg, obj, r, current_word, layout,
                                    image_segid);
      resolved_address = rewrite_banked_relocation(cfg, obj, image_segid, r,
                                                   &target, layout);

      if ((r->type & O26_RTYPE_INDIRECT_JMP) && !relocation_is_bank_target(r) &&
          (resolved_address & 0xffu) == 0xffu) {
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
//! @brief Reject CPU/link-time address references to file-domain-only data.
static void validate_data_only_relocation_segment(input_set_t *in,
                                                  object_file_t *obj,
                                                  o26_segment_t *seg,
                                                  const linker_config_t *cfg)
{
   size_t i;
   for (i = 0; i < seg->reloc_count; ++i) {
      const reloc_t *r = &seg->relocs[i];
      uint16_t current_word;
      uint16_t delta = 0;
      const char *target_name = NULL;
      object_layout_t *target;
      const memory_region_t *mem;

      if (r->offset >= seg->length)
         continue;
      switch (r->type & (O26_RTYPE_LOW | O26_RTYPE_HIGH | O26_RTYPE_WORD)) {
         case O26_RTYPE_WORD:
            if (r->offset + 1 >= seg->length)
               continue;
            current_word = (uint16_t)(seg->data[r->offset] |
                                      (seg->data[r->offset + 1] << 8));
            break;
         case O26_RTYPE_LOW:
            current_word = (uint16_t)(seg->data[r->offset] |
                                      ((r->has_aux_low ? r->aux_low : 0) << 8));
            break;
         case O26_RTYPE_HIGH:
            current_word = (uint16_t)((r->has_aux_low ? r->aux_low : 0) |
                                      (seg->data[r->offset] << 8));
            break;
         default:
            continue;
      }
      target = read_hazard_reloc_target(in, obj, r, current_word,
                                        &delta, &target_name);
      (void)delta;
      if (!target)
         continue;
      mem = bank_placement_layout_memory(cfg, target);
      if (!mem || mem->output_mode != MEM_OUTPUT_DATA_ONLY)
         continue;
      fprintf(stderr,
              "vcsc-ld: relocation in %s targets data-only object '%s' in bank '%s'; data-only banks have no 6507 address\n",
              obj->origin, target_name ? target_name : target->name,
              mem->output_bank_name[0] ? mem->output_bank_name : mem->data_bank_name);
      exit(1);
   }
}

//! @brief Reject any ordinary relocation that would manufacture a CPU address for data-only storage.
static void validate_data_only_relocations(input_set_t *in,
                                           const linker_config_t *cfg)
{
   size_t i;
   if (!in || !cfg)
      return;
   for (i = 0; i < in->object_count; ++i) {
      validate_data_only_relocation_segment(in, &in->objects[i],
                                            &in->objects[i].text, cfg);
      validate_data_only_relocation_segment(in, &in->objects[i],
                                            &in->objects[i].data, cfg);
   }
}

static void resolve_all(input_set_t *in, layout_t *layout,
                        const linker_config_t *cfg)
{
   size_t i;
   for (i = 0; i < in->object_count; ++i) {
      apply_segment_relocs(in, &in->objects[i], &in->objects[i].text, layout, cfg,
                           O26_SEG_TEXT, "text");
      apply_segment_relocs(in, &in->objects[i], &in->objects[i].data, layout, cfg,
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

//! @brief Opcode for a state-preserving selector access.
static uint8_t selector_access_opcode(uint16_t hotspot, int vector_bridge)
{
   /* ROM-window selectors can consume a store harmlessly.  Below-window
      selectors overlap console devices, so use the NMOS absolute NOP ($0C):
      it performs the required read bus cycle without changing registers/flags
      or writing through to the mirrored TIA/RIOT device. */
   if ((hotspot & 0x1000u) == 0)
      return 0x0Cu;
   return vector_bridge ? 0x2Cu : 0x8Du;
}

//! @brief Encode one selector-access/JMP-handler vector bridge entry.
static void encode_vector_bridge_entry(uint8_t *table, size_t offset,
                                       uint16_t bank0_hotspot,
                                       uint16_t handler)
{
   table[offset + 0u] = selector_access_opcode(bank0_hotspot, 1);
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
   table[offset + 0u] = selector_access_opcode(entry->destination_hotspot, 0); /* STA in ROM window, NOP-read below it. */
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
   table[offset + 3u] = selector_access_opcode(entry->source_hotspot, 0); /* Restore source bank. */
   table[offset + 4u] = (uint8_t)(entry->source_hotspot & 0xFFu);
   table[offset + 5u] = (uint8_t)((entry->source_hotspot >> 8) & 0xFFu);
   table[offset + 6u] = 0x60u; /* RTS through the original caller return. */
   table[offset + 7u] = selector_access_opcode(entry->destination_hotspot, 0); /* Select destination bank. */
   table[offset + 8u] = (uint8_t)(entry->destination_hotspot & 0xFFu);
   table[offset + 9u] = (uint8_t)((entry->destination_hotspot >> 8) & 0xFFu);
   table[offset + 10u] = 0x6Cu; /* JMP through the inline target word. */
   table[offset + 11u] = (uint8_t)(canonical_pointer & 0xFFu);
   table[offset + 12u] = (uint8_t)((canonical_pointer >> 8) & 0xFFu);
   table[offset + 13u] = (uint8_t)(entry->target_addr & 0xFFu);
   table[offset + 14u] = (uint8_t)((entry->target_addr >> 8) & 0xFFu);
}

//! @brief Instantiate the maintained S26 inline-target bank-call template.
static void encode_generic_bank_jsr_block(uint8_t *table,
                                          const linker_config_t *cfg,
                                          uint16_t canonical_base,
                                          uint16_t ptr0)
{
   size_t i;
   uint16_t selector_base = generic_bankcall_selector_base(cfg);
   uint16_t switch_addr;

   if (ptr0 > 0x00feu) {
      fprintf(stderr, "vcsc-ld: generic bank-call scratch _vcsc_ptr0 must be a two-byte zero-page object, got $%04X\n", ptr0);
      exit(1);
   }
   if (VCSC_GENERIC_BANKCALL_TEMPLATE_SIZE > BANK_GENERIC_JSR_SIZE) {
      fprintf(stderr,
              "vcsc-ld: internal error: assembled generic bank-call template needs %u bytes but only $%02X are reserved\n",
              (unsigned)VCSC_GENERIC_BANKCALL_TEMPLATE_SIZE, BANK_GENERIC_JSR_SIZE);
      exit(1);
   }

   memcpy(table, vcsc_generic_bankcall_template, VCSC_GENERIC_BANKCALL_TEMPLATE_SIZE);

   for (i = 0; i < VCSC_GENERIC_BANKCALL_PTR_PATCH_COUNT; ++i) {
      const vcsc_generic_bankcall_ptr_patch_t *patch = &vcsc_generic_bankcall_ptr_patches[i];
      table[patch->offset] = (uint8_t)(ptr0 + patch->delta);
   }
   for (i = 0; i < VCSC_GENERIC_BANKCALL_SELECTOR_PATCH_COUNT; ++i) {
      uint8_t off = vcsc_generic_bankcall_selector_patches[i];
      table[off + 0u] = (uint8_t)(selector_base & 0xffu);
      table[off + 1u] = (uint8_t)(selector_base >> 8);
   }

   switch_addr = (uint16_t)(canonical_base + VCSC_GENERIC_BANKCALL_SWITCH_OFFSET);
   table[VCSC_GENERIC_BANKCALL_INTERNAL_JSR_OPERAND_OFFSET + 0u] =
      (uint8_t)(switch_addr & 0xffu);
   table[VCSC_GENERIC_BANKCALL_INTERNAL_JSR_OPERAND_OFFSET + 1u] =
      (uint8_t)(switch_addr >> 8);
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
      table[out++] = (uint8_t)(rec->write_addr & 0xFFu);
      table[out++] = (uint8_t)((rec->write_addr >> 8) & 0xFFu);
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
      table[out++] = (uint8_t)(rec->write_addr & 0xFFu);
      table[out++] = (uint8_t)((rec->write_addr >> 8) & 0xFFu);
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
   if (!cfg->cartridge_banked && !cfg->topology_bank_count && !rom) {
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
         const memory_region_t *load_memory;
         const uint8_t *src;
         size_t image_len;

         if (lay->size == 0)
            continue;
         load_memory = bank_placement_layout_memory(cfg, lay);
         if (load_memory && load_memory->output_mode == MEM_OUTPUT_DATA_ONLY)
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
         if (layout->bank_generic_jsr_used) {
            uint16_t ptr0 = lookup_global_addr(layout, "_vcsc_ptr0");
            uint16_t canonical_base = (uint16_t)(startup->start + cfg->trampoline_offset);
            encode_generic_bank_jsr_block(trampoline, cfg, canonical_base, ptr0);
         }
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

//! @brief Compare C26 topology-bank pointers by explicit file index.
static int compare_topology_bank_file_index(const void *lhs, const void *rhs)
{
   const topology_bank_t *const *a = (const topology_bank_t *const *)lhs;
   const topology_bank_t *const *b = (const topology_bank_t *const *)rhs;
   if ((*a)->file_index < (*b)->file_index)
      return -1;
   if ((*a)->file_index > (*b)->file_index)
      return 1;
   return strcmp((*a)->name, (*b)->name);
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

//! @brief Return the signature byte for one final-bank physical offset.
static int topology_signature_byte(const linker_config_t *cfg, size_t file_index,
                                   uint32_t image_size, uint32_t offset, uint8_t *byte)
{
   uint32_t signature_offset;
   size_t i;
   size_t signature_file_index = 0;
   int found = 0;
   if (!cfg || !byte || !(cfg->topology_cartridge.present_mask & 0x80u) ||
       image_size < 8u)
      return 0;
   for (i = 0; i < cfg->topology_bank_count; ++i) {
      const topology_bank_t *bank = &cfg->topology_banks[i];
      if (bank->data_only)
         continue;
      if (!found || bank->file_index > signature_file_index) {
         signature_file_index = bank->file_index;
         found = 1;
      }
   }
   if (!found || file_index != signature_file_index)
      return 0;
   signature_offset = image_size - 8u;
   if (offset < signature_offset || offset > signature_offset + 3u)
      return 0;
   *byte = cfg->topology_cartridge.signature[offset - signature_offset];
   return 1;
}

//! @brief Write a flat binary in unbanked address-span or banked physical order.
//! @brief Return packed source bytes for one placed object layout.
static const uint8_t *layout_image_source(const object_file_t *obj,
                                          const object_layout_t *lay,
                                          const char *who)
{
   size_t image_len;
   if (!obj || !lay)
      return NULL;
   if (lay->image_segid == O26_SEG_TEXT) {
      image_len = obj->text.length;
      if ((uint32_t)lay->image_base + lay->size > image_len) {
         fprintf(stderr, "vcsc-ld: text image layout %s exceeds packed image in %s\n",
                 lay->name, who ? who : obj->origin);
         exit(1);
      }
      return obj->text.data + lay->image_base;
   }
   if (lay->image_segid == O26_SEG_DATA) {
      image_len = obj->data.length;
      if ((uint32_t)lay->image_base + lay->size > image_len) {
         fprintf(stderr, "vcsc-ld: data image layout %s exceeds packed image in %s\n",
                 lay->name, who ? who : obj->origin);
         exit(1);
      }
      return obj->data.data + lay->image_base;
   }
   return NULL;
}

//! @brief Emit one bank whose bytes exist only in the cartridge file domain.
static void write_data_only_bank(FILE *fp, const char *path,
                                 const linker_config_t *cfg,
                                 const input_set_t *in,
                                 const topology_bank_t *bank)
{
   uint8_t *bytes;
   uint8_t *occupied;
   size_t i, j;

   bytes = (uint8_t *)xmalloc(bank->image_size);
   occupied = (uint8_t *)calloc(bank->image_size, 1u);
   if (!occupied) {
      fprintf(stderr, "vcsc-ld: out of memory building data-only bank '%s'\n",
              bank->name);
      exit(1);
   }
   memset(bytes, cfg->topology_cartridge.fill_value, bank->image_size);

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->layout_count; ++j) {
         const object_layout_t *lay = &obj->layouts[j];
         const memory_region_t *mem;
         const uint8_t *src;
         uint32_t offset;
         size_t k;

         if (!lay->size)
            continue;
         mem = bank_placement_layout_memory(cfg, lay);
         if (!mem || mem->output_mode != MEM_OUTPUT_DATA_ONLY ||
             strcmp(mem->output_bank_name, bank->name))
            continue;
         if (!strncmp(lay->name, "CODE.", 5) ||
             !strncmp(lay->name, "STARTUP", 7)) {
            fprintf(stderr,
                    "vcsc-ld: executable layout '%s' from %s cannot be placed in data-only bank '%s'\n",
                    lay->name, obj->origin, bank->name);
            exit(1);
         }
         if (lay->load_addr < mem->start) {
            fprintf(stderr,
                    "vcsc-ld: data-only layout '%s' starts before mem region '%s'\n",
                    lay->name, mem->name);
            exit(1);
         }
         offset = (uint32_t)lay->load_addr - mem->start;
         if (offset + lay->size > mem->size || offset + lay->size > bank->image_size) {
            fprintf(stderr,
                    "vcsc-ld: data-only layout '%s' exceeds bank '%s'\n",
                    lay->name, bank->name);
            exit(1);
         }
         src = layout_image_source(obj, lay, obj->origin);
         if (!src)
            continue;
         for (k = 0; k < lay->size; ++k) {
            if (occupied[offset + k]) {
               fprintf(stderr,
                       "vcsc-ld: data-only layouts overlap at bank '%s' offset $%04X\n",
                       bank->name, (unsigned)(offset + k));
               exit(1);
            }
            bytes[offset + k] = src[k];
            occupied[offset + k] = 1;
         }
      }
   }

   for (i = 0; i < bank->image_size; ++i)
      write_binary_byte(fp, path, bytes[i]);
   free(bytes);
   free(occupied);
}

static void write_flat_binary(const char *path, const linker_config_t *cfg,
                              const input_set_t *in,
                              const uint8_t *image, const uint8_t *used)
{
   FILE *fp;
   uint32_t addr;

   fp = fopen(path, "wb");
   if (!fp) {
      fprintf(stderr, "vcsc-ld: cannot create '%s': %s\n", path, strerror(errno));
      exit(1);
   }

   if (cfg->topology_bank_count) {
      const topology_bank_t **order;
      size_t i;
      order = (const topology_bank_t **)xmalloc(
         cfg->topology_bank_count * sizeof(*order));
      for (i = 0; i < cfg->topology_bank_count; ++i)
         order[i] = &cfg->topology_banks[i];
      qsort(order, cfg->topology_bank_count, sizeof(*order),
            compare_topology_bank_file_index);

      for (i = 0; i < cfg->topology_bank_count; ++i) {
         const topology_bank_t *bank = order[i];
         uint32_t offset;
         if (bank->data_only) {
            write_data_only_bank(fp, path, cfg, in, bank);
            continue;
         }
         for (offset = 0; offset < bank->image_size; ++offset) {
            uint8_t byte = cfg->topology_cartridge.fill_value;
            if (offset >= bank->image_offset &&
                offset < (uint32_t)bank->image_offset + bank->map_size) {
               uint32_t logical = (uint32_t)bank->link_start +
                                  (offset - bank->image_offset);
               if (used[logical])
                  byte = image[logical];
            }
            (void)topology_signature_byte(cfg, bank->file_index,
                                          bank->image_size, offset, &byte);
            write_binary_byte(fp, path, byte);
         }
      }
      free(order);
   } else if (cfg->cartridge_banked) {
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

   if (!cfg || (!cfg->cartridge_banked && !c26_topology_is_fe(cfg)))
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
   if (str_ieq(mem->type, "ro")) {
      if (cfg->topology_bank_count && mem->compiler_declared &&
          mem->output_mode == MEM_OUTPUT_SHARED)
         return 0;
      return 1;
   }
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

//! @brief Count occupied bytes inside one file-domain data-only MEMORY region.
static uint32_t data_only_memory_region_used_bytes(const linker_config_t *cfg,
                                                   const memory_region_t *mem,
                                                   const input_set_t *in)
{
   uint8_t *occupied;
   uint32_t count = 0;
   size_t i, j;

   if (!cfg || !mem || !in || !mem->size)
      return 0;
   occupied = (uint8_t *)calloc(mem->size, 1u);
   if (!occupied) {
      fprintf(stderr, "vcsc-ld: out of memory measuring data-only region '%s'\n",
              mem->name);
      exit(1);
   }
   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      for (j = 0; j < obj->layout_count; ++j) {
         const object_layout_t *lay = &obj->layouts[j];
         const memory_region_t *owner;
         uint32_t offset;
         uint32_t k;

         if (!lay->size)
            continue;
         owner = bank_placement_layout_memory(cfg, lay);
         if (owner != mem || lay->load_addr < mem->start)
            continue;
         offset = (uint32_t)lay->load_addr - mem->start;
         if (offset >= mem->size)
            continue;
         for (k = 0; k < lay->size && offset + k < mem->size; ++k)
            occupied[offset + k] = 1;
      }
   }
   for (i = 0; i < mem->size; ++i)
      if (occupied[i])
         count++;
   free(occupied);
   return count;
}

//! @brief Write cartridge-ROM usage lines to the selected stream.
static void write_cartridge_rom_usage(FILE *fp, const linker_config_t *cfg,
                                      const input_set_t *in, const uint8_t *used,
                                      const char *indent)
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
      used_bytes = mem->output_mode == MEM_OUTPUT_DATA_ONLY
                 ? data_only_memory_region_used_bytes(cfg, mem, in)
                 : memory_region_used_bytes(mem, used);
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


//! @brief Report item-22 automatic locals which share their function return allocation.
static void write_return_coalescing(FILE *fp, const linker_config_t *cfg,
                                    const input_set_t *in)
{
   int wrote_header = 0;
   size_t i;

   if (!fp || !cfg || !in)
      return;
   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      size_t j;
      for (j = 0; j < obj->export_count; ++j) {
         const symbol_t *exp = &obj->exports[j];
         char *function = NULL;
         char *local = NULL;
         char *return_symbol = NULL;
         char *region = NULL;
         int size = 0;
         uint16_t read_addr;
         uint16_t write_addr;

         if (!return_coalesce_metadata_has_prefix(exp->name))
            continue;
         if (!return_coalesce_metadata_parse(exp->name, &function, &local,
                                             &return_symbol, &region, &size)) {
            fprintf(stderr, "vcsc-ld: malformed return-coalescing metadata symbol '%s' in %s\n",
                    exp->name, obj->origin);
            exit(1);
         }
         if (exp->segid == O26_SEG_ABS)
            read_addr = exp->value;
         else
            read_addr = object_runtime_addr_for_value(obj, exp->segid, exp->value);
         write_addr = (region && *region)
            ? memory_runtime_write_address(cfg, region, read_addr, (uint16_t)size)
            : read_addr;
         if (!wrote_header) {
            fprintf(fp, "\nRETURN COALESCING\n");
            wrote_header = 1;
         }
         fprintf(fp,
                 "  function=%s local=%s return=%s region=%s read=$%04X write=$%04X bytes=%d object=%s\n",
                 function, local, return_symbol,
                 region && *region ? region : "<default>",
                 read_addr, write_addr, size, obj->origin);
         free(function);
         free(local);
         free(return_symbol);
         free(region);
      }
   }
}


//! @brief Emit the source call-graph edges and hidden assembly contribution behind the hardware-stack reserve.
static void write_call_stack_diagnostics(FILE *fp, const linker_config_t *cfg,
                                         const input_set_t *in,
                                         const layout_t *layout)
{
   call_graph_node_t *nodes = NULL;
   call_graph_edge_t *edges = NULL;
   const cartridge_bank_t **banks = NULL;
   int *memo = NULL;
   size_t node_count = 0;
   size_t edge_count = 0;
   size_t i;
   int root = -1;
   int best = 0;
   uint32_t hidden_total = 0;

   if (!fp || !cfg || !in || !layout || !layout->call_stack_enabled)
      return;

   for (i = 0; i < in->object_count; ++i)
      call_graph_collect_from_object(&in->objects[i], &nodes, &node_count,
                                     &edges, &edge_count, 0);

   fprintf(fp, "\nCALL GRAPH\n");
   for (i = 0; i < edge_count; ++i) {
      const object_file_t *caller_obj = NULL;
      const cartridge_bank_t *from_bank = NULL;
      const cartridge_bank_t *to_bank = NULL;
      int bridge = 0;

      (void)call_graph_find_function_layout(in, nodes[edges[i].from].name,
                                            &caller_obj);
      from_bank = call_graph_function_bank(cfg, in, nodes[edges[i].from].name);
      to_bank = call_graph_function_bank(cfg, in, nodes[edges[i].to].name);
      bridge = from_bank && to_bank && from_bank != to_bank;
      {
         char from_display[512];
         char to_display[512];
         const char *display;

         display = display_function_symbol(nodes[edges[i].from].name);
         snprintf(from_display, sizeof(from_display), "%s", display);
         display = display_function_symbol(nodes[edges[i].to].name);
         snprintf(to_display, sizeof(to_display), "%s", display);
         fprintf(fp,
                 "  EDGE %s -> %s slots=%u reason=compiled-direct-call object=%s%s\n",
                 from_display, to_display, bridge ? 2u : 1u,
                 caller_obj ? caller_obj->origin : "<metadata>",
                 bridge ? " bank-bridge=yes" : "");
      }
   }

   if (node_count) {
      banks = (const cartridge_bank_t **)xcalloc(node_count, sizeof(*banks));
      memo = (int *)xcalloc(node_count, sizeof(*memo));
      for (i = 0; i < node_count; ++i)
         banks[i] = call_graph_function_bank(cfg, in, nodes[i].name);
      for (i = 0; i < node_count; ++i) {
         const char *display = display_function_symbol(nodes[i].name);
         int main_root = !strcmp(display, "main");
         int init_root = symbol_is_init_function(display);
         int depth;

         if (!main_root && !init_root)
            continue;
         depth = call_graph_longest_weighted_depth_visit((int)i, edges,
            edge_count, banks, memo);
         if (main_root && selected_startup_tail_enters_main(in) && depth > 0)
            depth--;
         if (depth > best ||
             (depth == best && root >= 0 &&
              strcmp(nodes[i].name, nodes[root].name) < 0)) {
            best = depth;
            root = (int)i;
         }
      }
      if (root >= 0) {
         int current = root;
         fprintf(fp, "  DEEPEST weighted-depth=%d path=%s", best,
                 display_function_symbol(nodes[current].name));
         while (memo[current] > 1) {
            int chosen = -1;
            size_t j;
            for (j = 0; j < edge_count; ++j) {
               int bridge;
               int candidate;
               if (edges[j].from != current)
                  continue;
               bridge = banks[current] && banks[edges[j].to] &&
                        banks[current] != banks[edges[j].to];
               candidate = 1 + bridge + memo[edges[j].to];
               if (candidate != memo[current])
                  continue;
               if (chosen < 0 ||
                   strcmp(nodes[edges[j].to].name, nodes[chosen].name) < 0)
                  chosen = edges[j].to;
            }
            if (chosen < 0)
               break;
            fprintf(fp, " -> %s", display_function_symbol(nodes[chosen].name));
            current = chosen;
         }
         fputc('\n', fp);
      }
   }

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      size_t j;
      for (j = 0; j < obj->export_count; ++j) {
         const char *name = obj->exports[j].name;
         const char *p;
         char *end = NULL;
         unsigned long value;
         if (!component_constraint_metadata_has_prefix(name))
            continue;
         p = name + sizeof(COMPONENT_CONSTRAINT_META_PREFIX) - 1u;
         if (p[0] != 'S' || p[1] != '$')
            continue;
         value = strtoul(p + 2, &end, 10);
         if (!end || *end || value > 0xffffu)
            continue;
         hidden_total += (uint32_t)value;
         fprintf(fp,
                 "  HIDDEN bytes=$%04lX reason=.callstackextra object=%s\n",
                 value, obj->origin);
      }
   }
   if (hidden_total < layout->call_stack_extra) {
      fprintf(fp,
              "  HIDDEN bytes=$%04X reason=linker-configured-callstack-extra object=<linker-script>\n",
              (unsigned)(layout->call_stack_extra - hidden_total));
   }
   hidden_total = layout->call_stack_extra;
   if (selected_objects_have_export(in, "__vcsc_startup_full")) {
      hidden_total += 2u;
      fprintf(fp,
              "  HIDDEN bytes=$0002 reason=full-startup-transient-stack object=<runtime>\n");
   }
   if (count_init_functions_in_input(in) > 0) {
      hidden_total += 2u;
      fprintf(fp,
              "  HIDDEN bytes=$0002 reason=runtime-init-cursor object=<runtime>\n");
   }
   fprintf(fp,
           "  TOTAL source-bytes=$%04X hidden-bytes=$%04X total-bytes=$%04X\n",
           (unsigned)(layout->call_stack_weighted_depth * 2u),
           (unsigned)hidden_total, layout->call_stack_size);

   for (i = 0; i < node_count; ++i)
      free(nodes[i].name);
   free(nodes);
   free(edges);
   free(banks);
   free(memo);
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

   if (cfg->topology_bank_count) {
      uint32_t output_size = 0;
      const topology_cartridge_t *cart = &cfg->topology_cartridge;
      for (i = 0; i < cfg->topology_bank_count; ++i)
         output_size += cfg->topology_banks[i].image_size;
      fprintf(fp, "C26 CARTRIDGE TOPOLOGY\n");
      fprintf(fp, "  output-size=$%08" PRIX32 " fill=$%02X",
              output_size, cart->fill_value);
      if (cart->present_mask & 0x06u)
         fprintf(fp, " trampoline=$%04X size=$%04X",
                 cart->trampoline_offset, cart->trampoline_size);
      if (cart->present_mask & 0x18u)
         fprintf(fp, " vector-bridge=$%04X size=$%04X",
                 cart->vector_bridge_offset, cart->vector_bridge_size);
      if (cart->present_mask & 0x60u)
         fprintf(fp, " vectors=$%04X size=$%04X",
                 cart->vectors_offset, cart->vectors_size);
      if (cart->present_mask & 0x80u) {
         fprintf(fp, " signature=\"");
         for (i = 0; i < 4u; ++i) {
            if (cart->signature[i])
               fputc(cart->signature[i], fp);
            else
               fputs("\\0", fp);
         }
         fputc('\"', fp);
      }
      fprintf(fp, " declaration=%s source=%s\n",
              cart->declaration[0] ? cart->declaration : "<unknown>",
              cart->source[0] ? cart->source : "<unknown>");
      for (i = 0; i < cfg->topology_bank_count; ++i) {
         const topology_bank_t *bank = &cfg->topology_banks[i];
         fprintf(fp,
                 "  %-12s file-index=%u image-size=$%04X image-offset=$%04X link=$%04X cpu=$%04X map-size=$%04X mode=%s",
                 bank->name, (unsigned)bank->file_index, bank->image_size,
                 bank->image_offset, bank->link_start, bank->cpu_start,
                 bank->map_size, bank->data_only ? "data-only" :
                 (bank->has_selector ? "selector" :
                 (c26_topology_is_fe(cfg) ? "fe-delayed" :
                  (c26_topology_is_wd(cfg) ? "wd-segmented" : "direct"))));
         if (bank->has_selector)
            fprintf(fp, " select-access=$%04X", bank->select_access);
         if (bank->startup)
            fprintf(fp, " startup=yes");
         fprintf(fp, " declaration=%s source=%s\n",
                 bank->declaration[0] ? bank->declaration : "<unknown>",
                 bank->source);
      }
      fprintf(fp, "\n");
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
      if (cfg->mem[i].compiler_declared) {
         const char *mode = cfg->mem[i].output_mode == MEM_OUTPUT_SWITCHED ? "switched" :
                            cfg->mem[i].output_mode == MEM_OUTPUT_DIRECT ? "direct" :
                            cfg->mem[i].output_mode == MEM_OUTPUT_DATA_ONLY ? "data-only" :
                            "shared";
         fprintf(fp, " priority=%" PRId32 " output-bank=%s mode=%s declaration=%s",
                 cfg->mem[i].priority,
                 cfg->mem[i].output_bank_name[0] ? cfg->mem[i].output_bank_name : "<none>",
                 mode,
                 cfg->mem[i].declaration[0] ? cfg->mem[i].declaration : "<unknown>");
      }
      else if (cfg->mem[i].bank_name[0])
         fprintf(fp, " bank=%s", cfg->mem[i].bank_name);
      fputc('\n', fp);
   }

   fprintf(fp, "\nMEMORY USAGE\n");
   write_cartridge_rom_usage(fp, cfg, in, used, "  ");
   write_ram_usage(fp, cfg, in, layout, "  ");
   write_return_coalescing(fp, cfg, in);

   if (cfg->bank_count > 1) {
      uint16_t max_component = 0;
      int have_component = 0;
      fprintf(fp, "\nBANK PLACEMENT\n");
      fprintf(fp, "  mode=%s\n",
              cfg->bank_placement_mode == BANK_PLACEMENT_MODE_SIMPLE
                 ? "simple" : "optimized");
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

      if (cfg->cartridge_banked && in->replica_count > 0) {
         uint32_t grand_total = 0;
         fprintf(fp, "\nREPLICATED ROM\n");
         for (i = 0; i < in->replica_count; ++i) {
            const replica_group_t *group = &in->replicas[i];
            const object_layout_t *original =
               &group->obj->layouts[group->original_layout_index];
            uint32_t total = (uint32_t)original->size * (uint32_t)group->copy_count;
            size_t copy_index;
            grand_total += total;
            fprintf(fp,
                    "  kind=%s symbol=%s copies=%zu bytes-each=$%04X physical-total=$%08" PRIX32 " object=%s\n",
                    group->kind == 'F' ? "function" : "object",
                    group->symbol, group->copy_count, original->size, total,
                    group->obj->origin);
            for (copy_index = 0; copy_index < group->copy_count; ++copy_index) {
               const object_layout_t *copy =
                  &group->obj->layouts[group->layout_indices[copy_index]];
               const cartridge_bank_t *bank =
                  replica_copy_bank(cfg, group, copy_index);
               fprintf(fp,
                       "     region=%-12s bank=%-8s load=$%04X size=$%04X layout=%s\n",
                       group->regions[copy_index], bank ? bank->name : "<none>",
                       copy->load_addr, copy->size, copy->name);
            }
         }
         fprintf(fp, "  physical-total-all=$%08" PRIX32 "\n", grand_total);
      }

      if (cfg->cartridge_banked) {
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
                 " target-passing=inline generic-jsr=$%03X entries=%zu jmp=%zu jsr=%zu jmp-size=$%02X jsr-size=$%02X\n",
                 cfg->trampoline_offset, cfg->trampoline_size,
                 layout->bank_trampoline_used,
                 (uint32_t)layout->bank_trampoline_used * (uint32_t)cfg->bank_count,
                 layout->bank_generic_jsr_used ? BANK_GENERIC_JSR_SIZE : 0u,
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
            if (lay->component_memory[0])
               fprintf(fp, " component-region=%s", lay->component_memory);
            if (lay->component_alignment) {
               fprintf(fp, " component-align=$%04X", lay->component_alignment);
               if (lay->component_phase)
                  fprintf(fp, " component-phase=$%04X", lay->component_phase);
            }
            if (lay->component_private)
               fprintf(fp, " component-private=yes");
            if (lay->phase_use_seen) {
               if (lay->phase_unscoped_use)
                  fprintf(fp, " phase=unscoped");
               else
                  fprintf(fp, " phase=$%02X", (unsigned)lay->phase_mask);
            }
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
            fprintf(fp, " size=$%04X load-page=%s run-page=%s",
                    lay->size, page_placement_name(lay->load_addr, lay->size, 0),
                    page_placement_name(lay->run_addr, lay->size,
                       (lay->flags & O26_LAYOUT_PAGE_CONTAINED) != 0));
            if (lay->component_memory[0])
               fprintf(fp, " component-region=%s", lay->component_memory);
            if (lay->component_alignment) {
               fprintf(fp, " component-align=$%04X", lay->component_alignment);
               if (lay->component_phase)
                  fprintf(fp, " component-phase=$%04X", lay->component_phase);
            }
            if (lay->component_private)
               fprintf(fp, " component-private=yes");
            if (lay->phase_use_seen) {
               if (lay->phase_unscoped_use)
                  fprintf(fp, " phase=unscoped");
               else
                  fprintf(fp, " phase=$%02X", (unsigned)lay->phase_mask);
            }
            fputc('\n', fp);
         }
         else {
            const memory_region_t *runtime_mem =
               find_runtime_memory_for_range(cfg, lay->run_addr, lay->size);
            fprintf(fp, "     %-16s run=$%04X", lay->name, lay->run_addr);
            if (runtime_mem && runtime_mem->has_write_start)
               fprintf(fp, " write=$%04X",
                       memory_runtime_write_address(cfg, runtime_mem->name,
                                                    lay->run_addr, lay->size));
            fprintf(fp, " size=$%04X page=%s", lay->size,
                    page_placement_name(lay->run_addr, lay->size,
                       (lay->flags & O26_LAYOUT_PAGE_CONTAINED) != 0));
            if (lay->component_memory[0])
               fprintf(fp, " component-region=%s", lay->component_memory);
            if (lay->component_alignment) {
               fprintf(fp, " component-align=$%04X", lay->component_alignment);
               if (lay->component_phase)
                  fprintf(fp, " component-phase=$%04X", lay->component_phase);
            }
            if (lay->component_private)
               fprintf(fp, " component-private=yes");
            if (lay->phase_use_seen) {
               if (lay->phase_unscoped_use)
                  fprintf(fp, " phase=unscoped");
               else
                  fprintf(fp, " phase=$%02X", (unsigned)lay->phase_mask);
            }
            fputc('\n', fp);
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

   fprintf(fp, "\nSTARTUP INITIALIZATION\n");
   if (selected_objects_have_export(in, "__vcsc_startup_simple"))
      fprintf(fp, "  policy=compact-riot-clear\n");
   else
      fprintf(fp, "  policy=every-reset bss=zero data=copy-through-write-alias\n");
   for (i = 0; i < layout->copy_record_count; ++i) {
      const copy_record_t *rec = &layout->copy_records[i];
      fprintf(fp, "  COPY %-48s load=$%04X read=$%04X write=$%04X size=$%04X%s\n",
              rec->name, rec->load_addr, rec->read_addr, rec->write_addr, rec->size,
              rec->read_addr != rec->write_addr ? " split=yes" : "");
   }
   for (i = 0; i < layout->zero_record_count; ++i) {
      const zero_record_t *rec = &layout->zero_records[i];
      fprintf(fp, "  ZERO %-48s read=$%04X write=$%04X size=$%04X%s\n",
              rec->name, rec->read_addr, rec->write_addr, rec->size,
              rec->read_addr != rec->write_addr ? " split=yes" : "");
   }

   fprintf(fp, "\nTABLES\n");
   if (layout->copy_table_size || layout->zero_table_size || layout->init_table_size) {
      fprintf(fp, "  __copy_table  $%04X size=$%04X\n", layout->copy_table_addr, layout->copy_table_size);
      fprintf(fp, "  __zero_table  $%04X size=$%04X\n", layout->zero_table_addr, layout->zero_table_size);
      fprintf(fp, "  __init_table  $%04X size=$%04X\n", layout->init_table_addr, layout->init_table_size);
   }
   else
      fprintf(fp, "  (not generated for compact startup)\n");
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
      write_call_stack_diagnostics(fp, cfg, in, layout);
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

//! One source-correlated statement placed into the final linked address space.
typedef struct {
   const object_file_t *obj;
   const object_layout_t *layout;
   const listing_record_t *record;
   const uint8_t *bytes;
   uint16_t addr;
} linked_listing_entry_t;

//! @brief Compare linked listing statements by final address, bank/layout, then source.
static int compare_linked_listing_entries(const void *a, const void *b)
{
   const linked_listing_entry_t *aa = (const linked_listing_entry_t *)a;
   const linked_listing_entry_t *bb = (const linked_listing_entry_t *)b;
   int cmp;
   if (aa->addr != bb->addr)
      return aa->addr < bb->addr ? -1 : 1;
   cmp = strcmp(aa->layout->placement_bank, bb->layout->placement_bank);
   if (cmp)
      return cmp;
   cmp = strcmp(aa->layout->name ? aa->layout->name : "", bb->layout->name ? bb->layout->name : "");
   if (cmp)
      return cmp;
   cmp = strcmp(aa->record->source_file ? aa->record->source_file : "",
                bb->record->source_file ? bb->record->source_file : "");
   if (cmp)
      return cmp;
   if (aa->record->source_line != bb->record->source_line)
      return aa->record->source_line < bb->record->source_line ? -1 : 1;
   return aa->record->offset < bb->record->offset ? -1 : aa->record->offset > bb->record->offset;
}

//! @brief Return final relocated bytes backing one source-listing record.
static const uint8_t *linked_listing_record_bytes(const object_file_t *obj,
                                                  const object_layout_t *layout,
                                                  const listing_record_t *record)
{
   const o26_segment_t *seg;
   size_t offset;
   if (layout->image_segid == O26_SEG_TEXT)
      seg = &obj->text;
   else if (layout->image_segid == O26_SEG_DATA)
      seg = &obj->data;
   else
      return NULL;
   offset = (size_t)layout->image_base + record->offset;
   if (offset > seg->length || record->size > seg->length - offset)
      return NULL;
   return seg->data + offset;
}

//! @brief Gather all source-correlated statement records with their final placements.
static linked_listing_entry_t *collect_linked_listing_entries(const input_set_t *in,
                                                               size_t *count_out)
{
   linked_listing_entry_t *entries = NULL;
   size_t count = 0;
   size_t i;

   for (i = 0; i < in->object_count; ++i) {
      const object_file_t *obj = &in->objects[i];
      size_t j;
      for (j = 0; j < obj->listing_count; ++j) {
         const listing_record_t *record = &obj->listing[j];
         const object_layout_t *layout;
         const uint8_t *bytes;
         uint32_t addr;
         if (record->layout_index >= obj->layout_count || record->size == 0)
            continue;
         layout = &obj->layouts[record->layout_index];
         if ((uint32_t)record->offset + record->size > layout->size)
            continue;
         bytes = linked_listing_record_bytes(obj, layout, record);
         if (!bytes)
            continue;
         addr = (uint32_t)layout->load_addr + record->offset;
         if (addr > 0xffffu || addr + record->size > 0x10000u)
            continue;
         entries = (linked_listing_entry_t *)xrealloc(entries, (count + 1) * sizeof(*entries));
         entries[count].obj = obj;
         entries[count].layout = layout;
         entries[count].record = record;
         entries[count].bytes = bytes;
         entries[count].addr = (uint16_t)addr;
         count++;
      }
   }
   qsort(entries, count, sizeof(*entries), compare_linked_listing_entries);
   *count_out = count;
   return entries;
}

//! @brief Resolve a final instruction operand to a local exact layout when available.
static const object_layout_t *listing_operand_reference(const object_file_t *obj,
                                                        const object_layout_t *layout,
                                                        const listing_record_t *record,
                                                        const char **name_out)
{
   const o26_segment_t *segment;
   size_t statement_offset;
   size_t i;
   if (name_out)
      *name_out = "<fixed operand>";
   if (!obj || !layout || !record)
      return NULL;
   if (layout->image_segid == O26_SEG_TEXT)
      segment = &obj->text;
   else if (layout->image_segid == O26_SEG_DATA)
      segment = &obj->data;
   else
      return NULL;
   statement_offset = (size_t)layout->image_base + record->offset;
   for (i = 0; i < segment->reloc_count; ++i) {
      const reloc_t *reloc = &segment->relocs[i];
      if (reloc->offset != statement_offset + 1u &&
          reloc->offset != statement_offset + 2u)
         continue;
      if (reloc->segid == O26_SEG_UNDEF && reloc->undef_index < obj->undef_count) {
         if (name_out)
            *name_out = obj->undefs[reloc->undef_index];
         return NULL;
      }
      if (reloc->has_layout_index && reloc->layout_index < obj->layout_count) {
         if (name_out)
            *name_out = obj->layouts[reloc->layout_index].name;
         return &obj->layouts[reloc->layout_index];
      }
      if (reloc->segid == O26_SEG_ABS) {
         if (name_out)
            *name_out = "<absolute operand>";
         return NULL;
      }
      if (name_out)
         *name_out = "<relocatable operand>";
      return NULL;
   }
   return NULL;
}

//! @brief Limit symbolic indexed references to effective addresses inside their object.
static int indexed_reference_range(const object_layout_t *target, uint16_t operand,
                                   uint8_t *min_out, uint8_t *max_out)
{
   uint32_t base;
   unsigned int i;
   unsigned int first = 256u, last = 0u, matches = 0u;
   if (!target || !min_out || !max_out || target->size == 0)
      return 0;
   base = target->segid == O26_SEG_TEXT ? target->load_addr : target->run_addr;
   for (i = 0; i < 256u; ++i) {
      uint16_t effective = (uint16_t)(operand + i);
      if ((uint32_t)effective >= base &&
          (uint32_t)effective < base + target->size) {
         if (first == 256u)
            first = i;
         last = i;
         matches++;
      }
   }
   if (matches == 0 || matches != last - first + 1u)
      return 0;
   *min_out = (uint8_t)first;
   *max_out = (uint8_t)last;
   return 1;
}

//! @brief Reject destructive NMOS-6502 reads visible in the final linked instruction bytes.
static void validate_linked_read_hazards(const linker_config_t *cfg,
                                         const input_set_t *in)
{
   linked_listing_entry_t *entries;
   size_t count = 0;
   size_t i;

   entries = collect_linked_listing_entries(in, &count);
   for (i = 0; i < count; ++i) {
      const linked_listing_entry_t *entry = &entries[i];
      const listing_record_t *record = entry->record;
      uint8_t opcode = entry->bytes[0];
      uint16_t operand = 0;
      read_hazard_hit_t hit;
      uint32_t write_start;
      uint32_t write_end;
      const char *reference = "<fixed operand>";
      const object_layout_t *target;
      uint8_t index_min = 0, index_max = 255;

      if (!listing_record_is_instruction(record, opcode))
         continue;
      if (record->size >= 2)
         operand = entry->bytes[1];
      if (record->size >= 3)
         operand |= (uint16_t)(entry->bytes[2] << 8);
      target = listing_operand_reference(entry->obj, entry->layout, record, &reference);
      if ((nmos6502_addr_mode[opcode] == NMOS_ABSX ||
           nmos6502_addr_mode[opcode] == NMOS_ABSY) && target)
         (void)indexed_reference_range(target, operand, &index_min, &index_max);
      if (!nmos6502_instruction_read_hazard_range(cfg, opcode, entry->addr,
                                                  operand, index_min, index_max, &hit))
         continue;
      write_start = hit.memory->has_write_start ? hit.memory->write_start
                                                : hit.memory->start;
      write_end = write_start + hit.memory->size - 1u;
      fprintf(stderr,
              "vcsc-ld: destructive dummy/read hazard at %s:%u: %s\n"
              "vcsc-ld: linked PC=$%04X opcode=$%02X operand=$%04X may perform %s at $%04X%s%s\n"
              "vcsc-ld: operand/reference %s; memory '%s' destructive-read window $%04X-$%04X\n",
              record->source_file ? record->source_file : entry->obj->origin,
              (unsigned)record->source_line,
              record->asm_text ? record->asm_text : "<assembly instruction>",
              entry->addr, opcode, operand,
              hit.cycle ? hit.cycle : "a read",
              hit.address,
              hit.has_index ? " with runtime index $" : "",
              hit.has_index ? "XX" : "",
              reference ? reference : "<unknown operand>",
              hit.memory->name,
              (unsigned)write_start, (unsigned)write_end);
      if (hit.has_index)
         fprintf(stderr,
                 "vcsc-ld: first statically hazardous index value is $%02X\n",
                 hit.index);
      free(entries);
      exit(1);
   }
   free(entries);
}

//! @brief Return whether two records share the same original source statement.
static int listing_same_source(const listing_record_t *a, const listing_record_t *b)
{
   if (!a || !b)
      return 0;
   return a->source_line == b->source_line &&
          !strcmp(a->source_file ? a->source_file : "", b->source_file ? b->source_file : "") &&
          !strcmp(a->source_text ? a->source_text : "", b->source_text ? b->source_text : "");
}

//! @brief Print one source-origin banner before the machine instructions it generated.
static void write_listing_source_banner(FILE *fp, const linked_listing_entry_t *entry)
{
   const listing_record_t *record = entry->record;
   const char *file = record->source_file && record->source_file[0] ? record->source_file : "<unknown>";
   const char *text = record->source_text && record->source_text[0] ? record->source_text : "";

   if (!strcmp(file, "<compiler-generated>")) {
      fprintf(fp, "; <compiler-generated>");
   } else if (record->source_line) {
      fprintf(fp, "; %s:%u", file, (unsigned)record->source_line);
   } else {
      fprintf(fp, "; %s", file);
   }
   if (entry->layout->placement_bank[0])
      fprintf(fp, " [bank %s]", entry->layout->placement_bank);
   else if (entry->layout->name && entry->layout->name[0])
      fprintf(fp, " [layout %s]", entry->layout->name);
   if (text[0])
      fprintf(fp, " | %s", text);
   fputc('\n', fp);
}

//! @brief Print one final linked statement in a DASM-compatible human-readable row.
static void write_listing_statement(FILE *fp, unsigned *line,
                                    const linked_listing_entry_t *entry,
                                    uint8_t *covered)
{
   const listing_record_t *record = entry->record;
   unsigned offset = 0;
   while (offset < record->size) {
      unsigned count = record->size - offset;
      unsigned n;
      uint16_t addr = (uint16_t)(entry->addr + offset);
      if (count > 8)
         count = 8;
      fprintf(fp, "%5u %04x ", (*line)++, addr);
      for (n = 0; n < count; ++n) {
         fprintf(fp, "%02x ", entry->bytes[offset + n]);
         covered[(uint16_t)(addr + n)] = 1;
      }
      while (n++ < 8)
         fputs("   ", fp);
      if (offset == 0 && record->asm_text && record->asm_text[0]) {
         fprintf(fp, "; %s", record->asm_text);
         /* A three-byte 6502 instruction has a final 16-bit operand.  Showing
            its resolved value makes split read/write aliases (notably SC RAM)
            obvious without making humans decode little-endian bytes by eye. */
         if (record->size == 3 && record->asm_text[0] != '.') {
            uint16_t operand = (uint16_t)(entry->bytes[1] | (entry->bytes[2] << 8));
            fprintf(fp, "  => $%04X", operand);
         }
      } else if (offset != 0) {
         fprintf(fp, "; +%u", offset);
      }
      fputc('\n', fp);
      offset += count;
   }
}

//! @brief Write a DASM-shaped, source-correlated final linked listing.
static void write_stella_list_file(const char *path,
                                   const input_set_t *in,
                                   const layout_t *layout,
                                   const uint8_t *image,
                                   const uint8_t *used)
{
   FILE *fp;
   unsigned line = 1;
   size_t i;
   uint32_t addr = 0;
   uint8_t *covered;
   linked_listing_entry_t *entries;
   size_t entry_count;
   const listing_record_t *previous_source = NULL;
   const object_layout_t *previous_layout = NULL;

   if (!path)
      return;
   fp = fopen(path, "w");
   if (!fp) {
      fprintf(stderr, "vcsc-ld: cannot create '%s': %s\n", path, strerror(errno));
      exit(1);
   }

   fprintf(fp, "------- VCSC linked image listing\n");
   fprintf(fp, "------- Human source listing; addresses and bytes are final after relocation.\n");
   fprintf(fp, "------- RAM symbols retain DASM constant rows for Stella compatibility.\n");

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

   covered = (uint8_t *)xcalloc(65536, 1);
   entries = collect_linked_listing_entries(in, &entry_count);
   if (entry_count)
      fputs("------- Source-correlated linked statements\n", fp);
   for (i = 0; i < entry_count; ++i) {
      const linked_listing_entry_t *entry = &entries[i];
      if (previous_layout != entry->layout || !listing_same_source(previous_source, entry->record))
         write_listing_source_banner(fp, entry);
      write_listing_statement(fp, &line, entry, covered);
      previous_source = entry->record;
      previous_layout = entry->layout;
   }
   free(entries);

   /* Linker-generated vectors/tables and bytes from legacy objects have no
      source provenance.  Keep them visible rather than silently omitting them. */
   fputs("------- Unattributed/linker-generated linked bytes\n", fp);
   while (addr < 65536u) {
      unsigned count = 0;
      const char *label;
      uint32_t start;

      while (addr < 65536u && (!used[addr] || covered[addr]))
         addr++;
      if (addr >= 65536u)
         break;
      start = addr;
      fprintf(fp, "%5u %04x ", line++, (unsigned)start);
      while (addr < 65536u && used[addr] && !covered[addr] && count < 8) {
         fprintf(fp, "%02x ", image[addr]);
         addr++;
         count++;
      }
      while (count++ < 8)
         fputs("   ", fp);
      label = symbol_at_address(layout, (uint16_t)start);
      if (label)
         fprintf(fp, "; %s", label);
      else
         fputs("; <linker-generated/unattributed>", fp);
      fputc('\n', fp);
   }

   free(covered);
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
   uint8_t bank_placement_mode = BANK_PLACEMENT_MODE_OPTIMIZED;
   int explain_bank_placement = 0;
   int trial_mode = 0;
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
         if (strcmp(arg, "--trial") == 0) {
            const char *null_path;
            trial_mode = 1;
#ifdef _WIN32
            null_path = "NUL";
#else
            null_path = "/dev/null";
#endif
            if (freopen(null_path, "w", stdout) == NULL) {
               return 1;
            }
            if (freopen(null_path, "w", stderr) == NULL) {
               return 1;
            }
            continue;
         }
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
         if (strcmp(arg, "--bank-placement") == 0) {
            if (++argi >= argc) {
               fprintf(stderr, "vcsc-ld: missing argument for --bank-placement\n");
               return 1;
            }
            arg = argv[argi];
            if (strcmp(arg, "optimized") == 0)
               bank_placement_mode = BANK_PLACEMENT_MODE_OPTIMIZED;
            else if (strcmp(arg, "simple") == 0)
               bank_placement_mode = BANK_PLACEMENT_MODE_SIMPLE;
            else {
               fprintf(stderr,
                       "vcsc-ld: bad bank-placement mode '%s'; expected optimized or simple\n",
                       arg);
               return 1;
            }
            continue;
         }
         if (strncmp(arg, "--bank-placement=", 17) == 0) {
            const char *mode = arg + 17;
            if (strcmp(mode, "optimized") == 0)
               bank_placement_mode = BANK_PLACEMENT_MODE_OPTIMIZED;
            else if (strcmp(mode, "simple") == 0)
               bank_placement_mode = BANK_PLACEMENT_MODE_SIMPLE;
            else {
               fprintf(stderr,
                       "vcsc-ld: bad bank-placement mode '%s'; expected optimized or simple\n",
                       mode);
               return 1;
            }
            continue;
         }
         if (strcmp(arg, "--explain-bank-placement") == 0) {
            explain_bank_placement = 1;
            continue;
         }

         fprintf(stderr, "vcsc-ld: unsupported option '%s'\n", arg);
         fprintf(stderr, "Try '%s --help' for a list of supported options.\n", argv[0]);
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
   cfg.bank_placement_mode = bank_placement_mode;

   select_needed_objects(&inputs);
   collect_c26_topology(&cfg, &inputs);
   collect_c26_mem_declarations(&cfg, &inputs);
   infer_c26_mem_output_ownership(&cfg);
   validate_c26_topology(&cfg);
   apply_c26_topology_to_linker_config(&cfg);
   synthesize_c26_segment_rules(&cfg);
   apply_component_constraints(&cfg, &inputs);
   validate_linker_config(&cfg);
   if (selected_objects_have_export(&inputs, "__vcsc_startup_full") &&
       startup_simple_is_safe(&cfg, &inputs)) {
      reselect_needed_objects_with_preferred_provider(&inputs, "__vcsc_startup_simple");
   }
   if ((cfg.cartridge_banked || cfg.topology_bank_count) && !ends_with(hex_path, ".bin")) {
      fprintf(stderr,
              "vcsc-ld: cartridge topology requires a flat .bin output\n");
      return 1;
   }
   validate_abi_metadata(&inputs);
   validate_absolute_binding_memory_regions(&cfg, &inputs);
   validate_mem_region_metadata(&cfg, &inputs);
   prepare_replicated_rom(&cfg, &inputs);
   prepare_read_hazard_constraints(&cfg, &inputs);
   assign_automatic_bank_placements(&cfg, &inputs,
                                    bank_placement_mode,
                                    explain_bank_placement);
   {
      uint16_t weighted_call_depth = 0;
      uint16_t call_depth = enforce_symbol_backed_call_graph(
         &inputs, &cfg, &weighted_call_depth,
         selected_startup_tail_enters_main(&inputs));
      size_t init_count = count_init_functions_in_input(&inputs);
      reserve_call_stack_from_call_graph(&cfg, call_depth,
                                         weighted_call_depth, init_count,
                                         selected_objects_have_export(
                                            &inputs, "__vcsc_startup_full"));
   }
   warn_unused_cmdline_objects(&inputs);
   apply_phase_workspace_metadata(&inputs);
   apply_phase_use_metadata(&inputs);
   layout_objects(&cfg, &inputs, &layout);
   validate_data_only_relocations(&inputs, &cfg);
   enforce_branch_bank_contracts(&cfg, &inputs);
   enforce_branch_page_contracts(&inputs);
   add_generated_symbols(&layout);
   prepare_generic_bankcall_corridor(&cfg, &inputs, &layout);
   resolve_all(&inputs, &layout, &cfg);
   validate_linked_read_hazards(&cfg, &inputs);
   enforce_declaration_use_contracts(&inputs);

   image = (uint8_t *)xmalloc(65536);
   used = (uint8_t *)xmalloc(65536);
   build_rom_image(&cfg, &inputs, &layout, image, used);
   if (ends_with(hex_path, ".bin"))
      write_flat_binary(hex_path, &cfg, &inputs, image, used);
   else
      write_intel_hex(hex_path, image, used);
   write_map_file(map_output.enabled ? map_output.path : NULL,
                  &cfg, &inputs, &layout, used);
   write_stella_symbol_file(sym_output.enabled ? sym_output.path : NULL, &layout);
   write_stella_list_file(list_output.enabled ? list_output.path : NULL,
                          &inputs, &layout, image, used);
   write_stella_config_file(cfg_output.enabled ? cfg_output.path : NULL,
                            &cfg, &inputs, used);
   if (!trial_mode) {
      puts("MEMORY USAGE");
      write_cartridge_rom_usage(stdout, &cfg, &inputs, used, "  ");
      write_ram_usage(stdout, &cfg, &inputs, &layout, "  ");
   }

   free(image);
   free(used);
   free(map_output.owned_default);
   free(sym_output.owned_default);
   free(list_output.owned_default);
   free(cfg_output.owned_default);

   for (i = 0; i < inputs.replica_count; ++i) {
      size_t j;
      free(inputs.replicas[i].symbol);
      for (j = 0; j < inputs.replicas[i].copy_count; ++j)
         free(inputs.replicas[i].regions[j]);
      free(inputs.replicas[i].regions);
      free(inputs.replicas[i].layout_indices);
   }
   free(inputs.replicas);
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
