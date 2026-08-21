#ifndef VCSC_CONCRETE_DISCOVERY_H
#define VCSC_CONCRETE_DISCOVERY_H

#include <stddef.h>
#include <stdint.h>

#include "dynamic_video_probe.h"

#ifdef __cplusplus
extern "C" {
#endif

#define VCSC_CONCRETE_RIOT_RAM_SIZE 128u
#define VCSC_CONCRETE_MAX_INSN_BYTES 3u
#define VCSC_CONCRETE_NO_SOURCE UINT32_MAX

typedef struct {
   uint16_t pc;
   uint16_t mapper_config;
   uint16_t bank;
   uint8_t a;
   uint8_t x;
   uint8_t y;
   uint8_t sp;
   uint8_t p;
   uint8_t ram[VCSC_CONCRETE_RIOT_RAM_SIZE];
} vcsc_concrete_seed_t;

typedef struct {
   uint16_t mapper_config;
   uint8_t a;
   uint8_t x;
   uint8_t y;
   uint8_t sp;
   uint8_t p;
   uint8_t valid;
} vcsc_concrete_rom_state_t;

typedef struct {
   unsigned instructions;
   unsigned rom_instruction_starts;
   unsigned rom_data_bytes_read;
   unsigned ram_instruction_starts;
   unsigned ram_bytes_written;
   unsigned scenarios_run;
   unsigned scenarios_with_new_reachability;
   uint32_t input_read_mask;
   int halted;
   int instruction_limit;
   int converged;
   int top_level_return;
   uint16_t final_pc;
   uint8_t final_a;
   uint8_t final_x;
   uint8_t final_y;
   uint8_t final_sp;
   uint8_t final_p;
   uint8_t ram[VCSC_CONCRETE_RIOT_RAM_SIZE];
   uint8_t ram_written[VCSC_CONCRETE_RIOT_RAM_SIZE];
   uint8_t ram_exec_start[VCSC_CONCRETE_RIOT_RAM_SIZE];
   uint16_t ram_exec_pc[VCSC_CONCRETE_RIOT_RAM_SIZE];
   uint8_t ram_exec_len[VCSC_CONCRETE_RIOT_RAM_SIZE];
   uint8_t ram_exec_bytes[VCSC_CONCRETE_RIOT_RAM_SIZE * VCSC_CONCRETE_MAX_INSN_BYTES];
   uint32_t ram_exec_source[VCSC_CONCRETE_RIOT_RAM_SIZE * VCSC_CONCRETE_MAX_INSN_BYTES];
   uint32_t ram_source_offset[VCSC_CONCRETE_RIOT_RAM_SIZE];
} vcsc_concrete_result_t;

/* Execute bounded concrete discovery from RESET.  The first run uses inactive
 * controller/console inputs; additional one-active-low-input scenarios are run
 * only for input families observed by an already executed path. rom_exec_start,
 * rom_exec_pc, rom_data_read, and rom_branch_edges are caller-owned arrays of
 * rom_size entries.  For a conditional branch, rom_branch_edges bit 0 records an
 * observed fall-through and bit 1 an observed taken edge, but only for the same
 * retained physical-PC/mapper context stored in rom_exec_pc/rom_exec_state.  The pass is
 * positive discovery evidence only: unsupported concrete mapper models return
 * 0 and leave normal static analysis authoritative. */
int vcsc_concrete_discover(const uint8_t *rom, size_t rom_size,
                           int mapper, size_t bank_count,
                           size_t reset_bank, int superchip,
                           uint8_t *rom_exec_start,
                           uint16_t *rom_exec_pc,
                           uint8_t *rom_data_read,
                           uint8_t *rom_branch_edges,
                           vcsc_concrete_rom_state_t *rom_exec_state,
                           vcsc_concrete_result_t *result);

/* Continue concrete discovery from one statically proven exact execution state.
 * The aggregate result/ROM-exec arrays must already have been initialized by
 * vcsc_concrete_discover().  This is used by H2 fixed-point iteration: static
 * analysis supplies only fully concrete states, and newly observed execution is
 * unioned as positive evidence. */
int vcsc_concrete_discover_seed(const uint8_t *rom, size_t rom_size,
                                int mapper, size_t bank_count, int superchip,
                                const vcsc_concrete_seed_t *seed,
                                uint8_t *rom_exec_start,
                                uint16_t *rom_exec_pc,
                                uint8_t *rom_data_read,
                                uint8_t *rom_branch_edges,
                                vcsc_concrete_rom_state_t *rom_exec_state,
                                vcsc_concrete_result_t *result);

#ifdef __cplusplus
}
#endif

#endif
