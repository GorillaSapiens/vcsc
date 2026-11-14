```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Cooperating layers, score below

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
X is 0..159; Y is 0..87 in two-scanline units.
See the [family controls](../README.md#interactive-controls). The default
automatic rocket preview is unchanged.

176 gameplay lines (64+64+48), a12-line two-plus-two score, then four blank tail
lines. Objects slowly traverse both scenery seams; both runtime scores increase.
Uses56/128 RAM bytes, including stack, and one4K bank. Score pointers occupy
eight private bytes, independent of the fourteen-byte event schedule. Edit `main.c26`;
no other example leaf is required. See the [family guide](../README.md).
