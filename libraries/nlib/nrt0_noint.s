; nrt0.s

.weak __nmi
.weak __irqbrk

.global __nmi
.global __irqbrk

.export __nmi
.export __irqbrk

.import _handle_irq
.import _handle_nmi

.segment "CODE"

__nmi:
__irqbrk:
   rti
