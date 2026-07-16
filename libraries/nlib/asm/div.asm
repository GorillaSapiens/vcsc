; div.asm - Arbitrary-length unsigned division
;
; Little-endian helper: _divNle
; Big-endian helper:    _divNbe
;
; Divides ptr0 (dividend) by ptr1 (divisor), arg0 bytes each.
; Stores quotient in ptr2, remainder in ptr3.
; Clobbers: A, X, Y, and zero page temps
; NB: also writes to the stack.

.include "nlib.inc"
.def tmpX  _nl_tmp0
.def carry _nl_tmp1

.proc _divNle
    ldx arg0
    ldy #0
@cpy_loop:
    lda (ptr0), y
    sta (sp), y
    iny
    dex
    bne @cpy_loop

    ldy #0
@clear_loop:
    lda #0
    sta (ptr2), y
    sta (ptr3), y
    iny
    cpy arg0
    bne @clear_loop

    ldx #0
    lda arg0
    asl
    asl
    asl
    sta tmpX

@bit_loop:
    clc
    ldx arg0
    dex
    ldy #0
@shift_div:
    lda (sp), y
    rol a
    sta (sp), y
    iny
    dex
    bpl @shift_div

    bcs @have_carry
    ldx #0
@have_carry:
    stx carry

    ldx arg0
    dex
    ldy #0
@shift_rem:
    lda (ptr3), y
    rol a
    sta (ptr3), y
    iny
    dex
    bpl @shift_rem

    ldy #0
    lda carry
    and #1
    ora (sp), y
    sta (sp), y

    jsr @cmp_rem_div
    bcc @skip_subtract

    jsr @sub_div_from_rem
    sec

@skip_subtract:
    ldx arg0
    dex
    ldy #0
@store_qbit:
    lda (ptr2), y
    rol a
    sta (ptr2), y
    iny
    dex
    bpl @store_qbit

    dec tmpX
    lda tmpX
    bne @bit_loop
    rts

@cmp_rem_div:
    ldy arg0
    dey
@cmp_loop:
    lda (ptr3), y
    cmp (ptr1), y
    bne @finish_cmp
    dey
    bpl @cmp_loop
    sec
    rts
@finish_cmp:
    bcc @lt
    sec
    rts
@lt:
    clc
    rts

@sub_div_from_rem:
    ldx arg0
    dex
    ldy #0
    sec
@sub_loop:
    lda (ptr3), y
    sbc (ptr1), y
    sta (ptr3), y
    iny
    dex
    bpl @sub_loop
    rts
.endproc

.proc _divNbe
    ldx arg0
    ldy #0
@cpy_loop:
    lda (ptr0), y
    sta (sp), y
    iny
    dex
    bne @cpy_loop

    ldy #0
@clear_loop:
    lda #0
    sta (ptr2), y
    sta (ptr3), y
    iny
    cpy arg0
    bne @clear_loop

    lda arg0
    asl
    asl
    asl
    sta tmpX

@bit_loop:
    clc
    ldy arg0
    dey
@shift_div:
    lda (sp), y
    rol a
    sta (sp), y
    dey
    bpl @shift_div

    lda #0
    bcc @carry_saved
    lda #1
@carry_saved:
    sta carry

    ldy arg0
    dey
@shift_rem:
    lda (ptr3), y
    rol a
    sta (ptr3), y
    dey
    bpl @shift_rem

    ldy arg0
    dey
    lda carry
    and #1
    ora (sp), y
    sta (sp), y

    jsr @cmp_rem_div
    bcc @skip_subtract

    jsr @sub_div_from_rem
    sec

@skip_subtract:
    ldy arg0
    dey
@store_qbit:
    lda (ptr2), y
    rol a
    sta (ptr2), y
    dey
    bpl @store_qbit

    dec tmpX
    lda tmpX
    bne @bit_loop
    rts

@cmp_rem_div:
    ldy #0
@cmp_loop:
    lda (ptr3), y
    cmp (ptr1), y
    bne @finish_cmp
    iny
    cpy arg0
    bcc @cmp_loop
    sec
    rts
@finish_cmp:
    bcc @lt
    sec
    rts
@lt:
    clc
    rts

@sub_div_from_rem:
    ldy arg0
    dey
    sec
@sub_loop:
    lda (ptr3), y
    sbc (ptr1), y
    sta (ptr3), y
    dey
    bpl @sub_loop
    rts
.endproc
