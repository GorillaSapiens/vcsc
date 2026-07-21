; div.asm - Fixed-width unsigned little-endian division/remainder
;
; Each selected helper uses the compiler expression scratch as all algorithm
; state.  The quotient and remainder occupy one adjacent 2*N-byte result block,
; so ptr3, tmp bytes, and a private dividend workspace are unnecessary.
; Division by zero retains the historical behavior: all quotient bits set and
; the original dividend left as the remainder.

.include "vcsc-runtime.inc"

.proc _div8
    ; ptr0 = dividend scratch (destroyed), ptr1 = divisor scratch.
    ; ptr2 points at quotient followed immediately by remainder.
    lda #0
    ldy #0
    sta (ptr2), y
    ldy #1
    sta (ptr2), y
    ldx #8
@bit_loop:
    clc
    ldy #0
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #1
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #1
    lda (ptr2), y
    ldy #0
    cmp (ptr1), y
    bcc @no_subtract
    bne @subtract
@subtract:
    sec
    ldy #1
    lda (ptr2), y
    ldy #0
    sbc (ptr1), y
    ldy #1
    sta (ptr2), y
    sec
    bcs @shift_quotient
@no_subtract:
    clc
@shift_quotient:
    ldy #0
    lda (ptr2), y
    rol a
    sta (ptr2), y
    dex
    beq @done
    jmp @bit_loop
@done:
    rts
.endproc

.proc _div16
    ; ptr0 = dividend scratch (destroyed), ptr1 = divisor scratch.
    ; ptr2 points at quotient followed immediately by remainder.
    lda #0
    ldy #0
    sta (ptr2), y
    ldy #1
    sta (ptr2), y
    ldy #2
    sta (ptr2), y
    ldy #3
    sta (ptr2), y
    ldx #16
@bit_loop:
    clc
    ldy #0
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #1
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #2
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #3
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #3
    lda (ptr2), y
    ldy #1
    cmp (ptr1), y
    bcc @no_subtract
    bne @subtract
    ldy #2
    lda (ptr2), y
    ldy #0
    cmp (ptr1), y
    bcc @no_subtract
    bne @subtract
@subtract:
    sec
    ldy #2
    lda (ptr2), y
    ldy #0
    sbc (ptr1), y
    ldy #2
    sta (ptr2), y
    ldy #3
    lda (ptr2), y
    ldy #1
    sbc (ptr1), y
    ldy #3
    sta (ptr2), y
    sec
    bcs @shift_quotient
@no_subtract:
    clc
@shift_quotient:
    ldy #0
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #1
    lda (ptr2), y
    rol a
    sta (ptr2), y
    dex
    beq @done
    jmp @bit_loop
@done:
    rts
.endproc

.proc _div24
    ; ptr0 = dividend scratch (destroyed), ptr1 = divisor scratch.
    ; ptr2 points at quotient followed immediately by remainder.
    lda #0
    ldy #0
    sta (ptr2), y
    ldy #1
    sta (ptr2), y
    ldy #2
    sta (ptr2), y
    ldy #3
    sta (ptr2), y
    ldy #4
    sta (ptr2), y
    ldy #5
    sta (ptr2), y
    ldx #24
@bit_loop:
    clc
    ldy #0
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #1
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #2
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #3
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #4
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #5
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #5
    lda (ptr2), y
    ldy #2
    cmp (ptr1), y
    bcc @no_subtract
    bne @subtract
    ldy #4
    lda (ptr2), y
    ldy #1
    cmp (ptr1), y
    bcc @no_subtract
    bne @subtract
    ldy #3
    lda (ptr2), y
    ldy #0
    cmp (ptr1), y
    bcc @no_subtract
    bne @subtract
@subtract:
    sec
    ldy #3
    lda (ptr2), y
    ldy #0
    sbc (ptr1), y
    ldy #3
    sta (ptr2), y
    ldy #4
    lda (ptr2), y
    ldy #1
    sbc (ptr1), y
    ldy #4
    sta (ptr2), y
    ldy #5
    lda (ptr2), y
    ldy #2
    sbc (ptr1), y
    ldy #5
    sta (ptr2), y
    sec
    bcs @shift_quotient
@no_subtract:
    clc
@shift_quotient:
    ldy #0
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #1
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #2
    lda (ptr2), y
    rol a
    sta (ptr2), y
    dex
    beq @done
    jmp @bit_loop
@done:
    rts
.endproc

.proc _div32
    ; ptr0 = dividend scratch (destroyed), ptr1 = divisor scratch.
    ; ptr2 points at quotient followed immediately by remainder.
    lda #0
    ldy #0
    sta (ptr2), y
    ldy #1
    sta (ptr2), y
    ldy #2
    sta (ptr2), y
    ldy #3
    sta (ptr2), y
    ldy #4
    sta (ptr2), y
    ldy #5
    sta (ptr2), y
    ldy #6
    sta (ptr2), y
    ldy #7
    sta (ptr2), y
    ldx #32
@bit_loop:
    clc
    ldy #0
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #1
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #2
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #3
    lda (ptr0), y
    rol a
    sta (ptr0), y
    ldy #4
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #5
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #6
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #7
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #7
    lda (ptr2), y
    ldy #3
    cmp (ptr1), y
    bcc @no_subtract
    bne @subtract
    ldy #6
    lda (ptr2), y
    ldy #2
    cmp (ptr1), y
    bcc @no_subtract
    bne @subtract
    ldy #5
    lda (ptr2), y
    ldy #1
    cmp (ptr1), y
    bcc @no_subtract
    bne @subtract
    ldy #4
    lda (ptr2), y
    ldy #0
    cmp (ptr1), y
    bcc @no_subtract
    bne @subtract
@subtract:
    sec
    ldy #4
    lda (ptr2), y
    ldy #0
    sbc (ptr1), y
    ldy #4
    sta (ptr2), y
    ldy #5
    lda (ptr2), y
    ldy #1
    sbc (ptr1), y
    ldy #5
    sta (ptr2), y
    ldy #6
    lda (ptr2), y
    ldy #2
    sbc (ptr1), y
    ldy #6
    sta (ptr2), y
    ldy #7
    lda (ptr2), y
    ldy #3
    sbc (ptr1), y
    ldy #7
    sta (ptr2), y
    sec
    bcs @shift_quotient
@no_subtract:
    clc
@shift_quotient:
    ldy #0
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #1
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #2
    lda (ptr2), y
    rol a
    sta (ptr2), y
    ldy #3
    lda (ptr2), y
    rol a
    sta (ptr2), y
    dex
    beq @done
    jmp @bit_loop
@done:
    rts
.endproc
