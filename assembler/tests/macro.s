MACRO delay_x count
   LDX #count
@loop:
   DEX
   BNE @loop
ENDM

start:
   delay_x 10
   delay_x 20
