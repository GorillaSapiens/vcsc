; floating-point compare helper
;
; Inputs:
;   ptr0 - lhs
;   ptr1 - rhs
;   arg0 - total size in bytes
;   arg1 - exponent bit count (currently unused by the ordered finite-value path)
; Layout is always SEM from the most-significant bit down.
;
; Result:
;   arg1 = comparison result
;          $ff => lhs < rhs
;          $00 => lhs == rhs
;          $01 => lhs > rhs
;
; Notes:
;   - treats +0 and -0 as equal
;   - orders finite values and infinities correctly for IEEE-style encodings
;   - NaN payload semantics are not yet handled specially
;
.include "nlib.inc"
.export _fcmp

.proc _fcmp
    ; tmp0 = sign-byte index
    lda arg0
    sec
    sbc #1
    sta tmp0

    ; tmp1 = lhs zero accumulator (ignoring sign)
    lda #0
    sta tmp1
    ldy #0
@lhs_zero_loop:
    lda (ptr0), y
    cpy tmp0
    bne @lhs_zero_or
    and #$7f
@lhs_zero_or:
    ora tmp1
    sta tmp1
    iny
    cpy arg0
    bne @lhs_zero_loop

    ; tmp2 = rhs zero accumulator (ignoring sign)
    lda #0
    sta tmp2
    ldy #0
@rhs_zero_loop:
    lda (ptr1), y
    cpy tmp0
    bne @rhs_zero_or
    and #$7f
@rhs_zero_or:
    ora tmp2
    sta tmp2
    iny
    cpy arg0
    bne @rhs_zero_loop

    ; +0 == -0
    lda tmp1
    ora tmp2
    beq @equal

    ; tmp1 = lhs negative? 0/1
    ldy tmp0
    lda (ptr0), y
    and #$80
    beq @lhs_positive
    lda #1
    bne @lhs_sign_done
@lhs_positive:
    lda #0
@lhs_sign_done:
    sta tmp1

    ; tmp2 = rhs negative? 0/1
    lda (ptr1), y
    and #$80
    beq @rhs_positive
    lda #1
    bne @rhs_sign_done
@rhs_positive:
    lda #0
@rhs_sign_done:
    sta tmp2

    ldy tmp0
@cmp_loop:
    lda (ptr0), y
    sta tmp3
    lda (ptr1), y
    sta tmp4

    ; transform lhs into tmp3 for sortable unsigned compare
    lda tmp1
    beq @lhs_nonneg
    lda tmp3
    eor #$ff
    sta tmp3
    jmp @lhs_done
@lhs_nonneg:
    cpy tmp0
    bne @lhs_done
    lda tmp3
    eor #$80
    sta tmp3
@lhs_done:

    ; transform rhs into tmp4 for sortable unsigned compare
    lda tmp2
    beq @rhs_nonneg
    lda tmp4
    eor #$ff
    sta tmp4
    jmp @rhs_done
@rhs_nonneg:
    cpy tmp0
    bne @rhs_done
    lda tmp4
    eor #$80
    sta tmp4
@rhs_done:

    lda tmp3
    cmp tmp4
    bcc @less
    bne @greater
    dey
    bpl @cmp_loop

@equal:
    lda #0
    sta arg1
    rts

@less:
    lda #$ff
    sta arg1
    rts

@greater:
    lda #$01
    sta arg1
    rts
.endproc
