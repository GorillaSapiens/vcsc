; stack.asm - Arbitrary-length stack and buffer helpers

.include "nlib.inc"
.def src_idx _nl_tmp0
.def dst_idx _nl_tmp1
.def fillval _nl_tmp2

.proc _pushN
    clc
    lda sp
    adc arg0
    sta sp
    lda sp+1
    adc #0
    sta sp+1
    rts
.endproc

.proc _popN
    sec
    lda sp
    sbc arg0
    sta sp
    lda sp+1
    sbc #0
    sta sp+1
    rts
.endproc

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

.proc _copyzxNbe
    lda arg0
    cmp arg1
    bcc @extend

    sec
    sbc arg1
    sta src_idx
    lda #0
    sta dst_idx
    ldx arg1
    jmp @copy

@extend:
    lda arg1
    sec
    sbc arg0
    sta dst_idx
    lda #0
    sta src_idx
    tay
    lda #0
@fill_loop:
    cpy #0
    beq @prep_copy
    sta (ptr1), y
    dey
    bne @fill_loop
    sta (ptr1), y
@prep_copy:
    ldx arg0
@copy:
    beq @done
@copy_loop:
    ldy src_idx
    lda (ptr0), y
    ldy dst_idx
    sta (ptr1), y
    inc src_idx
    inc dst_idx
    dex
    bne @copy_loop
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

.proc _copysxNbe
    ldy #0
    lda (ptr0), y
    and #$80
    beq @zero_fill
    lda #$ff
    bne @got_fill
@zero_fill:
    lda #$00
@got_fill:
    sta fillval

    lda arg0
    cmp arg1
    bcc @extend

    sec
    sbc arg1
    sta src_idx
    lda #0
    sta dst_idx
    ldx arg1
    jmp @copy

@extend:
    lda arg1
    sec
    sbc arg0
    sta dst_idx
    lda #0
    sta src_idx
    tay
    lda fillval
@fill_loop:
    cpy #0
    beq @prep_copy
    sta (ptr1), y
    dey
    bne @fill_loop
    sta (ptr1), y
@prep_copy:
    ldx arg0
@copy:
    beq @done
@copy_loop:
    ldy src_idx
    lda (ptr0), y
    ldy dst_idx
    sta (ptr1), y
    inc src_idx
    inc dst_idx
    dex
    bne @copy_loop
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

.proc _comp2Nbe
    ldy arg0
    dey
    sec
@loop:
    lda (ptr0), y
    eor #$FF
    adc #$00
    sta (ptr1), y
    dey
    bpl @loop
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

.proc _callptr0
    sec
    lda ptr0
    sbc #1
    tax
    lda ptr0+1
    sbc #0
    pha
    txa
    pha
    rts
.endproc
