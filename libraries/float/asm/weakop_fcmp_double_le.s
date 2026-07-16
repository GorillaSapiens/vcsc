;;; builtin float weak comparison operator split from nlib weakops
.include "nlib.inc"
.import _sp2ptr0m, _sp2ptr1m, _fcmp, _sp2ptr2m
.export ?@op_le@double_p0_a0@double_p0_a0

.proc ?@op_le@double_p0_a0@double_p0_a0
    lda #$08
    sta arg0
    jsr _sp2ptr0m
    lda #$10
    sta arg0
    jsr _sp2ptr1m
    lda #$08
    sta arg0
    lda #$0b
    sta arg1
    jsr _fcmp
    lda #$11
    sta arg0
    jsr _sp2ptr2m
    ldy #0
    lda arg1
    cmp #$01
    bne @true
    lda #0
    beq @store
@true:
    lda #1
@store:
    sta (ptr2),y
    rts
.endproc

