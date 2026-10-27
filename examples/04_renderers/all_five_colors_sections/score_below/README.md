```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Combined colours: score below

```sh
make play
```

Controls, configuration and the supported fixed layout are the same as
[`score_above`](../score_above/). RAM **122/128**, including eleven stack bytes;
ordinary 8K F8 ROM and one drawing bank, with no mirrored graphics.

**Coupled terminal:** gameplay calls `draw_combined_score_tail()` before its
final WSYNC. That helper completes the timed handoff, draws the score and starts
overscan before returning. Do not add another handoff, score draw or overscan
start after `game_draw()`. Moving the helper after the final WSYNC shifts score
pixels six cycles and is rejected by an exact-RGB mutation test.

This runnable NTSC preview is not an independent score-below component ABI.
Supported heights are exactly `2,2,2,2,2,2,2,162`; other layouts are rejected.
