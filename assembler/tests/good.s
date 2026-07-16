; 6502 parser torture test
; Mix of legal syntax, grouped expressions, labels, directives,
; and comments.

.org $0200

start:
   NOP
   CLC
   CLD
   CLI
   CLV
   DEX
   DEY
   INX
   INY
   PHA
   PHP
   PLA
   PLP
   RTI
   RTS
   SEC
   SED
   SEI
   TAX
   TAY
   TSX
   TXA
   TXS
   TYA
   BRK

accum_tests:
   ASL A
   LSR A
   ROL A
   ROR A

   ASL
   LSR
   ROL
   ROR

imm_tests:
   LDA #$10
   LDX #$20
   LDY #$30
   ADC #1
   AND #%10101010
   CMP #'A
   CPX #10
   CPY #$7F
   EOR #<target
   ORA #>target
   SBC #-5

zp_abs_tests:
   LDA $44
   LDA $4400
   STA $20
   STA $2000
   BIT $33
   BIT $1234
   JMP $3456
   JSR target
   INC $40
   INC $4000
   DEC $50
   DEC $5000
   CPX $60
   CPX $6000
   CPY $70
   CPY $7000

indexed_tests:
   LDA $44,X
   LDA $4400,X
   LDA $44,Y
   LDA $4400,Y
   LDX $55,Y
   LDX $5500,Y
   LDY $66,X
   LDY $6600,X
   STA $77,X
   STA $7700,X
   STA $88,Y
   STA $8800,Y
   STX $99,Y
   ;STX $9900,Y
   STY $AA,X
   ;STY $AA00,X
   ADC $12,X
   ADC $1234,X
   ADC $13,Y
   ADC $1334,Y

indirect_tests:
   JMP ($1234)
   LDA ($20,X)
   LDA ($21),Y
   ADC ($22,X)
   ADC ($23),Y
   AND ($24,X)
   AND ($25),Y
   CMP ($26,X)
   CMP ($27),Y
   EOR ($28,X)
   EOR ($29),Y
   ORA ($2A,X)
   ORA ($2B),Y
   SBC ($2C,X)
   SBC ($2D),Y
   STA ($2E,X)
   STA ($2F),Y

branch_tests:
   BCC expr_tests
   BCS expr_tests
   BEQ expr_tests
   BMI expr_tests
   BNE expr_tests
   BPL expr_tests
   BVC expr_tests
   BVS expr_tests

expr_tests:
   LDA <target
   LDA >target
   ;LDA (target + 4),Y
   LDA -{1 + 2}
   LDA #{1 + 2}
   LDA #{3 * 4 + 1}
   LDA #<{$1234 + 2}
   LDA #>{$1234 + 2}

directive_tests:
   .org $8000
   .byte $01, $02, $03, 'A, 'B, 'C
   .word $1234, target, {target + 2}
   .text "HELLO"
   .ascii "WORLD", 13, 10
   .byte $01, $02, $03, 'A', 'B', 'C'

label1:
target:
   NOP

comment_tests:
   LDA $44      ; zero-page
   LDA $4400    ; absolute
   LDA ($20,X)  ; indexed indirect
   LDA ($21),Y  ; indirect indexed

