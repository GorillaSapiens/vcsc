//! @file assembler/o26.h
//! @brief Declares o26 object file emission for the VCSC assembler.
//! @ingroup assembler

#ifndef O26_H
#define O26_H

#include <stdio.h>
#include "asm_pass.h"

int o26_write_object_file(FILE *fp, asm_context_t *ctx);

#endif
