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

/* Shared mapper IDs for the C/C++ dynamic-probe boundary.  Keep the private
 * disassembler enum pinned to these values so adding a mapper cannot silently
 * reinterpret an existing mapper inside the probe. */
enum {
   VCSC_VIDEO_MAP_RAW = 0,
   VCSC_VIDEO_MAP_1K,
   VCSC_VIDEO_MAP_2K,
   VCSC_VIDEO_MAP_4K,
   VCSC_VIDEO_MAP_F8,
   VCSC_VIDEO_MAP_F6,
   VCSC_VIDEO_MAP_F4,
   VCSC_VIDEO_MAP_FA,
   VCSC_VIDEO_MAP_DPC,
   VCSC_VIDEO_MAP_WD,
   VCSC_VIDEO_MAP_WDSW,
   VCSC_VIDEO_MAP_FC,
   VCSC_VIDEO_MAP_E0,
   VCSC_VIDEO_MAP_E7,
   VCSC_VIDEO_MAP_3F,
   VCSC_VIDEO_MAP_3E,
   VCSC_VIDEO_MAP_CV,
   VCSC_VIDEO_MAP_JANE,
   VCSC_VIDEO_MAP_0840,
   VCSC_VIDEO_MAP_UA,
   VCSC_VIDEO_MAP_UASW,
   VCSC_VIDEO_MAP_0FA0,
   VCSC_VIDEO_MAP_FE
};

int vcsc_dynamic_video_probe(const uint8_t *rom, size_t rom_size,
                             int mapper, size_t bank_count,
                             size_t reset_bank, int superchip,
                             vcsc_video_probe_result_t *result);

#ifdef __cplusplus
}
#endif

#endif
