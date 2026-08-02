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
 *   - A small abstract interpreter tracks constants in A, X, Y, zero page,
 *     and the most recent hardware-stack bytes.  This resolves common
 *     LDA/LDX/LDY-immediate plus STA/STX/STY pointer setup, JMP through a
 *     zero-page pointer, synthetic return-address dispatches made by pushing
 *     constant high/low bytes followed by RTS, and the common table-driven RTS
 *     dispatch sequence that loads a correlated high/low pair with the same
 *     even X or Y index.  At branches, constants survive only when all incoming
 *     paths agree.
 *   - JSR fallthrough preserves zero-page constants only for cells that a
 *     conservative scan of the called routine cannot write.  Registers are
 *     treated as clobbered.  Unresolved indirect control flow in a called
 *     routine invalidates every tracked zero-page constant.
 *   - Runtime targets that remain unknown, nonconstant RTS/RTI tricks,
 *     self-generated RAM code, and unresolved indirect data reads are reported.  Candidate bytes
 *     remain listed when an indirect data address cannot be resolved, so such
 *     output requires review of the accompanying warning.
 *   - "Safe" means bus-equivalent under normal 6507 mirroring.  Deliberate
 *     software inspection of logical PC/stack address bits can invalidate that
 *     assumption.
 */

#define CART_WINDOW_SIZE 4096u
#define TWO_K_SIZE 2048u
#define DPC_TRAILING_SIZE (2048u + 255u)
#define ADDRESS_SPACE_SIZE 65536u
#define ZERO_PAGE_SIZE 256u
#define ZERO_PAGE_KNOWN_BYTES (ZERO_PAGE_SIZE / 8u)
#define STACK_TRACK_DEPTH 8u
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
   FLOW_RTS,
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
   uint8_t a_known;
   uint8_t a;
   uint8_t x_known;
   uint8_t x;
   uint8_t y_known;
   uint8_t y;
   uint8_t zp_known[ZERO_PAGE_KNOWN_BYTES];
   uint8_t zp_value[ZERO_PAGE_SIZE];
   /* Entries are stored in pull order: element 0 is the next byte popped. */
   uint8_t stack_count;
   uint8_t stack_known[STACK_TRACK_DEPTH];
   uint8_t stack_value[STACK_TRACK_DEPTH];
} abstract_state_t;

