; Immutable 32x12 asymmetric playfield for the static kernel test.
.segment "PLAYFIELD_RODATA"
.align 256, $54
.export vcs_standard_playfield
vcs_standard_playfield:
   .byte $FF,$FF,$FF,$FF
   .byte $AA,$55,$AA,$55
   .byte $55,$AA,$55,$AA
   .byte $CC,$33,$CC,$33
   .byte $33,$CC,$33,$CC
   .byte $00,$00,$00,$00
   .byte $80,$00,$00,$01
   .byte $80,$00,$00,$01
   .byte $80,$00,$00,$01
   .byte $00,$00,$00,$00
   .byte $FF,$FF,$FF,$FF
   .byte $81,$00,$00,$81
