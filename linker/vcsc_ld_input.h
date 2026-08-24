//! @file linker/vcsc_ld_input.h
//! @brief Declares linker input loading for the VCSC linker.
//! @ingroup linker

#ifndef VCSC_LD_INPUT_H
#define VCSC_LD_INPUT_H

#include "vcsc_ld_internal.h"

void load_archive(const char *path, archive_file_t *archive);
void load_object(const char *path, object_file_t *obj);
void select_needed_objects(input_set_t *in);
int selected_objects_have_export(const input_set_t *in, const char *name);
void reselect_needed_objects_with_preferred_provider(input_set_t *in, const char *symbol);
void warn_unused_cmdline_objects(const input_set_t *in);
void free_object(object_file_t *obj);

#endif
