```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Joystick input

This is a deliberately small left-controller tutorial. It reads the four
active-low direction bits from `SWCHA` and the active-low fire button from
`INPT4`. It does not use a reusable display renderer, game rules, collision
logic, or a controller abstraction, so the hardware reads stay obvious.

The visible screen is five horizontal bands, from top to bottom: **UP**,
**DOWN**, **LEFT**, **RIGHT**, and **FIRE**. Direction bands are dark blue while
released and turn green while held. The fire band is dark blue while released
and turns red while pressed.

For the left joystick, the direction inputs are `SWCHA` bits 4 through 7:
`0x10` is UP, `0x20` is DOWN, `0x40` is LEFT, and `0x80` is RIGHT. A pressed
direction clears its bit. The left fire button is bit 7 of `INPT4`; it is also
clear while pressed. The source samples both registers during VBLANK, then uses
the captured values for the entire visible frame.

Build with `make` and run `make play`. Stella normally auto-detects a joystick
for this cartridge.
