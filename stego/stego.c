#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * stego.c
 *
 * Standalone, conservative 6507 ROM tracer for finding high operand bytes
 * whose bits 7..5 are not visible on the Atari 2600 cartridge bus.
 *
 * The 6507 exposes only A0..A12.  Therefore, for an address whose bit 12 is
 * set (the cartridge half of the 8 KiB console address space), changing A13,
 * A14, or A15 does not change the address observed by the cartridge.  In a
 * 16-bit address high byte this is the pattern 0bxxx1yyyy: xxx may carry three
 * hidden bits while 1yyyy must remain unchanged.
 *
 * This program traces every complete 4 KiB bank in the input file (or a lone
 * 2 KiB ROM) independently, starting from each bank's three vectors.  A vector
 * is followed, and its high byte may be reported as mutable, only when the
 * high byte has cartridge-select bit 4 set: 0bxxx1xxxx.  It follows ordinary
 * branches, JMP, JSR, and resolvable JMP-indirect paths.  It lists high bytes
 * of reached absolute operands, valid vector entries, and resolved indirect
 * targets that may be changed with mask 0xe0.
 *
 * Complete banks are taken from the beginning of the file.  Any final partial
 * bank is ignored.  In particular, the 2,303-byte DPC tail used by cartridges
 * such as Pitfall II (2,048 display bytes plus 255 frequency bytes) is never
 * interpreted as executable ROM.
 *
 * Important limits:
 *   - Banks are traced independently.  Bank-switch accesses are not interpreted
 *     as control-flow edges between physical banks.
 *   - Runtime targets obtained from RAM, RTS/RTI tricks, self-generated RAM
 *     code, and data reached through zero-page indirect pointers cannot be
 *     resolved statically.  The program reports such uncertainty.
 *   - "Safe" means bus-equivalent under normal 6507 mirroring.  Deliberate
 *     software inspection of logical PC/stack address bits can invalidate that
 *     assumption.
 */

#define CART_WINDOW_SIZE 4096u
#define TWO_K_SIZE 2048u
#define DPC_TRAILING_SIZE (2048u + 255u)
#define ADDRESS_SPACE_SIZE 65536u
#define MUTABLE_MASK 0xe0u

#define USE_OPCODE          0x01u
#define USE_OTHER_OPERAND   0x02u
#define USE_MUTABLE_HIGH    0x04u
#define USE_ROM_DATA        0x08u

#define CAND_ABSOLUTE       0x01u
#define CAND_VECTOR_NMI     0x02u
#define CAND_VECTOR_RESET   0x04u
#define CAND_VECTOR_IRQ     0x08u
#define CAND_INDIRECT_TARGET 0x10u

typedef enum {
   AM_IMPLIED,
   AM_ACCUMULATOR,
   AM_IMMEDIATE,
   AM_ZERO_PAGE,
   AM_ZERO_PAGE_X,
   AM_ZERO_PAGE_Y,
   AM_RELATIVE,
   AM_ABSOLUTE,
   AM_ABSOLUTE_X,
   AM_ABSOLUTE_Y,
   AM_INDIRECT,
   AM_INDEXED_INDIRECT,
   AM_INDIRECT_INDEXED
} address_mode_t;

typedef enum {
   FLOW_NEXT,
   FLOW_BRANCH,
   FLOW_JSR,
   FLOW_JMP_ABSOLUTE,
   FLOW_JMP_INDIRECT,
   FLOW_BRK,
   FLOW_STOP
} flow_kind_t;

typedef struct {
   uint8_t uses;
   uint8_t candidate_kinds;
   uint16_t first_pc;
   uint16_t first_address;
   uint8_t first_opcode;
   uint8_t first_mode;
} byte_info_t;

typedef struct {
   uint8_t *cart;
   size_t file_size;
   size_t bank_file_offset;
   size_t bank_index;
   size_t bank_size;
   size_t bank_count;
   size_t trailing_bytes;
   byte_info_t *byte_info;
   uint8_t visited[ADDRESS_SPACE_SIZE];
   uint8_t queued[ADDRESS_SPACE_SIZE];
   uint16_t work[ADDRESS_SPACE_SIZE];
   size_t work_count;
   size_t instruction_count;
   size_t unresolved_indirect_jumps;
   size_t dynamic_data_accesses;
   size_t truncated_instructions;
} analysis_t;

