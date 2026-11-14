```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Cooperating layers, score above

```sh
make
make play
make clean
```

For joystick control, run `make play-interactive` (`make interactive` only builds).
`interactive.c26` uses the standard example sprites: console SELECT chooses an
object, left joystick moves it, and right joystick left/right selects a score
digit. Right joystick up/down changes its decimal weight once per press. Fire is unused.
Console RESET restores the scene.
X is bounded to 0..119 for the in-frame positioning entry; Y is 0..85 in
two-scanline units. See the [family controls](../README.md#interactive-controls).
The default automatic rocket preview is unchanged.

A12-line two-plus-two score, eight frame-owner-blanked positioning lines, then
172 gameplay lines (64+64+44). Objects slowly traverse both scenery seams; both
runtime scores increase. The fixed positioning entry requires all X0..119.
Uses56/128 RAM bytes, including stack, and one4K bank. Edit `main.c26`; no other
example leaf is required. See the [family guide](../README.md) for contracts.
