; generated builtin float assembly, checked in under libraries/float/asm
; fixed-format builtin float support, direct assembly template
.include "nlib.inc"

; imports
.import nlf_half_a
.import nlf_half_b
.import nlf_half_r
.import nlf_half_wide_a
.import nlf_half_wide_b
.import nlf_half_wide_p
.import nlf_half_wide_t
.import nlf_half_mant_ll
.import nlf_half_exp_a
.import nlf_half_exp_b
.import nlf_half_sign_out
.import nlf_half_sig_a
.import nlf_half_sig_b
.import nlf_half_sig_out
.import _pushN
.import _fp2ptr1p
.import _zeroN
.import _cpyN
.import _fp2ptr0p
.import _eqN
.import _popN
.import _fp2ptr2p
.import _bit_xorN
.import _bit_orN
.import _copysxNle
.import _lslNle
.import _fp2ptr3p
.import _divNle
.import _mulNle
.import _ltNsle
.import _ltNule
.import _bit_andN
.import _lsrNle
.import _leNsle

; exports
.export __abimeta$V1$global$declaration$nlf_half_a$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D2Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D2Q3AfloatQ28szQ3D2Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D5Q3BexactopsQ3D1Q29Q2CoffQ3D0Q3AstoreQ3D2Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D2Q3AarrayQ28nQ3D2Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q2CoffQ3D0Q3AstoreQ3D2Q3AstructQ232Q28szQ3D2Q3BmembersQ3DQ5BoffQ3D0Q2E0Q3AwQ3D10Q3AstoreQ3D2Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D1Q2E2Q3AwQ3D5Q3AstoreQ3D1Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D1Q2E7Q3AwQ3D1Q3AstoreQ3D1Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q5DQ29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D2Q29Q7BvalueQ20Q400Q20storageQ3D2Q20float_likeQ28sizeQ3D2Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D5Q2CQ20exactopsQ29Q3BQ20rawQ20Q400Q20storageQ3D2Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D2Q20arrayQ5B2Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q3BQ20bitsQ20Q400Q20storageQ3D2Q20structQ232Q28sizeQ3D2Q29Q7BmantissaQ20Q400Q2E0Q20bitfieldQ28widthQ3D10Q2CQ20storageQ3D2Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20exponentQ20Q401Q2E2Q20bitfieldQ28widthQ3D5Q2CQ20storageQ3D1Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20signQ20Q401Q2E7Q20bitfieldQ28widthQ3D1Q2CQ20storageQ3D1Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q7DQ7D
__abimeta$V1$global$declaration$nlf_half_a$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D2Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D2Q3AfloatQ28szQ3D2Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D5Q3BexactopsQ3D1Q29Q2CoffQ3D0Q3AstoreQ3D2Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D2Q3AarrayQ28nQ3D2Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q2CoffQ3D0Q3AstoreQ3D2Q3AstructQ232Q28szQ3D2Q3BmembersQ3DQ5BoffQ3D0Q2E0Q3AwQ3D10Q3AstoreQ3D2Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D1Q2E2Q3AwQ3D5Q3AstoreQ3D1Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D1Q2E7Q3AwQ3D1Q3AstoreQ3D1Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q5DQ29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D2Q29Q7BvalueQ20Q400Q20storageQ3D2Q20float_likeQ28sizeQ3D2Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D5Q2CQ20exactopsQ29Q3BQ20rawQ20Q400Q20storageQ3D2Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D2Q20arrayQ5B2Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q3BQ20bitsQ20Q400Q20storageQ3D2Q20structQ232Q28sizeQ3D2Q29Q7BmantissaQ20Q400Q2E0Q20bitfieldQ28widthQ3D10Q2CQ20storageQ3D2Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20exponentQ20Q401Q2E2Q20bitfieldQ28widthQ3D5Q2CQ20storageQ3D1Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20signQ20Q401Q2E7Q20bitfieldQ28widthQ3D1Q2CQ20storageQ3D1Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q7DQ7D = 0
.export __abimeta$V1$global$declaration$nlf_half_b$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D2Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D2Q3AfloatQ28szQ3D2Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D5Q3BexactopsQ3D1Q29Q2CoffQ3D0Q3AstoreQ3D2Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D2Q3AarrayQ28nQ3D2Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q2CoffQ3D0Q3AstoreQ3D2Q3AstructQ232Q28szQ3D2Q3BmembersQ3DQ5BoffQ3D0Q2E0Q3AwQ3D10Q3AstoreQ3D2Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D1Q2E2Q3AwQ3D5Q3AstoreQ3D1Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D1Q2E7Q3AwQ3D1Q3AstoreQ3D1Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q5DQ29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D2Q29Q7BvalueQ20Q400Q20storageQ3D2Q20float_likeQ28sizeQ3D2Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D5Q2CQ20exactopsQ29Q3BQ20rawQ20Q400Q20storageQ3D2Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D2Q20arrayQ5B2Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q3BQ20bitsQ20Q400Q20storageQ3D2Q20structQ232Q28sizeQ3D2Q29Q7BmantissaQ20Q400Q2E0Q20bitfieldQ28widthQ3D10Q2CQ20storageQ3D2Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20exponentQ20Q401Q2E2Q20bitfieldQ28widthQ3D5Q2CQ20storageQ3D1Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20signQ20Q401Q2E7Q20bitfieldQ28widthQ3D1Q2CQ20storageQ3D1Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q7DQ7D
__abimeta$V1$global$declaration$nlf_half_b$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D2Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D2Q3AfloatQ28szQ3D2Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D5Q3BexactopsQ3D1Q29Q2CoffQ3D0Q3AstoreQ3D2Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D2Q3AarrayQ28nQ3D2Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q2CoffQ3D0Q3AstoreQ3D2Q3AstructQ232Q28szQ3D2Q3BmembersQ3DQ5BoffQ3D0Q2E0Q3AwQ3D10Q3AstoreQ3D2Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D1Q2E2Q3AwQ3D5Q3AstoreQ3D1Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D1Q2E7Q3AwQ3D1Q3AstoreQ3D1Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q5DQ29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D2Q29Q7BvalueQ20Q400Q20storageQ3D2Q20float_likeQ28sizeQ3D2Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D5Q2CQ20exactopsQ29Q3BQ20rawQ20Q400Q20storageQ3D2Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D2Q20arrayQ5B2Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q3BQ20bitsQ20Q400Q20storageQ3D2Q20structQ232Q28sizeQ3D2Q29Q7BmantissaQ20Q400Q2E0Q20bitfieldQ28widthQ3D10Q2CQ20storageQ3D2Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20exponentQ20Q401Q2E2Q20bitfieldQ28widthQ3D5Q2CQ20storageQ3D1Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20signQ20Q401Q2E7Q20bitfieldQ28widthQ3D1Q2CQ20storageQ3D1Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q7DQ7D = 0
.export __abimeta$V1$global$declaration$nlf_half_r$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D2Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D2Q3AfloatQ28szQ3D2Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D5Q3BexactopsQ3D1Q29Q2CoffQ3D0Q3AstoreQ3D2Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D2Q3AarrayQ28nQ3D2Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q2CoffQ3D0Q3AstoreQ3D2Q3AstructQ232Q28szQ3D2Q3BmembersQ3DQ5BoffQ3D0Q2E0Q3AwQ3D10Q3AstoreQ3D2Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D1Q2E2Q3AwQ3D5Q3AstoreQ3D1Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D1Q2E7Q3AwQ3D1Q3AstoreQ3D1Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q5DQ29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D2Q29Q7BvalueQ20Q400Q20storageQ3D2Q20float_likeQ28sizeQ3D2Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D5Q2CQ20exactopsQ29Q3BQ20rawQ20Q400Q20storageQ3D2Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D2Q20arrayQ5B2Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q3BQ20bitsQ20Q400Q20storageQ3D2Q20structQ232Q28sizeQ3D2Q29Q7BmantissaQ20Q400Q2E0Q20bitfieldQ28widthQ3D10Q2CQ20storageQ3D2Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20exponentQ20Q401Q2E2Q20bitfieldQ28widthQ3D5Q2CQ20storageQ3D1Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20signQ20Q401Q2E7Q20bitfieldQ28widthQ3D1Q2CQ20storageQ3D1Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q7DQ7D
__abimeta$V1$global$declaration$nlf_half_r$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D2Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D2Q3AfloatQ28szQ3D2Q3BstyleQ3Dieee754Q3BendQ3DlittleQ3BexpQ3D5Q3BexactopsQ3D1Q29Q2CoffQ3D0Q3AstoreQ3D2Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D2Q3AarrayQ28nQ3D2Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q2CoffQ3D0Q3AstoreQ3D2Q3AstructQ232Q28szQ3D2Q3BmembersQ3DQ5BoffQ3D0Q2E0Q3AwQ3D10Q3AstoreQ3D2Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D1Q2E2Q3AwQ3D5Q3AstoreQ3D1Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D1Q2E7Q3AwQ3D1Q3AstoreQ3D1Q3AscalarQ28szQ3D2Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q5DQ29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D2Q29Q7BvalueQ20Q400Q20storageQ3D2Q20float_likeQ28sizeQ3D2Q2CQ20styleQ3Dieee754Q2CQ20littleQ2DendianQ2CQ20expbitsQ3D5Q2CQ20exactopsQ29Q3BQ20rawQ20Q400Q20storageQ3D2Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D2Q20arrayQ5B2Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q3BQ20bitsQ20Q400Q20storageQ3D2Q20structQ232Q28sizeQ3D2Q29Q7BmantissaQ20Q400Q2E0Q20bitfieldQ28widthQ3D10Q2CQ20storageQ3D2Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20exponentQ20Q401Q2E2Q20bitfieldQ28widthQ3D5Q2CQ20storageQ3D1Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q3BQ20signQ20Q401Q2E7Q20bitfieldQ28widthQ3D1Q2CQ20storageQ3D1Q29Q20unsigned_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29Q7DQ7D = 0
.export __abimeta$V1$global$declaration$nlf_half_wide_a$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D4Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D4Q3AscalarQ28szQ3D4Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D4Q3AarrayQ28nQ3D4Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D4Q29Q7BvQ20Q400Q20storageQ3D4Q20unsigned_integerQ28sizeQ3D4Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D4Q20arrayQ5B4Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q7D
__abimeta$V1$global$declaration$nlf_half_wide_a$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D4Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D4Q3AscalarQ28szQ3D4Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D4Q3AarrayQ28nQ3D4Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D4Q29Q7BvQ20Q400Q20storageQ3D4Q20unsigned_integerQ28sizeQ3D4Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D4Q20arrayQ5B4Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q7D = 0
.export __abimeta$V1$global$declaration$nlf_half_wide_b$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D4Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D4Q3AscalarQ28szQ3D4Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D4Q3AarrayQ28nQ3D4Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D4Q29Q7BvQ20Q400Q20storageQ3D4Q20unsigned_integerQ28sizeQ3D4Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D4Q20arrayQ5B4Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q7D
__abimeta$V1$global$declaration$nlf_half_wide_b$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D4Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D4Q3AscalarQ28szQ3D4Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D4Q3AarrayQ28nQ3D4Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D4Q29Q7BvQ20Q400Q20storageQ3D4Q20unsigned_integerQ28sizeQ3D4Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D4Q20arrayQ5B4Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q7D = 0
.export __abimeta$V1$global$declaration$nlf_half_wide_p$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D4Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D4Q3AscalarQ28szQ3D4Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D4Q3AarrayQ28nQ3D4Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D4Q29Q7BvQ20Q400Q20storageQ3D4Q20unsigned_integerQ28sizeQ3D4Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D4Q20arrayQ5B4Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q7D
__abimeta$V1$global$declaration$nlf_half_wide_p$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D4Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D4Q3AscalarQ28szQ3D4Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D4Q3AarrayQ28nQ3D4Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D4Q29Q7BvQ20Q400Q20storageQ3D4Q20unsigned_integerQ28sizeQ3D4Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D4Q20arrayQ5B4Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q7D = 0
.export __abimeta$V1$global$declaration$nlf_half_wide_t$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D4Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D4Q3AscalarQ28szQ3D4Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D4Q3AarrayQ28nQ3D4Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D4Q29Q7BvQ20Q400Q20storageQ3D4Q20unsigned_integerQ28sizeQ3D4Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D4Q20arrayQ5B4Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q7D
__abimeta$V1$global$declaration$nlf_half_wide_t$object$modeQ3DmemoryQ3BunionQ231Q28szQ3D4Q3BmembersQ3DQ5BoffQ3D0Q3AstoreQ3D4Q3AscalarQ28szQ3D4Q3BkindQ3Dunsigned_intQ3BendQ3DlittleQ29Q2CoffQ3D0Q3AstoreQ3D4Q3AarrayQ28nQ3D4Q3BofQ3DscalarQ28szQ3D1Q3BkindQ3Dsigned_intQ29Q29Q5DQ29$memoryQ20unionQ231Q28sizeQ3D4Q29Q7BvQ20Q400Q20storageQ3D4Q20unsigned_integerQ28sizeQ3D4Q2CQ20littleQ2DendianQ29Q3BQ20bytesQ20Q400Q20storageQ3D4Q20arrayQ5B4Q5DQ20ofQ20signed_integerQ28sizeQ3D1Q29Q7D = 0
.export __abimeta$V1$global$declaration$nlf_half_mant_ll$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29
__abimeta$V1$global$declaration$nlf_half_mant_ll$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29 = 0
.export __abimeta$V1$global$declaration$nlf_half_exp_a$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29
__abimeta$V1$global$declaration$nlf_half_exp_a$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29 = 0
.export __abimeta$V1$global$declaration$nlf_half_exp_b$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29
__abimeta$V1$global$declaration$nlf_half_exp_b$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29 = 0
.export __abimeta$V1$global$declaration$nlf_half_sign_out$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29
__abimeta$V1$global$declaration$nlf_half_sign_out$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29 = 0
.export __abimeta$V1$global$declaration$nlf_half_sig_a$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29
__abimeta$V1$global$declaration$nlf_half_sig_a$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29 = 0
.export __abimeta$V1$global$declaration$nlf_half_sig_b$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29
__abimeta$V1$global$declaration$nlf_half_sig_b$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29 = 0
.export __abimeta$V1$global$declaration$nlf_half_sig_out$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29
__abimeta$V1$global$declaration$nlf_half_sig_out$object$modeQ3DmemoryQ3BscalarQ28szQ3D2Q3BkindQ3Dsigned_intQ3BendQ3DlittleQ29$memoryQ20signed_integerQ28sizeQ3D2Q2CQ20littleQ2DendianQ29 = 0
.export nlf_half_div_impl
.export __abimeta$V1$function$definition$nlf_half_div_impl$summary$paramsQ3D0Q3BvariadicQ3D0$parametersQ3D0Q20variadicQ3Dno
__abimeta$V1$function$definition$nlf_half_div_impl$summary$paramsQ3D0Q3BvariadicQ3D0$parametersQ3D0Q20variadicQ3Dno = 0
.export __abimeta$V1$function$definition$nlf_half_div_impl$return$modeQ3Dreturn_valueQ3BvoidQ28szQ3D0Q29$return_valueQ20voidQ28sizeQ3D0Q29
__abimeta$V1$function$definition$nlf_half_div_impl$return$modeQ3Dreturn_valueQ3BvoidQ28szQ3D0Q29$return_valueQ20voidQ28sizeQ3D0Q29 = 0

