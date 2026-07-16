;;; builtin float weak comparison operator split from nlib weakops
.include "nlib.inc"
.import _sp2ptr0m, _sp2ptr1m, _fcmp, _sp2ptr2m
.export ?@op_ge@float_p0_a0@float_p0_a0

.proc ?@op_ge@float_p0_a0@float_p0_a0
    lda #$04
    sta arg0
    jsr _sp2ptr0m
    lda #$08
    sta arg0
    jsr _sp2ptr1m
    lda #$04
    sta arg0
    lda #$08
    sta arg1
    jsr _fcmp
    lda #$09
    sta arg0
    jsr _sp2ptr2m
    ldy #0
    lda arg1
    cmp #$ff
    bne @true
    lda #0
    beq @store
@true:
    lda #1
@store:
    sta (ptr2),y
    rts
.endproc

