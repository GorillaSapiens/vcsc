//! @file assembler/util.c
//! @brief Implements shared assembler utilities for the n65 assembler.
//! @ingroup assembler

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "util.h"

//! @brief Duplicate a string for tool-owned storage, terminating with a diagnostic on failure.
char *xstrdup(const char *s)
{
   size_t n;
   char *p;

   if (!s)
      return NULL;

   n = strlen(s) + 1;
   p = (char *)malloc(n);
   if (!p) {
      fprintf(stderr, "out of memory\n");
      exit(1);
   }

   memcpy(p, s, n);
   return p;
}
