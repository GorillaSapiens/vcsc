.segmentdef "CODE", $8000, $8000
.segmentdef "RODATA", $8000 + CODE_SIZE, $8000 - CODE_SIZE
.segmentdef "BSS", $80, $80
.segmentdef "DATA", $80 + BSS_SIZE, $80 - BSS_SIZE

.global main
.export main

.segment "BSS"
.res 5

.segment "DATA"
.word $1234

.segment "RODATA"
.asciiz "fnord"

.segment "CODE"
main:
    rts
