; bitwise.s - AND, OR, NOT, XOR
;
; Arbitrary-width bitwise logic on buffers
; Inputs:
;   ptr0, ptr1 - input buffers (ptr1 not needed for NOT)
;   ptr2 - destination
;   arg0 - byte count
; Clobbers: A, Y

.include "nlib.inc"

.proc _bit_andN
    ldx arg0
    ldy #0
@loop:
    lda (ptr0), y
    and (ptr1), y
    sta (ptr2), y
    iny
    dex
    bne @loop
    rts
.endproc

.proc _bit_notN
    ldx arg0
    ldy #0
@loop:
    lda (ptr0), y
    eor #$FF
    sta (ptr2), y
    iny
    dex
    bne @loop
    rts
.endproc

.proc _bit_orN
    ldx arg0
    ldy #0
@loop:
    lda (ptr0), y
    ora (ptr1), y
    sta (ptr2), y
    iny
    dex
    bne @loop
    rts
.endproc

.proc _bit_xorN
    ldx arg0
    ldy #0
@loop:
    lda (ptr0), y
    eor (ptr1), y
    sta (ptr2), y
    iny
    dex
    bne @loop
    rts
.endproc
