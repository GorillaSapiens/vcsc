; This file is covered under CC0-1.0. See libraries/LICENSE.txt.
;
; Deliberate vcsc-as ports of the only retained macros selected by the minimal
; unbanked/non-Superchip multisprite profile.

MACRO SLEEP duration
   .if duration < 2
      .error "MACRO ERROR: 'SLEEP': Duration must be > 1"
   .endif
   .if duration & 1
      BIT VSYNC
      .repeat {duration - 3} / 2
         NOP
      .endrepeat
   .else
      .repeat duration / 2
         NOP
      .endrepeat
   .endif
ENDM

MACRO RETURN
   RTS
ENDM
