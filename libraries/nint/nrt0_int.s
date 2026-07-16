; nrt0_int.s

.global __nmi
.global __irqbrk

.export __nmi
.export __irqbrk

.import handle_irq
.import handle_nmi

.segment "CODE"

; Ordinary n function calls treat A, P, X, and Y as caller-clobbered.
; Interrupt entry is different: the interrupted code did not agree to that ABI,
; so the runtime saves and restores the full machine state that C-visible code
; might have been using before it vectors to the language-level handlers.

__nmi:
   php
   pha
   txa
   pha
   tya
   pha

   jsr handle_nmi

   jmp __nmi_irqbrk_common

__irqbrk:
   php
   pha
   txa
   pha
   tya
   pha

   jsr handle_irq

__nmi_irqbrk_common:
   pla
   tay
   pla
   tax
   pla
   plp
   rti
