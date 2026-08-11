```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Static score-below diagnostic

This cartridge draws P0, P1, M0, M1, and Ball over an asymmetric reflected
playfield. P0 and P1 use visibly different eight-row color tables. A fixed
centered score of `123456` appears below the 181-line gameplay field.

The cartridge currently links at **3739/4090 ROM bytes** (351 free) and
**107/128 RAM bytes** (21 free). It remains the minimal static raster diagnostic. The companion `02_interactive`
example uses the recovered ROM space for full two-axis motion of all five objects.

Build with `make`. The result is `all_five_player_color_181_score_below.bin`.
