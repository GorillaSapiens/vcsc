; shift.asm - fixed-width VCSC scalar shift helpers
;
; Inputs: ptr0 source, ptr1 destination, arg1 low-byte shift count.
; ptr0 and ptr1 are preserved.  A, X, and Y are clobbered.
; Widths are 8, 16, 24, and 32 bits; multibyte values are little-endian.

.include "vcsc-runtime.inc"

.proc _shl8
    ldy #0
    lda (ptr0), y
    sta (ptr1), y
    ldx arg1
    beq @done
    cpx #8
    bcs @saturate
@loop:
    clc
    ldy #0
    lda (ptr1), y
    rol
    sta (ptr1), y
    dex
    bne @loop
@done:
    rts
@saturate:
    lda #0
    ldy #0
    sta (ptr1), y
    rts
.endproc

.proc _shl16
    ldy #0
    lda (ptr0), y
    sta (ptr1), y
    ldy #1
    lda (ptr0), y
    sta (ptr1), y
    ldx arg1
    beq @done
    cpx #16
    bcs @saturate
@loop:
    clc
    ldy #0
    lda (ptr1), y
    rol
    sta (ptr1), y
    ldy #1
    lda (ptr1), y
    rol
    sta (ptr1), y
    dex
    bne @loop
@done:
    rts
@saturate:
    lda #0
    ldy #0
    sta (ptr1), y
    ldy #1
    sta (ptr1), y
    rts
.endproc

.proc _shl24
    ldy #0
    lda (ptr0), y
    sta (ptr1), y
    ldy #1
    lda (ptr0), y
    sta (ptr1), y
    ldy #2
    lda (ptr0), y
    sta (ptr1), y
    ldx arg1
    beq @done
    cpx #24
    bcs @saturate
@loop:
    clc
    ldy #0
    lda (ptr1), y
    rol
    sta (ptr1), y
    ldy #1
    lda (ptr1), y
    rol
    sta (ptr1), y
    ldy #2
    lda (ptr1), y
    rol
    sta (ptr1), y
    dex
    bne @loop
@done:
    rts
@saturate:
    lda #0
    ldy #0
    sta (ptr1), y
    ldy #1
    sta (ptr1), y
    ldy #2
    sta (ptr1), y
    rts
.endproc

.proc _shl32
    ldy #0
    lda (ptr0), y
    sta (ptr1), y
    ldy #1
    lda (ptr0), y
    sta (ptr1), y
    ldy #2
    lda (ptr0), y
    sta (ptr1), y
    ldy #3
    lda (ptr0), y
    sta (ptr1), y
    ldx arg1
    beq @done
    cpx #32
    bcs @saturate
@loop:
    clc
    ldy #0
    lda (ptr1), y
    rol
    sta (ptr1), y
    ldy #1
    lda (ptr1), y
    rol
    sta (ptr1), y
    ldy #2
    lda (ptr1), y
    rol
    sta (ptr1), y
    ldy #3
    lda (ptr1), y
    rol
    sta (ptr1), y
    dex
    bne @loop
@done:
    rts
@saturate:
    lda #0
    ldy #0
    sta (ptr1), y
    ldy #1
    sta (ptr1), y
    ldy #2
    sta (ptr1), y
    ldy #3
    sta (ptr1), y
    rts
.endproc

.proc _shr8
    ldy #0
    lda (ptr0), y
    sta (ptr1), y
    ldx arg1
    beq @done
    cpx #8
    bcs @saturate
@loop:
    clc
    ldy #0
    lda (ptr1), y
    ror
    sta (ptr1), y
    dex
    bne @loop
@done:
    rts
@saturate:
    lda #0
    ldy #0
    sta (ptr1), y
    rts
.endproc

.proc _shr16
    ldy #0
    lda (ptr0), y
    sta (ptr1), y
    ldy #1
    lda (ptr0), y
    sta (ptr1), y
    ldx arg1
    beq @done
    cpx #16
    bcs @saturate
@loop:
    clc
    ldy #1
    lda (ptr1), y
    ror
    sta (ptr1), y
    ldy #0
    lda (ptr1), y
    ror
    sta (ptr1), y
    dex
    bne @loop
@done:
    rts
@saturate:
    lda #0
    ldy #0
    sta (ptr1), y
    ldy #1
    sta (ptr1), y
    rts
.endproc

.proc _shr24
    ldy #0
    lda (ptr0), y
    sta (ptr1), y
    ldy #1
    lda (ptr0), y
    sta (ptr1), y
    ldy #2
    lda (ptr0), y
    sta (ptr1), y
    ldx arg1
    beq @done
    cpx #24
    bcs @saturate
@loop:
    clc
    ldy #2
    lda (ptr1), y
    ror
    sta (ptr1), y
    ldy #1
    lda (ptr1), y
    ror
    sta (ptr1), y
    ldy #0
    lda (ptr1), y
    ror
    sta (ptr1), y
    dex
    bne @loop
