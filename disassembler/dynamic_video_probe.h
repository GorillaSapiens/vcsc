#ifndef VCSC_DYNAMIC_VIDEO_PROBE_H
#define VCSC_DYNAMIC_VIDEO_PROBE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
   unsigned frames;
   unsigned stable_lines;
   unsigned min_lines;
   unsigned max_lines;
   int stable;
   int halted;
   int instruction_limit;
} vcsc_video_probe_result_t;

/* mapper values intentionally match mapper_t in vcsc_disas.c. */
int vcsc_dynamic_video_probe(const uint8_t *rom, size_t rom_size,
                             int mapper, size_t bank_count,
                             size_t reset_bank, int superchip,
                             vcsc_video_probe_result_t *result);

#ifdef __cplusplus
}
#endif

#endif
