; sub.asm - Arbitrary-length and fixed-width subtraction routines (unsigned/signed)
;
; Little-endian helpers use the *le suffix.
; Big-endian helpers use the *be suffix.
;
; Inputs:
;   ptr0 - minuend
;   ptr1 - subtrahend
;   ptr2 - destination
;   arg0 - byte count for *N helpers
; Clobbers: A, X, Y, status flags

.include "nlib.inc"

.proc _subNle
    ldx arg0
    ldy #0
    sec
@loop:
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    iny
    dex
    bne @loop
    rts
.endproc

.proc _subNbe
    ldy arg0
    dey
    sec
@loop:
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    dey
    bpl @loop
    rts
.endproc

.proc _sub8le
    ldy #0
    sec
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    rts
.endproc

.proc _sub8be
    jmp _sub8le
.endproc

.proc _sub16le
    ldy #0
    sec
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    iny
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    rts
.endproc

.proc _sub16be
    ldy #1
    sec
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    dey
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    rts
.endproc

.proc _sub24le
    ldy #0
    sec
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    iny
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    iny
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    rts
.endproc

.proc _sub24be
    ldy #2
    sec
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    dey
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    dey
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    rts
.endproc

.proc _sub32le
    ldy #0
    sec
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    iny
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    iny
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    iny
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    rts
.endproc

.proc _sub32be
    ldy #3
    sec
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    dey
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    dey
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    dey
    lda (ptr0), y
    sbc (ptr1), y
    sta (ptr2), y
    rts
.endproc
