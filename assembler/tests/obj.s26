.global foo
.export foo
.import data2

.proc foo
LDA #0
LDX #<data
LDY #>data
JSR $FFFF
JMP $FF00
LDX #<data2
LDY #>data2
.endproc

data:
.asciiz "Hello, World!\n"
.ascii  "test1"
.text   "test2"