#define I  AM_IMPLIED
#define A  AM_ACCUMULATOR
#define M  AM_IMMEDIATE
#define Z  AM_ZERO_PAGE
#define ZX AM_ZERO_PAGE_X
#define ZY AM_ZERO_PAGE_Y
#define R  AM_RELATIVE
#define B  AM_ABSOLUTE
#define BX AM_ABSOLUTE_X
#define BY AM_ABSOLUTE_Y
#define D  AM_INDIRECT
#define IX AM_INDEXED_INDIRECT
#define IY AM_INDIRECT_INDEXED

/*
 * Addressing modes for all 256 NMOS 6502 opcodes, including the commonly
 * documented unofficial opcodes.  Knowing their lengths prevents an executed
 * unofficial instruction from throwing the trace out of alignment.
 */
static const uint8_t opcode_modes[256] = {
   /* 0x00 */ I, IX, I, IX, Z, Z, Z, Z, I, M, A, M, B, B, B, B,
   /* 0x10 */ R, IY, I, IY, ZX, ZX, ZX, ZX, I, BY, I, BY, BX, BX, BX, BX,
   /* 0x20 */ B, IX, I, IX, Z, Z, Z, Z, I, M, A, M, B, B, B, B,
   /* 0x30 */ R, IY, I, IY, ZX, ZX, ZX, ZX, I, BY, I, BY, BX, BX, BX, BX,
   /* 0x40 */ I, IX, I, IX, Z, Z, Z, Z, I, M, A, M, B, B, B, B,
   /* 0x50 */ R, IY, I, IY, ZX, ZX, ZX, ZX, I, BY, I, BY, BX, BX, BX, BX,
   /* 0x60 */ I, IX, I, IX, Z, Z, Z, Z, I, M, A, M, D, B, B, B,
   /* 0x70 */ R, IY, I, IY, ZX, ZX, ZX, ZX, I, BY, I, BY, BX, BX, BX, BX,
   /* 0x80 */ M, IX, M, IX, Z, Z, Z, Z, I, M, I, M, B, B, B, B,
   /* 0x90 */ R, IY, I, IY, ZX, ZX, ZY, ZY, I, BY, I, BY, BX, BX, BY, BY,
   /* 0xa0 */ M, IX, M, IX, Z, Z, Z, Z, I, M, I, M, B, B, B, B,
   /* 0xb0 */ R, IY, I, IY, ZX, ZX, ZY, ZY, I, BY, I, BY, BX, BX, BY, BY,
   /* 0xc0 */ M, IX, M, IX, Z, Z, Z, Z, I, M, I, M, B, B, B, B,
   /* 0xd0 */ R, IY, I, IY, ZX, ZX, ZX, ZX, I, BY, I, BY, BX, BX, BX, BX,
   /* 0xe0 */ M, IX, M, IX, Z, Z, Z, Z, I, M, I, M, B, B, B, B,
   /* 0xf0 */ R, IY, I, IY, ZX, ZX, ZX, ZX, I, BY, I, BY, BX, BX, BX, BX
};

#undef I
#undef A
#undef M
#undef Z
#undef ZX
#undef ZY
#undef R
#undef B
#undef BX
#undef BY
#undef D
#undef IX
#undef IY

static const char *mode_name(address_mode_t mode)
{
   switch (mode) {
   case AM_IMPLIED:          return "implied";
   case AM_ACCUMULATOR:      return "accumulator";
   case AM_IMMEDIATE:        return "immediate";
   case AM_ZERO_PAGE:        return "zero-page";
   case AM_ZERO_PAGE_X:      return "zero-page,X";
   case AM_ZERO_PAGE_Y:      return "zero-page,Y";
   case AM_RELATIVE:         return "relative";
   case AM_ABSOLUTE:         return "absolute";
   case AM_ABSOLUTE_X:       return "absolute,X";
   case AM_ABSOLUTE_Y:       return "absolute,Y";
   case AM_INDIRECT:         return "indirect";
   case AM_INDEXED_INDIRECT: return "(zero-page,X)";
   case AM_INDIRECT_INDEXED: return "(zero-page),Y";
   }
   return "unknown";
}

