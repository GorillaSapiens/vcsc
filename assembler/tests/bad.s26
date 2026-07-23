; 6502 parser torture test
; A few intentionally illegal addressing modes.

; Intentionally illegal addressing modes for opcode legality checks
illegal_tests:
   JMP #$10
   STA ($44)
   LDX $1234,X
   ROR ($20),Y
   JSR ($1234)
   STY $1234,Y
   CPY ($44,X)
   BIT #$01
   LDA (1 + 2)
   LDA (label1 + 4)
   LDA ((1 + 2) * 3)

   LDA (target + 3),X
