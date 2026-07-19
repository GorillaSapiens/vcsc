//! @file assembler/source_loader.h
//! @brief Declares assembler source loading for the VCSC assembler.
//! @ingroup assembler

#ifndef SOURCE_LOADER_H
#define SOURCE_LOADER_H

#include <stdio.h>

void source_loader_add_include_dir(const char *dir);
void source_loader_clear_include_dirs(void);
FILE *source_loader_open_expanded(const char *root_path);
FILE *source_loader_open_expanded_with_defines(const char *root_path, const char *const *defines, int define_count);

#endif
