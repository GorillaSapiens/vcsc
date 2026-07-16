//! @file compiler/xray.c
//! @brief Implements diagnostic tracing for the n65 compiler.
//! @ingroup compiler

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "messages.h"
#define NO_XRAY_OVERRIDE_EXIT
#include "xray.h"

#define MAX_XRAY 512 // suitably large

static unsigned int xrays[MAX_XRAY / (8 * sizeof(unsigned int))] = { 0 };

static struct {
   int number;         // MUST BE IN RANGE [0..MAX_XRAY]
   const char *name;
   const char *description;
} name2number[] = {
   { XRAY_INVERT,      "invert",      "invert success/failure exit value" },
   { XRAY_DEBUG,       "debug",       "print debug() messages" },
   { XRAY_COVERAGE,    "coverage",    "yacc/bison rule coverage testing" },
   { XRAY_PARSEONLY,   "parseonly",   "exit after parsing" },
   { XRAY_DUMPAST,     "dumpast",     "dump AST tree after parsing" },
   { XRAY_TYPEINFO,    "typeinfo",    "type information" },
   { XRAY_EXPROPT,     "dumpexpr",    "dump expropt stats" },
   { XRAY_EXPROPTONLY, "exproptonly", "exit after expropt" },
   { XRAY_PEEPHOLE,    "peephole",    "dump peephole optimizer stats" },
};

//! @brief Handle xray exit logic for xray.
void xray_exit(int n, const char *file, int line) {
   if (get_xray(0)) {
      n = ~n;
      debug("xray:inverting exit value at %s:%d", file, line);
   }
   exit(n);
}

//! @brief Find xray in xray tables without transferring ownership.
int lookup_xray(const char *name) {
   if (!strcmp(name, "list")) {
      // special code to list defined xrays
      printf("%19s   %s\n", "name", "description");
      for (size_t i = 0; i < sizeof(name2number) / sizeof(name2number[0]); i++) {
         printf("(%3d)%14s   %s\n",
            name2number[i].number,
            name2number[i].name,
            name2number[i].description);
      }
      xray_exit(0, __FILE__, __LINE__);
   }

   for (size_t i = 0; i < sizeof(name2number) / sizeof(name2number[0]); i++) {
      if (!strcmp(name2number[i].name, name)) {
         return name2number[i].number;
      }
   }
   return -1;
}

//! @brief Handle set xray logic for xray.
void set_xray(int n) {
   if (n < 0 || n >= MAX_XRAY) {
      error_unreachable("xray %d out of bounds", n);
   }
   xrays[n / (8 * sizeof(unsigned int))] |= 1 << (n % (8 * sizeof(unsigned int)));
}

//! @brief Handle get xray logic for xray.
int get_xray(int n) {
   if (n < 0 || n >= MAX_XRAY) {
      error_unreachable("xray %d out of bounds", n);
   }
   if (xrays[n / (8 * sizeof(unsigned int))] & (1 << (n % (8 * sizeof(unsigned int))))) {
      return 1;
   }
   return 0;
}
