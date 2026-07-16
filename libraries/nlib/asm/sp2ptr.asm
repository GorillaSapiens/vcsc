; stacksess.asm - Stack access functions
;
; these all transfer sp to ptrN, and add arg0

.include "nlib.inc"

.proc _sp2ptr0p
    clc
    lda sp
    adc arg0
    sta ptr0
    lda sp+1
    adc #0
    sta ptr0+1
    rts
.endproc

.proc _sp2ptr1p
    clc
    lda sp
    adc arg0
    sta ptr1
    lda sp+1
    adc #0
    sta ptr1+1
    rts
.endproc

.proc _sp2ptr2p
    clc
    lda sp
    adc arg0
    sta ptr2
    lda sp+1
    adc #0
    sta ptr2+1
    rts
.endproc

.proc _sp2ptr3p
    clc
    lda sp
    adc arg0
    sta ptr3
    lda sp+1
    adc #0
    sta ptr3+1
    rts
.endproc

.proc _sp2ptr0m
    sec
    lda sp
    sbc arg0
    sta ptr0
    lda sp+1
    sbc #0
    sta ptr0+1
    rts
.endproc

.proc _sp2ptr1m
    sec
    lda sp
    sbc arg0
    sta ptr1
    lda sp+1
    sbc #0
    sta ptr1+1
    rts
.endproc

.proc _sp2ptr2m
    sec
    lda sp
    sbc arg0
    sta ptr2
    lda sp+1
    sbc #0
    sta ptr2+1
    rts
.endproc

.proc _sp2ptr3m
    sec
    lda sp
    sbc arg0
    sta ptr3
    lda sp+1
    sbc #0
    sta ptr3+1
    rts
.endproc
