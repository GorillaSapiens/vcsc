; Timing-safe immutable playfield for the ROM contract smoke test.
.segment "PLAYFIELD_RODATA"
.align 256, $54
.export vcs_standard_playfield
vcs_standard_playfield:
   .byte $FF,$FF,$FF,$FF
   .byte $81,$00,$00,$81
   .byte $BD,$FF,$FF,$BD
   .byte $A5,$81,$81,$A5
   .byte $A5,$BD,$BD,$A5
   .byte $A5,$A5,$A5,$A5
   .byte $BD,$A5,$A5,$BD
   .byte $81,$A5,$A5,$81
   .byte $FF,$BD,$BD,$FF
   .byte $00,$81,$81,$00
   .byte $FF,$FF,$FF,$FF
   .byte $00,$00,$00,$00
