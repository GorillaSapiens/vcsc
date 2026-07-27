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

The scene is the same full-height smoke scene used by the kernel regression. Its
built cartridge is checked for exact 262-line frames, all twelve playfield rows,
P0/P1 graphics and row colors, Ball activity, and absence of score ownership.

Build with `make`, then run `multicolor_full_static.bin` in Stella.
