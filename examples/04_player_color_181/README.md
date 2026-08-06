```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# `player_color_181` examples

This group demonstrates the official-opcode `renderers/player_color_181/player_color_181.c26` lifecycle component. It draws
181 gameplay scanlines and P0, P1, and Ball; an adjacent eleven-line score-profile
component completes the 192-line visible field.

The first ten public cartridges form the original score-composition matrix for
this gameplay family: four production score layouts plus the poison diagnostic,
each above and below gameplay. Two additional interactive cartridges prove the widely spaced score above
and below the renderer. They provide direct two-joystick player motion and a changing six-digit score
while leaving fourteen RAM bytes free.

| Layout | Score profile | Draw order | Diagnostic |
|---|---|---|---|
| [`01_score_above`](01_score_above/) | centered mutable-color six-digit | score, handoff, gameplay | object motion and score editing |
| [`02_score_below`](02_score_below/) | centered mutable-color six-digit | gameplay, handoff, score | object motion and score editing |
| [`03_left_justified_score_above`](03_left_justified_score_above/) | left-justified fixed-color six-digit | score, handoff, gameplay | object motion and score editing |
| [`04_left_justified_score_below`](04_left_justified_score_below/) | left-justified fixed-color six-digit | gameplay, handoff, score | object motion and score editing |
| [`05_right_justified_score_above`](05_right_justified_score_above/) | right-justified fixed-color six-digit | score, handoff, gameplay | object motion and score editing |
| [`06_right_justified_score_below`](06_right_justified_score_below/) | right-justified fixed-color six-digit | gameplay, handoff, score | object motion and score editing |
| [`07_two_plus_two_score_above`](07_two_plus_two_score_above/) | independent left/right two-plus-two | score, handoff, gameplay | object motion plus independently movable score fields |
| [`08_two_plus_two_score_below`](08_two_plus_two_score_below/) | independent left/right two-plus-two | gameplay, handoff, score | object motion plus independently movable score fields |
| [`09_poison_score_above`](09_poison_score_above/) | hostile poison diagnostic | score, handoff, gameplay | predecessor-state recovery stress |
| [`10_poison_score_below`](10_poison_score_below/) | hostile poison diagnostic | gameplay, handoff, score | next-frame recovery stress |
| [`11_wide_score_above`](11_wide_score_above/) | widely spaced fixed-color six-digit | score, handoff, gameplay | exact 88-pixel score raster plus gameplay preservation |
| [`12_wide_score_below`](12_wide_score_below/) | widely spaced fixed-color six-digit | gameplay, handoff, score | exact 88-pixel score raster plus gameplay preservation |

The automated matrix builds static and moving-game fixtures for the original
forty compositions. A separate wide-score composition regression builds both
new public cartridges and checks the exact six-glyph write schedule, the complete
181-line gameplay raster, the handoff boundary, and exact 262-line frames.
