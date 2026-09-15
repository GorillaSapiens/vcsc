```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Heart score

`heart_score.c26` is the automatic fixed-footprint 0..11 health-meter demo. It
advances in half-heart steps every 30 frames and wraps after eleven hearts.

The two interactive 4K cartridges compose the seven-line heart component with
the maintained 181-line `player_color` gameplay renderer in both orders. A
four-line blank separator makes the visible field exactly 192 scanlines:

- `heart_score_above_interactive.bin`: heart score, four blank lines, gameplay.
- `heart_score_below_interactive.bin`: gameplay, four blank lines, heart score.

Both interactive demos start at 5.5 hearts. Right joystick UP adds half a heart
and DOWN removes half a heart, clamped to 0..11. A held direction changes health
only once; return the stick fully to neutral before the next change. The gameplay
scene is intentionally static so these examples spend their ROM budget on the
real `player_color_181` and heart renderers rather than unrelated controls. Reset
restarts the scene.

The heart component consumes seven visible scanlines and eight bytes of RIOT
RAM. Eleven eight-pixel hearts occupy a fixed 12-pixel-pitch footprint; smaller
values are exact left-justified prefixes. Half states through 10.5 draw the left
half of the next heart, while 11 is the maximum state.