@done:
    rts
@saturate:
    lda #0
    ldy #0
    sta (ptr1), y
    ldy #1
    sta (ptr1), y
    ldy #2
    sta (ptr1), y
    rts
.endproc

.proc _shr32
    ldy #0
    lda (ptr0), y
    sta (ptr1), y
    ldy #1
    lda (ptr0), y
    sta (ptr1), y
    ldy #2
    lda (ptr0), y
    sta (ptr1), y
    ldy #3
    lda (ptr0), y
    sta (ptr1), y
    ldx arg1
    beq @done
    cpx #32
    bcs @saturate
@loop:
    clc
    ldy #3
    lda (ptr1), y
    ror
    sta (ptr1), y
    ldy #2
    lda (ptr1), y
    ror
    sta (ptr1), y
    ldy #1
    lda (ptr1), y
    ror
    sta (ptr1), y
    ldy #0
    lda (ptr1), y
    ror
    sta (ptr1), y
    dex
    bne @loop
@done:
    rts
@saturate:
    lda #0
    ldy #0
    sta (ptr1), y
    ldy #1
    sta (ptr1), y
    ldy #2
    sta (ptr1), y
    ldy #3
    sta (ptr1), y
    rts
.endproc

.proc _sar8
    ldy #0
    lda (ptr0), y
    sta (ptr1), y
    ldx arg1
    beq @done
    cpx #8
    bcs @saturate
@loop:
    ldy #0
    lda (ptr1), y
    asl
    ldy #0
    lda (ptr1), y
    ror
    sta (ptr1), y
    dex
    bne @loop
@done:
    rts
@saturate:
    ldy #0
    lda (ptr1), y
    bpl @sat_zero
    lda #$ff
    bne @sat_fill
@sat_zero:
    lda #0
@sat_fill:
    ldy #0
    sta (ptr1), y
    rts
.endproc

.proc _sar16
    ldy #0
    lda (ptr0), y
    sta (ptr1), y
    ldy #1
    lda (ptr0), y
    sta (ptr1), y
    ldx arg1
    beq @done
    cpx #16
    bcs @saturate
@loop:
    ldy #1
    lda (ptr1), y
    asl
    ldy #1
    lda (ptr1), y
    ror
    sta (ptr1), y
    ldy #0
    lda (ptr1), y
    ror
    sta (ptr1), y
    dex
    bne @loop
@done:
    rts
@saturate:
    ldy #1
    lda (ptr1), y
    bpl @sat_zero
    lda #$ff
    bne @sat_fill
@sat_zero:
    lda #0
@sat_fill:
    ldy #0
    sta (ptr1), y
    ldy #1
    sta (ptr1), y
    rts
.endproc

.proc _sar24
    ldy #0
    lda (ptr0), y
    sta (ptr1), y
    ldy #1
    lda (ptr0), y
    sta (ptr1), y
    ldy #2
    lda (ptr0), y
    sta (ptr1), y
    ldx arg1
    beq @done
    cpx #24
    bcs @saturate
@loop:
    ldy #2
    lda (ptr1), y
    asl
    ldy #2
    lda (ptr1), y
    ror
    sta (ptr1), y
    ldy #1
    lda (ptr1), y
    ror
    sta (ptr1), y
    ldy #0
    lda (ptr1), y
    ror
    sta (ptr1), y
    dex
    bne @loop
@done:
    rts
@saturate:
    ldy #2
    lda (ptr1), y
    bpl @sat_zero
    lda #$ff
    bne @sat_fill
@sat_zero:
    lda #0
@sat_fill:
    ldy #0
    sta (ptr1), y
    ldy #1
    sta (ptr1), y
    ldy #2
    sta (ptr1), y
    rts
.endproc

.proc _sar32
    ldy #0
    lda (ptr0), y
    sta (ptr1), y
    ldy #1
    lda (ptr0), y
    sta (ptr1), y
    ldy #2
    lda (ptr0), y
    sta (ptr1), y
    ldy #3
    lda (ptr0), y
    sta (ptr1), y
    ldx arg1
    beq @done
    cpx #32
    bcs @saturate
@loop:
    ldy #3
    lda (ptr1), y
    asl
    ldy #3
    lda (ptr1), y
    ror
    sta (ptr1), y
    ldy #2
    lda (ptr1), y
    ror
    sta (ptr1), y
    ldy #1
    lda (ptr1), y
    ror
    sta (ptr1), y
    ldy #0
    lda (ptr1), y
    ror
    sta (ptr1), y
    dex
    bne @loop
@done:
    rts
@saturate:
    ldy #3
    lda (ptr1), y
    bpl @sat_zero
    lda #$ff
    bne @sat_fill
@sat_zero:
    lda #0
@sat_fill:
    ldy #0
    sta (ptr1), y
    ldy #1
    sta (ptr1), y
    ldy #2
    sta (ptr1), y
    ldy #3
    sta (ptr1), y
    rts
.endproc

