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

This example is still pending display repair. Its smoke test checks the 262-line
frame schedule, VBLANK positioning, P0/P1 row activity, Ball activity, and the
absence of missiles. It does not certify the playfield pixels or serve as a
rendering oracle.

Build with `make`, then run `multicolor_full_static.bin` in Stella.