.segment "ZEROPAGE"

.segment "ZEROPAGE"

.segment "BSS"

.segment "DATA"

.segment "RODATA"

.segment "CODE"
.proc nlf_half_div_impl
    lda sp+1
    sta fp+1
    lda sp
    sta fp
    lda #$02
    sta arg0
    jsr _pushN
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_2:
    cpx #0
    beq @bitfield_load_shift_done_4
    clc
    ldy #$01
@bitfield_load_shift_inner_3:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_3
    dex
    bne @bitfield_load_shift_outer_2
@bitfield_load_shift_done_4:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #4
    lda #$1f
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_0
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldy #1
    lda (ptr1),y
    and #$03
    sta (ptr1),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    bne @if_false_0
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    sta nlf_half_r,y
    ldy #1
    lda (ptr0),y
    ldy #1
    sta nlf_half_r,y
    jmp @fini
@if_false_0:
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_7:
    cpx #0
    beq @bitfield_load_shift_done_9
    clc
    ldy #$01
@bitfield_load_shift_inner_8:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_8
    dex
    bne @bitfield_load_shift_outer_7
@bitfield_load_shift_done_9:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #4
    lda #$1f
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_5
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldy #1
    lda (ptr1),y
    and #$03
    sta (ptr1),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    bne @if_false_5
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    sta nlf_half_r,y
    ldy #1
    lda (ptr0),y
    ldy #1
    sta nlf_half_r,y
    jmp @fini
@if_false_5:
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$07
@bitfield_load_shift_outer_10:
    cpx #0
    beq @bitfield_load_shift_done_12
    clc
    ldy #$01
@bitfield_load_shift_inner_11:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_11
    dex
    bne @bitfield_load_shift_outer_10
@bitfield_load_shift_done_12:
    ldy #0
    lda (ptr1),y
    and #$01
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$07
@bitfield_load_shift_outer_13:
    cpx #0
    beq @bitfield_load_shift_done_15
    clc
    ldy #$01
@bitfield_load_shift_inner_14:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_14
    dex
    bne @bitfield_load_shift_outer_13
@bitfield_load_shift_done_15:
    ldy #0
    lda (ptr1),y
    and #$01
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _fp2ptr2p
    lda #$02
    sta arg0
    jsr _bit_xorN
    ldy #3
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    lda #$04
    sta arg0
    jsr _popN
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_sign_out,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_sign_out,y
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_20:
    cpx #0
    beq @bitfield_load_shift_done_22
    clc
    ldy #$01
@bitfield_load_shift_inner_21:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_21
    dex
    bne @bitfield_load_shift_outer_20
@bitfield_load_shift_done_22:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #4
    lda #$1f
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @or_rhs_18
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldy #1
    lda (ptr1),y
    and #$03
    sta (ptr1),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @or_rhs_18
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_23:
    cpx #0
    beq @bitfield_load_shift_done_25
    clc
    ldy #$01
@bitfield_load_shift_inner_24:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_24
    dex
    bne @bitfield_load_shift_outer_23
@bitfield_load_shift_done_25:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #4
    lda #$1f
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @or_rhs_18
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldy #1
    lda (ptr1),y
    and #$03
    sta (ptr1),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @or_rhs_18
    jmp @or_end_19
@or_rhs_18:
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_26:
    cpx #0
    beq @bitfield_load_shift_done_28
    clc
    ldy #$01
@bitfield_load_shift_inner_27:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_27
    dex
    bne @bitfield_load_shift_outer_26
@bitfield_load_shift_done_28:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_16
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldy #1
    lda (ptr1),y
    and #$03
    sta (ptr1),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_16
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_29:
    cpx #0
    beq @bitfield_load_shift_done_31
    clc
    ldy #$01
@bitfield_load_shift_inner_30:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_30
    dex
    bne @bitfield_load_shift_outer_29
@bitfield_load_shift_done_31:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_16
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldy #1
    lda (ptr1),y
    and #$03
    sta (ptr1),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_16
@or_end_19:
    ldy #2
    lda #$00
    sta (fp),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_r,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_r,y
    lda #$02
    sta arg0
    jsr _pushN
    ldy #2
    lda #$00
    sta (fp),y
    ldy #3
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_32
    ldy #0
    lda (ptr0),y
    ora #$80
    sta (ptr0),y
    jmp @bitfield_store_done_33
@bitfield_store_clear_32:
    ldy #0
    lda (ptr0),y
    and #$7f
    sta (ptr0),y
@bitfield_store_done_33:
    lda #$02
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _pushN
    ldy #2
    lda #$1f
    sta (fp),y
    ldy #3
    lda #$00
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_34
    ldy #0
    lda (ptr0),y
    ora #$04
    sta (ptr0),y
    jmp @bitfield_store_done_35
