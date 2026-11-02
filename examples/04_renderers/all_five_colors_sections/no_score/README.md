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
arguments, along with `section1_lines` through `section8_lines`.

This **experimental even-line preview** defaults to seams at visible scanlines
6, 18, 46, 80, 114, 150 and 190. The eight heights are
**6, 12, 28, 34, 34, 36, 40, 2**, totaling 192 scanlines.
Heights must be even and total 192. Section one must be nonempty;
later slots may have zero height. Boundaries can cross playfield rows and may
be two scanlines apart, including at the bottom of the display.
Movement extends to Y=103, allowing objects to cross the last boundary and clip
below the display rather than stopping above it.
The two visual playfield row
aliases repeat down the display; edit those aliases rather than individual copies.
It uses ordinary 8K F8 ROM and 106 of the stock 128 RAM bytes, not cartridge RAM. Drawing and
sprite tables stay in bank0; preparation, initialization and controls use bank1.
No sprite mirroring or external source generator is required.

The example-local renderer is not installed as a general public component.
The sibling score previews retain their bounded geometry; they do not yet use
this display-wide scheduler. Arbitrary, distinct playfield rows remain unsupported.