static unsigned instruction_length(address_mode_t mode)
{
   switch (mode) {
   case AM_IMPLIED:
   case AM_ACCUMULATOR:
      return 1;

   case AM_IMMEDIATE:
   case AM_ZERO_PAGE:
   case AM_ZERO_PAGE_X:
   case AM_ZERO_PAGE_Y:
   case AM_RELATIVE:
   case AM_INDEXED_INDIRECT:
   case AM_INDIRECT_INDEXED:
      return 2;

   case AM_ABSOLUTE:
   case AM_ABSOLUTE_X:
   case AM_ABSOLUTE_Y:
   case AM_INDIRECT:
      return 3;
   }
   return 1;
}

static flow_kind_t instruction_flow(uint8_t opcode)
{
   switch (opcode) {
   case 0x10: case 0x30: case 0x50: case 0x70:
   case 0x90: case 0xb0: case 0xd0: case 0xf0:
      return FLOW_BRANCH;

   case 0x20:
      return FLOW_JSR;
   case 0x4c:
      return FLOW_JMP_ABSOLUTE;
   case 0x6c:
      return FLOW_JMP_INDIRECT;
   case 0x00:
      return FLOW_BRK;
   case 0x40:
   case 0x60:
   case 0x02: case 0x12: case 0x22: case 0x32:
   case 0x42: case 0x52: case 0x62: case 0x72:
   case 0x92: case 0xb2: case 0xd2: case 0xf2:
      return FLOW_STOP;
   default:
      return FLOW_NEXT;
   }
}

static int mode_has_absolute_operand(address_mode_t mode)
{
   return mode == AM_ABSOLUTE || mode == AM_ABSOLUTE_X ||
          mode == AM_ABSOLUTE_Y || mode == AM_INDIRECT;
}

/*
 * These unstable unofficial stores use address-high information internally;
 * bits 7..5 therefore cannot honestly be called unused for their operands.
 */
static int operand_high_is_bus_only(uint8_t opcode)
{
   switch (opcode) {
   case 0x93: /* AHX (zp),Y */
   case 0x9b: /* TAS abs,Y */
   case 0x9c: /* SHY abs,X */
   case 0x9e: /* SHX abs,Y */
   case 0x9f: /* AHX abs,Y */
      return 0;
   default:
      return 1;
   }
}

static int opcode_is_write_only(uint8_t opcode)
{
   switch (opcode) {
   case 0x81: case 0x85: case 0x8d: case 0x91:
   case 0x95: case 0x99: case 0x9d:             /* STA */
   case 0x84: case 0x8c: case 0x94:             /* STY */
   case 0x86: case 0x8e: case 0x96:             /* STX */
   case 0x83: case 0x87: case 0x8f: case 0x97: /* SAX */
   case 0x93: case 0x9b: case 0x9c: case 0x9e: case 0x9f:
      return 1;
   default:
      return 0;
   }
}

static int address_is_cartridge(uint16_t address)
{
   return (address & 0x1000u) != 0;
}

static int address_to_bank_offset(const analysis_t *a, uint16_t address,
                                  size_t *offset)
{
   if (!address_is_cartridge(address))
      return 0;

   if (a->bank_size == TWO_K_SIZE)
      *offset = (size_t)(address & 0x07ffu);
   else
      *offset = (size_t)(address & 0x0fffu);
   return 1;
}

static int fetch_bank_byte(const analysis_t *a, uint16_t address,
                           uint8_t *value, size_t *bank_offset)
{
   size_t offset;
   if (!address_to_bank_offset(a, address, &offset))
      return 0;
   if (offset >= a->bank_size)
      return 0;
   if (value != NULL)
      *value = a->cart[a->bank_file_offset + offset];
   if (bank_offset != NULL)
      *bank_offset = offset;
   return 1;
}