@bitfield_store_clear_34:
    ldy #0
    lda (ptr0),y
    and #$fb
    sta (ptr0),y
@bitfield_store_done_35:
    ldy #2
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_36
    ldy #0
    lda (ptr0),y
    ora #$08
    sta (ptr0),y
    jmp @bitfield_store_done_37
@bitfield_store_clear_36:
    ldy #0
    lda (ptr0),y
    and #$f7
    sta (ptr0),y
@bitfield_store_done_37:
    ldy #2
    lda (fp),y
    and #$04
    beq @bitfield_store_clear_38
    ldy #0
    lda (ptr0),y
    ora #$10
    sta (ptr0),y
    jmp @bitfield_store_done_39
@bitfield_store_clear_38:
    ldy #0
    lda (ptr0),y
    and #$ef
    sta (ptr0),y
@bitfield_store_done_39:
    ldy #2
    lda (fp),y
    and #$08
    beq @bitfield_store_clear_40
    ldy #0
    lda (ptr0),y
    ora #$20
    sta (ptr0),y
    jmp @bitfield_store_done_41
@bitfield_store_clear_40:
    ldy #0
    lda (ptr0),y
    and #$df
    sta (ptr0),y
@bitfield_store_done_41:
    ldy #2
    lda (fp),y
    and #$10
    beq @bitfield_store_clear_42
    ldy #0
    lda (ptr0),y
    ora #$40
    sta (ptr0),y
    jmp @bitfield_store_done_43
@bitfield_store_clear_42:
    ldy #0
    lda (ptr0),y
    and #$bf
    sta (ptr0),y
@bitfield_store_done_43:
    lda #$02
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _pushN
    ldy #2
    lda #$00
    sta (fp),y
    ldy #3
    lda #$02
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_44
    ldy #0
    lda (ptr0),y
    ora #$01
    sta (ptr0),y
    jmp @bitfield_store_done_45
@bitfield_store_clear_44:
    ldy #0
    lda (ptr0),y
    and #$fe
    sta (ptr0),y
@bitfield_store_done_45:
    ldy #2
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_46
    ldy #0
    lda (ptr0),y
    ora #$02
    sta (ptr0),y
    jmp @bitfield_store_done_47
@bitfield_store_clear_46:
    ldy #0
    lda (ptr0),y
    and #$fd
    sta (ptr0),y
@bitfield_store_done_47:
    ldy #2
    lda (fp),y
    and #$04
    beq @bitfield_store_clear_48
    ldy #0
    lda (ptr0),y
    ora #$04
    sta (ptr0),y
    jmp @bitfield_store_done_49
@bitfield_store_clear_48:
    ldy #0
    lda (ptr0),y
    and #$fb
    sta (ptr0),y
@bitfield_store_done_49:
    ldy #2
    lda (fp),y
    and #$08
    beq @bitfield_store_clear_50
    ldy #0
    lda (ptr0),y
    ora #$08
    sta (ptr0),y
    jmp @bitfield_store_done_51
@bitfield_store_clear_50:
    ldy #0
    lda (ptr0),y
    and #$f7
    sta (ptr0),y
@bitfield_store_done_51:
    ldy #2
    lda (fp),y
    and #$10
    beq @bitfield_store_clear_52
    ldy #0
    lda (ptr0),y
    ora #$10
    sta (ptr0),y
    jmp @bitfield_store_done_53
@bitfield_store_clear_52:
    ldy #0
    lda (ptr0),y
    and #$ef
    sta (ptr0),y
@bitfield_store_done_53:
    ldy #2
    lda (fp),y
    and #$20
    beq @bitfield_store_clear_54
    ldy #0
    lda (ptr0),y
    ora #$20
    sta (ptr0),y
    jmp @bitfield_store_done_55
@bitfield_store_clear_54:
    ldy #0
    lda (ptr0),y
    and #$df
    sta (ptr0),y
@bitfield_store_done_55:
    ldy #2
    lda (fp),y
    and #$40
    beq @bitfield_store_clear_56
    ldy #0
    lda (ptr0),y
    ora #$40
    sta (ptr0),y
    jmp @bitfield_store_done_57
@bitfield_store_clear_56:
    ldy #0
    lda (ptr0),y
    and #$bf
    sta (ptr0),y
@bitfield_store_done_57:
    ldy #2
    lda (fp),y
    and #$80
    beq @bitfield_store_clear_58
    ldy #0
    lda (ptr0),y
    ora #$80
    sta (ptr0),y
    jmp @bitfield_store_done_59
@bitfield_store_clear_58:
    ldy #0
    lda (ptr0),y
    and #$7f
    sta (ptr0),y
@bitfield_store_done_59:
    ldy #3
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_60
    ldy #1
    lda (ptr0),y
    ora #$01
    sta (ptr0),y
    jmp @bitfield_store_done_61
@bitfield_store_clear_60:
    ldy #1
    lda (ptr0),y
    and #$fe
    sta (ptr0),y
@bitfield_store_done_61:
    ldy #3
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_62
    ldy #1
    lda (ptr0),y
    ora #$02
    sta (ptr0),y
    jmp @bitfield_store_done_63
@bitfield_store_clear_62:
    ldy #1
    lda (ptr0),y
    and #$fd
    sta (ptr0),y
@bitfield_store_done_63:
    lda #$02
    sta arg0
    jsr _popN
    jmp @fini
@if_false_16:
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_66:
    cpx #0
    beq @bitfield_load_shift_done_68
    clc
    ldy #$01
@bitfield_load_shift_inner_67:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_67
    dex
    bne @bitfield_load_shift_outer_66
@bitfield_load_shift_done_68:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #4
    lda #$1f
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_64
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldy #1
    lda (ptr1),y
    and #$03
    sta (ptr1),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_64
    ldy #2
    lda #$00
    sta (fp),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_r,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_r,y
    lda #$02
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_sign_out,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_sign_out,y
    ldy #3
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_69
    ldy #0
    lda (ptr0),y
    ora #$80
    sta (ptr0),y
    jmp @bitfield_store_done_70
@bitfield_store_clear_69:
    ldy #0
    lda (ptr0),y
    and #$7f
    sta (ptr0),y
@bitfield_store_done_70:
    lda #$02
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _pushN
    ldy #2
    lda #$1f
    sta (fp),y
    ldy #3
    lda #$00
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_71
    ldy #0
    lda (ptr0),y
    ora #$04
    sta (ptr0),y
    jmp @bitfield_store_done_72
@bitfield_store_clear_71:
    ldy #0
    lda (ptr0),y
    and #$fb
    sta (ptr0),y
@bitfield_store_done_72:
    ldy #2
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_73
    ldy #0
    lda (ptr0),y
    ora #$08
    sta (ptr0),y
    jmp @bitfield_store_done_74
@bitfield_store_clear_73:
    ldy #0
    lda (ptr0),y
    and #$f7
    sta (ptr0),y
@bitfield_store_done_74:
    ldy #2
    lda (fp),y
    and #$04
    beq @bitfield_store_clear_75
    ldy #0
    lda (ptr0),y
    ora #$10
    sta (ptr0),y
    jmp @bitfield_store_done_76
@bitfield_store_clear_75:
    ldy #0
    lda (ptr0),y
    and #$ef
    sta (ptr0),y
@bitfield_store_done_76:
    ldy #2
    lda (fp),y
    and #$08
    beq @bitfield_store_clear_77
    ldy #0
    lda (ptr0),y
    ora #$20
    sta (ptr0),y
    jmp @bitfield_store_done_78
@bitfield_store_clear_77:
    ldy #0
    lda (ptr0),y
    and #$df
    sta (ptr0),y
@bitfield_store_done_78:
    ldy #2
    lda (fp),y
    and #$10
    beq @bitfield_store_clear_79
    ldy #0
    lda (ptr0),y
    ora #$40
    sta (ptr0),y
    jmp @bitfield_store_done_80
@bitfield_store_clear_79:
    ldy #0
    lda (ptr0),y
    and #$bf
    sta (ptr0),y
@bitfield_store_done_80:
    lda #$02
    sta arg0
    jsr _popN
    jmp @fini
@if_false_64:
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_83:
    cpx #0
    beq @bitfield_load_shift_done_85
    clc
    ldy #$01
@bitfield_load_shift_inner_84:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_84
    dex
    bne @bitfield_load_shift_outer_83
@bitfield_load_shift_done_85:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #4
    lda #$1f
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_81
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldy #1
    lda (ptr1),y
    and #$03
    sta (ptr1),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_81
    ldy #2
    lda #$00
    sta (fp),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_r,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_r,y
    lda #$02
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_sign_out,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_sign_out,y
    ldy #3
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_86
    ldy #0
    lda (ptr0),y
    ora #$80
    sta (ptr0),y
    jmp @bitfield_store_done_87
@bitfield_store_clear_86:
    ldy #0
    lda (ptr0),y
    and #$7f
    sta (ptr0),y
@bitfield_store_done_87:
    lda #$02
    sta arg0
    jsr _popN
    jmp @fini
@if_false_81:
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_90:
    cpx #0
    beq @bitfield_load_shift_done_92
    clc
    ldy #$01
@bitfield_load_shift_inner_91:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_91
    dex
    bne @bitfield_load_shift_outer_90
@bitfield_load_shift_done_92:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_88
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldy #1
    lda (ptr1),y
    and #$03
    sta (ptr1),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_88
    ldy #2
    lda #$00
    sta (fp),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_r,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_r,y
    lda #$02
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_sign_out,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_sign_out,y
    ldy #3
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_93
    ldy #0
    lda (ptr0),y
    ora #$80
    sta (ptr0),y
    jmp @bitfield_store_done_94
@bitfield_store_clear_93:
    ldy #0
    lda (ptr0),y
    and #$7f
    sta (ptr0),y
@bitfield_store_done_94:
    lda #$02
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _pushN
    ldy #2
    lda #$1f
    sta (fp),y
    ldy #3
    lda #$00
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_95
    ldy #0
    lda (ptr0),y
    ora #$04
    sta (ptr0),y
    jmp @bitfield_store_done_96
