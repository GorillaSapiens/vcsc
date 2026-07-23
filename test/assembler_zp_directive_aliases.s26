.segment "ZEROPAGE"
.zpexport foo
.zpimport bar
foo:
   .byte $11

.segment "CODE"
.proc demo
   lda foo
   lda bar
   rts
.endproc
