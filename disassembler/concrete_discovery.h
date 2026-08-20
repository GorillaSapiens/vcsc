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
   unsigned instructions;
   unsigned rom_instruction_starts;
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
 * only for input families observed by an already executed path. rom_exec_start
 * and rom_exec_pc are caller-owned arrays of rom_size entries.  The pass is
 * positive discovery evidence only: unsupported concrete mapper models return
 * 0 and leave normal static analysis authoritative. */
int vcsc_concrete_discover(const uint8_t *rom, size_t rom_size,
                           int mapper, size_t bank_count,
                           size_t reset_bank, int superchip,
                           uint8_t *rom_exec_start,
                           uint16_t *rom_exec_pc,
                           vcsc_concrete_result_t *result);

#ifdef __cplusplus
}
#endif

#endif
