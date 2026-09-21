```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# `player_color` examples

This group demonstrates the official-opcode player-color specialization of `renderers/all_five/all_five.c26` (`missiles:=0, player_colors:=1`). The `score_above` and `score_below` trees draw 181 gameplay scanlines and P0, P1, and Ball; an adjacent score-profile component completes the 192-line visible field. The renderer family also contains the scoreless, animated-sprite, and dual-score demonstrations alongside these 181-line compositions.

The first ten public cartridges form the original score-composition matrix for
this gameplay family: four production score layouts plus the poison diagnostic,
each above and below gameplay. Two additional interactive cartridges prove the widely spaced score above
and below the renderer. They follow the same Game Select, selected-object motion,
right-joystick score editing, score-color, reset, playfield, sprite, and per-row
color conventions as the centered interactive pair, while leaving ten RAM bytes
free.

| Layout | Score profile | Draw order | Diagnostic |
|---|---|---|---|
| [`01_score_above`](score_above/centered/) | centered mutable-color six-digit | score, handoff, gameplay | object motion and score editing |
| [`02_score_below`](score_below/centered/) | centered mutable-color six-digit | gameplay, handoff, score | object motion and score editing |
| [`03_left_justified_score_above`](score_above/left/) | left-justified fixed-color six-digit | score, handoff, gameplay | object motion and score editing |
| [`04_left_justified_score_below`](score_below/left/) | left-justified fixed-color six-digit | gameplay, handoff, score | object motion and score editing |
| [`05_right_justified_score_above`](score_above/right/) | right-justified fixed-color six-digit | score, handoff, gameplay | object motion and score editing |
| [`06_right_justified_score_below`](score_below/right/) | right-justified fixed-color six-digit | gameplay, handoff, score | object motion and score editing |
| [`07_two_plus_two_score_above`](score_above/two_plus_two/) | independent left/right two-plus-two | score, handoff, gameplay | object motion plus independently movable score fields |
| [`08_two_plus_two_score_below`](score_below/two_plus_two/) | independent left/right two-plus-two | gameplay, handoff, score | object motion plus independently movable score fields |
| [`09_poison_score_above`](score_above/poison/) | hostile poison diagnostic | score, handoff, gameplay | predecessor-state recovery stress |
| [`10_poison_score_below`](score_below/poison/) | hostile poison diagnostic | gameplay, handoff, score | next-frame recovery stress |
| [`11_wide_score_above`](score_above/wide/) | widely spaced mutable-color six-digit | score, handoff, gameplay | standard object motion and score editing plus exact 88-pixel raster |
| [`12_wide_score_below`](score_below/wide/) | widely spaced mutable-color six-digit | gameplay, handoff, score | standard object motion and score editing plus exact 88-pixel raster |

The automated matrix builds static and moving-game fixtures for the original
forty compositions. A separate wide-score composition regression builds both
new public cartridges and checks the exact six-glyph write schedule, the complete
181-line gameplay raster, the handoff boundary, and exact 262-line frames.
