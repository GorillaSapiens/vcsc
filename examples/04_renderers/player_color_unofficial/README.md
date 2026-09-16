```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# `player_color_unofficial` examples

This group demonstrates the reviewed stable/common NMOS unofficial-opcode `renderers/player_color_181_unofficial/player_color_181_unofficial.c26` lifecycle component. It draws
181 gameplay scanlines and P0, P1, and Ball; an adjacent eleven-line score-profile
component completes the 192-line visible field. Every leaf Makefile passes `-Wa,--illegals` explicitly.

The ten public cartridges form the complete score-composition slice for this
gameplay family: four production score layouts plus the poison diagnostic, each
above and below gameplay. Each layout has one interactive cartridge rather than
separate static and motion variants.

| Layout | Score profile | Draw order | Diagnostic |
|---|---|---|---|
| [`score_above/centered`](score_above/centered/) | centered mutable-color six-digit | score, handoff, gameplay | object motion and score editing |
| [`score_below/centered`](score_below/centered/) | centered mutable-color six-digit | gameplay, handoff, score | object motion and score editing |
| [`score_above/left`](score_above/left/) | left-justified fixed-color six-digit | score, handoff, gameplay | object motion and score editing |
| [`score_below/left`](score_below/left/) | left-justified fixed-color six-digit | gameplay, handoff, score | object motion and score editing |
| [`score_above/right`](score_above/right/) | right-justified fixed-color six-digit | score, handoff, gameplay | object motion and score editing |
| [`score_below/right`](score_below/right/) | right-justified fixed-color six-digit | gameplay, handoff, score | object motion and score editing |
| [`score_above/two_plus_two`](score_above/two_plus_two/) | independent left/right two-plus-two | score, handoff, gameplay | object motion plus independently movable score fields |
| [`score_below/two_plus_two`](score_below/two_plus_two/) | independent left/right two-plus-two | gameplay, handoff, score | object motion plus independently movable score fields |
| [`score_above/poison`](score_above/poison/) | hostile poison diagnostic | score, handoff, gameplay | predecessor-state recovery stress |
| [`score_below/poison`](score_below/poison/) | hostile poison diagnostic | gameplay, handoff, score | next-frame recovery stress |

The automated matrix builds static and moving-game fixtures for every row and
checks score pixels, gameplay pixels, handoff state, and exact 262-line frames.
