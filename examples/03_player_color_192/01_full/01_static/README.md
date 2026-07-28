```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Multicolor Full Static

This example uses the official scoreless `player_color_192` component to draw a
full 192-line NTSC gameplay field.

It displays a twelve-row asymmetric playfield, two fixed eight-row multicolor
players, and the Ball. It contains no score component, score font, or missiles.
The source uses visual binary rows and the shared NTSC color aliases.

This example is the exact static certification scene for the 192-line renderer.
Its regression builds the public source, verifies stable 262-line frames and
VBLANK-only positioning, and checks all twelve asymmetric playfield rows at the
actual TIA write phases together with every P0/P1 graphics and color row, Ball
activity, and the absence of missiles. The resulting cartridge was also reviewed
in Stella 7.0; historical checked-in PNGs are not used as correctness oracles.

Build with `make`, then run `multicolor_full_static.bin` in Stella.
