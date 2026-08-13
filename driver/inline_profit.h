//! @file driver/inline_profit.h
//! @brief Final-link metrics used by measured optimizer inlining.
//! @ingroup driver

#ifndef VCSC_DRIVER_INLINE_PROFIT_H
#define VCSC_DRIVER_INLINE_PROFIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
   uint64_t rom_bytes;
   uint64_t ram_object_bytes;
   uint64_t hardware_stack_bytes;
} inline_link_metrics_t;

typedef enum {
   INLINE_PROFIT_REJECT = 0,
   INLINE_PROFIT_ACCEPT_ROM = 1,
   INLINE_PROFIT_ACCEPT_STACK = 2,
   INLINE_PROFIT_REJECT_RAM_REGRESSION = -1
} inline_profit_decision_t;

bool inline_link_metrics_read_map(const char *path, inline_link_metrics_t *out,
                                  char *error, size_t error_size);
inline_profit_decision_t inline_profit_decide(const inline_link_metrics_t *before,
                                              const inline_link_metrics_t *after);

#endif
