```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Blank screen

`blank_screen.c26` is the first complete unbanked 4K Atari 2600/VCS cartridge
produced by this reduced compiler.

It calls `choose_background()` using VCSC's fixed-symbol function model: the
parameter and named local storage are statically allocated, while the local
initializer runs when control reaches its declaration. The television renderer is intentionally inline 6502
assembly because scanline timing is exact machine behavior, not ordinary C-like
control flow.

Build from this directory after building the toolchain:

```sh
make
```

The result is `blank_screen.bin`, a raw 4096-byte cartridge image mapped at
`$F000-$FFFF`, plus `blank_screen.map`. The display uses a medium blue background (`COLUBK=$84`). The frame consists of 262 scanlines:
3 VSYNC, 37 vertical blank, 192 visible, and 30 overscan.
