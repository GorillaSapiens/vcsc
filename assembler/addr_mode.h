//! @file assembler/addr_mode.h
//! @brief Declares 6502 addressing mode helpers for the n65 assembler.
//! @ingroup assembler

#ifndef ADDR_MODE_H
#define ADDR_MODE_H

//! Parser-level addressing modes before final opcode relaxation.
typedef enum addr_mode {
   AM_NONE = 0,
   AM_IMPLIED,
   AM_ACCUMULATOR,
   AM_IMMEDIATE,
   AM_ZP_OR_ABS,
   AM_ZPX_OR_ABSX,
   AM_ZPY_OR_ABSY,
   AM_INDIRECT,
   AM_INDEXED_INDIRECT,
   AM_INDIRECT_INDEXED,
   AM_RELATIVE
} addr_mode_t;

#endif
