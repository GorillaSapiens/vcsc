```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Two Indy 500 driving controllers

This example reads one Atari Indy 500 driving controller in each controller
port. The left controller drives a P0 hexadecimal glyph centered in the left
half of the screen; the right controller drives P1 in the right half.

Each side starts at `0`. Turning its controller clockwise increments the glyph
through `0`..`9`,`A`..`F`; turning counterclockwise decrements it. Both directions
wrap naturally between `0` and `F`. The glyph is white while the controller
button is released and red for exactly as long as the button is held. The
background uses the project's blue.

`libraries/vcs/driving_controller.c26` decodes the two-bit Gray code on pins 1
and 2: left SWCHA D4/D5 and right SWCHA D0/D1. Written as pin1:pin2,
the clockwise sequence is `11 -> 10 -> 00 -> 01 -> 11`; counterclockwise is the reverse. Each call to
`sample()` reports a signed `step` and adds that movement to the signed `delta`
for the current application frame. `begin_frame()` resets that accumulation.
An opposite-state jump means one intermediate Gray state was missed; the
component preserves a known direction and counts that case as two steps. Before
a direction has been established it refuses to guess.

The example samples both controllers three times during VBLANK and three more
times during overscan. All input-dependent work stays in timer-owned blanking
periods, so the visible raster remains a stable 262-line NTSC frame. The 16
hexadecimal glyphs come directly from `fonts/big_hex.c26`.

The fire button is pin 6: INPT4 on the left and INPT5 on the right. Current
Stella does not auto-detect Indy 500 driving controllers from a ROM, so select
**Driving** for the left and right controller types when running this example in
Stella.
