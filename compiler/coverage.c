//! @file compiler/coverage.c
//! @brief Implements grammar coverage instrumentation for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>

#include "xray.h"

static unsigned char coverage_map[] = {
#include "coverage_map.h"
};

static unsigned char visited[sizeof(coverage_map)] = { 0 };

//! @brief Handle coverage report logic for coverage.
void coverage_report(void) {
   int missing = 0;
   bool begin = false;
   for (size_t i = 0; i < sizeof(coverage_map); i++) {
      if (visited[i] != coverage_map[i]) {
         for (int j = 0; j < 8; j++) {
            unsigned char k = 1 << j;
            if ((coverage_map[i] & k) != (visited[i] & k)) {
               int line = i * 8 + j;
               if (!begin) {
                  printf("COVERAGE MISSING");
                  begin = true;
               }
               printf(" %d", line);
               missing++;
            }
         }
      }
   }
   if (missing) {
      printf("\nCOVERAGE MISSING COUNT %d\n", missing);
      exit(-1);
   }
}

//! @brief Handle cover logic for coverage.
void cover(int n) {
   visited[n / 8] |= 1 << (n % 8);
}
