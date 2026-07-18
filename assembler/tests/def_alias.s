.importzp _runtime_zp
.def work _runtime_zp

.segment "CODE"
.proc demo
   lda work
   rts
.endproc
