; nrt0.s

.global __reset

.export __reset

.import main

.import __copy_table
.import __zero_table
.import __stack_start
.import __init_table

.include "../nlib.inc"

.segment "CODE"

__reset:
   sei
   cld

   ; hardware stack at $01FF downward
   ldx #$ff
   txs

   ; ptr0 = __copy_table
   lda #<__copy_table
   sta ptr0
   lda #>__copy_table
   sta ptr0+1

_copy_record:
   ldy #0
   lda (ptr0),y
   sta ptr1
   iny
   lda (ptr0),y
   sta ptr1+1
   iny
   lda (ptr0),y
   sta ptr2
   iny
   lda (ptr0),y
   sta ptr2+1
   iny
   lda (ptr0),y
   sta arg0
   iny
   lda (ptr0),y
   sta arg0+1
   lda arg0
   ora arg0+1
   beq _zero_setup

_copy_loop:
   ldy #0
   lda (ptr1),y
   sta (ptr2),y

   inc ptr1
   bne _copy_dst
   inc ptr1+1

_copy_dst:
   inc ptr2
   bne _copy_count
   inc ptr2+1

_copy_count:
   lda arg0
   bne _copy_dec_lo
   dec arg0+1
_copy_dec_lo:
   dec arg0
   lda arg0
   ora arg0+1
   bne _copy_loop

   clc
   lda ptr0
   adc #6
   sta ptr0
   bcc _copy_record
   inc ptr0+1
   jmp _copy_record

_zero_setup:
   ; ptr0 = __zero_table
   lda #<__zero_table
   sta ptr0
   lda #>__zero_table
   sta ptr0+1

_zero_record:
   ldy #0
   lda (ptr0),y
   sta ptr1
   iny
   lda (ptr0),y
   sta ptr1+1
   iny
   lda (ptr0),y
   sta arg0
   iny
   lda (ptr0),y
   sta arg0+1
   lda arg0
   ora arg0+1
   beq _start_init

_zero_loop:
   ldy #0
   lda #0
   sta (ptr1),y

   inc ptr1
   bne _zero_count
   inc ptr1+1

_zero_count:
   lda arg0
   bne _zero_dec_lo
   dec arg0+1
_zero_dec_lo:
   dec arg0
   lda arg0
   ora arg0+1
   bne _zero_loop

   clc
   lda ptr0
   adc #4
   sta ptr0
   bcc _zero_record
   inc ptr0+1
   jmp _zero_record

_start_init:
   ; argument stack grows upward from linker-selected stack start
   lda #<__stack_start
   sta sp
   sta fp
   lda #>__stack_start
   sta sp+1
   sta fp+1

   lda #<__init_table
   sta ptr0
   lda #>__init_table
   sta ptr0+1

_call_init_loop:
   ldy #0
   lda (ptr0),y
   sta ptr1
   iny
   lda (ptr0),y
   sta ptr1+1
   lda ptr1
   ora ptr1+1
   beq _start_main
   lda ptr0
   pha
   lda ptr0+1
   pha
   jsr _call_init_trampoline
   pla
   sta ptr0+1
   pla
   sta ptr0
   clc
   lda ptr0
   adc #2
   sta ptr0
   bcc _call_init_loop
   inc ptr0+1
   jmp _call_init_loop

_call_init_trampoline:
   jmp (ptr1)

_start_main:
   jsr main

_forever:
   jmp _forever
