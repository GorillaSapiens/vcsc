```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Interactive all-five + player-color 192-line diagnostic

This cartridge exercises the combined `all_five_player_color_192` renderer with
P0, P1, M0, M1, and Ball all visible over an asymmetric reflected playfield.
P0 and P1 use independent eight-row color tables, so their striped colors make
the capability added by this renderer immediately visible.

## Controls

- **Game Select:** cycle the selected object through P0, P1, M0, M1, and Ball.
  One press advances once; holding the switch does not repeat.
- **Left joystick:** move the selected object one horizontal pixel or one
  renderer Y unit per frame. X is clamped to 0 through 159 and Y to 0 through
  95.
- **Game Reset:** jump indirectly through `$FFFC`, restoring the initial scene
  and selecting P0 again.

The cartridge currently links at **97/128 RAM bytes** and **3481/4090 ROM
bytes**.

Build with `make`. The result is `all_five_player_color_192_interactive.bin`.
