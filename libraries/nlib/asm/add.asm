; add.asm - Arbitrary-length and fixed-width addition routines (unsigned/signed)
;
; Little-endian helpers use the *le suffix.
; Big-endian helpers use the *be suffix.
;
; Inputs:
;   ptr0 - pointer to operand A
;   ptr1 - pointer to operand B
;   ptr2 - pointer to destination buffer
;   arg0 - number of bytes for *N helpers
; Clobbers: A, X, Y, status flags

.include "nlib.inc"

.proc _addNle
    ldx arg0
    ldy #0
    clc
@loop:
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    iny
    dex
    bne @loop
    rts
.endproc

.proc _addNbe
    ldy arg0
    dey
    clc
@loop:
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    dey
    bpl @loop
    rts
.endproc

.proc _add8le
    ldy #0
    clc
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    rts
.endproc

.proc _add8be
    jmp _add8le
.endproc

.proc _add16le
    ldy #0
    clc
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    iny
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    rts
.endproc

.proc _add16be
    ldy #1
    clc
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    dey
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    rts
.endproc

.proc _add24le
    ldy #0
    clc
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    iny
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    iny
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    rts
.endproc

.proc _add24be
    ldy #2
    clc
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    dey
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    dey
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    rts
.endproc

.proc _add32le
    ldy #0
    clc
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    iny
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    iny
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    iny
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    rts
.endproc

.proc _add32be
    ldy #3
    clc
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    dey
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    dey
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    dey
    lda (ptr0), y
    adc (ptr1), y
    sta (ptr2), y
    rts
.endproc
