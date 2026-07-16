.global __reset
.global __nmi
.global __irqbrk
.global counter
.global message

.export __reset
.export __nmi
.export __irqbrk
.export counter
.export message

.proc __reset
   LDX #$FF
   TXS

   LDA #0
   STA counter

loop:
   INC counter
   JMP loop
.endproc

.proc __nmi
   RTI
.endproc

.proc __irqbrk
   RTI
.endproc

counter:
   .byte 0

message:
   .asciiz "Hello from n65ld!\n"

scratch:
   .res 16
