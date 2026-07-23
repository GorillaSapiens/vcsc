.segmentdef "ZEROPAGE", $0000, $0100
.segmentdef "CODE",     $8000, $2000
.segmentdef "RODATA",   CODE_END, $2000 - CODE_SIZE

.global start
.export start

.segment "CODE"
start:
   LDA #1
   RTS

.segment "RODATA"
msg:
   .asciiz "hello"
