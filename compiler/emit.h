//! @file compiler/emit.h
//! @brief Declares assembly emission buffers for the VCSC compiler.
//! @ingroup compiler

#ifndef _INCLUDE_EMIT_H_
#define _INCLUDE_EMIT_H_

#include <stdbool.h>

#include <stdio.h>

#define EMIT_INLINE_ASM_BEGIN_MARKER "; vcsc-cc1:inline-asm-begin"
#define EMIT_INLINE_ASM_END_MARKER   "; vcsc-cc1:inline-asm-end"

//! One chunk in an emission sink; allocated by emit() and linked in output order.
struct EmitPiece;
typedef struct EmitPiece {
   const char *txt;
   struct EmitPiece *next;
} EmitPiece;

//! Append-only stream of emitted assembly text.
typedef struct EmitSink {
   EmitPiece *head;
   EmitPiece *tail;
} EmitSink;

//! Static initializer for an empty EmitSink.
#define EMIT_INIT { NULL, NULL }

// add text to an EmitSink
void emit(EmitSink *es, const char *fmt, ...);

// run peephole optimization over compiler-emitted assembly in an EmitSink
void emit_peephole_optimize(EmitSink *es, bool enabled);

// print the text stored in an EmitSink
void emit_print(EmitSink *es, FILE *out);

#endif
