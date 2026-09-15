```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Heart score component

`heart_score.c26` is the standalone automatic fixed-footprint 0..11 health-meter
demo. It advances in half-heart steps every 30 frames and wraps after eleven
hearts.

The default component profile consumes seven visible scanlines and eight bytes
of RIOT RAM. Eleven hearts occupy the fixed X=16..136 footprint; smaller values
are exact left-justified prefixes. Half states through 10.5 draw the left half
of the next heart, while 11 is the maximum state.

The interactive `player_color` compositions that exercise the optional
line-marker profile live separately under
`04_renderers/player_color/score_above/heart` and
`04_renderers/player_color/score_below/heart`.
