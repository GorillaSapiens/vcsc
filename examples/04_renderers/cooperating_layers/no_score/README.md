```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Cooperating layers, no score

```sh
make
make play
make clean
```

For joystick control, run `make play-interactive` (`make interactive` only builds).
`interactive.c26` uses the standard example sprites: console SELECT chooses one
of the five objects and the left joystick moves it independently. Console RESET
restores the initial state. X is 0..159; Y is 0..95 in two-scanline units.
See the [family controls](../README.md#interactive-controls). The automatic
rocket preview and its default build are retained.

Automatic slow motion through three independent64-line sections, with two
upright animated rockets, both missiles and Ball. Uses46/128 RAM bytes and one
4K bank. Edit all scenery directly in `main.c26`; no generator or score leaf is
required. See the [family guide](../README.md) for shared controls and limits.
