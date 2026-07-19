; Linker-visible symbols may contain ? and @ as long as they do not begin with
; @, which remains reserved for assembler-local labels.
.export ?@compiler_entry
.import ?@runtime_helper

.proc ?@compiler_entry
    jsr ?@runtime_helper
@local:
    bne @local
    rts
.endproc
