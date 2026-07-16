//! @file assembler/xray.h
//! @brief Declares diagnostic tracing for the n65 assembler.
//! @ingroup assembler

#ifndef ASM_XRAY_H
#define ASM_XRAY_H

#define ASM_XRAY_PASSES 0

int assembler_lookup_xray(const char *name);
void assembler_set_xray(int n);
int assembler_get_xray(int n);

#endif
