; sbrk.asm - simple downward-growing allocator
;
; __init_sbrk seeds the heap pointer to the top free byte of the RAM arena
; shared with the upward-growing N argument stack.
;
; _sbrk uses the ordinary external-function ABI.
; After mirroring the normal function prologue (fp := sp):
;   return value lives at fp-4
;   first int argument lives at fp-2
;
; Input:
;   first int argument - requested byte count (unsigned 16-bit)
; Returns:
;   pointer to the base address of the allocated block, or 0 on failure
;   size 0 returns the current heap top pointer without modifying it
;
; This only prevents the heap from crossing the current argument stack top.
; Future stack growth is still the caller/runtime's problem.

.include "nlib.inc"

.proc __init_sbrk
    lda #<__stack_top
    sta sbrk
    lda #>__stack_top
    sta sbrk+1
    rts
.endproc

.proc _sbrk
    lda sp+1
    sta fp+1
    lda sp
    sta fp

    lda #2
    sta arg0
    jsr _fp2ptr0m
    lda #4
    sta arg0
    jsr _fp2ptr1m

    ldy #0
    lda (ptr0), y
    sta tmp0
    iny
    lda (ptr0), y
    sta tmp1

    lda tmp0
    ora tmp1
    beq @return_current

    sec
    lda tmp0
    sbc #1
    sta tmp0
    lda tmp1
    sbc #0
    sta tmp1

    sec
    lda sbrk
    sbc tmp0
    sta ptr2
    lda sbrk+1
    sbc tmp1
    sta ptr2+1
    bcc @fail

    lda ptr2+1
    cmp sp+1
    bcc @fail
    bne @commit
    lda ptr2
    cmp sp
    bcc @fail

@commit:
    sec
    lda ptr2
    sbc #1
    sta sbrk
    lda ptr2+1
    sbc #0
    sta sbrk+1

    ldy #0
    lda ptr2
    sta (ptr1), y
    iny
    lda ptr2+1
    sta (ptr1), y
    rts

    ; archive-selection anchor: pulling _sbrk should also pull __init_sbrk.
    lda #<__init_sbrk

@return_current:
    ldy #0
    lda sbrk
    sta (ptr1), y
    iny
    lda sbrk+1
    sta (ptr1), y
    rts

@fail:
    ldy #0
    lda #0
    sta (ptr1), y
    iny
    sta (ptr1), y
    rts
.endproc
