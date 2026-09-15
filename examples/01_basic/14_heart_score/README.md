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

The two interactive 4K cartridges instantiate the optional
`line_markers:=1` profile and compose its ten-line output with the maintained
181-line `player_color` gameplay renderer in both orders. A one-line separator
keeps the visible composition at 192 scanlines:

- `heart_score_above_interactive.bin`: marked heart score, one blank line, gameplay.
- `heart_score_below_interactive.bin`: gameplay, one blank line, marked heart score.

Both interactive demos start at 5.5 hearts and 8 marker segments. Right joystick
UP adds half a heart and DOWN removes half a heart, clamped to 0..11. Right
joystick RIGHT adds one marker segment and LEFT removes one, independently
clamped to 0..11. A held direction changes its value only once; return the stick
fully to neutral before the next change. The left joystick moves the selected
gameplay object exactly like the other maintained `player_color_181` interactive
examples; SELECT cycles P0, P1, and Ball. The sprites keep one static animation
frame so the complete two-renderer diagnostic still fits in a plain 4K
cartridge. Reset restarts the scene.

The default heart component remains seven visible scanlines and eight bytes of
RIOT RAM. The marker-enabled profile is ten visible scanlines and twelve bytes.
Its top and bottom marker lines use one configurable playfield color and an
independent 0..11 left-prefix count. Every marker segment is eight pixels wide
on the same 12-pixel pitch as the hearts. Eleven hearts occupy the fixed
X=16..136 footprint; smaller values are exact left-justified prefixes. Half
states through 10.5 draw the left half of the next heart, while 11 is the
maximum state.
