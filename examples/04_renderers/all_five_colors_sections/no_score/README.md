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
restarts. All five objects initially span the narrow section band near the top.
Players use the same four eight-row animation frames as the other section demos;
each player's eight row colours are independently editable in the `.c26` source.
The seven section palettes are also editable in the source's `instantiate`
arguments; changing their heights is not supported in this preview.

This **experimental fixed-layout preview** has seams at visible scanlines
18, 20, 22, 24, 26 and 28. It does not yet accept arbitrary section heights.
It uses ordinary 8K F8 ROM and stock 128-byte RAM, not cartridge RAM. Drawing and
sprite tables stay in bank0; preparation, initialization and controls use bank1.
No sprite mirroring or external source generator is required.

The example-local renderer is not installed as a general public component.
Score-above and score-below combined-colour previews are not supplied yet.
