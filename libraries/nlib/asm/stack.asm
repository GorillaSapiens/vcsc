; stack.asm - Arbitrary-length buffer helpers

.include "nlib.inc"
.def src_idx _nl_tmp0
.def dst_idx _nl_tmp1
.def fillval _nl_tmp2

.proc _cpyN
    ldx arg0
    ldy #0
@loop:
    lda (ptr0), y
    sta (ptr1), y
    iny
    dex
    bne @loop
    rts
.endproc

.proc _setN
    ldx arg0
    beq @done
    ldy #0
    lda arg1
@loop:
    sta (ptr1), y
    iny
    dex
    bne @loop
@done:
    rts
.endproc

.proc _zeroN
    lda #0
    sta arg1
    jmp _setN
.endproc

.proc _copyzxNle
    ldy #0
    lda arg0
    cmp arg1
    bcc @copy_src
    ldx arg1
    jmp @copy
@copy_src:
    ldx arg0
@copy:
    beq @post_copy
@copy_loop:
    lda (ptr0), y
    sta (ptr1), y
    iny
    dex
    bne @copy_loop
@post_copy:
    lda arg1
    cmp arg0
    bcc @done
    beq @done
    lda #0
@fill_loop:
    sta (ptr1), y
    iny
    cpy arg1
    bcc @fill_loop
@done:
    rts
.endproc

.proc _copysxNle
    ldy #0
    lda arg0
    cmp arg1
    bcc @copy_src
    ldx arg1
    jmp @copy
@copy_src:
    ldx arg0
@copy:
    beq @post_copy
@copy_loop:
    lda (ptr0), y
    sta (ptr1), y
    iny
    dex
    bne @copy_loop
@post_copy:
    lda arg1
    cmp arg0
    bcc @done
    beq @done
    tya
    beq @zero_fill
    dey
    lda (ptr0), y
    and #$80
    beq @prep_zero_fill
    iny
    lda #$ff
    bne @fill_loop
@prep_zero_fill:
    iny
@zero_fill:
    lda #$00
@fill_loop:
    sta (ptr1), y
    iny
    cpy arg1
    bcc @fill_loop
@done:
    rts
.endproc

.proc _comp2Nle
    ldx arg0
    ldy #0
    sec
@loop:
    lda (ptr0), y
    eor #$FF
    adc #$00
    sta (ptr1), y
    iny
    dex
    bne @loop
    rts
.endproc

.proc _swapN
    ldx arg0
    ldy #0
@loop:
    lda (ptr0), y
    sta tmp0
    lda (ptr1), y
    sta (ptr0), y
    lda tmp0
    sta (ptr1), y
    iny
    dex
    bne @loop
    rts
.endproc

