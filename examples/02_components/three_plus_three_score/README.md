```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Dual three-digit score

This 2K example instantiates `three_plus_three_score_component.c26` once to draw
independent three-digit packed-BCD scores centered in the left and right halves
of the screen. The fields have independent colors and increment together every
20 frames, wrapping explicitly from 999 to 000.

The glyph origins are X=20,36,52 on the left and X=100,116,132 on the right.
The score component consumes 11 visible scanlines and composes with the shared
`frame_ntsc.c26` scheduler.
