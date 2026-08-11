```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# `all_five_player_color_181` score examples

This group demonstrates the score-composable 181-line combined renderer: all
five ordinary TIA objects remain available while P0 and P1 use independent
eight-row color tables. One eleven-line six-digit score fills the rest of the
standard 192-line visible field.

| No. | Example | Purpose |
|---:|---|---|
| 01 | [`score_above`](01_score_above/) | Fixed six-digit score above 181-line combined gameplay |
| 02 | [`score_below`](02_score_below/) | Fixed six-digit score below 181-line combined gameplay |

The examples are static because this profile plus the independent score nearly
fills a 4K ROM. The renderer itself retains mutable object coordinates and can
be used by a larger or bank-switched application.