@bitfield_store_clear_95:
    ldy #0
    lda (ptr0),y
    and #$fb
    sta (ptr0),y
@bitfield_store_done_96:
    ldy #2
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_97
    ldy #0
    lda (ptr0),y
    ora #$08
    sta (ptr0),y
    jmp @bitfield_store_done_98
@bitfield_store_clear_97:
    ldy #0
    lda (ptr0),y
    and #$f7
    sta (ptr0),y
@bitfield_store_done_98:
    ldy #2
    lda (fp),y
    and #$04
    beq @bitfield_store_clear_99
    ldy #0
    lda (ptr0),y
    ora #$10
    sta (ptr0),y
    jmp @bitfield_store_done_100
@bitfield_store_clear_99:
    ldy #0
    lda (ptr0),y
    and #$ef
    sta (ptr0),y
@bitfield_store_done_100:
    ldy #2
    lda (fp),y
    and #$08
    beq @bitfield_store_clear_101
    ldy #0
    lda (ptr0),y
    ora #$20
    sta (ptr0),y
    jmp @bitfield_store_done_102
@bitfield_store_clear_101:
    ldy #0
    lda (ptr0),y
    and #$df
    sta (ptr0),y
@bitfield_store_done_102:
    ldy #2
    lda (fp),y
    and #$10
    beq @bitfield_store_clear_103
    ldy #0
    lda (ptr0),y
    ora #$40
    sta (ptr0),y
    jmp @bitfield_store_done_104
@bitfield_store_clear_103:
    ldy #0
    lda (ptr0),y
    and #$bf
    sta (ptr0),y
@bitfield_store_done_104:
    lda #$02
    sta arg0
    jsr _popN
    jmp @fini
@if_false_88:
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_107:
    cpx #0
    beq @bitfield_load_shift_done_109
    clc
    ldy #$01
@bitfield_load_shift_inner_108:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_108
    dex
    bne @bitfield_load_shift_outer_107
@bitfield_load_shift_done_109:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_105
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldy #1
    lda (ptr1),y
    and #$03
    sta (ptr1),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_105
    ldy #2
    lda #$00
    sta (fp),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_r,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_r,y
    lda #$02
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_sign_out,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_sign_out,y
    ldy #3
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_110
    ldy #0
    lda (ptr0),y
    ora #$80
    sta (ptr0),y
    jmp @bitfield_store_done_111
@bitfield_store_clear_110:
    ldy #0
    lda (ptr0),y
    and #$7f
    sta (ptr0),y
@bitfield_store_done_111:
    lda #$02
    sta arg0
    jsr _popN
    jmp @fini
@if_false_105:
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldy #1
    lda (ptr1),y
    and #$03
    sta (ptr1),y
    ldy #3
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_sig_a,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_sig_a,y
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldy #1
    lda (ptr1),y
    and #$03
    sta (ptr1),y
    ldy #3
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_sig_b,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_sig_b,y
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_112:
    cpx #0
    beq @bitfield_load_shift_done_114
    clc
    ldy #$01
@bitfield_load_shift_inner_113:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_113
    dex
    bne @bitfield_load_shift_outer_112
@bitfield_load_shift_done_114:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #3
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_exp_a,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_exp_a,y
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_115:
    cpx #0
    beq @bitfield_load_shift_done_117
    clc
    ldy #$01
@bitfield_load_shift_inner_116:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_116
    dex
    bne @bitfield_load_shift_outer_115
@bitfield_load_shift_done_117:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #3
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_exp_b,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_exp_b,y
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_exp_a,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_exp_a,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_118
    ldy #2
    lda #$01
    sta (fp),y
    ldy #3
    lda #$00
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_exp_a,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_exp_a,y
@if_false_118:
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_exp_b,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_exp_b,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_120
    ldy #2
    lda #$01
    sta (fp),y
    ldy #3
    lda #$00
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_exp_b,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_exp_b,y
@if_false_120:
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_a + 0}
    sta ptr0
    lda #>{nlf_half_a + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_124:
    cpx #0
    beq @bitfield_load_shift_done_126
    clc
    ldy #$01
@bitfield_load_shift_inner_125:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_125
    dex
    bne @bitfield_load_shift_outer_124
@bitfield_load_shift_done_126:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    bne @if_false_122
    lda #$06
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_sig_a,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_sig_a,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    lda #$04
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _fp2ptr2p
    lda #$02
    sta arg0
    jsr _bit_orN
    ldy #2
    lda (fp),y
    ldy #6
    sta (fp),y
    ldy #3
    lda (fp),y
    ldy #7
    sta (fp),y
    ldy #6
    lda (fp),y
    ldy #0
    sta nlf_half_sig_a,y
    ldy #7
    lda (fp),y
    ldy #1
    sta nlf_half_sig_a,y
    lda #$06
    sta arg0
    jsr _popN
@if_false_122:
    lda #$04
    sta arg0
    jsr _pushN
    lda #<{nlf_half_b + 0}
    sta ptr0
    lda #>{nlf_half_b + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _cpyN
    ldx #$02
@bitfield_load_shift_outer_129:
    cpx #0
    beq @bitfield_load_shift_done_131
    clc
    ldy #$01
@bitfield_load_shift_inner_130:
    lda (ptr1),y
    ror a
    sta (ptr1),y
    dey
    bpl @bitfield_load_shift_inner_130
    dex
    bne @bitfield_load_shift_outer_129
@bitfield_load_shift_done_131:
    ldy #0
    lda (ptr1),y
    and #$1f
    sta (ptr1),y
    clc
    lda ptr1
    adc #$01
    sta ptr1
    lda ptr1+1
    adc #$00
    sta ptr1+1
    lda #$01
    sta arg0
    jsr _zeroN
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    bne @if_false_127
    lda #$06
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_sig_b,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_sig_b,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    lda #$04
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _fp2ptr2p
    lda #$02
    sta arg0
    jsr _bit_orN
    ldy #2
    lda (fp),y
    ldy #6
    sta (fp),y
    ldy #3
    lda (fp),y
    ldy #7
    sta (fp),y
    ldy #6
    lda (fp),y
    ldy #0
    sta nlf_half_sig_b,y
    ldy #7
    lda (fp),y
    ldy #1
    sta nlf_half_sig_b,y
    lda #$06
    sta arg0
    jsr _popN
