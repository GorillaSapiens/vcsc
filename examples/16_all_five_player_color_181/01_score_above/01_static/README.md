```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Static score-above diagnostic

This cartridge draws P0, P1, M0, M1, and Ball over an asymmetric reflected
playfield. P0 and P1 use visibly different eight-row color tables. A fixed
centered score of `123456` appears above the 181-line gameplay field.

The cartridge currently links at **3739/4090 ROM bytes** (351 free) and
**107/128 RAM bytes** (21 free). It is intentionally kept as a static raster
diagnostic; the compact renderer now leaves enough ROM to consider a small
interactive layer separately.

Build with `make`. The result is `all_five_player_color_181_score_above.bin`.
