; handler.s - default IRQ and NMI handlers

.include "nlib.inc"

.proc _handle_nmi
    rts
.endproc

.proc _handle_irq
    rts
.endproc
