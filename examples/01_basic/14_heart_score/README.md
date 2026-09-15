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

The two interactive F8 cartridges compose the seven-line heart component with
the maintained 181-line `player_color` gameplay renderer in both orders. A
four-line blank separator makes the visible field exactly 192 scanlines:

- `heart_score_above_interactive.bin`: heart score, four blank lines, gameplay.
- `heart_score_below_interactive.bin`: gameplay, four blank lines, heart score.

Both interactive demos start at 5.5 hearts with eight capacity boxes. Right
joystick UP/DOWN changes health by half a heart and LEFT/RIGHT changes capacity
by one box. Health cannot exceed capacity; reducing capacity below the current
health clamps the health to the new box count. A held direction changes state
only once; return the stick fully to neutral before the next change. The left
joystick moves the selected gameplay object exactly like the other maintained
`player_color_181` interactive examples; SELECT cycles P0, P1, and Ball. Reset
restarts the scene.

The heart component consumes seven visible scanlines and 16 bytes of RIOT RAM.
Eleven eight-pixel heart/box slots occupy a fixed 12-pixel-pitch footprint;
smaller values are exact left-justified prefixes. `box_color` is one configurable
color shared by every enabled playfield box. Half states through 10.5 draw the
left half of the next heart, while 11 is the maximum state. The larger box-aware
renderer plus the fully interactive gameplay application is why these two
diagnostics use F8 rather than deleting controls to force them into 4K.
