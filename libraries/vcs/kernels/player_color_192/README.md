```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Player-color 192-line gameplay component

`player_color_192.c26` is the official-opcode, scoreless full-height P0/P1/Ball
profile with independent per-row P0 and P1 color tables. Instantiate it after
`vcs.c26` and drive its four lifecycle functions from `frame_ntsc.c26`.

The application supplies page-contained `INSTANCE_playfield[48]`,
`INSTANCE_player0_colors[8]`, and `INSTANCE_player1_colors[8]` objects plus
page-contained player graphics. The component owns exactly 192 visible lines;
it cannot be combined with an eleven-line score inside the standard visible
field.

RAM contract: 13 public bytes, 53 private bytes, 66 bytes total. The component
also contains the same 176-byte packed player-position support used by the
181-line profile. Missiles are unavailable. It owns no score/font, VSYNC,
VBLANK, or RIOT timer state and uses only official NMOS 6502 opcodes.

`vcs_ntsc_end_vblank()` supplies the canonical cycle-3 entry phase. The first
two setup lines re-establish P1/P0 position for all X coordinates, and the third
applies HMOVE and restores NUSIZ. Ball is positioned during VBLANK.

The full-height regression places P0, P1, and Ball in the terminal gameplay
band and verifies the special twelfth-row paths rather than merely recognizing
their source labels. It checks all eight terminal P0/P1 graphics activations,
all row-color writes including the special final P1 write, Ball activity in the
last band, the complete twelve-row playfield raster, and the final 262-line
frame boundary.

A second fixture runs the 192-line frame after the poison debug component has
left hostile P0/P1 state during the preceding overscan. The next frame restores
P0/P1/Ball positions and produces the same measured raster and horizontal pixel
endpoints. No score code, font, or score RAM is linked.

## Reviewed Stella reference

The terminal-band fixture has a reviewed Stella 7.0 capture:

Source-tree reference:

```text
test/fixtures/player_color_192/reference_terminal_stella_7.0.png
```

The image is hash-locked by the regression. P0, P1, and Ball visibly reach the
bottom gameplay band, providing a human review alongside the exact terminal
write and line-boundary checks.
