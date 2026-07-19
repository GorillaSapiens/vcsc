; vcsc-zeropage.s

.exportzp _vcsc_fp
.exportzp _vcsc_arg0, _vcsc_arg1
.exportzp _vcsc_ptr0, _vcsc_ptr1, _vcsc_ptr2, _vcsc_ptr3
.exportzp _vcsc_tmp0, _vcsc_tmp1, _vcsc_tmp2, _vcsc_tmp3, _vcsc_tmp4, _vcsc_tmp5

.segment "ZEROPAGE"

; 18 bytes total

_vcsc_fp:    .res 2 ; the frame pointer

_vcsc_arg0:  .res 1 ; byte argument 0 ; size
_vcsc_arg1:  .res 1 ; byte argument 1 ; shift / result

_vcsc_ptr0:  .res 2 ; pointer to argument 0
_vcsc_ptr1:  .res 2 ; pointer to argument 1
_vcsc_ptr2:  .res 2 ; pointer to argument 2
_vcsc_ptr3:  .res 2 ; pointer to argument 3
_vcsc_tmp0:  .res 1 ; temporary scratch register 0
_vcsc_tmp1:  .res 1 ; temporary scratch register 1
_vcsc_tmp2:  .res 1 ; temporary scratch register 2
_vcsc_tmp3:  .res 1 ; temporary scratch register 3
_vcsc_tmp4:  .res 1 ; temporary scratch register 4
_vcsc_tmp5:  .res 1 ; temporary scratch register 5