static void remember_candidate(analysis_t *a, size_t bank_offset,
                               uint8_t kind, uint16_t pc, uint8_t opcode,
                               address_mode_t mode, uint16_t address)
{
   byte_info_t *info = &a->byte_info[bank_offset];
   if ((info->uses & USE_MUTABLE_HIGH) == 0) {
      info->first_pc = pc;
      info->first_opcode = opcode;
      info->first_mode = (uint8_t)mode;
      info->first_address = address;
   }
   info->uses |= USE_MUTABLE_HIGH;
   info->candidate_kinds |= kind;
}

static void mark_rom_data_byte(analysis_t *a, uint16_t address)
{
   size_t offset;
   if (address_to_bank_offset(a, address, &offset))
      a->byte_info[offset].uses |= USE_ROM_DATA;
}

static void mark_possible_indexed_rom_data(analysis_t *a, uint16_t base)
{
   unsigned i;
   for (i = 0; i <= 0xffu; ++i)
      mark_rom_data_byte(a, (uint16_t)(base + i));
}

static void enqueue(analysis_t *a, uint16_t pc)
{
   if (!address_is_cartridge(pc))
      return;
   if (a->queued[pc])
      return;
   a->queued[pc] = 1;
   a->work[a->work_count++] = pc;
}

static int fetch_instruction(const analysis_t *a, uint16_t pc,
                             uint8_t bytes[3], size_t offsets[3],
                             unsigned length)
{
   unsigned i;
   for (i = 0; i < length; ++i) {
      if (!fetch_bank_byte(a, (uint16_t)(pc + i), &bytes[i], &offsets[i]))
         return 0;
   }
   return 1;
}

static void mark_instruction_bytes(analysis_t *a, uint16_t pc,
                                   uint8_t opcode, address_mode_t mode,
                                   const uint8_t bytes[3],
                                   const size_t offsets[3], unsigned length)
{
   unsigned i;
   a->byte_info[offsets[0]].uses |= USE_OPCODE;

   for (i = 1; i < length; ++i) {
      if (i == 2 && mode_has_absolute_operand(mode)) {
         uint16_t address = (uint16_t)(bytes[1] | ((uint16_t)bytes[2] << 8));
         if ((bytes[2] & 0x10u) != 0 && operand_high_is_bus_only(opcode)) {
            remember_candidate(a, offsets[2], CAND_ABSOLUTE, pc, opcode,
                               mode, address);
         }
         else {
            a->byte_info[offsets[2]].uses |= USE_OTHER_OPERAND;
         }
      }
      else {
         a->byte_info[offsets[i]].uses |= USE_OTHER_OPERAND;
      }
   }
}

static void mark_direct_rom_access(analysis_t *a, uint8_t opcode,
                                   address_mode_t mode, uint16_t address)
{
   flow_kind_t flow = instruction_flow(opcode);

   if (flow == FLOW_JSR || flow == FLOW_JMP_ABSOLUTE ||
       flow == FLOW_JMP_INDIRECT)
      return;
   if (opcode_is_write_only(opcode))
      return;

   if (mode == AM_ABSOLUTE)
      mark_rom_data_byte(a, address);
   else if (mode == AM_ABSOLUTE_X || mode == AM_ABSOLUTE_Y)
      mark_possible_indexed_rom_data(a, address);
}

static int resolve_indirect_jump(analysis_t *a, uint16_t pc,
                                 uint16_t pointer, uint16_t *target)
{
   uint16_t high_address;
   uint8_t low;
   uint8_t high;
   size_t low_offset;
   size_t high_offset;

   /* Reproduce the NMOS 6502 JMP ($xxff) page-wrap behavior. */
   high_address = (uint16_t)((pointer & 0xff00u) |
                             ((uint16_t)(pointer + 1u) & 0x00ffu));

   if (!fetch_bank_byte(a, pointer, &low, &low_offset) ||
       !fetch_bank_byte(a, high_address, &high, &high_offset)) {
      ++a->unresolved_indirect_jumps;
      return 0;
   }

   a->byte_info[low_offset].uses |= USE_ROM_DATA;
   *target = (uint16_t)(low | ((uint16_t)high << 8));

   if ((high & 0x10u) != 0) {
      remember_candidate(a, high_offset, CAND_INDIRECT_TARGET, pc, 0x6c,
                         AM_INDIRECT, *target);
   }
   else {
      a->byte_info[high_offset].uses |= USE_ROM_DATA;
   }
   return 1;
}

