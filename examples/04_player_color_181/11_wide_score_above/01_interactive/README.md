```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# player_color_181 wide score above

This cartridge composes the 11-line widely spaced six-glyph score before the
181-line `player_color_181` gameplay renderer. The explicit
`vcs_ntsc_component_handoff()` keeps the combined visible field at exactly 192
lines.

The score starts at packed-BCD `123456`. Its 8-pixel glyphs begin at visible X
positions `36, 52, 68, 84, 100, 116`, for an 88-pixel span. P0, P1, the Ball,
the playfield, and both per-row player color tables remain active in the adjacent
gameplay region.

The example is interactive:

- The left joystick moves P0 one pixel horizontally or one gameplay row
  vertically.
- The right joystick independently moves P1.
- The Ball and playfield remain active while the packed-BCD score increments
  every 20 frames.
- Game Reset restarts the cartridge.

The compact wide-score pipeline owns 17 bytes, the same as the centered score.
This complete interactive cartridge uses 3,013 ROM bytes and 114 of 128 RAM
bytes, leaving fourteen bytes free. The focused composition without controls uses
110 total RAM bytes.

Build with `make`. The result is
`player_color_181_wide_score_above_interactive.bin`.
