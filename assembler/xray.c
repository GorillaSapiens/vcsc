//! @file assembler/xray.c
//! @brief Implements diagnostic tracing for the n65 assembler.
//! @ingroup assembler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "xray.h"

typedef struct asm_xray_desc {
   int number;
   const char *name;
   const char *description;
} asm_xray_desc_t;

static unsigned int g_xray_bits = 0;

static const asm_xray_desc_t g_xray_descs[] = {
   { ASM_XRAY_PASSES, "passes", "trace assembler layout and relaxation passes" },
   { -1, NULL, NULL }
};

//! @brief Handle assembler lookup xray logic for xray.
int assembler_lookup_xray(const char *name)
{
   int i;

   if (!strcmp(name, "list")) {
      fprintf(stderr, "assembler xrays:\n");
      for (i = 0; g_xray_descs[i].name; ++i)
         fprintf(stderr, "   %-12s %s\n", g_xray_descs[i].name, g_xray_descs[i].description);
      exit(0);
   }

   for (i = 0; g_xray_descs[i].name; ++i) {
      if (!strcmp(name, g_xray_descs[i].name))
         return g_xray_descs[i].number;
   }

   fprintf(stderr, "unknown assembler xray '%s'\n", name);
   exit(1);
}

//! @brief Handle assembler set xray logic for xray.
void assembler_set_xray(int n)
{
   if (n < 0 || n >= (int)(8 * sizeof(g_xray_bits))) {
      fprintf(stderr, "assembler xray %d out of bounds\n", n);
      exit(1);
   }

   g_xray_bits |= 1U << n;
}

//! @brief Handle assembler get xray logic for xray.
int assembler_get_xray(int n)
{
   if (n < 0 || n >= (int)(8 * sizeof(g_xray_bits))) {
      fprintf(stderr, "assembler xray %d out of bounds\n", n);
      exit(1);
   }

   return (g_xray_bits & (1U << n)) ? 1 : 0;
}