static void trace(analysis_t *a)
{
   while (a->work_count != 0) {
      uint16_t pc = a->work[--a->work_count];
      uint8_t bytes[3] = { 0, 0, 0 };
      size_t offsets[3] = { 0, 0, 0 };
      uint8_t opcode;
      address_mode_t mode;
      flow_kind_t flow;
      unsigned length;
      uint16_t next;
      uint16_t address = 0;

      if (a->visited[pc])
         continue;
      a->visited[pc] = 1;

      if (!fetch_bank_byte(a, pc, &opcode, NULL))
         continue;

      mode = (address_mode_t)opcode_modes[opcode];
      length = instruction_length(mode);
      if (!fetch_instruction(a, pc, bytes, offsets, length)) {
         ++a->truncated_instructions;
         continue;
      }

      ++a->instruction_count;
      mark_instruction_bytes(a, pc, opcode, mode, bytes, offsets, length);
      next = (uint16_t)(pc + length);

      if (mode_has_absolute_operand(mode)) {
         address = (uint16_t)(bytes[1] | ((uint16_t)bytes[2] << 8));
         mark_direct_rom_access(a, opcode, mode, address);
      }
      else if (mode == AM_INDEXED_INDIRECT || mode == AM_INDIRECT_INDEXED) {
         /* Runtime zero-page pointers can refer anywhere, including ROM. */
         ++a->dynamic_data_accesses;
      }

      flow = instruction_flow(opcode);
      switch (flow) {
      case FLOW_NEXT:
         enqueue(a, next);
         break;

      case FLOW_BRANCH: {
         int8_t displacement = (int8_t)bytes[1];
         enqueue(a, next);
         enqueue(a, (uint16_t)(next + displacement));
         break;
      }

      case FLOW_JSR:
         enqueue(a, next);
         enqueue(a, address);
         break;

      case FLOW_JMP_ABSOLUTE:
         enqueue(a, address);
         break;

      case FLOW_JMP_INDIRECT: {
         uint16_t target;
         if (resolve_indirect_jump(a, pc, address, &target))
            enqueue(a, target);
         break;
      }

      case FLOW_BRK:
         /* BRK returns to PC+2 if its handler eventually executes RTI. */
         enqueue(a, (uint16_t)(pc + 2u));
         break;

      case FLOW_STOP:
         break;
      }
   }
}

static int read_vector(analysis_t *a, uint16_t vector_address,
                       uint8_t kind, uint16_t *target)
{
   uint8_t low;
   uint8_t high;
   size_t low_offset;
   size_t high_offset;

   *target = 0;
   if (!fetch_bank_byte(a, vector_address, &low, &low_offset) ||
       !fetch_bank_byte(a, (uint16_t)(vector_address + 1u), &high,
                        &high_offset)) {
      fprintf(stderr, "stego: bank %zu vector at $%04" PRIx16
                      " is outside ROM\n",
              a->bank_index, vector_address);
      return 0;
   }

   /* Vector low bytes are ordinary data and are never mutation candidates. */
   a->byte_info[low_offset].uses |= USE_ROM_DATA;
   *target = (uint16_t)(low | ((uint16_t)high << 8));

   /*
    * Only 0bxxx1xxxx high bytes name the cartridge half of the 6507 address
    * space.  Invalid vectors are neither followed nor reported as safe.
    */
   if ((high & 0x10u) == 0) {
      a->byte_info[high_offset].uses |= USE_ROM_DATA;
      return 0;
   }

   remember_candidate(a, high_offset, kind,
                      (uint16_t)(vector_address + 1u), 0,
                      AM_ABSOLUTE, *target);
   return 1;
}