@if_false_127:
    lda #$04
    sta arg0
    jsr _pushN
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_exp_a,y
    ldy #6
    sta (fp),y
    ldy #1
    lda nlf_half_exp_a,y
    ldy #7
    sta (fp),y
    ldy #0
    lda nlf_half_exp_b,y
    ldy #8
    sta (fp),y
    ldy #1
    lda nlf_half_exp_b,y
    ldy #9
    sta (fp),y
    sec
    ldy #6
    lda (fp),y
    ldy #8
    sbc (fp),y
    ldy #6
    sta (fp),y
    ldy #7
    lda (fp),y
    ldy #9
    sbc (fp),y
    ldy #7
    sta (fp),y
    ldy #6
    lda (fp),y
    ldy #2
    sta (fp),y
    ldy #7
    lda (fp),y
    ldy #3
    sta (fp),y
    lda #$04
    sta arg0
    jsr _popN
    ldy #4
    lda #$0f
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    clc
    ldy #2
    lda (fp),y
    ldy #4
    adc (fp),y
    ldy #2
    sta (fp),y
    ldy #3
    lda (fp),y
    ldy #5
    adc (fp),y
    ldy #3
    sta (fp),y
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    lda #$04
    sta arg0
    jsr _popN
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_exp_a,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_exp_a,y
    lda #<{nlf_half_sig_a + 0}
    sta ptr0
    lda #>{nlf_half_sig_a + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    lda #$04
    sta arg1
    jsr _copysxNle
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_wide_a,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_wide_a,y
    ldy #4
    lda (fp),y
    ldy #2
    sta nlf_half_wide_a,y
    ldy #5
    lda (fp),y
    ldy #3
    sta nlf_half_wide_a,y
    lda #$0c
    sta arg0
    jsr _pushN
    lda #<{nlf_half_wide_a + 0}
    sta ptr0
    lda #>{nlf_half_wide_a + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #4
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #5
    sta (fp),y
    ldy #6
    lda #$0d
    sta (fp),y
    ldy #7
    lda #$00
    sta (fp),y
    ldy #8
    sta (fp),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$0a
    sta arg0
    jsr _fp2ptr1p
    ldy #6
    lda (fp),y
    sta arg1
    lda #$04
    sta arg0
    jsr _lslNle
    ldy #10
    lda (fp),y
    ldy #2
    sta (fp),y
    ldy #11
    lda (fp),y
    ldy #3
    sta (fp),y
    ldy #12
    lda (fp),y
    ldy #4
    sta (fp),y
    ldy #13
    lda (fp),y
    ldy #5
    sta (fp),y
    lda #$0c
    sta arg0
    jsr _popN
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_wide_a,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_wide_a,y
    ldy #4
    lda (fp),y
    ldy #2
    sta nlf_half_wide_a,y
    ldy #5
    lda (fp),y
    ldy #3
    sta nlf_half_wide_a,y
    lda #<{nlf_half_sig_b + 0}
    sta ptr0
    lda #>{nlf_half_sig_b + 0}
    sta ptr0+1
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    lda #$04
    sta arg1
    jsr _copysxNle
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_wide_b,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_wide_b,y
    ldy #4
    lda (fp),y
    ldy #2
    sta nlf_half_wide_b,y
    ldy #5
    lda (fp),y
    ldy #3
    sta nlf_half_wide_b,y
    lda #$10
    sta arg0
    jsr _pushN
    lda #<{nlf_half_wide_a + 0}
    sta ptr0
    lda #>{nlf_half_wide_a + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #4
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #5
    sta (fp),y
    lda #<{nlf_half_wide_b + 0}
    sta ptr0
    lda #>{nlf_half_wide_b + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #6
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #7
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #8
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$06
    sta arg0
    jsr _fp2ptr1p
    lda #$0a
    sta arg0
    jsr _fp2ptr2p
    lda #$0e
    sta arg0
    jsr _fp2ptr3p
    lda #$04
    sta arg0
    jsr _divNle
    ldy #10
    lda (fp),y
    ldy #2
    sta (fp),y
    ldy #11
    lda (fp),y
    ldy #3
    sta (fp),y
    ldy #12
    lda (fp),y
    ldy #4
    sta (fp),y
    ldy #13
    lda (fp),y
    ldy #5
    sta (fp),y
    lda (fp),y
    pha
    ldy #4
    lda (fp),y
    pha
    ldy #3
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    pla
    ldy #4
    sta (fp),y
    pla
    ldy #5
    sta (fp),y
    lda #$10
    sta arg0
    jsr _popN
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_wide_p,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_wide_p,y
    ldy #4
    lda (fp),y
    ldy #2
    sta nlf_half_wide_p,y
    ldy #5
    lda (fp),y
    ldy #3
    sta nlf_half_wide_p,y
    lda #$10
    sta arg0
    jsr _pushN
    lda #<{nlf_half_wide_p + 0}
    sta ptr0
    lda #>{nlf_half_wide_p + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #4
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #5
    sta (fp),y
    lda #<{nlf_half_wide_b + 0}
    sta ptr0
    lda #>{nlf_half_wide_b + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #6
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #7
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #8
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$06
    sta arg0
    jsr _fp2ptr1p
    lda #$0a
    sta arg0
    jsr _fp2ptr2p
    lda #$04
    sta arg0
    jsr _mulNle
    ldy #10
    lda (fp),y
    ldy #2
    sta (fp),y
    ldy #11
    lda (fp),y
    ldy #3
    sta (fp),y
    ldy #12
    lda (fp),y
    ldy #4
    sta (fp),y
    ldy #13
    lda (fp),y
    ldy #5
    sta (fp),y
    lda (fp),y
    pha
    ldy #4
    lda (fp),y
    pha
    ldy #3
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    pla
    ldy #4
    sta (fp),y
    pla
    ldy #5
    sta (fp),y
    lda #$10
    sta arg0
    jsr _popN
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_wide_t,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_wide_t,y
    ldy #4
    lda (fp),y
    ldy #2
    sta nlf_half_wide_t,y
    ldy #5
    lda (fp),y
    ldy #3
    sta nlf_half_wide_t,y
    lda #$08
    sta arg0
    jsr _pushN
    lda #<{nlf_half_wide_t + 0}
    sta ptr0
    lda #>{nlf_half_wide_t + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #4
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #5
    sta (fp),y
    lda #<{nlf_half_wide_a + 0}
    sta ptr0
    lda #>{nlf_half_wide_a + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #6
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #7
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #8
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$06
    sta arg0
    jsr _fp2ptr1p
    lda #$04
    sta arg0
    jsr _eqN
    lda #$08
    sta arg0
    jsr _popN
    lda arg1
    bne @if_false_132
    lda #$0c
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_wide_p,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_wide_p,y
    ldy #3
    sta (fp),y
    ldy #2
    lda nlf_half_wide_p,y
    ldy #4
    sta (fp),y
    ldy #3
    lda nlf_half_wide_p,y
    ldy #5
    sta (fp),y
    ldy #6
    lda #$01
    sta (fp),y
    ldy #7
    lda #$00
    sta (fp),y
    ldy #8
    sta (fp),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$06
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _fp2ptr2p
    lda #$04
    sta arg0
    jsr _bit_orN
    ldy #2
    lda (fp),y
    ldy #10
    sta (fp),y
    ldy #3
    lda (fp),y
    ldy #11
    sta (fp),y
    ldy #4
    lda (fp),y
    ldy #12
    sta (fp),y
    ldy #5
    lda (fp),y
    ldy #13
    sta (fp),y
    ldy #10
    lda (fp),y
    ldy #0
    sta nlf_half_wide_p,y
    ldy #11
    lda (fp),y
    ldy #1
    sta nlf_half_wide_p,y
    ldy #12
    lda (fp),y
    ldy #2
    sta nlf_half_wide_p,y
    ldy #13
    lda (fp),y
    ldy #3
    sta nlf_half_wide_p,y
    lda #$0c
    sta arg0
    jsr _popN
@if_false_132:
@while_start_134:
    lda #$08
    sta arg0
    jsr _pushN
    lda #<{nlf_half_wide_p + 0}
    sta ptr0
    lda #>{nlf_half_wide_p + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #4
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #5
    sta (fp),y
    ldy #6
    lda #$00
    sta (fp),y
    ldy #7
    sta (fp),y
    ldy #8
    sta (fp),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$06
    sta arg0
    jsr _fp2ptr1p
    lda #$04
    sta arg0
    jsr _eqN
    lda #$08
    sta arg0
    jsr _popN
    lda arg1
    bne @while_end_135
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_exp_a,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_exp_a,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$01
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    lda #$04
    sta arg0
    jsr _fp2ptr0p
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _ltNsle
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @while_end_135
    lda #$08
    sta arg0
    jsr _pushN
    lda #<{nlf_half_wide_p + 0}
    sta ptr0
    lda #>{nlf_half_wide_p + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #4
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #5
    sta (fp),y
    ldy #6
    lda #$00
    sta (fp),y
    ldy #7
    lda #$20
    sta (fp),y
    ldy #8
    lda #$00
    sta (fp),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$06
    sta arg0
    jsr _fp2ptr1p
    lda #$04
    sta arg0
    jsr _ltNule
    lda #$08
    sta arg0
    jsr _popN
    lda arg1
    beq @while_end_135
    lda #$0c
    sta arg0
    jsr _pushN
    lda #<{nlf_half_wide_p + 0}
    sta ptr0
    lda #>{nlf_half_wide_p + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #4
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #5
    sta (fp),y
    ldy #6
    lda #$01
    sta (fp),y
    ldy #7
    lda #$00
    sta (fp),y
    ldy #8
    sta (fp),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$0a
    sta arg0
    jsr _fp2ptr1p
    ldy #6
    lda (fp),y
    sta arg1
    lda #$04
    sta arg0
    jsr _lslNle
    ldy #10
    lda (fp),y
    ldy #2
    sta (fp),y
    ldy #11
    lda (fp),y
    ldy #3
    sta (fp),y
    ldy #12
    lda (fp),y
    ldy #4
    sta (fp),y
    ldy #13
    lda (fp),y
    ldy #5
    sta (fp),y
    lda #$0c
    sta arg0
    jsr _popN
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_wide_p,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_wide_p,y
    ldy #4
    lda (fp),y
    ldy #2
    sta nlf_half_wide_p,y
    ldy #5
    lda (fp),y
    ldy #3
    sta nlf_half_wide_p,y
    lda #$02
    sta arg0
    jsr _pushN
    lda #$02
    sta arg0
    jsr _pushN
    lda #<{nlf_half_exp_a + 0}
    sta ptr0
    lda #>{nlf_half_exp_a + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    sec
    ldy #2
    lda (fp),y
    sbc #$01
    sta (fp),y
    ldy #3
    lda (fp),y
    sbc #$00
    sta (fp),y
    lda #<{nlf_half_exp_a + 0}
    sta ptr0
    lda #>{nlf_half_exp_a + 0}
    sta ptr0+1
    ldy #2
    lda (fp),y
    ldy #0
    sta (ptr0),y
    ldy #3
    lda (fp),y
    ldy #1
    sta (ptr0),y
    lda #$02
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _popN
    jmp @while_start_134
@while_end_135:
@while_start_136:
    lda #$08
    sta arg0
    jsr _pushN
    lda #<{nlf_half_wide_p + 0}
    sta ptr0
    lda #>{nlf_half_wide_p + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #4
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #5
    sta (fp),y
    ldy #6
    lda #$00
    sta (fp),y
    ldy #7
    sta (fp),y
    ldy #8
    sta (fp),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$06
    sta arg0
    jsr _fp2ptr1p
    lda #$04
    sta arg0
    jsr _eqN
    lda #$08
    sta arg0
    jsr _popN
    lda arg1
    bne @while_end_137
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_exp_a,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_exp_a,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$01
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _ltNsle
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @while_end_137
    lda #$08
    sta arg0
    jsr _pushN
    lda #<{nlf_half_wide_p + 0}
    sta ptr0
    lda #>{nlf_half_wide_p + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #4
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #5
    sta (fp),y
    ldy #6
    lda #$01
    sta (fp),y
    ldy #7
    lda #$00
    sta (fp),y
    ldy #8
    sta (fp),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$06
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _fp2ptr2p
    lda #$04
    sta arg0
    jsr _bit_andN
    ldy #5
    lda (fp),y
    pha
    ldy #4
    lda (fp),y
    pha
    ldy #3
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    pla
    ldy #4
    sta (fp),y
    pla
    ldy #5
    sta (fp),y
    lda #$08
    sta arg0
    jsr _popN
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_wide_t,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_wide_t,y
    ldy #4
    lda (fp),y
    ldy #2
    sta nlf_half_wide_t,y
    ldy #5
    lda (fp),y
    ldy #3
    sta nlf_half_wide_t,y
    lda #$0c
    sta arg0
    jsr _pushN
    lda #<{nlf_half_wide_p + 0}
    sta ptr0
    lda #>{nlf_half_wide_p + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #4
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #5
    sta (fp),y
    ldy #6
    lda #$01
    sta (fp),y
    ldy #7
    lda #$00
    sta (fp),y
    ldy #8
    sta (fp),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$0a
    sta arg0
    jsr _fp2ptr1p
    ldy #6
    lda (fp),y
    sta arg1
    lda #$04
    sta arg0
    jsr _lsrNle
    ldy #10
    lda (fp),y
    ldy #2
    sta (fp),y
    ldy #11
    lda (fp),y
    ldy #3
    sta (fp),y
    ldy #12
    lda (fp),y
    ldy #4
    sta (fp),y
    ldy #13
    lda (fp),y
    ldy #5
    sta (fp),y
    lda #$0c
    sta arg0
    jsr _popN
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_wide_p,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_wide_p,y
    ldy #4
    lda (fp),y
    ldy #2
    sta nlf_half_wide_p,y
    ldy #5
    lda (fp),y
    ldy #3
    sta nlf_half_wide_p,y
    lda #$08
    sta arg0
    jsr _pushN
    lda #<{nlf_half_wide_t + 0}
    sta ptr0
    lda #>{nlf_half_wide_t + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (ptr0),y
    ldy #4
    sta (fp),y
    ldy #3
    lda (ptr0),y
    ldy #5
    sta (fp),y
    ldy #6
    lda #$00
    sta (fp),y
    ldy #7
    sta (fp),y
    ldy #8
    sta (fp),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$06
    sta arg0
    jsr _fp2ptr1p
    lda #$04
    sta arg0
    jsr _eqN
    lda #$08
    sta arg0
    jsr _popN
    lda arg1
    bne @if_false_138
    lda #$0c
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_wide_p,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_wide_p,y
    ldy #3
    sta (fp),y
    ldy #2
    lda nlf_half_wide_p,y
    ldy #4
    sta (fp),y
    ldy #3
    lda nlf_half_wide_p,y
    ldy #5
    sta (fp),y
    ldy #6
    lda #$01
    sta (fp),y
    ldy #7
    lda #$00
    sta (fp),y
    ldy #8
    sta (fp),y
    ldy #9
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$06
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _fp2ptr2p
    lda #$04
    sta arg0
    jsr _bit_orN
    ldy #2
    lda (fp),y
    ldy #10
    sta (fp),y
    ldy #3
    lda (fp),y
    ldy #11
    sta (fp),y
    ldy #4
    lda (fp),y
    ldy #12
    sta (fp),y
    ldy #5
    lda (fp),y
    ldy #13
    sta (fp),y
    ldy #10
    lda (fp),y
    ldy #0
    sta nlf_half_wide_p,y
    ldy #11
    lda (fp),y
    ldy #1
    sta nlf_half_wide_p,y
    ldy #12
    lda (fp),y
    ldy #2
    sta nlf_half_wide_p,y
    ldy #13
    lda (fp),y
    ldy #3
    sta nlf_half_wide_p,y
    lda #$0c
    sta arg0
    jsr _popN
