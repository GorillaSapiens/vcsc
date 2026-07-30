```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Faithful legacy interactive diagnostic

The cartridge starts at the retained static certification scene:

- P0 at `(44, 78)`
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

### Score controls

- **Right joystick:** sampled only once every tenth frame. A direction must be
  present in two consecutive samples before it acts; a held stable direction
  then repeats at the ten-frame sample cadence.
- **Right joystick left/right:** select the next digit visually to the left or
  right. The score uses the same conventional left-to-right significance order
  as the eleven-line score components: the hundred-thousands digit is at the
  far left and the ones digit is at the far right. Each accepted digit change
  also adds `$10` to the score color, cycling the TIA hue while preserving
  luminance.
- **Right joystick up/down:** add/subtract that digit's decimal weight
  (`10^n`). Carries and borrows may change neighboring digits.

Build with `make`. The result is
`faithful_legacy_playercolors_interactive.bin`.
