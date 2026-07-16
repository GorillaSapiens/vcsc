; generated builtin float assembly, checked in under libraries/float/asm
; Fixed-format builtin big-endian float pointer-ABI wrapper.
;
; Inputs:
;   ptr0 = big-endian lhs
;   ptr1 = big-endian rhs
;   ptr2 = big-endian destination
;
; The builtin float core is little-endian.  This wrapper reverses the
; input bytes into stack scratch buffers, calls the little-endian helper,
; then reverses the result back to the caller's big-endian destination.
.include "nlib.inc"
.import _pushN, _popN, _sp2ptr0m, _sp2ptr1m, _sp2ptr2m, _sp2ptr3m, _f64_div
.export _f64be_div

.proc _f64be_div
    lda #$1e
    sta arg0
    jsr _pushN

    ; Save incoming ptr0/ptr1/ptr2 at the base of the scratch frame.
    lda #$1e
    sta arg0
    jsr _sp2ptr3m
    ldy #0
    lda ptr0
    sta (ptr3), y
    iny
    lda ptr0+1
    sta (ptr3), y
    iny
    lda ptr1
    sta (ptr3), y
    iny
    lda ptr1+1
    sta (ptr3), y
    iny
    lda ptr2
    sta (ptr3), y
    iny
    lda ptr2+1
    sta (ptr3), y

    ; lhs BE -> LE scratch
    ldy #0
    lda (ptr3), y
    sta ptr0
    iny
    lda (ptr3), y
    sta ptr0+1
    lda #$18
    sta arg0
    jsr _sp2ptr1m
    lda #0
    sta tmp0
    lda #$07
    sta tmp1
@lhs_loop:
    ldy tmp1
    lda (ptr0), y
    ldy tmp0
    sta (ptr1), y
    inc tmp0
    dec tmp1
    lda tmp0
    cmp #$08
    bne @lhs_loop


    ; rhs BE -> LE scratch
    ldy #2
    lda (ptr3), y
    sta ptr0
    iny
    lda (ptr3), y
    sta ptr0+1
    lda #$10
    sta arg0
    jsr _sp2ptr1m
    lda #0
    sta tmp0
    lda #$07
    sta tmp1
@rhs_loop:
    ldy tmp1
    lda (ptr0), y
    ldy tmp0
    sta (ptr1), y
    inc tmp0
    dec tmp1
    lda tmp0
    cmp #$08
    bne @rhs_loop


    ; Call little-endian fixed helper with LE scratch pointers.
    lda #$18
    sta arg0
    jsr _sp2ptr0m
    lda #$10
    sta arg0
    jsr _sp2ptr1m
    lda #$08
    sta arg0
    jsr _sp2ptr2m
    jsr _f64_div

    ; LE result scratch -> original BE destination
    lda #$1e
    sta arg0
    jsr _sp2ptr3m
    lda #$08
    sta arg0
    jsr _sp2ptr0m
    ldy #4
    lda (ptr3), y
    sta ptr1
    iny
    lda (ptr3), y
    sta ptr1+1
    lda #0
    sta tmp0
    lda #$07
    sta tmp1
@dst_loop:
    ldy tmp1
    lda (ptr0), y
    ldy tmp0
    sta (ptr1), y
    inc tmp0
    dec tmp1
    lda tmp0
    cmp #$08
    bne @dst_loop


    lda #$1e
    sta arg0
    jsr _popN
    rts
.endproc
