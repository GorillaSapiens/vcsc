; rem.asm - Remainder-only division helpers

.include "nlib.inc"

.proc _remNle
    jmp _divNle
.endproc

.proc _remNbe
    jmp _divNbe
.endproc
