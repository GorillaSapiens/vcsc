; generated builtin float assembly, checked in under libraries/float/asm
; fixed-format builtin float support, direct assembly template
.include "nlib.inc"

; imports
.import ?@op_add@float_p0_a0@float_p0_a0
.import _pushN
.import _fp2ptr0m
.import _popN
.import _fp2ptr1m
.import _sp2ptr0m
.import _sp2ptr1m

; exports
.export __abimeta$V1$function$declaration$?@op_add@float_p0_a0@float_p0_a0$summary$paramsQ3D2Q3BvariadicQ3D0$parametersQ3D2Q20variadicQ3Dno
__abimeta$V1$function$declaration$?@op_add@float_p0_a0@float_p0_a0$summary$paramsQ3D2Q3BvariadicQ3D0$parametersQ3D2Q20variadicQ3Dno = 0
.export __abimeta$V1$function$declaration$?@op_add@float_p0_a0@float_p0_a0$return$modeQ3Dreturn_valueQ3BfloatQ28szQ3D4Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D8Q3BexactopsQ3D1Q29$return_valueQ20float_likeQ28sizeQ3D4Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D8Q2CQ20exactopsQ29
__abimeta$V1$function$declaration$?@op_add@float_p0_a0@float_p0_a0$return$modeQ3Dreturn_valueQ3BfloatQ28szQ3D4Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D8Q3BexactopsQ3D1Q29$return_valueQ20float_likeQ28sizeQ3D4Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D8Q2CQ20exactopsQ29 = 0
.export __abimeta$V1$function$declaration$?@op_add@float_p0_a0@float_p0_a0$param0$modeQ3Dstack_valueQ3BfloatQ28szQ3D4Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D8Q3BexactopsQ3D1Q29$stack_valueQ20float_likeQ28sizeQ3D4Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D8Q2CQ20exactopsQ29
__abimeta$V1$function$declaration$?@op_add@float_p0_a0@float_p0_a0$param0$modeQ3Dstack_valueQ3BfloatQ28szQ3D4Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D8Q3BexactopsQ3D1Q29$stack_valueQ20float_likeQ28sizeQ3D4Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D8Q2CQ20exactopsQ29 = 0
.export __abimeta$V1$function$declaration$?@op_add@float_p0_a0@float_p0_a0$param1$modeQ3Dstack_valueQ3BfloatQ28szQ3D4Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D8Q3BexactopsQ3D1Q29$stack_valueQ20float_likeQ28sizeQ3D4Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D8Q2CQ20exactopsQ29
__abimeta$V1$function$declaration$?@op_add@float_p0_a0@float_p0_a0$param1$modeQ3Dstack_valueQ3BfloatQ28szQ3D4Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D8Q3BexactopsQ3D1Q29$stack_valueQ20float_likeQ28sizeQ3D4Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D8Q2CQ20exactopsQ29 = 0
.export ?@op_sub@float_p0_a0@float_p0_a0
.export __abimeta$V1$function$definition$?@op_sub@float_p0_a0@float_p0_a0$summary$paramsQ3D2Q3BvariadicQ3D0$parametersQ3D2Q20variadicQ3Dno
__abimeta$V1$function$definition$?@op_sub@float_p0_a0@float_p0_a0$summary$paramsQ3D2Q3BvariadicQ3D0$parametersQ3D2Q20variadicQ3Dno = 0
.export __abimeta$V1$function$definition$?@op_sub@float_p0_a0@float_p0_a0$return$modeQ3Dreturn_valueQ3BfloatQ28szQ3D4Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D8Q3BexactopsQ3D1Q29$return_valueQ20float_likeQ28sizeQ3D4Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D8Q2CQ20exactopsQ29
__abimeta$V1$function$definition$?@op_sub@float_p0_a0@float_p0_a0$return$modeQ3Dreturn_valueQ3BfloatQ28szQ3D4Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D8Q3BexactopsQ3D1Q29$return_valueQ20float_likeQ28sizeQ3D4Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D8Q2CQ20exactopsQ29 = 0
.export __abimeta$V1$function$definition$?@op_sub@float_p0_a0@float_p0_a0$param0$modeQ3Dstack_valueQ3BfloatQ28szQ3D4Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D8Q3BexactopsQ3D1Q29$stack_valueQ20float_likeQ28sizeQ3D4Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D8Q2CQ20exactopsQ29
__abimeta$V1$function$definition$?@op_sub@float_p0_a0@float_p0_a0$param0$modeQ3Dstack_valueQ3BfloatQ28szQ3D4Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D8Q3BexactopsQ3D1Q29$stack_valueQ20float_likeQ28sizeQ3D4Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D8Q2CQ20exactopsQ29 = 0
.export __abimeta$V1$function$definition$?@op_sub@float_p0_a0@float_p0_a0$param1$modeQ3Dstack_valueQ3BfloatQ28szQ3D4Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D8Q3BexactopsQ3D1Q29$stack_valueQ20float_likeQ28sizeQ3D4Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D8Q2CQ20exactopsQ29
__abimeta$V1$function$definition$?@op_sub@float_p0_a0@float_p0_a0$param1$modeQ3Dstack_valueQ3BfloatQ28szQ3D4Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D8Q3BexactopsQ3D1Q29$stack_valueQ20float_likeQ28sizeQ3D4Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D8Q2CQ20exactopsQ29 = 0
.export __sbpmeta$E$?@op_sub@float_p0_a0@float_p0_a0$?@op_add@float_p0_a0@float_p0_a0
__sbpmeta$E$?@op_sub@float_p0_a0@float_p0_a0$?@op_add@float_p0_a0@float_p0_a0 = 0