static void append_word(char *buffer, size_t buffer_size, const char *word)
{
   size_t used = strlen(buffer);
   if (used != 0 && used + 1u < buffer_size) {
      buffer[used++] = '+';
      buffer[used] = '\0';
   }
   if (used < buffer_size - 1u)
      (void)snprintf(buffer + used, buffer_size - used, "%s", word);
}

static void describe_candidate_kinds(uint8_t kinds, char *buffer,
                                     size_t buffer_size)
{
   buffer[0] = '\0';
   if (kinds & CAND_ABSOLUTE)
      append_word(buffer, buffer_size, "absolute-operand");
   if (kinds & CAND_VECTOR_NMI)
      append_word(buffer, buffer_size, "nmi-vector");
   if (kinds & CAND_VECTOR_RESET)
      append_word(buffer, buffer_size, "reset-vector");
   if (kinds & CAND_VECTOR_IRQ)
      append_word(buffer, buffer_size, "irq-brk-vector");
   if (kinds & CAND_INDIRECT_TARGET)
      append_word(buffer, buffer_size, "indirect-target");
}

static void print_allowed_values(uint8_t value)
{
   unsigned hidden;
   uint8_t fixed = (uint8_t)(value & (uint8_t)~MUTABLE_MASK);
   for (hidden = 0; hidden < 8u; ++hidden) {
      if (hidden != 0)
         putchar(',');
      printf("%02x", (unsigned)(fixed | (uint8_t)(hidden << 5)));
   }
}

static size_t print_candidates(const analysis_t *a)
{
   size_t offset;
   size_t count = 0;

   for (offset = 0; offset < a->bank_size; ++offset) {
      const byte_info_t *info = &a->byte_info[offset];
      uint8_t conflicts = (uint8_t)(info->uses &
                           (USE_OPCODE | USE_OTHER_OPERAND | USE_ROM_DATA));
      uint8_t value;
      char kinds[96];

      if ((info->uses & USE_MUTABLE_HIGH) == 0 || conflicts != 0)
         continue;

      value = a->cart[a->bank_file_offset + offset];
      describe_candidate_kinds(info->candidate_kinds, kinds, sizeof(kinds));
      printf("safe bank=%zu file_offset=0x%zx bank_offset=0x%03zx "
             "byte=%02x mask=e0 kinds=%s",
             a->bank_index, a->bank_file_offset + offset, offset,
             (unsigned)value, kinds);

      if (info->candidate_kinds & CAND_ABSOLUTE) {
         printf(" pc=$%04" PRIx16 " opcode=%02x mode=%s address=$%04" PRIx16,
                info->first_pc, (unsigned)info->first_opcode,
                mode_name((address_mode_t)info->first_mode),
                info->first_address);
      }
      else if (info->candidate_kinds & CAND_INDIRECT_TARGET) {
         printf(" jmp_pc=$%04" PRIx16 " target=$%04" PRIx16,
                info->first_pc, info->first_address);
      }
      else {
         printf(" target=$%04" PRIx16, info->first_address);
      }

      printf(" values=");
      print_allowed_values(value);
      putchar('\n');
      ++count;
   }
   return count;
}

static int choose_bank_layout(analysis_t *a)
{
   if (a->file_size == TWO_K_SIZE) {
      a->bank_size = TWO_K_SIZE;
      a->bank_count = 1;
      a->bank_file_offset = 0;
      a->bank_index = 0;
      a->trailing_bytes = 0;
      return 1;
   }

   a->bank_size = CART_WINDOW_SIZE;
   a->bank_count = a->file_size / CART_WINDOW_SIZE;
   a->trailing_bytes = a->file_size % CART_WINDOW_SIZE;
   if (a->bank_count == 0)
      return 0;

   /*
    * Every complete 4 KiB bank begins at the start of the file.  A remainder
    * is deliberately excluded.  DPC ROMs such as Pitfall II have exactly
    * 2,303 trailing bytes: 2,048 display bytes plus 255 frequency bytes.
    */
   a->bank_file_offset = 0;
   a->bank_index = 0;
   return 1;
}

