; shift.asm - Bit shifting routines
;
; Little-endian helpers use the *le suffix.
; Big-endian helpers use the *be suffix.
;
; Inputs:
;   ptr0  - source for *N, read-only
;   ptr1  - destination for *N, modified in place for *1
;   arg0  - byte count
;   arg1  - bits to shift for N
; Clobbers: A, X, Y

.include "nlib.inc"
.def n_byte  _nl_tmp0
.def n_bit   _nl_tmp1
.def tmp     _nl_tmp2

.proc _lsl1le
    ldx arg0
    ldy #0
    clc
@loop:
    lda (ptr1), y
    rol
    sta (ptr1), y
    iny
    dex
    bne @loop
    rts
.endproc

.proc _lsr1le
    ldy arg0
    dey
    clc
@loop:
    lda (ptr1), y
    ror
    sta (ptr1), y
    dey
    bpl @loop
    rts
.endproc

.proc _asr1le
    ldy arg0
    dey
    lda (ptr1), y
    asl
@loop:
    lda (ptr1), y
    ror
    sta (ptr1), y
    dey
    bpl @loop
    rts
.endproc

.proc _arg1Nle
    jmp @start
@trampoline1:
    jmp (ptr3)
@start:
    lda arg1
    and #7
    sta n_bit
    beq @done
@loop:
    jsr @trampoline1
    dec n_bit
    bne @loop
@done:
    rts
.endproc

.proc _lslNle
    lda #<_lsl1le
    sta ptr3
    lda #>_lsl1le
    sta ptr3+1

    lda arg1
    lsr
    lsr
    lsr
    sta n_byte
    cmp arg0
    bcc @copy_bytes

    ldy arg0
    dey
    lda #0
@fill_all:
    sta (ptr1), y
    dey
    bpl @fill_all
    rts

@copy_bytes:
    lda ptr0
    sec
    sbc n_byte
    sta ptr2
    lda ptr0+1
    sbc #0
    sta ptr2+1

    ldy arg0
    dey
@copy:
    cpy n_byte
    bcc @fill_low
    lda (ptr2), y
    sta (ptr1), y
    dey
    bpl @copy
    jsr _arg1Nle
    rts

@fill_low:
    lda #0
@fill_low_loop:
    sta (ptr1), y
    dey
    bpl @fill_low_loop
    jsr _arg1Nle
    rts
.endproc

.proc _lsrNle
    lda #<_lsr1le
    sta ptr3
    lda #>_lsr1le
    sta ptr3+1

    lda arg1
    lsr
    lsr
    lsr
    sta n_byte
    cmp arg0
    bcc @copy_bytes

    ldy #0
    lda #0
@fill_all:
    sta (ptr1), y
    iny
    cpy arg0
    bcc @fill_all
    rts

@copy_bytes:
    lda ptr0
    clc
    adc n_byte
    sta ptr2
    lda ptr0+1
    adc #0
    sta ptr2+1

    lda arg0
    sec
    sbc n_byte
    tax
    ldy #0
@copy:
    lda (ptr2), y
    sta (ptr1), y
    iny
    dex
    bne @copy

    lda #0
@fill_high:
    cpy arg0
    bcs @post_bits
    sta (ptr1), y
    iny
    bne @fill_high
@post_bits:
    jsr _arg1Nle
    rts
.endproc

.proc _asrNle
    lda #<_asr1le
    sta ptr3
    lda #>_asr1le
    sta ptr3+1

    ldy arg0
    dey
    lda (ptr0), y
    bmi @negative
    lda #0
    jmp @got_fill
@negative:
    lda #$ff
@got_fill:
    sta tmp

    lda arg1
    lsr
    lsr
    lsr
    sta n_byte
    cmp arg0
    bcc @copy_bytes

    ldy #0
    lda tmp
@fill_all:
    sta (ptr1), y
    iny
    cpy arg0
    bcc @fill_all
    rts

@copy_bytes:
    lda ptr0
    clc
    adc n_byte
    sta ptr2
    lda ptr0+1
    adc #0
    sta ptr2+1

    lda arg0
    sec
    sbc n_byte
    tax
    ldy #0
@copy:
    lda (ptr2), y
    sta (ptr1), y
    iny
    dex
    bne @copy

    lda tmp
