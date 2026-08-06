; This file is covered under CC0-1.0. See libraries/LICENSE.txt.

; memory.asm - byte-buffer helpers used only for objects wider than four bytes
;
; Scalar copies, fills, and integer extension are emitted directly by vcsc-cc1.
; These helpers remain for aggregate initialization and copying.

.include "vcsc-runtime.inc"

.proc _copy_bytes
    ldx arg0
    ldy #0
@loop:
    lda (ptr0), y
    sta (ptr1), y
    iny
    dex
    bne @loop
    rts
.endproc

.proc _fill_bytes
    ldx arg0
    beq @done
    ldy #0
    lda arg1
@loop:
    sta (ptr1), y
    iny
    dex
    bne @loop
@done:
    rts
.endproc

.proc _zero_bytes
    lda #0
    sta arg1
    jmp _fill_bytes
.endproc
