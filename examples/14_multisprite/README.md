```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Parameterized multisprite examples

These examples exercise the modern composable derivative of the faithful legacy
multisprite raster. The renderer uses the required `lines` instantiation
parameter and retains one stable/common NMOS `LAX`, so these cartridges build
with `-Wa,--illegals`.

- `01_192` demonstrates the full 192-line profile interactively.
- `02_181_score_above` composes an independent 11-line score above the 181-line
  gameplay profile.
- `03_181_score_below` composes the same score below gameplay.

The interactive scene keeps the proven vertical multiplexing schedule fixed.
Select cycles P0 and the five logical P1 sprites, and the left joystick moves
the selected sprite horizontally.
