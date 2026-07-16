; generated builtin float assembly, checked in under libraries/float/asm
; Fixed-format builtin float pointer-ABI wrapper.
;
; Inputs:
;   ptr0 = lhs
;   ptr1 = rhs
;   ptr2 = destination
;
; This wrapper adapts the compiler/runtime pointer ABI to the generated
; embedded builtin-float stack ABI.
.include "nlib.inc"
.import _pushN, _popN, _sp2ptr0m, _sp2ptr1m, _sp2ptr3m, _cpyN, ?@op_mul@double_p0_a0@double_p0_a0
.export _f64_mul

.proc _f64_mul
    lda #$1e
    sta arg0
    jsr _pushN

    ; Save incoming ptr0/ptr1/ptr2 below the generated operator call frame.
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

    ; Copy lhs to the generated operator's first stack argument.
    ldy #0
    lda (ptr3), y
    sta ptr0
    iny
    lda (ptr3), y
    sta ptr0+1
    lda #$08
    sta arg0
    jsr _sp2ptr1m
    lda #$08
    sta arg0
    jsr _cpyN

    ; Copy rhs to the generated operator's second stack argument.
    ldy #2
    lda (ptr3), y
    sta ptr0
    iny
    lda (ptr3), y
    sta ptr0+1
    lda #$10
    sta arg0
    jsr _sp2ptr1m
    lda #$08
    sta arg0
    jsr _cpyN

    ; Call the generated exact operator.  It uses fp as its frame pointer.
    lda fp+1
    pha
    lda fp
    pha
    jsr ?@op_mul@double_p0_a0@double_p0_a0
    pla
    sta fp
    pla
    sta fp+1

    ; Copy return value to the original destination pointer.
    ; The generated operator may clobber ptr3, so recover our saved-pointer base.
    lda #$1e
    sta arg0
    jsr _sp2ptr3m
    lda #$18
    sta arg0
    jsr _sp2ptr0m
    ldy #4
    lda (ptr3), y
    sta ptr1
    iny
    lda (ptr3), y
    sta ptr1+1
    lda #$08
    sta arg0
    jsr _cpyN

    lda #$1e
    sta arg0
    jsr _popN
    rts
.endproc
