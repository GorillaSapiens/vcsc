; incdec.asm - Increment and decrement
;
; Little-endian helpers use the *le suffix.
; Big-endian helpers use the *be suffix.
;
; Inputs:
;   ptr0 - buffer to modify in place
;   arg0 - byte count for *N helpers
; Clobbers: A, X, Y, status flags

.include "nlib.inc"

.proc _incNle
    ldx arg0
    ldy #0
@loop:
    lda (ptr0), y
    clc
    adc #1
    sta (ptr0), y
    bne @done
    iny
    dex
    bne @loop
@done:
    rts
.endproc

.proc _incNbe
    ldy arg0
    dey
@loop:
    lda (ptr0), y
    clc
    adc #1
    sta (ptr0), y
    bne @done
    dey
    bpl @loop
@done:
    rts
.endproc

.proc _decNle
    ldx arg0
    ldy #0
    sec
    lda (ptr0), y
    sbc #1
    sta (ptr0), y
    iny
    dex
    beq @done
@loop:
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    iny
    dex
    bne @loop
@done:
    rts
.endproc

.proc _decNbe
    ldy arg0
    dey
    sec
    lda (ptr0), y
    sbc #1
    sta (ptr0), y
    beq @borrow
    rts
@borrow:
    cpy #0
    beq @done
@loop:
    dey
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    bcs @done
    cpy #0
    bne @loop
@done:
    rts
.endproc

.proc _inc8le
    ldy #0
    clc
    lda (ptr0), y
    adc #1
    sta (ptr0), y
    rts
.endproc

.proc _inc8be
    jmp _inc8le
.endproc

.proc _inc16le
    ldy #0
    clc
    lda (ptr0), y
    adc #1
    sta (ptr0), y
    iny
    lda (ptr0), y
    adc #0
    sta (ptr0), y
    rts
.endproc

.proc _inc16be
    ldy #1
    clc
    lda (ptr0), y
    adc #1
    sta (ptr0), y
    dey
    lda (ptr0), y
    adc #0
    sta (ptr0), y
    rts
.endproc

.proc _inc24le
    ldy #0
    clc
    lda (ptr0), y
    adc #1
    sta (ptr0), y
    iny
    lda (ptr0), y
    adc #0
    sta (ptr0), y
    iny
    lda (ptr0), y
    adc #0
    sta (ptr0), y
    rts
.endproc

.proc _inc24be
    ldy #2
    clc
    lda (ptr0), y
    adc #1
    sta (ptr0), y
    dey
    lda (ptr0), y
    adc #0
    sta (ptr0), y
    dey
    lda (ptr0), y
    adc #0
    sta (ptr0), y
    rts
.endproc

.proc _inc32le
    ldy #0
    clc
    lda (ptr0), y
    adc #1
    sta (ptr0), y
    iny
    lda (ptr0), y
    adc #0
    sta (ptr0), y
    iny
    lda (ptr0), y
    adc #0
    sta (ptr0), y
    iny
    lda (ptr0), y
    adc #0
    sta (ptr0), y
    rts
.endproc

.proc _inc32be
    ldy #3
    clc
    lda (ptr0), y
    adc #1
    sta (ptr0), y
    dey
    lda (ptr0), y
    adc #0
    sta (ptr0), y
    dey
    lda (ptr0), y
    adc #0
    sta (ptr0), y
    dey
    lda (ptr0), y
    adc #0
    sta (ptr0), y
    rts
.endproc

.proc _dec8le
    ldy #0
    sec
    lda (ptr0), y
    sbc #1
    sta (ptr0), y
    rts
.endproc

.proc _dec8be
    jmp _dec8le
.endproc

.proc _dec16le
    ldy #0
    sec
    lda (ptr0), y
    sbc #1
    sta (ptr0), y
    iny
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    rts
.endproc

.proc _dec16be
    ldy #1
    sec
    lda (ptr0), y
    sbc #1
    sta (ptr0), y
    dey
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    rts
.endproc

.proc _dec24le
    ldy #0
    sec
    lda (ptr0), y
    sbc #1
    sta (ptr0), y
    iny
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    iny
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    rts
.endproc

.proc _dec24be
    ldy #2
    sec
    lda (ptr0), y
    sbc #1
    sta (ptr0), y
    dey
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    dey
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    rts
.endproc

.proc _dec32le
    ldy #0
    sec
    lda (ptr0), y
    sbc #1
    sta (ptr0), y
    iny
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    iny
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    iny
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    rts
.endproc

.proc _dec32be
    ldy #3
    sec
    lda (ptr0), y
    sbc #1
    sta (ptr0), y
    dey
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    dey
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    dey
    lda (ptr0), y
    sbc #0
    sta (ptr0), y
    rts
.endproc