static void reset_bank_analysis(analysis_t *a, size_t bank_index)
{
   a->bank_index = bank_index;
   a->bank_file_offset = bank_index * a->bank_size;
   memset(a->byte_info, 0, a->bank_size * sizeof(*a->byte_info));
   memset(a->visited, 0, sizeof(a->visited));
   memset(a->queued, 0, sizeof(a->queued));
   a->work_count = 0;
   a->instruction_count = 0;
   a->unresolved_indirect_jumps = 0;
   a->dynamic_data_accesses = 0;
   a->truncated_instructions = 0;
}

static int analyze(uint8_t *cart, size_t size)
{
   analysis_t a;
   size_t bank_index;
   size_t total_safe = 0;
   size_t total_instructions = 0;
   size_t total_unresolved = 0;
   size_t total_dynamic = 0;
   size_t total_truncated = 0;

   memset(&a, 0, sizeof(a));
   a.cart = cart;
   a.file_size = size;
   if (!choose_bank_layout(&a)) {
      fprintf(stderr, "stego: file is too small to contain a 2K or 4K ROM\n");
      return 0;
   }

   a.byte_info = (byte_info_t *)calloc(a.bank_size, sizeof(*a.byte_info));
   if (a.byte_info == NULL) {
      fprintf(stderr, "stego: could not allocate analysis table: %s\n",
              strerror(errno));
      return 0;
   }

   printf("size=%zu\n", a.file_size);
   printf("complete_banks=%zu\n", a.bank_count);
   printf("bank_size=%zu\n", a.bank_size);
   printf("trailing_bytes=%zu\n", a.trailing_bytes);
   if (a.trailing_bytes == DPC_TRAILING_SIZE)
      printf("ignored_tail=dpc-2048+255\n");
   else if (a.trailing_bytes != 0)
      printf("ignored_tail=partial-bank\n");

   for (bank_index = 0; bank_index < a.bank_count; ++bank_index) {
      uint16_t nmi = 0;
      uint16_t reset = 0;
      uint16_t irq = 0;
      int nmi_valid;
      int reset_valid;
      int irq_valid;
      size_t safe_count;

      reset_bank_analysis(&a, bank_index);
      printf("bank=%zu file_offset=0x%zx\n", a.bank_index,
             a.bank_file_offset);

      nmi_valid = read_vector(&a, 0xfffau, CAND_VECTOR_NMI, &nmi);
      reset_valid = read_vector(&a, 0xfffcu, CAND_VECTOR_RESET, &reset);
      irq_valid = read_vector(&a, 0xfffeu, CAND_VECTOR_IRQ, &irq);
      printf("bank=%zu nmi_vector=$%04" PRIx16 " valid=%s\n",
             a.bank_index, nmi, nmi_valid ? "yes" : "no");
      printf("bank=%zu reset_vector=$%04" PRIx16 " valid=%s\n",
             a.bank_index, reset, reset_valid ? "yes" : "no");
      printf("bank=%zu irq_brk_vector=$%04" PRIx16 " valid=%s\n",
             a.bank_index, irq, irq_valid ? "yes" : "no");

      if (nmi_valid)
         enqueue(&a, nmi);
      if (reset_valid)
         enqueue(&a, reset);
      if (irq_valid)
         enqueue(&a, irq);
      trace(&a);

      safe_count = print_candidates(&a);
      printf("bank=%zu reachable_instruction_starts=%zu\n",
             a.bank_index, a.instruction_count);
      printf("bank=%zu safe_bytes=%zu\n", a.bank_index, safe_count);
      printf("bank=%zu unresolved_indirect_jumps=%zu\n",
             a.bank_index, a.unresolved_indirect_jumps);
      printf("bank=%zu dynamic_indirect_data_accesses=%zu\n",
             a.bank_index, a.dynamic_data_accesses);
      printf("bank=%zu truncated_instructions=%zu\n",
             a.bank_index, a.truncated_instructions);

      total_safe += safe_count;
      total_instructions += a.instruction_count;
      total_unresolved += a.unresolved_indirect_jumps;
      total_dynamic += a.dynamic_data_accesses;
      total_truncated += a.truncated_instructions;
   }

   printf("total_reachable_instruction_starts=%zu\n", total_instructions);
   printf("total_safe_bytes=%zu\n", total_safe);
   printf("total_unresolved_indirect_jumps=%zu\n", total_unresolved);
   printf("total_dynamic_indirect_data_accesses=%zu\n", total_dynamic);
   printf("total_truncated_instructions=%zu\n", total_truncated);

   if (a.bank_count > 1u) {
      fprintf(stderr,
              "stego: warning: all %zu banks were traced independently; "
              "runtime bank-switch control flow was not modeled\n",
              a.bank_count);
   }
   if (a.trailing_bytes == DPC_TRAILING_SIZE) {
      fprintf(stderr,
              "stego: ignored the final %u-byte DPC data tail "
              "(2048 + 255 bytes)\n",
              (unsigned)DPC_TRAILING_SIZE);
   }
   else if (a.trailing_bytes != 0) {
      fprintf(stderr, "stego: warning: ignored %zu trailing byte(s) after "
                      "the last complete bank\n",
              a.trailing_bytes);
   }
   if (total_unresolved != 0) {
      fprintf(stderr,
              "stego: warning: %zu JMP-indirect target(s) were outside the "
              "currently analyzed ROM bank\n",
              total_unresolved);
   }
   if (total_dynamic != 0) {
      fprintf(stderr,
              "stego: warning: %zu reached instruction(s) use runtime "
              "zero-page indirect addresses; arbitrary ROM data reads are "
              "not modeled\n",
              total_dynamic);
   }

   free(a.byte_info);
   return 1;
}

