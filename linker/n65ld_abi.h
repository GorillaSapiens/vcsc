//! @file linker/n65ld_abi.h
//! @brief Declares link-time ABI metadata validation for the n65 linker.
//! @ingroup linker

#ifndef N65LD_ABI_H
#define N65LD_ABI_H

#include "n65ld_internal.h"

int abi_metadata_has_prefix(const char *name);
void validate_abi_metadata(const input_set_t *in);

#endif
