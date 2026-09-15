```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Heart score below player_color

This 4K interactive cartridge runs the maintained 181-line `player_color`
renderer first, then one blank separator line and the ten-line marker-enabled
heart score, for 192 visible scanlines total. This order also certifies that the
heart renderer re-establishes its own player positioning after preceding
renderer state.

It starts at 5.5 hearts and 8 marker segments. Right joystick UP/DOWN changes
health by half a heart, RIGHT/LEFT changes the independent marker count, and a
held direction changes its value only once until the stick returns to neutral.
The left joystick moves the selected P0, P1, or Ball; SELECT cycles that
selection and Reset restarts the scene.
