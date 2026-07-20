```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# First VCSC cartridge

`solid_color.vcsc` is the first complete unbanked 4K Atari 2600/VCS cartridge
produced by this reduced compiler.

It uses the source-level static-frame ABI to call `choose_background()` and
initialize a local value. The television kernel is intentionally inline 6502
assembly because scanline timing is exact machine behavior, not ordinary C-like
control flow.

Build from this directory after building the toolchain:

```sh
make
```

The result is `solid_color.bin`, a raw 4096-byte cartridge image mapped at
`$F000-$FFFF`, plus `solid_color.map`. The display uses a medium blue background (`COLUBK=$84`). The frame consists of 262 scanlines:
3 VSYNC, 37 vertical blank, 192 visible, and 30 overscan.
