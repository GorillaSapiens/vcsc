```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# `player_color_181_unofficial` examples

This group demonstrates the separately named unofficial-opcode
`renderers/player_color_181_unofficial/player_color_181_unofficial.c26`
lifecycle component. It has the same P0/P1/Ball API and 181-line score
composition contract as the official renderer, but uses reviewed stable/common
NMOS unofficial opcodes. Every leaf Makefile therefore passes
`-Wa,--illegals` explicitly.

The two examples are deliberately direct twins of the official diagnostics so
their controls and visible behavior can be compared without changing the
application.

| Layout | Draw order | Diagnostic |
|---|---|---|
| [`01_score_above`](01_score_above/) | score, handoff, gameplay | P0/P1/Ball motion and six-digit score editing |
| [`02_score_below`](02_score_below/) | gameplay, handoff, score | P0/P1/Ball motion and six-digit score editing |

For the opcode inventory, resource contract, and measured result, see
[`libraries/vcs/renderers/player_color_181_unofficial/README.md`](../../libraries/vcs/renderers/player_color_181_unofficial/README.md).
