; stacksess.asm - Stack access functions
;
; these all transfer fp to ptrN, and add arg0

.include "nlib.inc"

.proc _fp2ptr0p
    clc
    lda fp
    adc arg0
    sta ptr0
    lda fp+1
    adc #0
    sta ptr0+1
    rts
.endproc

.proc _fp2ptr1p
    clc
    lda fp
    adc arg0
    sta ptr1
    lda fp+1
    adc #0
    sta ptr1+1
    rts
.endproc

.proc _fp2ptr2p
    clc
    lda fp
    adc arg0
    sta ptr2
    lda fp+1
    adc #0
    sta ptr2+1
    rts
.endproc

.proc _fp2ptr3p
    clc
    lda fp
    adc arg0
    sta ptr3
    lda fp+1
    adc #0
    sta ptr3+1
    rts
.endproc

.proc _fp2ptr0m
    sec
    lda fp
    sbc arg0
    sta ptr0
    lda fp+1
    sbc #0
    sta ptr0+1
    rts
.endproc

.proc _fp2ptr1m
    sec
    lda fp
    sbc arg0
    sta ptr1
    lda fp+1
    sbc #0
    sta ptr1+1
    rts
.endproc

.proc _fp2ptr2m
    sec
    lda fp
    sbc arg0
    sta ptr2
    lda fp+1
    sbc #0
    sta ptr2+1
    rts
.endproc

.proc _fp2ptr3m
    sec
    lda fp
    sbc arg0
    sta ptr3
    lda fp+1
    sbc #0
    sta ptr3+1
    rts
.endproc
