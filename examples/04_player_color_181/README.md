```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# `player_color_181` examples

This group demonstrates the official-opcode
`renderers/player_color_181/player_color_181.c26` lifecycle component.

The renderer draws exactly 181 gameplay lines using eleven playfield rows of
sixteen scanlines plus its score-safe visible handoff. It draws P0, P1, and Ball
with independent page-contained player-color tables; M0 and M1 are absent. The
remaining eleven visible lines are supplied by the independent
`six_glyph_color_component.c26` score, producing a complete 192-line visible field.

Each layout now has one interactive diagnostic rather than separate static,
horizontal-motion, and two-axis-motion cartridges.

| Layout | Draw order | Diagnostic |
|---|---|---|
| [`01_score_above`](01_score_above/) | score, handoff, gameplay | P0/P1/Ball motion and six-digit score editing |
| [`02_score_below`](02_score_below/) | gameplay, handoff, score | P0/P1/Ball motion and six-digit score editing |

For the complete resource and timing contract, see
[`libraries/vcs/renderers/player_color_181/README.md`](../../libraries/vcs/renderers/player_color_181/README.md).
