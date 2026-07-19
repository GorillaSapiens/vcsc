; div.asm - Arbitrary-width unsigned division
;
; Little-endian helper: _divNle
;
; Divides ptr0 (dividend) by ptr1 (divisor), arg0 bytes each.
; Stores quotient in ptr2, remainder in ptr3.
; Clobbers: A, X, Y, and zero page temps.
; The private four-byte BSS copy is linked only when division/remainder is used.

.include "vcsc-runtime.inc"
.def tmpX  _vcsc_tmp0
.def carry _vcsc_tmp1

.proc _divNle
.segment "BSS"
@dividend:
    .res 4
.segment "CODE"
    ldx arg0
    ldy #0
@cpy_loop:
    lda (ptr0), y
    sta @dividend, y
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
    lda @dividend, y
    rol a
    sta @dividend, y
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
    ora @dividend, y
    sta @dividend, y

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

