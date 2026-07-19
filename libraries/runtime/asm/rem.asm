; rem.asm - Remainder-only division helpers

.include "vcsc-runtime.inc"

.proc _remNle
    jmp _divNle
.endproc

