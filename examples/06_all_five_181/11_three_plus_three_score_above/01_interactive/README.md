```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Interactive three-plus-three score-above diagnostic

The score is drawn **above** the 181-line all-five gameplay field. SELECT cycles
through P0, P1, M0, M1, and Ball; the left joystick moves the selected object.

The right joystick is sampled every twentieth frame and requires two matching
samples. Left/right selects one of the six visible score digits. Up/down
adds/subtracts that digit's decimal weight in the containing three-digit packed-
BCD field. Each accepted horizontal selection change advances that field's hue,
so the independently colored left and right scores also show which field received
the selection. RESET restores `123` / `456` and the initial scene.
