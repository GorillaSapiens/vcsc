//! @file compiler/md5seen.h
//! @brief Declares MD5 duplicate tracking for the n65 compiler.
//! @ingroup compiler

#ifndef _INCLUDE_MD5SEEN_H_
#define _INCLUDE_MD5SEEN_H_

#include <stdio.h>
#include <stdbool.h>

// returns true if the file has been seen before
// returns fals otherwise
// "seen" is based on md5sum
bool md5seen(const char *filename, FILE *f);

#endif