@if_false_138:
    lda #$02
    sta arg0
    jsr _pushN
    lda #$02
    sta arg0
    jsr _pushN
    lda #<{nlf_half_exp_a + 0}
    sta ptr0
    lda #>{nlf_half_exp_a + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    clc
    ldy #2
    lda (fp),y
    adc #$01
    sta (fp),y
    ldy #3
    lda (fp),y
    adc #$00
    sta (fp),y
    lda #<{nlf_half_exp_a + 0}
    sta ptr0
    lda #>{nlf_half_exp_a + 0}
    sta ptr0+1
    ldy #2
    lda (fp),y
    ldy #0
    sta (ptr0),y
    ldy #3
    lda (fp),y
    ldy #1
    sta (ptr0),y
    lda #$02
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _popN
    jmp @while_start_136
@while_end_137:
    lda #<{nlf_half_wide_p + 0}
    sta ptr0
    lda #>{nlf_half_wide_p + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_sig_out,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_sig_out,y
    ldy #2
    lda #$00
    sta (fp),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_r,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_r,y
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_sig_out,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_sig_out,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_140
    lda #$02
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_sign_out,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_sign_out,y
    ldy #3
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_142
    ldy #0
    lda (ptr0),y
    ora #$80
    sta (ptr0),y
    jmp @bitfield_store_done_143
@bitfield_store_clear_142:
    ldy #0
    lda (ptr0),y
    and #$7f
    sta (ptr0),y
@bitfield_store_done_143:
    lda #$02
    sta arg0
    jsr _popN
    jmp @if_end_141
@if_false_140:
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_sig_out,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_sig_out,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$07
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _fp2ptr2p
    lda #$02
    sta arg0
    jsr _bit_andN
    ldy #2
    lda (fp),y
    ldy #0
    sta (fp),y
    ldy #3
    lda (fp),y
    ldy #1
    sta (fp),y
    lda #$04
    sta arg0
    jsr _popN
    lda #$08
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_sig_out,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_sig_out,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$08
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$06
    sta arg0
    jsr _fp2ptr2p
    lda #$08
    sta arg0
    jsr _fp2ptr3p
    lda #$02
    sta arg0
    jsr _divNle
    ldy #6
    lda (fp),y
    ldy #2
    sta (fp),y
    ldy #7
    lda (fp),y
    ldy #3
    sta (fp),y
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    lda #$08
    sta arg0
    jsr _popN
    ldy #2
    lda (fp),y
    ldy #0
    sta nlf_half_mant_ll,y
    ldy #3
    lda (fp),y
    ldy #1
    sta nlf_half_mant_ll,y
    lda #$04
    sta arg0
    jsr _pushN
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda (fp),y
    ldy #6
    sta (fp),y
    ldy #1
    lda (fp),y
    ldy #7
    sta (fp),y
    ldy #8
    lda #$04
    sta (fp),y
    ldy #9
    lda #$00
    sta (fp),y
    lda #$06
    sta arg0
    jsr _fp2ptr0p
    lda #$08
    sta arg0
    jsr _fp2ptr1p
    lda #$06
    sta arg0
    jsr _fp2ptr2p
    lda #$02
    sta arg0
    jsr _bit_andN
    ldy #6
    lda (fp),y
    ldy #2
    sta (fp),y
    ldy #7
    lda (fp),y
    ldy #3
    sta (fp),y
    lda #$04
    sta arg0
    jsr _popN
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    bne @if_false_144
    lda #$04
    sta arg0
    jsr _pushN
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda (fp),y
    ldy #6
    sta (fp),y
    ldy #1
    lda (fp),y
    ldy #7
    sta (fp),y
    ldy #8
    lda #$03
    sta (fp),y
    ldy #9
    lda #$00
    sta (fp),y
    lda #$06
    sta arg0
    jsr _fp2ptr0p
    lda #$08
    sta arg0
    jsr _fp2ptr1p
    lda #$06
    sta arg0
    jsr _fp2ptr2p
    lda #$02
    sta arg0
    jsr _bit_andN
    ldy #6
    lda (fp),y
    ldy #2
    sta (fp),y
    ldy #7
    lda (fp),y
    ldy #3
    sta (fp),y
    lda #$04
    sta arg0
    jsr _popN
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    bne @or_rhs_146
    jmp @or_end_147
@or_rhs_146:
    lda #$04
    sta arg0
    jsr _pushN
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_mant_ll,y
    ldy #6
    sta (fp),y
    ldy #1
    lda nlf_half_mant_ll,y
    ldy #7
    sta (fp),y
    ldy #8
    lda #$01
    sta (fp),y
    ldy #9
    lda #$00
    sta (fp),y
    lda #$06
    sta arg0
    jsr _fp2ptr0p
    lda #$08
    sta arg0
    jsr _fp2ptr1p
    lda #$06
    sta arg0
    jsr _fp2ptr2p
    lda #$02
    sta arg0
    jsr _bit_andN
    ldy #6
    lda (fp),y
    ldy #2
    sta (fp),y
    ldy #7
    lda (fp),y
    ldy #3
    sta (fp),y
    lda #$04
    sta arg0
    jsr _popN
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _eqN
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    bne @if_false_144
@or_end_147:
    lda #$02
    sta arg0
    jsr _pushN
    lda #$02
    sta arg0
    jsr _pushN
    lda #<{nlf_half_mant_ll + 0}
    sta ptr0
    lda #>{nlf_half_mant_ll + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    clc
    ldy #2
    lda (fp),y
    adc #$01
    sta (fp),y
    ldy #3
    lda (fp),y
    adc #$00
    sta (fp),y
    lda #<{nlf_half_mant_ll + 0}
    sta ptr0
    lda #>{nlf_half_mant_ll + 0}
    sta ptr0+1
    ldy #2
    lda (fp),y
    ldy #0
    sta (ptr0),y
    ldy #3
    lda (fp),y
    ldy #1
    sta (ptr0),y
    lda #$02
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _popN
@if_false_144:
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_mant_ll,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_mant_ll,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    lda #$08
    sta (fp),y
    lda #$04
    sta arg0
    jsr _fp2ptr0p
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _leNsle
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_148
    lda #$0a
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_mant_ll,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_mant_ll,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$02
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    lda #$02
    sta arg0
    jsr _fp2ptr0p
    lda #$04
    sta arg0
    jsr _fp2ptr1p
    lda #$06
    sta arg0
    jsr _fp2ptr2p
    lda #$08
    sta arg0
    jsr _fp2ptr3p
    lda #$02
    sta arg0
    jsr _divNle
    ldy #6
    lda (fp),y
    ldy #2
    sta (fp),y
    ldy #7
    lda (fp),y
    ldy #3
    sta (fp),y
    ldy #2
    lda (fp),y
    ldy #10
    sta (fp),y
    ldy #3
    lda (fp),y
    ldy #11
    sta (fp),y
    ldy #10
    lda (fp),y
    ldy #0
    sta nlf_half_mant_ll,y
    ldy #11
    lda (fp),y
    ldy #1
    sta nlf_half_mant_ll,y
    lda #$0a
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _pushN
    lda #$02
    sta arg0
    jsr _pushN
    lda #<{nlf_half_exp_a + 0}
    sta ptr0
    lda #>{nlf_half_exp_a + 0}
    sta ptr0+1
    ldy #0
    lda (ptr0),y
    ldy #2
    sta (fp),y
    ldy #1
    lda (ptr0),y
    ldy #3
    sta (fp),y
    lda (fp),y
    pha
    ldy #2
    lda (fp),y
    pha
    pla
    sta (fp),y
    pla
    ldy #3
    sta (fp),y
    clc
    ldy #2
    lda (fp),y
    adc #$01
    sta (fp),y
    ldy #3
    lda (fp),y
    adc #$00
    sta (fp),y
    lda #<{nlf_half_exp_a + 0}
    sta ptr0
    lda #>{nlf_half_exp_a + 0}
    sta ptr0+1
    ldy #2
    lda (fp),y
    ldy #0
    sta (ptr0),y
    ldy #3
    lda (fp),y
    ldy #1
    sta (ptr0),y
    lda #$02
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _popN
@if_false_148:
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_exp_a,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_exp_a,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$1f
    sta (fp),y
    ldy #5
    lda #$00
    sta (fp),y
    lda #$04
    sta arg0
    jsr _fp2ptr0p
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _leNsle
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_150
    lda #$02
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_sign_out,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_sign_out,y
    ldy #3
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_152
    ldy #0
    lda (ptr0),y
    ora #$80
    sta (ptr0),y
    jmp @bitfield_store_done_153
