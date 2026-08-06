; This file is covered under CC0-1.0. See libraries/LICENSE.txt.

; mul.asm - Fixed-width little-endian multiplication
;
; Each selected helper computes the low 8/16/24/32 bits of the product.
; ptr0 and ptr1 point at dead compiler-expression operands and are shifted
; destructively; ptr2 points at the exact-width result.  No temporary RIOT RAM
; beyond the compiler-owned expression scratch is required.

.include "vcsc-runtime.inc"

.proc _mul8
    ; ptr0 = lhs scratch, ptr1 = rhs scratch, ptr2 = result scratch.
    ; Operands are dead after the call and are shifted in place.
    lda #0
    ldy #0
    sta (ptr2), y
    ldx #8
@bit_loop:
    ldy #0
    lda (ptr1), y
    and #1
    beq @no_add
    clc
    ldy #0
    lda (ptr2), y
    adc (ptr0), y
    sta (ptr2), y
@no_add:
    clc
    ldy #0
    lda (ptr0), y
    rol a
    sta (ptr0), y
    clc
    ldy #0
    lda (ptr1), y
    ror a
    sta (ptr1), y
    dex
    beq @done
    jmp @bit_loop
@done:
    rts
.endproc

.proc _mul16
    ; ptr0 = lhs scratch, ptr1 = rhs scratch, ptr2 = result scratch.
    ; Operands are dead after the call and are shifted in place.
    lda #0
    ldy #0
    sta (ptr2), y
    ldy #1
    sta (ptr2), y
    ldx #16
@bit_loop:
    ldy #0
    lda (ptr1), y
    and #1
    beq @no_add
    clc
    ldy #0
    lda (ptr2), y
    adc (ptr0), y
    sta (ptr2), y
    ldy #1
    lda (ptr2), y
    adc (ptr0), y
    sta (ptr2), y
@no_add:
    clc
    ldy #0
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #1
    lda (ptr0), y
    rol a
    sta (ptr0), y
    clc
    ldy #1
    lda (ptr1), y
    ror a
    sta (ptr1), y
    ldy #0
    lda (ptr1), y
    ror a
    sta (ptr1), y
    dex
    beq @done
    jmp @bit_loop
@done:
    rts
.endproc

.proc _mul24
    ; ptr0 = lhs scratch, ptr1 = rhs scratch, ptr2 = result scratch.
    ; Operands are dead after the call and are shifted in place.
    lda #0
    ldy #0
    sta (ptr2), y
    ldy #1
    sta (ptr2), y
    ldy #2
    sta (ptr2), y
    ldx #24
@bit_loop:
    ldy #0
    lda (ptr1), y
    and #1
    beq @no_add
    clc
    ldy #0
    lda (ptr2), y
    adc (ptr0), y
    sta (ptr2), y
    ldy #1
    lda (ptr2), y
    adc (ptr0), y
    sta (ptr2), y
    ldy #2
    lda (ptr2), y
    adc (ptr0), y
    sta (ptr2), y
@no_add:
    clc
    ldy #0
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #1
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #2
    lda (ptr0), y
    rol a
    sta (ptr0), y
    clc
    ldy #2
    lda (ptr1), y
    ror a
    sta (ptr1), y
    ldy #1
    lda (ptr1), y
    ror a
    sta (ptr1), y
    ldy #0
    lda (ptr1), y
    ror a
    sta (ptr1), y
    dex
    beq @done
    jmp @bit_loop
@done:
    rts
.endproc

.proc _mul32
    ; ptr0 = lhs scratch, ptr1 = rhs scratch, ptr2 = result scratch.
    ; Operands are dead after the call and are shifted in place.
    lda #0
    ldy #0
    sta (ptr2), y
    ldy #1
    sta (ptr2), y
    ldy #2
    sta (ptr2), y
    ldy #3
    sta (ptr2), y
    ldx #32
@bit_loop:
    ldy #0
    lda (ptr1), y
    and #1
    beq @no_add
    clc
    ldy #0
    lda (ptr2), y
    adc (ptr0), y
    sta (ptr2), y
    ldy #1
    lda (ptr2), y
    adc (ptr0), y
    sta (ptr2), y
    ldy #2
    lda (ptr2), y
    adc (ptr0), y
    sta (ptr2), y
    ldy #3
    lda (ptr2), y
    adc (ptr0), y
    sta (ptr2), y
@no_add:
    clc
    ldy #0
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #1
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #2
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #3
    lda (ptr0), y
    rol a
    sta (ptr0), y
    clc
    ldy #3
    lda (ptr1), y
    ror a
    sta (ptr1), y
    ldy #2
    lda (ptr1), y
    ror a
    sta (ptr1), y
    ldy #1
    lda (ptr1), y
    ror a
    sta (ptr1), y
    ldy #0
    lda (ptr1), y
    ror a
    sta (ptr1), y
    dex
    beq @done
    jmp @bit_loop
@done:
    rts
.endproc
