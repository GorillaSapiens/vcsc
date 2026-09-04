```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Interactive all-five 192-line diagnostic

SELECT cycles through P0, P1, M0, M1, and Ball. The left joystick moves the selected object one pixel horizontally or one logical scanline vertically per frame, with both axes clamped to the renderer's complete public range. RESET jumps through the cartridge reset vector and restores the initial scene.

This example is also the current proving ground for animated versions of the
two standard interactive P0/P1 glyphs.  Each player has four 8x8 frames, with
the displayed frame selected independently as `((x ^ y) & 3)`.  Frame zero is
the original static artwork; the other frames are intentionally small pose
changes so the animation can be tuned here before being shared by the other
interactive examples.
