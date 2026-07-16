.org $FF00
LDA #0
LDX #<data
LDY #>data
JSR $FFFF
JMP $FF00

data:
.asciiz "Hello, World!\n"
.ascii  "test1"
.text   "test2"

.org $FFFA
.word $FF00
.word $FF00
.word $FF00