static int read_file(const char *path, uint8_t **data, size_t *size)
{
   FILE *f;
   long end;
   uint8_t *buffer;
   size_t got;

   f = fopen(path, "rb");
   if (f == NULL) {
      fprintf(stderr, "stego: could not open '%s': %s\n", path,
              strerror(errno));
      return 0;
   }

   if (fseek(f, 0, SEEK_END) != 0 || (end = ftell(f)) < 0 ||
       fseek(f, 0, SEEK_SET) != 0) {
      fprintf(stderr, "stego: could not determine size of '%s': %s\n", path,
              strerror(errno));
      fclose(f);
      return 0;
   }

   if ((uintmax_t)end > (uintmax_t)SIZE_MAX) {
      fprintf(stderr, "stego: '%s' is too large for this build\n", path);
      fclose(f);
      return 0;
   }

   *size = (size_t)end;
   if (*size == 0) {
      fprintf(stderr, "stego: '%s' is empty\n", path);
      fclose(f);
      return 0;
   }

   buffer = (uint8_t *)malloc(*size);
   if (buffer == NULL) {
      fprintf(stderr, "stego: could not allocate %zu bytes: %s\n", *size,
              strerror(errno));
      fclose(f);
      return 0;
   }

   got = fread(buffer, 1, *size, f);
   if (got != *size) {
      if (ferror(f))
         fprintf(stderr, "stego: error reading '%s': %s\n", path,
                 strerror(errno));
      else
         fprintf(stderr, "stego: short read from '%s': got %zu of %zu bytes\n",
                 path, got, *size);
      free(buffer);
      fclose(f);
      return 0;
   }

   if (fclose(f) != 0) {
      fprintf(stderr, "stego: error closing '%s': %s\n", path,
              strerror(errno));
      free(buffer);
      return 0;
   }

   *data = buffer;
   return 1;
}

int main(int argc, char **argv)
{
   uint8_t *cart = NULL;
   size_t size = 0;
   int ok;

   if (argc != 2) {
      fprintf(stderr, "usage: %s cartridge.bin\n", argv[0]);
      return EXIT_FAILURE;
   }

   if (!read_file(argv[1], &cart, &size))
      return EXIT_FAILURE;

   ok = analyze(cart, size);
   free(cart);
   return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
