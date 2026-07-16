.org $8000

start:
   NOP
buf:
   .res 4
after:
   .byte $AA
   .word buf, after