typedef struct {
   uint8_t *cart;
   size_t file_size;
   size_t bank_file_offset;
   size_t bank_index;
   size_t bank_size;
   size_t bank_count;
   size_t trailing_bytes;
   byte_info_t *byte_info;
   abstract_state_t *states;
   uint8_t *subroutine_summaries;
   uint8_t visited[ADDRESS_SPACE_SIZE];
   uint8_t state_seen[ADDRESS_SPACE_SIZE];
   uint8_t queued[ADDRESS_SPACE_SIZE];
   uint8_t unresolved_indirect_pc[ADDRESS_SPACE_SIZE];
   uint8_t resolved_ram_indirect_pc[ADDRESS_SPACE_SIZE];
   uint8_t unresolved_rts_pc[ADDRESS_SPACE_SIZE];
   uint8_t resolved_stack_rts_pc[ADDRESS_SPACE_SIZE];
   uint8_t resolved_table_rts_pc[ADDRESS_SPACE_SIZE];
   uint8_t resolved_table_rts_target[ADDRESS_SPACE_SIZE];
   uint8_t unresolved_dynamic_pc[ADDRESS_SPACE_SIZE];
   uint8_t resolved_dynamic_pc[ADDRESS_SPACE_SIZE];
   uint8_t truncated_pc[ADDRESS_SPACE_SIZE];
   uint8_t summary_valid[ADDRESS_SPACE_SIZE];
   uint8_t summary_visited[ADDRESS_SPACE_SIZE];
   uint16_t work[ADDRESS_SPACE_SIZE];
   uint16_t summary_work[ADDRESS_SPACE_SIZE];
   size_t work_count;
   size_t instruction_count;
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
   case 0x60:
      return FLOW_RTS;
   case 0x40:
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

static int state_zp_is_known(const abstract_state_t *state, uint8_t address)
{
   return (state->zp_known[address >> 3] &
           (uint8_t)(1u << (address & 7u))) != 0;
}

static void state_zp_set_known(abstract_state_t *state, uint8_t address,
                               uint8_t value)
{
   state->zp_known[address >> 3] |= (uint8_t)(1u << (address & 7u));
   state->zp_value[address] = value;
}

static void state_zp_set_unknown(abstract_state_t *state, uint8_t address)
{
   state->zp_known[address >> 3] &=
      (uint8_t)~(uint8_t)(1u << (address & 7u));
}

static void state_zp_set_all_unknown(abstract_state_t *state)
{
   memset(state->zp_known, 0, sizeof(state->zp_known));
}

static int state_zp_get(const abstract_state_t *state, uint8_t address,
                        uint8_t *value)
{
   if (!state_zp_is_known(state, address))
      return 0;
   *value = state->zp_value[address];
   return 1;
}

static void state_stack_clear(abstract_state_t *state)
{
   state->stack_count = 0;
}

static void state_stack_push(abstract_state_t *state, int known, uint8_t value)
{
   size_t i;
   size_t limit = state->stack_count;

   if (limit >= STACK_TRACK_DEPTH)
      limit = STACK_TRACK_DEPTH - 1u;
   for (i = limit; i != 0; --i) {
      state->stack_known[i] = state->stack_known[i - 1u];
      state->stack_value[i] = state->stack_value[i - 1u];
   }
   state->stack_known[0] = known ? 1u : 0u;
   state->stack_value[0] = value;
   if (state->stack_count < STACK_TRACK_DEPTH)
      ++state->stack_count;
}

static int state_stack_pop(abstract_state_t *state, int *known, uint8_t *value)
{
   size_t i;

   if (state->stack_count == 0) {
      *known = 0;
      *value = 0;
      return 0;
   }
   *known = state->stack_known[0] != 0;
   *value = state->stack_value[0];
   for (i = 1; i < state->stack_count; ++i) {
      state->stack_known[i - 1u] = state->stack_known[i];
      state->stack_value[i - 1u] = state->stack_value[i];
   }
   --state->stack_count;
   return 1;
}

static int state_merge(abstract_state_t *destination,
                       const abstract_state_t *source)
{
   unsigned address;
   int changed = 0;

#define MERGE_REGISTER(name)                                                   \
   do {                                                                         \
      if (destination->name##_known &&                                         \
          (!source->name##_known || destination->name != source->name)) {      \
         destination->name##_known = 0;                                        \
         changed = 1;                                                          \
      }                                                                         \
   } while (0)

   MERGE_REGISTER(a);
   MERGE_REGISTER(x);
   MERGE_REGISTER(y);
#undef MERGE_REGISTER

   for (address = 0; address < ZERO_PAGE_SIZE; ++address) {
      uint8_t zp = (uint8_t)address;
      if (state_zp_is_known(destination, zp) &&
          (!state_zp_is_known(source, zp) ||
           destination->zp_value[zp] != source->zp_value[zp])) {
         state_zp_set_unknown(destination, zp);
         changed = 1;
      }
   }

   if (destination->stack_count != source->stack_count) {
      if (destination->stack_count != 0) {
         state_stack_clear(destination);
         changed = 1;
      }
   }
   else {
      for (address = 0; address < destination->stack_count; ++address) {
         if (destination->stack_known[address] &&
             (!source->stack_known[address] ||
              destination->stack_value[address] !=
                 source->stack_value[address])) {
            destination->stack_known[address] = 0;
            changed = 1;
         }
      }
   }
   return changed;
}

static void enqueue_state(analysis_t *a, uint16_t pc,
                          const abstract_state_t *state)
{
   int changed;

   if (!address_is_cartridge(pc))
      return;

   if (!a->state_seen[pc]) {
      a->states[pc] = *state;
      a->state_seen[pc] = 1;
      changed = 1;
   }
   else {
      changed = state_merge(&a->states[pc], state);
   }

   if (!changed || a->queued[pc])
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

static int resolve_zp_word(const abstract_state_t *state, uint8_t pointer,
                           uint16_t *value)
{
   uint8_t low;
   uint8_t high;
   if (!state_zp_get(state, pointer, &low) ||
       !state_zp_get(state, (uint8_t)(pointer + 1u), &high))
      return 0;
   *value = (uint16_t)(low | ((uint16_t)high << 8));
   return 1;
}

static int resolve_effective_address(const abstract_state_t *state,
                                     address_mode_t mode,
                                     uint16_t operand, uint16_t *address)
{
   uint16_t pointer;
   switch (mode) {
   case AM_ZERO_PAGE:
      *address = (uint8_t)operand;
      return 1;
   case AM_ZERO_PAGE_X:
      if (!state->x_known)
         return 0;
      *address = (uint8_t)((uint8_t)operand + state->x);
      return 1;
   case AM_ZERO_PAGE_Y:
      if (!state->y_known)
         return 0;
      *address = (uint8_t)((uint8_t)operand + state->y);
      return 1;
   case AM_ABSOLUTE:
      *address = operand;
      return 1;
   case AM_ABSOLUTE_X:
      if (!state->x_known)
         return 0;
      *address = (uint16_t)(operand + state->x);
      return 1;
   case AM_ABSOLUTE_Y:
      if (!state->y_known)
         return 0;
      *address = (uint16_t)(operand + state->y);
      return 1;
   case AM_INDEXED_INDIRECT:
      if (!state->x_known ||
          !resolve_zp_word(state,
                           (uint8_t)((uint8_t)operand + state->x), &pointer))
         return 0;
      *address = pointer;
      return 1;
   case AM_INDIRECT_INDEXED:
      if (!state->y_known ||
          !resolve_zp_word(state, (uint8_t)operand, &pointer))
         return 0;
      *address = (uint16_t)(pointer + state->y);
      return 1;
   default:
      return 0;
   }
}

static int read_known_byte(const analysis_t *a,
                           const abstract_state_t *state,
                           uint16_t address, uint8_t *value)
{
   if (address <= 0x00ffu)
      return state_zp_get(state, (uint8_t)address, value);
   return fetch_bank_byte(a, address, value, NULL);
}

static int read_known_operand(const analysis_t *a,
                              const abstract_state_t *state,
                              address_mode_t mode, const uint8_t bytes[3],
                              uint8_t *value)
{
   uint16_t operand;
   uint16_t address;

   if (mode == AM_IMMEDIATE) {
      *value = bytes[1];
      return 1;
   }

   operand = bytes[1];
   if (mode_has_absolute_operand(mode))
      operand |= (uint16_t)bytes[2] << 8;

   if (!resolve_effective_address(state, mode, operand, &address))
      return 0;
   return read_known_byte(a, state, address, value);
}

static int opcode_writes_a(uint8_t opcode)
{
   switch (opcode) {
   case 0x01: case 0x03: case 0x05: case 0x07: case 0x09: case 0x0a:
   case 0x0b: case 0x0d: case 0x0f: case 0x11: case 0x13: case 0x15:
   case 0x17: case 0x19: case 0x1b: case 0x1d: case 0x1f:
   case 0x21: case 0x23: case 0x25: case 0x27: case 0x29: case 0x2a:
   case 0x2b: case 0x2d: case 0x2f: case 0x31: case 0x33: case 0x35:
   case 0x37: case 0x39: case 0x3b: case 0x3d: case 0x3f:
   case 0x41: case 0x43: case 0x45: case 0x47: case 0x49: case 0x4a:
   case 0x4b: case 0x4d: case 0x4f: case 0x51: case 0x53: case 0x55:
   case 0x57: case 0x59: case 0x5b: case 0x5d: case 0x5f:
   case 0x61: case 0x63: case 0x65: case 0x67: case 0x68: case 0x69:
   case 0x6a: case 0x6b: case 0x6d: case 0x6f: case 0x71: case 0x73:
   case 0x75: case 0x77: case 0x79: case 0x7b: case 0x7d: case 0x7f:
   case 0x8a: case 0x8b: case 0x98:
   case 0xa1: case 0xa3: case 0xa5: case 0xa7: case 0xa9: case 0xab:
   case 0xad: case 0xaf: case 0xb1: case 0xb3: case 0xb5: case 0xb7:
   case 0xb9: case 0xbb: case 0xbd: case 0xbf:
   case 0xe1: case 0xe3: case 0xe5: case 0xe7: case 0xe9: case 0xeb:
   case 0xed: case 0xef: case 0xf1: case 0xf3: case 0xf5: case 0xf7:
   case 0xf9: case 0xfb: case 0xfd: case 0xff:
      return 1;
   default:
      return 0;
   }
}

static int opcode_writes_x(uint8_t opcode)
{
   switch (opcode) {
   case 0xa2: case 0xa3: case 0xa6: case 0xa7: case 0xaa: case 0xab:
   case 0xae: case 0xaf: case 0xb3: case 0xb6: case 0xb7: case 0xba:
   case 0xbb: case 0xbe: case 0xbf: case 0xca: case 0xcb: case 0xe8:
      return 1;
   default:
      return 0;
   }
}

static int opcode_writes_y(uint8_t opcode)
{
   switch (opcode) {
   case 0x88: case 0xa0: case 0xa4: case 0xa8: case 0xac:
   case 0xb4: case 0xbc: case 0xc8:
      return 1;
   default:
      return 0;
   }
}

static int opcode_writes_memory(uint8_t opcode)
{
   switch (opcode) {
   case 0x03: case 0x06: case 0x07: case 0x0e: case 0x0f:
   case 0x13: case 0x16: case 0x17: case 0x1b: case 0x1e: case 0x1f:
   case 0x23: case 0x26: case 0x27: case 0x2e: case 0x2f:
   case 0x33: case 0x36: case 0x37: case 0x3b: case 0x3e: case 0x3f:
   case 0x43: case 0x46: case 0x47: case 0x4e: case 0x4f:
   case 0x53: case 0x56: case 0x57: case 0x5b: case 0x5e: case 0x5f:
   case 0x63: case 0x66: case 0x67: case 0x6e: case 0x6f:
   case 0x73: case 0x76: case 0x77: case 0x7b: case 0x7e: case 0x7f:
   case 0x81: case 0x83: case 0x84: case 0x85: case 0x86: case 0x87:
   case 0x8c: case 0x8d: case 0x8e: case 0x8f:
   case 0x91: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97:
   case 0x99: case 0x9b: case 0x9c: case 0x9d: case 0x9e: case 0x9f:
   case 0xc3: case 0xc6: case 0xc7: case 0xce: case 0xcf:
   case 0xd3: case 0xd6: case 0xd7: case 0xdb: case 0xde: case 0xdf:
   case 0xe3: case 0xe6: case 0xe7: case 0xee: case 0xef:
   case 0xf3: case 0xf6: case 0xf7: case 0xfb: case 0xfe: case 0xff:
      return 1;
   default:
      return 0;
   }
}

static int known_store_value(uint8_t opcode, const abstract_state_t *state,
                             uint8_t *value)
{
   switch (opcode) {
   case 0x81: case 0x85: case 0x8d: case 0x91:
   case 0x95: case 0x99: case 0x9d:
      if (!state->a_known)
         return 0;
      *value = state->a;
      return 1;
   case 0x84: case 0x8c: case 0x94:
      if (!state->y_known)
         return 0;
      *value = state->y;
      return 1;
   case 0x86: case 0x8e: case 0x96:
      if (!state->x_known)
         return 0;
      *value = state->x;
      return 1;
   case 0x83: case 0x87: case 0x8f: case 0x97:
      if (!state->a_known || !state->x_known)
         return 0;
      *value = (uint8_t)(state->a & state->x);
      return 1;
   default:
      return 0;
   }
}

static void apply_memory_write(const abstract_state_t *input,
                               abstract_state_t *output, uint8_t opcode,
                               address_mode_t mode, const uint8_t bytes[3])
{
   uint16_t operand = bytes[1];
   uint16_t address;
   uint8_t value;
   int value_known;

   if (!opcode_writes_memory(opcode))
      return;

   if (mode_has_absolute_operand(mode))
      operand |= (uint16_t)bytes[2] << 8;
   value_known = known_store_value(opcode, input, &value);

   if (!resolve_effective_address(input, mode, operand, &address)) {
      /* An unresolved indexed or indirect write could alias any zero-page byte. */
      state_zp_set_all_unknown(output);
      return;
   }

   if (address > 0x00ffu)
      return;

   if (value_known)
      state_zp_set_known(output, (uint8_t)address, value);
   else
      state_zp_set_unknown(output, (uint8_t)address);
}

static void transfer_state(const analysis_t *a,
                           const abstract_state_t *input,
                           abstract_state_t *output, uint8_t opcode,
                           address_mode_t mode, const uint8_t bytes[3])
{
   uint8_t value;

   *output = *input;
   apply_memory_write(input, output, opcode, mode, bytes);

   if (opcode_writes_a(opcode))
      output->a_known = 0;
   if (opcode_writes_x(opcode))
      output->x_known = 0;
   if (opcode_writes_y(opcode))
      output->y_known = 0;

   switch (opcode) {
   case 0xa9: /* LDA #imm */
      output->a_known = 1;
      output->a = bytes[1];
      break;
   case 0xa2: /* LDX #imm */
      output->x_known = 1;
      output->x = bytes[1];
      break;
   case 0xa0: /* LDY #imm */
      output->y_known = 1;
      output->y = bytes[1];
      break;

   case 0xa1: case 0xa5: case 0xad: case 0xb1: case 0xb5:
   case 0xb9: case 0xbd: /* LDA */
      if (read_known_operand(a, input, mode, bytes, &value)) {
         output->a_known = 1;
         output->a = value;
      }
      break;
   case 0xa6: case 0xae: case 0xb6: case 0xbe: /* LDX */
      if (read_known_operand(a, input, mode, bytes, &value)) {
         output->x_known = 1;
         output->x = value;
      }
      break;
   case 0xa4: case 0xac: case 0xb4: case 0xbc: /* LDY */
      if (read_known_operand(a, input, mode, bytes, &value)) {
         output->y_known = 1;
         output->y = value;
      }
      break;
   case 0xa3: case 0xa7: case 0xab: case 0xaf:
   case 0xb3: case 0xb7: case 0xbf: /* LAX */
      if (read_known_operand(a, input, mode, bytes, &value)) {
         output->a_known = 1;
         output->a = value;
         output->x_known = 1;
         output->x = value;
      }
      break;

   case 0xaa: /* TAX */
      if (input->a_known) {
         output->x_known = 1;
         output->x = input->a;
      }
      break;
   case 0xa8: /* TAY */
      if (input->a_known) {
         output->y_known = 1;
         output->y = input->a;
      }
      break;
   case 0x8a: /* TXA */
      if (input->x_known) {
         output->a_known = 1;
         output->a = input->x;
      }
      break;
   case 0x98: /* TYA */
      if (input->y_known) {
         output->a_known = 1;
         output->a = input->y;
      }
      break;
   case 0xe8: /* INX */
      if (input->x_known) {
         output->x_known = 1;
         output->x = (uint8_t)(input->x + 1u);
      }
      break;
   case 0xca: /* DEX */
      if (input->x_known) {
         output->x_known = 1;
         output->x = (uint8_t)(input->x - 1u);
      }
      break;
   case 0xc8: /* INY */
      if (input->y_known) {
         output->y_known = 1;
         output->y = (uint8_t)(input->y + 1u);
      }
      break;
   case 0x88: /* DEY */
      if (input->y_known) {
         output->y_known = 1;
         output->y = (uint8_t)(input->y - 1u);
      }
      break;

   case 0x0a: /* ASL A */
      if (input->a_known) {
         output->a_known = 1;
         output->a = (uint8_t)(input->a << 1);
      }
      break;

   case 0x09: /* ORA #imm */
      if (input->a_known) {
         output->a_known = 1;
         output->a = (uint8_t)(input->a | bytes[1]);
      }
      break;
   case 0x29: /* AND #imm */
      if (input->a_known) {
         output->a_known = 1;
         output->a = (uint8_t)(input->a & bytes[1]);
      }
      break;
   case 0x49: /* EOR #imm */
      if (input->a_known) {
         output->a_known = 1;
         output->a = (uint8_t)(input->a ^ bytes[1]);
      }
      break;

   case 0x48: /* PHA */
      state_stack_push(output, input->a_known, input->a);
      break;
   case 0x08: /* PHP: status is not tracked, but stack depth is. */
      state_stack_push(output, 0, 0);
      break;
   case 0x68: { /* PLA */
      int known;
      if (state_stack_pop(output, &known, &value) && known) {
         output->a_known = 1;
         output->a = value;
      }
      else {
         output->a_known = 0;
      }
      break;
   }
   case 0x28: { /* PLP */
      int known;
      (void)state_stack_pop(output, &known, &value);
      break;
   }
   case 0x9a: /* TXS changes which physical bytes are at the stack top. */
      state_stack_clear(output);
      break;
   default:
      break;
   }
}

static void mark_direct_and_indirect_data_access(analysis_t *a,
                                                 uint16_t pc,
                                                 const abstract_state_t *state,
                                                 uint8_t opcode,
                                                 address_mode_t mode,
                                                 const uint8_t bytes[3])
{
   flow_kind_t flow = instruction_flow(opcode);
   uint16_t operand = bytes[1];
   uint16_t address;
   uint16_t pointer;

   if (flow == FLOW_JSR || flow == FLOW_JMP_ABSOLUTE ||
       flow == FLOW_JMP_INDIRECT || opcode_is_write_only(opcode))
      return;

   if (mode_has_absolute_operand(mode))
      operand |= (uint16_t)bytes[2] << 8;

   switch (mode) {
   case AM_ABSOLUTE:
      mark_rom_data_byte(a, operand);
      break;
   case AM_ABSOLUTE_X:
      if (state->x_known)
         mark_rom_data_byte(a, (uint16_t)(operand + state->x));
      else
         mark_possible_indexed_rom_data(a, operand);
      break;
   case AM_ABSOLUTE_Y:
      if (state->y_known)
         mark_rom_data_byte(a, (uint16_t)(operand + state->y));
      else
         mark_possible_indexed_rom_data(a, operand);
      break;
   case AM_INDEXED_INDIRECT:
      if (state->x_known &&
          resolve_zp_word(state,
                          (uint8_t)((uint8_t)operand + state->x), &address)) {
         mark_rom_data_byte(a, address);
         a->resolved_dynamic_pc[pc] = 1;
      }
      else {
         a->unresolved_dynamic_pc[pc] = 1;
      }
      break;
   case AM_INDIRECT_INDEXED:
      if (resolve_zp_word(state, (uint8_t)operand, &pointer)) {
         if (state->y_known)
            mark_rom_data_byte(a, (uint16_t)(pointer + state->y));
         else
            mark_possible_indexed_rom_data(a, pointer);
         a->resolved_dynamic_pc[pc] = 1;
      }
      else {
         a->unresolved_dynamic_pc[pc] = 1;
      }
      break;
   default:
      break;
   }
}

typedef enum {
   KNOWN_BYTE_NONE,
   KNOWN_BYTE_ROM,
   KNOWN_BYTE_ZERO_PAGE
} known_byte_source_t;

static known_byte_source_t read_indirect_pointer_byte(
   const analysis_t *a, const abstract_state_t *state, uint16_t address,
   uint8_t *value, size_t *rom_offset)
{
   if (address <= 0x00ffu && state_zp_get(state, (uint8_t)address, value))
      return KNOWN_BYTE_ZERO_PAGE;
   if (fetch_bank_byte(a, address, value, rom_offset))
      return KNOWN_BYTE_ROM;
   return KNOWN_BYTE_NONE;
}

static int resolve_indirect_jump(analysis_t *a, uint16_t pc,
                                 const abstract_state_t *state,
                                 uint16_t pointer, uint16_t *target)
{
   uint16_t high_address;
   uint8_t low;
   uint8_t high;
   size_t low_offset = 0;
   size_t high_offset = 0;
   known_byte_source_t low_source;
   known_byte_source_t high_source;

   /* Reproduce the NMOS 6502 JMP ($xxff) page-wrap behavior. */
   high_address = (uint16_t)((pointer & 0xff00u) |
                             ((uint16_t)(pointer + 1u) & 0x00ffu));

   low_source = read_indirect_pointer_byte(a, state, pointer, &low,
                                           &low_offset);
   high_source = read_indirect_pointer_byte(a, state, high_address, &high,
                                            &high_offset);
   if (low_source == KNOWN_BYTE_NONE || high_source == KNOWN_BYTE_NONE) {
      a->unresolved_indirect_pc[pc] = 1;
      return 0;
   }

   a->unresolved_indirect_pc[pc] = 0;
   if (low_source == KNOWN_BYTE_ROM)
      a->byte_info[low_offset].uses |= USE_ROM_DATA;

   *target = (uint16_t)(low | ((uint16_t)high << 8));
   if (high_source == KNOWN_BYTE_ROM) {
      if ((high & 0x10u) != 0) {
         remember_candidate(a, high_offset, CAND_INDIRECT_TARGET, pc, 0x6c,
                            AM_INDIRECT, *target);
      }
      else {
         a->byte_info[high_offset].uses |= USE_ROM_DATA;
      }
   }
   else {
      a->resolved_ram_indirect_pc[pc] = 1;
   }

   if (low_source == KNOWN_BYTE_ZERO_PAGE)
      a->resolved_ram_indirect_pc[pc] = 1;
   return 1;
}

static void summary_set_byte(uint8_t summary[ZERO_PAGE_KNOWN_BYTES],
                             uint8_t address)
{
   summary[address >> 3] |= (uint8_t)(1u << (address & 7u));
}

static void summary_set_all(uint8_t summary[ZERO_PAGE_KNOWN_BYTES])
{
   memset(summary, 0xff, ZERO_PAGE_KNOWN_BYTES);
}

static int summary_is_all(const uint8_t summary[ZERO_PAGE_KNOWN_BYTES])
{
   unsigned i;
   for (i = 0; i < ZERO_PAGE_KNOWN_BYTES; ++i) {
      if (summary[i] != 0xffu)
         return 0;
   }
   return 1;
}

static void summary_note_memory_write(
   uint8_t summary[ZERO_PAGE_KNOWN_BYTES], uint8_t opcode,
   address_mode_t mode, const uint8_t bytes[3])
{
   uint16_t address;

   if (!opcode_writes_memory(opcode))
      return;

   switch (mode) {
   case AM_ZERO_PAGE:
      summary_set_byte(summary, bytes[1]);
      break;
   case AM_ABSOLUTE:
      address = (uint16_t)(bytes[1] | ((uint16_t)bytes[2] << 8));
      if (address <= 0x00ffu)
         summary_set_byte(summary, (uint8_t)address);
      break;
   case AM_ZERO_PAGE_X:
   case AM_ZERO_PAGE_Y:
   case AM_ABSOLUTE_X:
   case AM_ABSOLUTE_Y:
   case AM_INDEXED_INDIRECT:
   case AM_INDIRECT_INDEXED:
      /* Without caller register/pointer state, any zero-page byte may alias. */
      summary_set_all(summary);
      break;
   default:
      break;
   }
}

static int resolve_rom_indirect_target(const analysis_t *a,
                                       uint16_t pointer, uint16_t *target)
{
   uint16_t high_address;
   uint8_t low;
   uint8_t high;

   high_address = (uint16_t)((pointer & 0xff00u) |
                             ((uint16_t)(pointer + 1u) & 0x00ffu));
   if (!fetch_bank_byte(a, pointer, &low, NULL) ||
       !fetch_bank_byte(a, high_address, &high, NULL))
      return 0;
   *target = (uint16_t)(low | ((uint16_t)high << 8));
   return 1;
}

static const uint8_t *subroutine_zp_summary(analysis_t *a, uint16_t target)
{
   uint8_t *summary = a->subroutine_summaries +
                      (size_t)target * ZERO_PAGE_KNOWN_BYTES;
   size_t count = 0;

   if (a->summary_valid[target])
      return summary;

   memset(summary, 0, ZERO_PAGE_KNOWN_BYTES);
   memset(a->summary_visited, 0, sizeof(a->summary_visited));
   if (address_is_cartridge(target)) {
      a->summary_visited[target] = 1;
      a->summary_work[count++] = target;
   }

   while (count != 0 && !summary_is_all(summary)) {
      uint16_t pc = a->summary_work[--count];
      uint8_t bytes[3] = { 0, 0, 0 };
      size_t offsets[3] = { 0, 0, 0 };
      uint8_t opcode;
      address_mode_t mode;
      flow_kind_t flow;
      unsigned length;
      uint16_t next;
      uint16_t address = 0;

      if (!fetch_bank_byte(a, pc, &opcode, NULL)) {
         summary_set_all(summary);
         break;
      }
      mode = (address_mode_t)opcode_modes[opcode];
      length = instruction_length(mode);
      if (!fetch_instruction(a, pc, bytes, offsets, length)) {
         summary_set_all(summary);
         break;
      }
      next = (uint16_t)(pc + length);
      if (mode_has_absolute_operand(mode))
         address = (uint16_t)(bytes[1] | ((uint16_t)bytes[2] << 8));
      summary_note_memory_write(summary, opcode, mode, bytes);
      flow = instruction_flow(opcode);

#define SUMMARY_PUSH(value)                                                     \
      do {                                                                       \
         uint16_t summary_pc_ = (uint16_t)(value);                              \
         if (address_is_cartridge(summary_pc_) &&                               \
             !a->summary_visited[summary_pc_]) {                                 \
            a->summary_visited[summary_pc_] = 1;                                \
            a->summary_work[count++] = summary_pc_;                             \
         }                                                                       \
      } while (0)

      switch (flow) {
      case FLOW_NEXT:
         SUMMARY_PUSH(next);
         break;
      case FLOW_BRANCH:
         SUMMARY_PUSH(next);
         SUMMARY_PUSH((uint16_t)(next + (int8_t)bytes[1]));
         break;
      case FLOW_JSR:
         SUMMARY_PUSH(next);
         SUMMARY_PUSH(address);
         break;
      case FLOW_JMP_ABSOLUTE:
         SUMMARY_PUSH(address);
         break;
      case FLOW_JMP_INDIRECT: {
         uint16_t indirect_target;
         if (resolve_rom_indirect_target(a, address, &indirect_target))
            SUMMARY_PUSH(indirect_target);
         else
            summary_set_all(summary);
         break;
      }
      case FLOW_RTS:
         break;
      case FLOW_BRK:
         summary_set_all(summary);
         break;
      case FLOW_STOP:
         break;
      }
#undef SUMMARY_PUSH
   }

   a->summary_valid[target] = 1;
   return summary;
}

static void apply_subroutine_clobbers(analysis_t *a,
                                      abstract_state_t *state,
                                      uint16_t target)
{
   const uint8_t *summary = subroutine_zp_summary(a, target);
   unsigned address;

   state->a_known = 0;
   state->x_known = 0;
   state->y_known = 0;
   for (address = 0; address < ZERO_PAGE_SIZE; ++address) {
      if ((summary[address >> 3] &
           (uint8_t)(1u << (address & 7u))) != 0)
         state_zp_set_unknown(state, (uint8_t)address);
   }
}

/*
 * Recognize this compact computed-dispatch idiom immediately before RTS:
 *
 *       ASL A
 *       TAY                    ; or TAX
 *       LDA high_table,Y       ; or ,X
 *       PHA
 *       LDA low_table,Y
 *       PHA
 *       RTS
 *
 * ASL guarantees that the shared index is even, so each table entry is one
 * little-endian target-minus-one word.  The two loads are deliberately paired
 * by the same index; independently combining their possible bytes would invent
 * a cross product of targets that the program can never produce.
 *
 * This is a conservative reachability expansion.  It enumerates every even
 * index, because the value shifted into X/Y may be unknown.  Extra paths can
 * reduce the final safe-byte set, but cannot make an unsafe byte appear safe.
 */
static int resolve_indexed_table_rts(analysis_t *a, uint16_t pc,
                                     const abstract_state_t *returned)
{
   uint8_t bytes[11];
   size_t ignored_offset;
   uint16_t start = (uint16_t)(pc - 10u);
   uint8_t index_transfer;
   uint8_t indexed_load;
   uint16_t high_base;
   uint16_t low_base;
   unsigned index;
   unsigned table_bytes;
   size_t target_count = 0;

   for (index = 0; index < sizeof(bytes); ++index) {
      if (!fetch_bank_byte(a, (uint16_t)(start + index), &bytes[index],
                           &ignored_offset))
         return 0;
   }

   if (bytes[0] != 0x0au || bytes[10] != 0x60u ||
       bytes[5] != 0x48u || bytes[9] != 0x48u)
      return 0;

   index_transfer = bytes[1];
   if (index_transfer == 0xa8u)       /* TAY */
      indexed_load = 0xb9u;           /* LDA abs,Y */
   else if (index_transfer == 0xaau)  /* TAX */
      indexed_load = 0xbdu;           /* LDA abs,X */
   else
      return 0;

   if (bytes[2] != indexed_load || bytes[6] != indexed_load)
      return 0;

   high_base = (uint16_t)(bytes[3] | ((uint16_t)bytes[4] << 8));
   low_base = (uint16_t)(bytes[7] | ((uint16_t)bytes[8] << 8));

   /*
    * Require the packed word table to begin immediately after the RTS.  In
    * this idiom entry zero points to the first instruction after the table,
    * which gives a structural, non-guessing bound for the valid even indexes.
    */
   if (!address_is_cartridge(low_base) || !address_is_cartridge(high_base) ||
       (low_base & 0x0fffu) == 0x0fffu ||
       ((high_base & 0x0fffu) != ((low_base + 1u) & 0x0fffu)) ||
       ((low_base & 0x0fffu) != ((pc + 1u) & 0x0fffu)))
      return 0;

   {
      uint8_t first_low;
      uint8_t first_high;
      uint16_t first_target;
      unsigned low_offset = (unsigned)(low_base & 0x0fffu);
      unsigned target_offset;

      if (!fetch_bank_byte(a, low_base, &first_low, NULL) ||
          !fetch_bank_byte(a, high_base, &first_high, NULL))
         return 0;
      first_target = (uint16_t)(
         (uint16_t)(first_low | ((uint16_t)first_high << 8)) + 1u);
      if (!address_is_cartridge(first_target))
         return 0;
      target_offset = (unsigned)(first_target & 0x0fffu);
      if (target_offset <= low_offset)
         return 0;
      table_bytes = target_offset - low_offset;
      if (table_bytes > 256u || (table_bytes & 1u) != 0)
         return 0;
   }

   for (index = 0; index < table_bytes; index += 2u) {
      uint16_t low_address = (uint16_t)(low_base + index);
      uint16_t high_address = (uint16_t)(high_base + index);
      uint8_t low;
      uint8_t high;
      uint16_t target;

      if (!fetch_bank_byte(a, low_address, &low, NULL) ||
          !fetch_bank_byte(a, high_address, &high, NULL))
         continue;

      /* These bytes are semantically live table data, never stego candidates. */
      mark_rom_data_byte(a, low_address);
      mark_rom_data_byte(a, high_address);

      target = (uint16_t)(
         (uint16_t)(low | ((uint16_t)high << 8)) + 1u);
      if (!address_is_cartridge(target))
         continue;

      a->resolved_table_rts_target[target] = 1;
      enqueue_state(a, target, returned);
      ++target_count;
   }

   if (target_count == 0)
      return 0;

   a->resolved_table_rts_pc[pc] = 1;
   return 1;
}

static void trace(analysis_t *a)
{
   while (a->work_count != 0) {
      uint16_t pc = a->work[--a->work_count];
      const abstract_state_t *input = &a->states[pc];
      abstract_state_t output;
      uint8_t bytes[3] = { 0, 0, 0 };
      size_t offsets[3] = { 0, 0, 0 };
      uint8_t opcode;
      address_mode_t mode;
      flow_kind_t flow;
      unsigned length;
      uint16_t next;
      uint16_t address = 0;

      a->queued[pc] = 0;
      if (!fetch_bank_byte(a, pc, &opcode, NULL))
         continue;

      mode = (address_mode_t)opcode_modes[opcode];
      length = instruction_length(mode);
      if (!fetch_instruction(a, pc, bytes, offsets, length)) {
         a->truncated_pc[pc] = 1;
         continue;
      }

      if (!a->visited[pc]) {
         a->visited[pc] = 1;
         ++a->instruction_count;
      }
      mark_instruction_bytes(a, pc, opcode, mode, bytes, offsets, length);
      next = (uint16_t)(pc + length);

      if (mode_has_absolute_operand(mode))
         address = (uint16_t)(bytes[1] | ((uint16_t)bytes[2] << 8));
      mark_direct_and_indirect_data_access(a, pc, input, opcode, mode, bytes);
      transfer_state(a, input, &output, opcode, mode, bytes);

      flow = instruction_flow(opcode);
      switch (flow) {
      case FLOW_NEXT:
         enqueue_state(a, next, &output);
         break;

      case FLOW_BRANCH:
         enqueue_state(a, next, &output);
         enqueue_state(a, (uint16_t)(next + (int8_t)bytes[1]), &output);
         break;

      case FLOW_JSR: {
         abstract_state_t called = output;
         abstract_state_t returned = output;
         uint16_t return_address = (uint16_t)(next - 1u);

         /*
          * JSR pushes the high byte and then the low byte of PC-1.  The stack
          * model stores bytes in pull order, so the low byte becomes entry 0.
          * The separate fallthrough edge remains as a conservative summary,
          * while the explicit stack bytes let an reached RTS return precisely.
          */
         state_stack_push(&called, 1, (uint8_t)(return_address >> 8));
         state_stack_push(&called, 1, (uint8_t)return_address);
         enqueue_state(a, address, &called);
         apply_subroutine_clobbers(a, &returned, address);
         enqueue_state(a, next, &returned);
         break;
      }

      case FLOW_JMP_ABSOLUTE:
         enqueue_state(a, address, &output);
         break;

      case FLOW_JMP_INDIRECT: {
         uint16_t target;
         if (resolve_indirect_jump(a, pc, input, address, &target))
            enqueue_state(a, target, &output);
         break;
      }

      case FLOW_RTS: {
         abstract_state_t returned = output;
         uint8_t low;
         uint8_t high;
         int low_known;
         int high_known;
         int have_low;
         int have_high;

         have_low = state_stack_pop(&returned, &low_known, &low);
         have_high = state_stack_pop(&returned, &high_known, &high);
         if (have_low && have_high && low_known && high_known) {
            uint16_t target = (uint16_t)(
               (uint16_t)(low | ((uint16_t)high << 8)) + 1u);
            a->resolved_stack_rts_pc[pc] = 1;
            a->unresolved_rts_pc[pc] = 0;
            enqueue_state(a, target, &returned);
         }
         else if (resolve_indexed_table_rts(a, pc, &returned)) {
            a->resolved_stack_rts_pc[pc] = 1;
            a->unresolved_rts_pc[pc] = 0;
         }
         else {
            a->unresolved_rts_pc[pc] = 1;
         }
         break;
      }

      case FLOW_BRK: {
         abstract_state_t unknown;
         memset(&unknown, 0, sizeof(unknown));
         enqueue_state(a, (uint16_t)(pc + 2u), &unknown);
         break;
      }

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

static size_t count_flags(const uint8_t flags[ADDRESS_SPACE_SIZE])
{
   size_t pc;
   size_t count = 0;
   for (pc = 0; pc < ADDRESS_SPACE_SIZE; ++pc) {
      if (flags[pc])
         ++count;
   }
   return count;
}

static void reset_bank_analysis(analysis_t *a, size_t bank_index)
{
   a->bank_index = bank_index;
   a->bank_file_offset = bank_index * a->bank_size;
   memset(a->byte_info, 0, a->bank_size * sizeof(*a->byte_info));
   memset(a->visited, 0, sizeof(a->visited));
   memset(a->state_seen, 0, sizeof(a->state_seen));
   memset(a->queued, 0, sizeof(a->queued));
   memset(a->unresolved_indirect_pc, 0, sizeof(a->unresolved_indirect_pc));
   memset(a->resolved_ram_indirect_pc, 0,
          sizeof(a->resolved_ram_indirect_pc));
   memset(a->unresolved_rts_pc, 0, sizeof(a->unresolved_rts_pc));
   memset(a->resolved_stack_rts_pc, 0, sizeof(a->resolved_stack_rts_pc));
   memset(a->resolved_table_rts_pc, 0, sizeof(a->resolved_table_rts_pc));
   memset(a->resolved_table_rts_target, 0,
          sizeof(a->resolved_table_rts_target));
   memset(a->unresolved_dynamic_pc, 0, sizeof(a->unresolved_dynamic_pc));
   memset(a->resolved_dynamic_pc, 0, sizeof(a->resolved_dynamic_pc));
   memset(a->truncated_pc, 0, sizeof(a->truncated_pc));
   memset(a->summary_valid, 0, sizeof(a->summary_valid));
   a->work_count = 0;
   a->instruction_count = 0;
}

static int allocate_analysis_tables(analysis_t *a)
{
   a->byte_info = (byte_info_t *)calloc(a->bank_size,
                                        sizeof(*a->byte_info));
   a->states = (abstract_state_t *)calloc(ADDRESS_SPACE_SIZE,
                                          sizeof(*a->states));
   a->subroutine_summaries = (uint8_t *)calloc(
      ADDRESS_SPACE_SIZE, ZERO_PAGE_KNOWN_BYTES);

   if (a->byte_info == NULL || a->states == NULL ||
       a->subroutine_summaries == NULL) {
      fprintf(stderr, "stego: could not allocate analysis tables: %s\n",
              strerror(errno));
      free(a->subroutine_summaries);
      free(a->states);
      free(a->byte_info);
      a->subroutine_summaries = NULL;
      a->states = NULL;
      a->byte_info = NULL;
      return 0;
   }
   return 1;
}

static void free_analysis_tables(analysis_t *a)
{
   free(a->subroutine_summaries);
   free(a->states);
   free(a->byte_info);
}

static int analyze(uint8_t *cart, size_t size)
{
   analysis_t a;
   size_t bank_index;
   size_t total_safe = 0;
   size_t total_instructions = 0;
   size_t total_unresolved = 0;
   size_t total_resolved_ram = 0;
   size_t total_unresolved_rts = 0;
   size_t total_resolved_stack_rts = 0;
   size_t total_resolved_table_rts_sites = 0;
   size_t total_resolved_table_rts_targets = 0;
   size_t total_unresolved_dynamic = 0;
   size_t total_resolved_dynamic = 0;
   size_t total_truncated = 0;

   memset(&a, 0, sizeof(a));
   a.cart = cart;
   a.file_size = size;
   if (!choose_bank_layout(&a)) {
      fprintf(stderr, "stego: file is too small to contain a 2K or 4K ROM\n");
      return 0;
   }

   if (!allocate_analysis_tables(&a))
      return 0;

   printf("size=%zu\n", a.file_size);
   printf("complete_banks=%zu\n", a.bank_count);
   printf("bank_size=%zu\n", a.bank_size);
   printf("trailing_bytes=%zu\n", a.trailing_bytes);
   if (a.trailing_bytes == DPC_TRAILING_SIZE)
      printf("ignored_tail=dpc-2048+255\n");
   else if (a.trailing_bytes != 0)
      printf("ignored_tail=partial-bank\n");

   for (bank_index = 0; bank_index < a.bank_count; ++bank_index) {
      abstract_state_t initial_state;
      uint16_t nmi = 0;
      uint16_t reset = 0;
      uint16_t irq = 0;
      int nmi_valid;
      int reset_valid;
      int irq_valid;
      size_t safe_count;
      size_t unresolved;
      size_t resolved_ram;
      size_t unresolved_rts;
      size_t resolved_stack_rts;
      size_t resolved_table_rts_sites;
      size_t resolved_table_rts_targets;
      size_t unresolved_dynamic;
      size_t resolved_dynamic;
      size_t truncated;

      memset(&initial_state, 0, sizeof(initial_state));
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
         enqueue_state(&a, nmi, &initial_state);
      if (reset_valid)
         enqueue_state(&a, reset, &initial_state);
      if (irq_valid)
         enqueue_state(&a, irq, &initial_state);
      trace(&a);

      safe_count = print_candidates(&a);
      unresolved = count_flags(a.unresolved_indirect_pc);
      resolved_ram = count_flags(a.resolved_ram_indirect_pc);
      unresolved_rts = count_flags(a.unresolved_rts_pc);
      resolved_stack_rts = count_flags(a.resolved_stack_rts_pc);
      resolved_table_rts_sites = count_flags(a.resolved_table_rts_pc);
      resolved_table_rts_targets = count_flags(a.resolved_table_rts_target);
      unresolved_dynamic = count_flags(a.unresolved_dynamic_pc);
      resolved_dynamic = count_flags(a.resolved_dynamic_pc);
      truncated = count_flags(a.truncated_pc);

      printf("bank=%zu reachable_instruction_starts=%zu\n",
             a.bank_index, a.instruction_count);
      printf("bank=%zu safe_bytes=%zu\n", a.bank_index, safe_count);
      printf("bank=%zu resolved_ram_indirect_jumps=%zu\n",
             a.bank_index, resolved_ram);
      printf("bank=%zu unresolved_indirect_jumps=%zu\n",
             a.bank_index, unresolved);
      printf("bank=%zu resolved_stack_rts_targets=%zu\n",
             a.bank_index, resolved_stack_rts);
      printf("bank=%zu resolved_indexed_table_rts_sites=%zu\n",
             a.bank_index, resolved_table_rts_sites);
      printf("bank=%zu resolved_indexed_table_rts_targets=%zu\n",
             a.bank_index, resolved_table_rts_targets);
      printf("bank=%zu unresolved_rts_targets=%zu\n",
             a.bank_index, unresolved_rts);
      printf("bank=%zu resolved_indirect_data_accesses=%zu\n",
             a.bank_index, resolved_dynamic);
      printf("bank=%zu unresolved_indirect_data_accesses=%zu\n",
             a.bank_index, unresolved_dynamic);
      printf("bank=%zu truncated_instructions=%zu\n",
             a.bank_index, truncated);

      total_safe += safe_count;
      total_instructions += a.instruction_count;
      total_unresolved += unresolved;
      total_resolved_ram += resolved_ram;
      total_unresolved_rts += unresolved_rts;
      total_resolved_stack_rts += resolved_stack_rts;
      total_resolved_table_rts_sites += resolved_table_rts_sites;
      total_resolved_table_rts_targets += resolved_table_rts_targets;
      total_unresolved_dynamic += unresolved_dynamic;
      total_resolved_dynamic += resolved_dynamic;
      total_truncated += truncated;
   }

   printf("total_reachable_instruction_starts=%zu\n", total_instructions);
   printf("total_safe_bytes=%zu\n", total_safe);
   printf("total_resolved_ram_indirect_jumps=%zu\n", total_resolved_ram);
   printf("total_unresolved_indirect_jumps=%zu\n", total_unresolved);
   printf("total_resolved_stack_rts_targets=%zu\n",
          total_resolved_stack_rts);
   printf("total_resolved_indexed_table_rts_sites=%zu\n",
          total_resolved_table_rts_sites);
   printf("total_resolved_indexed_table_rts_targets=%zu\n",
          total_resolved_table_rts_targets);
   printf("total_unresolved_rts_targets=%zu\n", total_unresolved_rts);
   printf("total_resolved_indirect_data_accesses=%zu\n",
          total_resolved_dynamic);
   printf("total_unresolved_indirect_data_accesses=%zu\n",
          total_unresolved_dynamic);
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
              "stego: warning: %zu JMP-indirect target(s) remained unknown "
              "after ROM and zero-page constant analysis\n",
              total_unresolved);
   }
   if (total_unresolved_rts != 0) {
      fprintf(stderr,
              "stego: warning: %zu RTS target(s) could not be resolved from "
              "constant stack bytes or a correlated indexed ROM table\n",
              total_unresolved_rts);
   }
   if (total_unresolved_dynamic != 0) {
      fprintf(stderr,
              "stego: warning: %zu indirect data access(es) retained an "
              "unknown pointer; listed candidates may require manual review\n",
              total_unresolved_dynamic);
   }

   free_analysis_tables(&a);
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
