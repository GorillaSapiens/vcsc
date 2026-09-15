```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# 192-line player-color interactive diagnostic

The cartridge starts at the former static certification positions:

- P0 at `(44, 70)`
- P1 at `(108, 42)`
- Ball at `(78, 45)`

## Controls

- **Game Select:** cycle the selected object through P0, P1, and Ball. One press
  advances once; holding the switch does not repeat.
- **Left joystick:** move the selected object by one horizontal pixel or one
  renderer Y unit per frame. X is clamped to 0 through 159.
- **Game Reset:** jump indirectly through `$FFFC`, the same address used by the
  reset vector, restoring the original scene and control selections.

The player-color profile does not expose M0 or M1 as independently movable
objects.

The renderer's Y range is 0 through 95. This scoreless profile uses the right
joystick for nothing.

Build with `make`. The result is `player_color_192_interactive.bin`.
