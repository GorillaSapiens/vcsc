//! @file assembler/o65.h
//! @brief Declares o65 object file emission for the n65 assembler.
//! @ingroup assembler

#ifndef O65_H
#define O65_H

#include <stdio.h>
#include "asm_pass.h"

int o65_write_object_file(FILE *fp, asm_context_t *ctx);

#endif
