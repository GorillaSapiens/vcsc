```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# `all_five_181_unofficial` examples

This group demonstrates the reviewed stable/common NMOS unofficial-opcode `renderers/all_five_unofficial/all_five_unofficial.c26` lifecycle component instantiated with `lines:=181`. It draws
181 gameplay scanlines and P0, P1, M0, M1, and Ball; an adjacent eleven-line score-profile
component completes the 192-line visible field. Every leaf Makefile passes `-Wa,--illegals` explicitly.

The ten public cartridges form the complete score-composition slice for this
gameplay family: four production score layouts plus the poison diagnostic, each
above and below gameplay. Each layout has one interactive cartridge rather than
separate static and motion variants.

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

The automated matrix builds static and moving-game fixtures for every row and
checks score pixels, gameplay pixels, handoff state, and exact 262-line frames.