@bitfield_store_clear_152:
    ldy #0
    lda (ptr0),y
    and #$7f
    sta (ptr0),y
@bitfield_store_done_153:
    lda #$02
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _pushN
    ldy #2
    lda #$1f
    sta (fp),y
    ldy #3
    lda #$00
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_154
    ldy #0
    lda (ptr0),y
    ora #$04
    sta (ptr0),y
    jmp @bitfield_store_done_155
@bitfield_store_clear_154:
    ldy #0
    lda (ptr0),y
    and #$fb
    sta (ptr0),y
@bitfield_store_done_155:
    ldy #2
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_156
    ldy #0
    lda (ptr0),y
    ora #$08
    sta (ptr0),y
    jmp @bitfield_store_done_157
@bitfield_store_clear_156:
    ldy #0
    lda (ptr0),y
    and #$f7
    sta (ptr0),y
@bitfield_store_done_157:
    ldy #2
    lda (fp),y
    and #$04
    beq @bitfield_store_clear_158
    ldy #0
    lda (ptr0),y
    ora #$10
    sta (ptr0),y
    jmp @bitfield_store_done_159
@bitfield_store_clear_158:
    ldy #0
    lda (ptr0),y
    and #$ef
    sta (ptr0),y
@bitfield_store_done_159:
    ldy #2
    lda (fp),y
    and #$08
    beq @bitfield_store_clear_160
    ldy #0
    lda (ptr0),y
    ora #$20
    sta (ptr0),y
    jmp @bitfield_store_done_161
@bitfield_store_clear_160:
    ldy #0
    lda (ptr0),y
    and #$df
    sta (ptr0),y
@bitfield_store_done_161:
    ldy #2
    lda (fp),y
    and #$10
    beq @bitfield_store_clear_162
    ldy #0
    lda (ptr0),y
    ora #$40
    sta (ptr0),y
    jmp @bitfield_store_done_163
@bitfield_store_clear_162:
    ldy #0
    lda (ptr0),y
    and #$bf
    sta (ptr0),y
@bitfield_store_done_163:
    lda #$02
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _pushN
    ldy #2
    lda #$00
    sta (fp),y
    ldy #3
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_164
    ldy #0
    lda (ptr0),y
    ora #$01
    sta (ptr0),y
    jmp @bitfield_store_done_165
@bitfield_store_clear_164:
    ldy #0
    lda (ptr0),y
    and #$fe
    sta (ptr0),y
@bitfield_store_done_165:
    ldy #2
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_166
    ldy #0
    lda (ptr0),y
    ora #$02
    sta (ptr0),y
    jmp @bitfield_store_done_167
@bitfield_store_clear_166:
    ldy #0
    lda (ptr0),y
    and #$fd
    sta (ptr0),y
@bitfield_store_done_167:
    ldy #2
    lda (fp),y
    and #$04
    beq @bitfield_store_clear_168
    ldy #0
    lda (ptr0),y
    ora #$04
    sta (ptr0),y
    jmp @bitfield_store_done_169
@bitfield_store_clear_168:
    ldy #0
    lda (ptr0),y
    and #$fb
    sta (ptr0),y
@bitfield_store_done_169:
    ldy #2
    lda (fp),y
    and #$08
    beq @bitfield_store_clear_170
    ldy #0
    lda (ptr0),y
    ora #$08
    sta (ptr0),y
    jmp @bitfield_store_done_171
@bitfield_store_clear_170:
    ldy #0
    lda (ptr0),y
    and #$f7
    sta (ptr0),y
@bitfield_store_done_171:
    ldy #2
    lda (fp),y
    and #$10
    beq @bitfield_store_clear_172
    ldy #0
    lda (ptr0),y
    ora #$10
    sta (ptr0),y
    jmp @bitfield_store_done_173
@bitfield_store_clear_172:
    ldy #0
    lda (ptr0),y
    and #$ef
    sta (ptr0),y
@bitfield_store_done_173:
    ldy #2
    lda (fp),y
    and #$20
    beq @bitfield_store_clear_174
    ldy #0
    lda (ptr0),y
    ora #$20
    sta (ptr0),y
    jmp @bitfield_store_done_175
@bitfield_store_clear_174:
    ldy #0
    lda (ptr0),y
    and #$df
    sta (ptr0),y
@bitfield_store_done_175:
    ldy #2
    lda (fp),y
    and #$40
    beq @bitfield_store_clear_176
    ldy #0
    lda (ptr0),y
    ora #$40
    sta (ptr0),y
    jmp @bitfield_store_done_177
@bitfield_store_clear_176:
    ldy #0
    lda (ptr0),y
    and #$bf
    sta (ptr0),y
@bitfield_store_done_177:
    ldy #2
    lda (fp),y
    and #$80
    beq @bitfield_store_clear_178
    ldy #0
    lda (ptr0),y
    ora #$80
    sta (ptr0),y
    jmp @bitfield_store_done_179
@bitfield_store_clear_178:
    ldy #0
    lda (ptr0),y
    and #$7f
    sta (ptr0),y
@bitfield_store_done_179:
    ldy #3
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_180
    ldy #1
    lda (ptr0),y
    ora #$01
    sta (ptr0),y
    jmp @bitfield_store_done_181
@bitfield_store_clear_180:
    ldy #1
    lda (ptr0),y
    and #$fe
    sta (ptr0),y
@bitfield_store_done_181:
    ldy #3
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_182
    ldy #1
    lda (ptr0),y
    ora #$02
    sta (ptr0),y
    jmp @bitfield_store_done_183
@bitfield_store_clear_182:
    ldy #1
    lda (ptr0),y
    and #$fd
    sta (ptr0),y
@bitfield_store_done_183:
    lda #$02
    sta arg0
    jsr _popN
    jmp @if_end_151
@if_false_150:
    lda #$02
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_sign_out,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_sign_out,y
    ldy #3
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_184
    ldy #0
    lda (ptr0),y
    ora #$80
    sta (ptr0),y
    jmp @bitfield_store_done_185
@bitfield_store_clear_184:
    ldy #0
    lda (ptr0),y
    and #$7f
    sta (ptr0),y
@bitfield_store_done_185:
    lda #$02
    sta arg0
    jsr _popN
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_mant_ll,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_mant_ll,y
    ldy #3
    sta (fp),y
    ldy #4
    lda #$00
    sta (fp),y
    ldy #5
    lda #$04
    sta (fp),y
    sta arg0
    jsr _fp2ptr0p
    lda #$02
    sta arg0
    jsr _fp2ptr1p
    lda #$02
    sta arg0
    jsr _leNsle
    lda #$04
    sta arg0
    jsr _popN
    lda arg1
    beq @if_false_186
    lda #$02
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_exp_a,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_exp_a,y
    ldy #3
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_188
    ldy #0
    lda (ptr0),y
    ora #$04
    sta (ptr0),y
    jmp @bitfield_store_done_189
@bitfield_store_clear_188:
    ldy #0
    lda (ptr0),y
    and #$fb
    sta (ptr0),y
@bitfield_store_done_189:
    ldy #2
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_190
    ldy #0
    lda (ptr0),y
    ora #$08
    sta (ptr0),y
    jmp @bitfield_store_done_191
@bitfield_store_clear_190:
    ldy #0
    lda (ptr0),y
    and #$f7
    sta (ptr0),y
@bitfield_store_done_191:
    ldy #2
    lda (fp),y
    and #$04
    beq @bitfield_store_clear_192
    ldy #0
    lda (ptr0),y
    ora #$10
    sta (ptr0),y
    jmp @bitfield_store_done_193
@bitfield_store_clear_192:
    ldy #0
    lda (ptr0),y
    and #$ef
    sta (ptr0),y
@bitfield_store_done_193:
    ldy #2
    lda (fp),y
    and #$08
    beq @bitfield_store_clear_194
    ldy #0
    lda (ptr0),y
    ora #$20
    sta (ptr0),y
    jmp @bitfield_store_done_195
@bitfield_store_clear_194:
    ldy #0
    lda (ptr0),y
    and #$df
    sta (ptr0),y
@bitfield_store_done_195:
    ldy #2
    lda (fp),y
    and #$10
    beq @bitfield_store_clear_196
    ldy #0
    lda (ptr0),y
    ora #$40
    sta (ptr0),y
    jmp @bitfield_store_done_197
@bitfield_store_clear_196:
    ldy #0
    lda (ptr0),y
    and #$bf
    sta (ptr0),y
@bitfield_store_done_197:
    lda #$02
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _pushN
    lda #$04
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_mant_ll,y
    ldy #4
    sta (fp),y
    ldy #1
    lda nlf_half_mant_ll,y
    ldy #5
    sta (fp),y
    ldy #6
    lda #$ff
    sta (fp),y
    ldy #7
    lda #$03
    sta (fp),y
    lda #$04
    sta arg0
    jsr _fp2ptr0p
    lda #$06
    sta arg0
    jsr _fp2ptr1p
    lda #$04
    sta arg0
    jsr _fp2ptr2p
    lda #$02
    sta arg0
    jsr _bit_andN
    ldy #4
    lda (fp),y
    ldy #2
    sta (fp),y
    ldy #5
    lda (fp),y
    ldy #3
    sta (fp),y
    lda #$04
    sta arg0
    jsr _popN
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_198
    ldy #0
    lda (ptr0),y
    ora #$01
    sta (ptr0),y
    jmp @bitfield_store_done_199
