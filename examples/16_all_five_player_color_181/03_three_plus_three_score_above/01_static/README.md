```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Static three-plus-three score-above diagnostic

This cartridge composes the 181-line `all_five_player_color_181` renderer
with `three_plus_three_score_component.c26` above the gameplay field. The
left half displays `123` and the right half displays `456` in independent
colors. Together the 11-line score and 181-line gameplay field consume exactly
192 visible scanlines.

The cartridge uses all 128 bytes of RIOT RAM, so this example is intentionally
static: it demonstrates that the renderer and dual score fit together without
pretending there is workspace left for interactive controls.

Build with `make`. The result is `all_five_player_color_181_three_plus_three_score_above.bin`.
