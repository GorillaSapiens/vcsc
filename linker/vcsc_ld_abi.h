//! @file linker/vcsc_ld_abi.h
//! @brief Declares link-time ABI metadata validation for the VCSC linker.
//! @ingroup linker

#ifndef VCSC_LD_ABI_H
#define VCSC_LD_ABI_H

#include "vcsc_ld_internal.h"

int abi_metadata_has_prefix(const char *name);
void validate_abi_metadata(const input_set_t *in);
void validate_absolute_binding_memory_regions(const linker_config_t *cfg,
                                              const input_set_t *in);

#endif
