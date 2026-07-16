; nlib_zeropage.s

.exportzp _nl_sp, _nl_fp
.exportzp _nl_arg0, _nl_arg1
.exportzp _nl_ptr0, _nl_ptr1, _nl_ptr2, _nl_ptr3, _nl_sbrk
.exportzp _nl_tmp0, _nl_tmp1, _nl_tmp2, _nl_tmp3, _nl_tmp4, _nl_tmp5

.segment "ZEROPAGE"

; 22 bytes total

_nl_sp:    .res 2 ; the argument stack pointer
_nl_fp:    .res 2 ; the frame pointer

_nl_arg0:  .res 1 ; byte argument 0 ; size
_nl_arg1:  .res 1 ; byte argument 1 ; shift / result

_nl_ptr0:  .res 2 ; pointer to argument 0
_nl_ptr1:  .res 2 ; pointer to argument 1
_nl_ptr2:  .res 2 ; pointer to argument 2
_nl_ptr3:  .res 2 ; pointer to argument 3
_nl_sbrk:  .res 2 ; downward-growing sbrk pointer

_nl_tmp0:  .res 1 ; temporary scratch register 0
_nl_tmp1:  .res 1 ; temporary scratch register 1
_nl_tmp2:  .res 1 ; temporary scratch register 2
_nl_tmp3:  .res 1 ; temporary scratch register 3
_nl_tmp4:  .res 1 ; temporary scratch register 4
_nl_tmp5:  .res 1 ; temporary scratch register 5