.segment "ZEROPAGE"

.segment "ZEROPAGE"

.segment "BSS"

.segment "DATA"

.segment "RODATA"

.segment "CODE"
.proc ?@op_sub@float_p0_a0@float_p0_a0
    lda sp+1
    sta fp+1
    lda sp
    sta fp
    lda #$0c
    sta arg0
    jsr _pushN
    lda #$04
    sta arg0
    jsr _fp2ptr0m
    ldy #0
    lda (ptr0),y
    ldy #8
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #9
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #10
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #11
    sta (fp),y
    lda #$08
    sta arg0
    jsr _pushN
    lda #$08
    sta arg0
    jsr _fp2ptr0m
    ldy #0
    lda (ptr0),y
    ldy #16
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #17
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #18
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #19
    sta (fp),y
    lda fp+1
    pha
    lda fp
    pha
    jsr _nlf_float_neg
    pla
    sta fp
    pla
    sta fp+1
    ldy #12
    lda (fp),y
    ldy #4
    sta (fp),y
    ldy #13
    lda (fp),y
    ldy #5
    sta (fp),y
    ldy #14
    lda (fp),y
    ldy #6
    sta (fp),y
    ldy #15
    lda (fp),y
    ldy #7
    sta (fp),y
    lda #$08
    sta arg0
    jsr _popN
    lda fp+1
    pha
    lda fp
    pha
    jsr ?@op_add@float_p0_a0@float_p0_a0
    pla
    sta fp
    pla
    sta fp+1
    lda #$0c
    sta arg0
    jsr _fp2ptr1m
    ldy #0
    lda (fp),y
    sta (ptr1),y
    ldy #1
    lda (fp),y
    sta (ptr1),y
    ldy #2
    lda (fp),y
    sta (ptr1),y
    ldy #3
    lda (fp),y
    sta (ptr1),y
    lda #$0c
    sta arg0
    jsr _popN
@fini:
    rts
.endproc


.proc _nlf_float_neg
    lda #$04
    sta arg0
    jsr _sp2ptr0m
    lda #$08
    sta arg0
    jsr _sp2ptr1m
    ldy #0
@copy_loop:
    lda (ptr0),y
    sta (ptr1),y
    iny
    cpy #$04
    bne @copy_loop
    ldy #$03
    lda (ptr1),y
    eor #$80
    sta (ptr1),y
    rts
.endproc
