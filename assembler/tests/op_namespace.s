; Compiler operator-overload symbols start with ?@op_ and are linker-visible,
; unlike ordinary @local assembler labels.
.export ?@op_add@int_p0_a0@int_p0_a0
.import ?@op_sub@int_p0_a0@int_p0_a0

.proc ?@op_add@int_p0_a0@int_p0_a0
    jsr ?@op_sub@int_p0_a0@int_p0_a0
@local:
    bne @local
    rts
.endproc
