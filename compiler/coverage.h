//! @file compiler/coverage.h
//! @brief Declares grammar coverage instrumentation for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COVERAGE_H_
#define _INCLUDE_COVERAGE_H_

//! Mark a specific parser source line as covered.
#define COVER_LINE(x) cover(x);
//! Mark the current parser source line as covered.
#define COVER COVER_LINE(__LINE__)

// register that a rule has been covered
void cover(int n);

// print a report.
// prints nothing if 100% coverage
// calls exit if not 100% coverage
void coverage_report(void);

#endif
