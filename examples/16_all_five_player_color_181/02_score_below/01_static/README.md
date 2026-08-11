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

The cartridge currently links at **3967/4090 ROM bytes** (123 free) and
**107/128 RAM bytes** (21 free). It is intentionally static: the score-above
placement leaves too little 4K ROM for the full five-object interactive control
layer used by the 192-line example.

Build with `make`. The result is `all_five_player_color_181_score_below.bin`.
