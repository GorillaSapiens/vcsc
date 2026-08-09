```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Interactive 192-line multisprite diagnostic

Build with `make`. Select cycles P0 and the five logical sprites multiplexed
through P1. The left joystick moves the selected sprite left/right/up/down over
the complete maintained coordinate range; Reset restores the scene.

Joystick Up moves toward larger Y, Down toward smaller Y, and Y=0 is the fully clipped bottom edge. Public P1 X positions run from the left edge at 0 through the rightmost position at 159 without a vertical-sort-dependent horizontal shift.

If two or more logical sprites multiplexed through P1 occupy overlapping
scanlines, the retained sorter intentionally flickers them. Its priority order
persists across frames, so the conflicting sprites take turns being displayed
instead of the lower-numbered sprite disappearing continuously.
