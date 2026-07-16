; mul.asm - Arbitrary-length unsigned multiplication
;
; Little-endian helper: _mulNle
; Big-endian helper:    _mulNbe
;
; Multiply *ptr0 * *ptr1 and store into *ptr2.
; arg0 = byte count of inputs (result uses 2 * arg0 bytes).
; Clobbers: A, X, Y, zero page temp vars

.include "nlib.inc"
.def product_lo _nl_ptr3
.def product_hi _nl_ptr3+1
.def byte_b     _nl_tmp0
.def tmp_b      _nl_tmp1
.def a_lo       _nl_tmp2
.def a_hi       _nl_tmp3
.def outer      _nl_tmp4
.def inner      _nl_tmp5

.proc _mulNle
    lda #0
    sta outer
    sta inner

    ldy #0
    ldx #0
@clear_ptr2:
    sta (ptr2), y
    iny
    sta (ptr2), y
    iny
    inx
    cpx arg0
    bne @clear_ptr2

@outer_loop:
    ldy outer
    cpy arg0
    beq @outer_fini

    lda (ptr1), y
    sta byte_b

@inner_loop:
    ldy inner
    cpy arg0
    beq @inner_fini

    lda (ptr0), y
    sta a_lo
    lda #0
    sta a_hi
    sta product_lo
    sta product_hi

    ldx #8
    lda byte_b
    sta tmp_b
@mult_loop:
    lsr tmp_b
    bcc @no_add

    clc
    lda product_lo
    adc a_lo
    sta product_lo
    lda product_hi
    adc a_hi
    sta product_hi

@no_add:
    asl a_lo
    rol a_hi

    dex
    bne @mult_loop

    clc
    lda inner
    adc outer
    tay
    clc
    lda (ptr2), y
    adc product_lo
    sta (ptr2), y
    iny
    lda (ptr2), y
    adc product_hi
    sta (ptr2), y
    iny
    lda (ptr2), y
    adc #0
    sta (ptr2), y

    inc inner
    jmp @inner_loop

@inner_fini:
    lda #0
    sta inner
    inc outer
    jmp @outer_loop

@outer_fini:
    rts
.endproc

.proc _mulNbe
    lda #0
    sta outer
    sta inner

    ldy #0
    ldx #0
@clear_ptr2:
    sta (ptr2), y
    iny
    sta (ptr2), y
    iny
    inx
    cpx arg0
    bne @clear_ptr2

@outer_loop:
    lda outer
    cmp arg0
    beq @outer_fini

    lda arg0
    sec
    sbc outer
    tay
    dey
    lda (ptr1), y
    sta byte_b

@inner_loop:
    lda inner
    cmp arg0
    beq @inner_fini

    lda arg0
    sec
    sbc inner
    tay
    dey
    lda (ptr0), y
    sta a_lo
    lda #0
    sta a_hi
    sta product_lo
    sta product_hi

    ldx #8
    lda byte_b
    sta tmp_b
@mult_loop:
    lsr tmp_b
    bcc @no_add

    clc
    lda product_lo
    adc a_lo
    sta product_lo
    lda product_hi
    adc a_hi
    sta product_hi

@no_add:
    asl a_lo
    rol a_hi

    dex
    bne @mult_loop

    lda arg0
    asl
    sec
    sbc inner
    sbc outer
    tay
    dey
    clc
    lda (ptr2), y
    adc product_lo
    sta (ptr2), y
    dey
    lda (ptr2), y
    adc product_hi
    sta (ptr2), y
    bcc @add_done
@carry_loop:
    cpy #0
    beq @add_done
    dey
    lda (ptr2), y
    adc #0
    sta (ptr2), y
    bcs @carry_loop
@add_done:
    inc inner
    jmp @inner_loop

@inner_fini:
    lda #0
    sta inner
    inc outer
    jmp @outer_loop

@outer_fini:
    rts
.endproc
