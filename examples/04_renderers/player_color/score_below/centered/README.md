```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# 181-line score-below interactive diagnostic

The cartridge starts at the former static certification positions:

- P0 at `(44, 70)`
- P1 at `(108, 42)`
- Ball at `(78, 45)`
- score `123456`

## Controls

- **Game Select:** cycle the selected object through P0, P1, and Ball. One press
  advances once; holding the switch does not repeat.
- **Left joystick:** move the selected object by one horizontal pixel or one
  renderer Y unit per frame. X is clamped to 0 through 159.
- **Game Reset:** jump indirectly through `$FFFC`, the same address used by the
  reset vector, restoring the original scene and control selections.

The player-color profile does not expose M0 or M1 as independently movable
objects.

The renderer's Y range is 0 through 87.

### Score controls

- **Right joystick:** acts immediately once when a direction is first pressed.
  Holding the joystick does not repeat; return it fully to neutral before the
  next direction press can act.
- **Right joystick left/right:** select the next more-/less-significant score
  digit. Each accepted digit change also adds `$10` to the score color, cycling
  the TIA hue while preserving luminance.
- **Right joystick up/down:** add/subtract that digit's decimal weight
  (`10^n`). Carries and borrows may change neighboring digits.

Build with `make`. The result is `player_color_181_score_below_interactive.bin`.
