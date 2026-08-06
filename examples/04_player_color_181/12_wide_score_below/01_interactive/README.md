```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# 181-line wide score-below interactive diagnostic

The cartridge starts at the standard player-color interactive positions:

- P0 at `(44, 70)`
- P1 at `(108, 42)`
- Ball at `(78, 45)`
- score `123456`

The wide score uses 8-pixel glyph origins at X=`36,52,68,84,100,116`, giving
16-pixel pitch and an 88-pixel span. It is drawn after the 181-line gameplay
region, with an explicit component handoff between them.

## Controls

- **Game Select:** cycle the selected object through P0, P1, and Ball. One press
  advances once; holding the switch does not repeat.
- **Left joystick:** move the selected object by one horizontal pixel or one
  renderer Y unit per frame. X is clamped to 0 through 159.
- **Game Reset:** jump indirectly through `$FFFC`, restoring the original scene,
  score, selected digit, and object selection.

The player-color profile does not expose M0 or M1 as independently movable
objects. The renderer's Y range is 0 through 87.

### Score controls

- **Right joystick:** sampled once every twentieth frame. A direction must be
  present in two consecutive samples before it acts; a held stable direction
  repeats at the twenty-frame sample cadence.
- **Right joystick left/right:** select the next more-/less-significant score
  digit. Each accepted digit change also adds `$10` to the score color, cycling
  the TIA hue while preserving luminance.
- **Right joystick up/down:** add/subtract that digit's decimal weight (`10^n`).
  Carries and borrows may change neighboring digits.

The wide component owns 18 bytes: the same compact score/pointer/row/delayed
state as the centered mutable-color component, including its one-byte color.
The complete cartridge uses 3,306 ROM bytes and 118 of 128 RAM bytes, leaving
ten bytes free.

Build with `make`. The result is
`player_color_181_wide_score_below_interactive.bin`.