@bitfield_store_clear_198:
    ldy #0
    lda (ptr0),y
    and #$fe
    sta (ptr0),y
@bitfield_store_done_199:
    ldy #2
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_200
    ldy #0
    lda (ptr0),y
    ora #$02
    sta (ptr0),y
    jmp @bitfield_store_done_201
@bitfield_store_clear_200:
    ldy #0
    lda (ptr0),y
    and #$fd
    sta (ptr0),y
@bitfield_store_done_201:
    ldy #2
    lda (fp),y
    and #$04
    beq @bitfield_store_clear_202
    ldy #0
    lda (ptr0),y
    ora #$04
    sta (ptr0),y
    jmp @bitfield_store_done_203
@bitfield_store_clear_202:
    ldy #0
    lda (ptr0),y
    and #$fb
    sta (ptr0),y
@bitfield_store_done_203:
    ldy #2
    lda (fp),y
    and #$08
    beq @bitfield_store_clear_204
    ldy #0
    lda (ptr0),y
    ora #$08
    sta (ptr0),y
    jmp @bitfield_store_done_205
@bitfield_store_clear_204:
    ldy #0
    lda (ptr0),y
    and #$f7
    sta (ptr0),y
@bitfield_store_done_205:
    ldy #2
    lda (fp),y
    and #$10
    beq @bitfield_store_clear_206
    ldy #0
    lda (ptr0),y
    ora #$10
    sta (ptr0),y
    jmp @bitfield_store_done_207
@bitfield_store_clear_206:
    ldy #0
    lda (ptr0),y
    and #$ef
    sta (ptr0),y
@bitfield_store_done_207:
    ldy #2
    lda (fp),y
    and #$20
    beq @bitfield_store_clear_208
    ldy #0
    lda (ptr0),y
    ora #$20
    sta (ptr0),y
    jmp @bitfield_store_done_209
@bitfield_store_clear_208:
    ldy #0
    lda (ptr0),y
    and #$df
    sta (ptr0),y
@bitfield_store_done_209:
    ldy #2
    lda (fp),y
    and #$40
    beq @bitfield_store_clear_210
    ldy #0
    lda (ptr0),y
    ora #$40
    sta (ptr0),y
    jmp @bitfield_store_done_211
@bitfield_store_clear_210:
    ldy #0
    lda (ptr0),y
    and #$bf
    sta (ptr0),y
@bitfield_store_done_211:
    ldy #2
    lda (fp),y
    and #$80
    beq @bitfield_store_clear_212
    ldy #0
    lda (ptr0),y
    ora #$80
    sta (ptr0),y
    jmp @bitfield_store_done_213
@bitfield_store_clear_212:
    ldy #0
    lda (ptr0),y
    and #$7f
    sta (ptr0),y
@bitfield_store_done_213:
    ldy #3
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_214
    ldy #1
    lda (ptr0),y
    ora #$01
    sta (ptr0),y
    jmp @bitfield_store_done_215
@bitfield_store_clear_214:
    ldy #1
    lda (ptr0),y
    and #$fe
    sta (ptr0),y
@bitfield_store_done_215:
    ldy #3
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_216
    ldy #1
    lda (ptr0),y
    ora #$02
    sta (ptr0),y
    jmp @bitfield_store_done_217
@bitfield_store_clear_216:
    ldy #1
    lda (ptr0),y
    and #$fd
    sta (ptr0),y
@bitfield_store_done_217:
    lda #$02
    sta arg0
    jsr _popN
    jmp @if_end_187
@if_false_186:
    lda #$02
    sta arg0
    jsr _pushN
    ldy #2
    lda #$00
    sta (fp),y
    ldy #3
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    clc
    lda ptr0
    adc #$01
    sta ptr0
    lda ptr0+1
    adc #$00
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_218
    ldy #0
    lda (ptr0),y
    ora #$04
    sta (ptr0),y
    jmp @bitfield_store_done_219
@bitfield_store_clear_218:
    ldy #0
    lda (ptr0),y
    and #$fb
    sta (ptr0),y
@bitfield_store_done_219:
    ldy #2
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_220
    ldy #0
    lda (ptr0),y
    ora #$08
    sta (ptr0),y
    jmp @bitfield_store_done_221
@bitfield_store_clear_220:
    ldy #0
    lda (ptr0),y
    and #$f7
    sta (ptr0),y
@bitfield_store_done_221:
    ldy #2
    lda (fp),y
    and #$04
    beq @bitfield_store_clear_222
    ldy #0
    lda (ptr0),y
    ora #$10
    sta (ptr0),y
    jmp @bitfield_store_done_223
@bitfield_store_clear_222:
    ldy #0
    lda (ptr0),y
    and #$ef
    sta (ptr0),y
@bitfield_store_done_223:
    ldy #2
    lda (fp),y
    and #$08
    beq @bitfield_store_clear_224
    ldy #0
    lda (ptr0),y
    ora #$20
    sta (ptr0),y
    jmp @bitfield_store_done_225
@bitfield_store_clear_224:
    ldy #0
    lda (ptr0),y
    and #$df
    sta (ptr0),y
@bitfield_store_done_225:
    ldy #2
    lda (fp),y
    and #$10
    beq @bitfield_store_clear_226
    ldy #0
    lda (ptr0),y
    ora #$40
    sta (ptr0),y
    jmp @bitfield_store_done_227
@bitfield_store_clear_226:
    ldy #0
    lda (ptr0),y
    and #$bf
    sta (ptr0),y
@bitfield_store_done_227:
    lda #$02
    sta arg0
    jsr _popN
    lda #$02
    sta arg0
    jsr _pushN
    ldy #0
    lda nlf_half_mant_ll,y
    ldy #2
    sta (fp),y
    ldy #1
    lda nlf_half_mant_ll,y
    ldy #3
    sta (fp),y
    lda #<{nlf_half_r + 0}
    sta ptr0
    lda #>{nlf_half_r + 0}
    sta ptr0+1
    ldy #2
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_228
    ldy #0
    lda (ptr0),y
    ora #$01
    sta (ptr0),y
    jmp @bitfield_store_done_229
@bitfield_store_clear_228:
    ldy #0
    lda (ptr0),y
    and #$fe
    sta (ptr0),y
@bitfield_store_done_229:
    ldy #2
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_230
    ldy #0
    lda (ptr0),y
    ora #$02
    sta (ptr0),y
    jmp @bitfield_store_done_231
@bitfield_store_clear_230:
    ldy #0
    lda (ptr0),y
    and #$fd
    sta (ptr0),y
@bitfield_store_done_231:
    ldy #2
    lda (fp),y
    and #$04
    beq @bitfield_store_clear_232
    ldy #0
    lda (ptr0),y
    ora #$04
    sta (ptr0),y
    jmp @bitfield_store_done_233
@bitfield_store_clear_232:
    ldy #0
    lda (ptr0),y
    and #$fb
    sta (ptr0),y
@bitfield_store_done_233:
    ldy #2
    lda (fp),y
    and #$08
    beq @bitfield_store_clear_234
    ldy #0
    lda (ptr0),y
    ora #$08
    sta (ptr0),y
    jmp @bitfield_store_done_235
@bitfield_store_clear_234:
    ldy #0
    lda (ptr0),y
    and #$f7
    sta (ptr0),y
@bitfield_store_done_235:
    ldy #2
    lda (fp),y
    and #$10
    beq @bitfield_store_clear_236
    ldy #0
    lda (ptr0),y
    ora #$10
    sta (ptr0),y
    jmp @bitfield_store_done_237
@bitfield_store_clear_236:
    ldy #0
    lda (ptr0),y
    and #$ef
    sta (ptr0),y
@bitfield_store_done_237:
    ldy #2
    lda (fp),y
    and #$20
    beq @bitfield_store_clear_238
    ldy #0
    lda (ptr0),y
    ora #$20
    sta (ptr0),y
    jmp @bitfield_store_done_239
@bitfield_store_clear_238:
    ldy #0
    lda (ptr0),y
    and #$df
    sta (ptr0),y
@bitfield_store_done_239:
    ldy #2
    lda (fp),y
    and #$40
    beq @bitfield_store_clear_240
    ldy #0
    lda (ptr0),y
    ora #$40
    sta (ptr0),y
    jmp @bitfield_store_done_241
@bitfield_store_clear_240:
    ldy #0
    lda (ptr0),y
    and #$bf
    sta (ptr0),y
@bitfield_store_done_241:
    ldy #2
    lda (fp),y
    and #$80
    beq @bitfield_store_clear_242
    ldy #0
    lda (ptr0),y
    ora #$80
    sta (ptr0),y
    jmp @bitfield_store_done_243
@bitfield_store_clear_242:
    ldy #0
    lda (ptr0),y
    and #$7f
    sta (ptr0),y
@bitfield_store_done_243:
    ldy #3
    lda (fp),y
    and #$01
    beq @bitfield_store_clear_244
    ldy #1
    lda (ptr0),y
    ora #$01
    sta (ptr0),y
    jmp @bitfield_store_done_245
@bitfield_store_clear_244:
    ldy #1
    lda (ptr0),y
    and #$fe
    sta (ptr0),y
@bitfield_store_done_245:
    ldy #3
    lda (fp),y
    and #$02
    beq @bitfield_store_clear_246
    ldy #1
    lda (ptr0),y
    ora #$02
    sta (ptr0),y
    jmp @bitfield_store_done_247
@bitfield_store_clear_246:
    ldy #1
    lda (ptr0),y
    and #$fd
    sta (ptr0),y
@bitfield_store_done_247:
    lda #$02
    sta arg0
    jsr _popN
@if_end_187:
@if_end_151:
@if_end_141:
@fini:
    lda #$02
    sta arg0
    jsr _popN
    rts
.endproc

