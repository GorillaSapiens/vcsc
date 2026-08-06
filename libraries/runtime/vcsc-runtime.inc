; This file is covered under CC0-1.0. See libraries/LICENSE.txt.

; vcsc-runtime.inc
;
; Source aliases only.  Each assembly object must import the workspace symbols
; it actually references so archive selection can omit unused RIOT RAM cells.

.def arg0 _vcsc_arg0
.def arg1 _vcsc_arg1
.def ptr0 _vcsc_ptr0
.def ptr1 _vcsc_ptr1
.def ptr2 _vcsc_ptr2