@fill_high:
    cpy arg0
    bcs @post_bits
    sta (ptr1), y
    iny
    bne @fill_high
@post_bits:
    jsr _arg1Nle
    rts
.endproc

.proc _lsl1be
    ldy arg0
    dey
    clc
@loop:
    lda (ptr1), y
    rol
    sta (ptr1), y
    dey
    bpl @loop
    rts
.endproc

.proc _lsr1be
    ldy #0
    clc
@loop:
    lda (ptr1), y
    ror
    sta (ptr1), y
    iny
    cpy arg0
    bcc @loop
    rts
.endproc

.proc _asr1be
    ldy #0
    lda (ptr1), y
    asl
@loop:
    lda (ptr1), y
    ror
    sta (ptr1), y
    iny
    cpy arg0
    bcc @loop
    rts
.endproc

.proc _arg1Nbe
    jmp @start
@trampoline1:
    jmp (ptr3)
@start:
    lda arg1
    and #7
    sta n_bit
    beq @done
@loop:
    jsr @trampoline1
    dec n_bit
    bne @loop
@done:
    rts
.endproc

.proc _lslNbe
    lda #<_lsl1be
    sta ptr3
    lda #>_lsl1be
    sta ptr3+1

    lda arg1
    lsr
    lsr
    lsr
    sta n_byte
    cmp arg0
    bcc @copy_bytes

    ldy #0
    lda #0
@fill_all:
    sta (ptr1), y
    iny
    cpy arg0
    bcc @fill_all
    rts

@copy_bytes:
    lda ptr0
    clc
    adc n_byte
    sta ptr2
    lda ptr0+1
    adc #0
    sta ptr2+1

    lda arg0
    sec
    sbc n_byte
    tax
    ldy #0
@copy:
    lda (ptr2), y
    sta (ptr1), y
    iny
    dex
    bne @copy

    lda #0
@fill_tail:
    cpy arg0
    bcs @post_bits
    sta (ptr1), y
    iny
    bne @fill_tail
@post_bits:
    jsr _arg1Nbe
    rts
.endproc

.proc _lsrNbe
    lda #<_lsr1be
    sta ptr3
    lda #>_lsr1be
    sta ptr3+1

    lda arg1
    lsr
    lsr
    lsr
    sta n_byte
    cmp arg0
    bcc @copy_bytes

    ldy #0
    lda #0
@fill_all:
    sta (ptr1), y
    iny
    cpy arg0
    bcc @fill_all
    rts

@copy_bytes:
    lda ptr0
    sec
    sbc n_byte
    sta ptr2
    lda ptr0+1
    sbc #0
    sta ptr2+1

    ldy arg0
    dey
@copy:
    cpy n_byte
    bcc @fill_head
    lda (ptr2), y
    sta (ptr1), y
    dey
    bpl @copy
    jsr _arg1Nbe
    rts

@fill_head:
    lda #0
@fill_head_loop:
    sta (ptr1), y
    dey
    bpl @fill_head_loop
    jsr _arg1Nbe
    rts
.endproc

.proc _asrNbe
    lda #<_asr1be
    sta ptr3
    lda #>_asr1be
    sta ptr3+1

    ldy #0
    lda (ptr0), y
    bmi @negative
    lda #0
    jmp @got_fill
@negative:
    lda #$ff
@got_fill:
    sta tmp

    lda arg1
    lsr
    lsr
    lsr
    sta n_byte
    cmp arg0
    bcc @copy_bytes

    ldy #0
    lda tmp
@fill_all:
    sta (ptr1), y
    iny
    cpy arg0
    bcc @fill_all
    rts

@copy_bytes:
    lda ptr0
    sec
    sbc n_byte
    sta ptr2
    lda ptr0+1
    sbc #0
    sta ptr2+1

    ldy arg0
    dey
@copy:
    cpy n_byte
    bcc @fill_head
    lda (ptr2), y
    sta (ptr1), y
    dey
    bpl @copy
    jsr _arg1Nbe
    rts

@fill_head:
    lda tmp
@fill_head_loop:
    sta (ptr1), y
    dey
    bpl @fill_head_loop
    jsr _arg1Nbe
    rts
.endproc
