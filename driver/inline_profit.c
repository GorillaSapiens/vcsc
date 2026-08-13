//! @file driver/inline_profit.c
//! @brief Parses final linker metrics and makes measured inline decisions.
//! @ingroup driver

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "inline_profit.h"

static void set_error(char *error, size_t error_size, const char *text) {
   if (!error || !error_size) return;
   snprintf(error, error_size, "%s", text ? text : "unknown error");
}

bool inline_link_metrics_read_map(const char *path, inline_link_metrics_t *out,
                                  char *error, size_t error_size) {
   FILE *fp;
   char line[1024];
   bool in_usage = false;
   bool saw_usage = false;
   bool saw_metric = false;

   if (!path || !out) {
      set_error(error, error_size, "invalid map metric request");
      return false;
   }
   memset(out, 0, sizeof(*out));
   fp = fopen(path, "r");
   if (!fp) {
      char buf[256];
      snprintf(buf, sizeof(buf), "cannot read map: %s", strerror(errno));
      set_error(error, error_size, buf);
      return false;
   }

   while (fgets(line, sizeof(line), fp)) {
      if (!in_usage) {
         if (!strcmp(line, "MEMORY USAGE\n") || !strcmp(line, "MEMORY USAGE\r\n")) {
            in_usage = true;
            saw_usage = true;
         }
         continue;
      }
      if (line[0] == '\n' || line[0] == '\r' || line[0] == '\0') break;
      {
         char *used = strstr(line, "used=");
         char *objects = strstr(line, "objects=");
         char *stack = strstr(line, "hardware-stack=");
         char *end = NULL;
         uint64_t value;
         if (!used) continue;
         value = strtoull(used + 5, &end, 10);
         if (end == used + 5) continue;
         if (objects && stack) {
            uint64_t obj = strtoull(objects + 8, &end, 10);
            if (end == objects + 8) continue;
            out->ram_object_bytes += obj;
            out->hardware_stack_bytes += strtoull(stack + 15, &end, 10);
            if (end == stack + 15) continue;
         }
         else {
            out->rom_bytes += value;
         }
         saw_metric = true;
      }
   }
   fclose(fp);
   if (!saw_usage || !saw_metric) {
      set_error(error, error_size, "map has no MEMORY USAGE metrics");
      return false;
   }
   return true;
}

inline_profit_decision_t inline_profit_decide(const inline_link_metrics_t *before,
                                              const inline_link_metrics_t *after) {
   if (!before || !after) return INLINE_PROFIT_REJECT;
   /* An inline transform should preserve equivalent activation overlay.  Treat
      a measured loss as a lifetime/allocation regression, not as RAM-for-ROM
      currency that the profitability heuristic is allowed to spend. */
   if (after->ram_object_bytes > before->ram_object_bytes)
      return INLINE_PROFIT_REJECT_RAM_REGRESSION;
   if (after->rom_bytes < before->rom_bytes)
      return INLINE_PROFIT_ACCEPT_ROM;
   if (after->rom_bytes > before->rom_bytes)
      return INLINE_PROFIT_REJECT;
   if (after->hardware_stack_bytes < before->hardware_stack_bytes)
      return INLINE_PROFIT_ACCEPT_STACK;
   return INLINE_PROFIT_REJECT;
}
