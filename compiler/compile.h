//! @file compiler/compile.h
//! @brief Declares compiler front-end orchestration for the VCSC compiler.
//! @ingroup compiler

#ifndef _INCLUDE_COMPILE_H_
#define _INCLUDE_COMPILE_H_

#include <stdio.h>
#include <stdbool.h>

// enable or disable the compiler assembly peephole pass
void set_peephole_enabled(bool enabled);

// enable/disable internal C26 source provenance markers for object/listing builds
void set_listing_provenance_enabled(bool enabled);
bool listing_provenance_enabled(void);

// perform compilation step
void do_compile(FILE *out);

#endif
