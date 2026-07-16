//! @file compiler/xray.h
//! @brief Declares diagnostic tracing for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_XRAY_H_
#define _INCLUDE_XRAY_H_

#include "noreturn.h"

#define XRAY_INVERT      0 // invert return value
#define XRAY_DEBUG       1 // enable debug messages
#define XRAY_COVERAGE    2 // perform coverage test
#define XRAY_PARSEONLY   3 // parse only, do not compile
#define XRAY_DUMPAST     4 // dump AST tree after parsing
#define XRAY_TYPEINFO    5 // dump type size information
#define XRAY_EXPROPT     6 // dump expropt statistics
#define XRAY_EXPROPTONLY 7 // exit after expropt
#define XRAY_PEEPHOLE    8 // dump peephole optimizer statistics

// return the xray number for a human readable string
int lookup_xray(const char *);

// set an xray by number
void set_xray(int n);

// determine if an xray is set
int get_xray(int n);

// override the system exit()
void noreturn xray_exit(int, const char *, int);

#ifndef NO_XRAY_OVERRIDE_EXIT
#define exit(x) xray_exit(x, __FILE__, __LINE__)
#endif

#endif
