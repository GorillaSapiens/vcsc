```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Combined-colour interactive preview

```sh
make
make play
```

Joystick 0 moves the selected object, Select cycles P0/P1/M0/M1/ball, and Reset
restarts. The five objects start at different heights across the display.
Players use the same four eight-row animation frames as the other section demos;
each player's eight row colours are independently editable in the `.c26` source.
The eight section palettes are also editable in the source's `instantiate`
arguments; changing their heights is not supported in this preview.

This **experimental fixed-layout preview** has seams at visible scanlines
16, 32, 48, 64, 96, 128 and 160. The eight heights are
**16, 16, 16, 16, 32, 32, 32, 32**, totaling 192 scanlines.
It does not yet accept arbitrary section heights. The two visual playfield row
aliases repeat down the display; edit those aliases rather than individual copies.
It uses ordinary 8K F8 ROM and 100 of the stock 128 RAM bytes, not cartridge RAM. Drawing and
sprite tables stay in bank0; preparation, initialization and controls use bank1.
No sprite mirroring or external source generator is required.

The example-local renderer is not installed as a general public component.
Score-above and score-below combined-colour previews are not supplied yet.
