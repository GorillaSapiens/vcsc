```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Joystick input

This example gives both joystick ports something immediately visible to do.
The **left joystick moves the red square** and the **right joystick moves the
blue square** over a black background. Each direction moves its square one step
per frame, including diagonals when two directions are held together.

Each player normally uses an 8x8 bitmap with a centered 4x4 square:

```text
........
........
..XXXX..
..XXXX..
..XXXX..
..XXXX..
........
........
```

Holding that joystick's fire button changes its player to this 8x8 bitmap:

```text
.XXXXXX.
X......X
X.XXXX.X
X.XXXX.X
X.XXXX.X
X.XXXX.X
X......X
.XXXXXX.
```

The controller wiring is still direct and visible in the source. `SWCHA` is
active low. The left joystick uses the high nibble: `0x10` UP, `0x20` DOWN,
`0x40` LEFT, and `0x80` RIGHT. The right joystick uses the low nibble: `0x01`
UP, `0x02` DOWN, `0x04` LEFT, and `0x08` RIGHT. The left and right fire buttons
are active-low bit 7 of `INPT4` and `INPT5`, respectively.

The example delegates beam timing and player positioning to the normal
`player_color` renderer so the tutorial can stay focused on controller input,
movement, and fire-button state rather than RESP/HMOVE timing.

Build with `make` and run `make play`. Stella normally auto-detects both
joysticks for this cartridge.
