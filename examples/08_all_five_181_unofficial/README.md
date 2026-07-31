```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# `all_five_181_unofficial` examples

This group demonstrates the separately named unofficial-opcode 181-line
all-five renderer composed with the independent 11-line score. It exposes P0,
P1, M0, M1, and Ball with the same public state and visible schedule as the
official renderer. Every leaf Makefile passes `-Wa,--illegals` explicitly.

The examples are direct application-level twins of the official score-above and
score-below diagnostics.

| Layout | Draw order | Diagnostic |
|---|---|---|
| [`01_score_above`](01_score_above/) | score, handoff, gameplay | Five-object motion and six-digit score editing |
| [`02_score_below`](02_score_below/) | gameplay, handoff, score | Five-object motion and six-digit score editing |

For the opcode inventory and measured zero-byte result, see
[`libraries/vcs/renderers/all_five_181_unofficial/README.md`](../../libraries/vcs/renderers/all_five_181_unofficial/README.md).
