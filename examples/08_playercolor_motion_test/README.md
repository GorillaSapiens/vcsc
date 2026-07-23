```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Per-row player-color motion test

This cartridge keeps eight distinct logical-row colors on both players while
P0, P1, and BL move asynchronously through the full public X=`0..159` range at
speeds 1, 5, and 7. Because this is a two-scanline kernel, each logical sprite
row normally occupies two physical television scanlines. It is the moving
companion to example 07 and deliberately contains no missiles.

Build from this directory with `make`, then run `playercolor_motion_test.bin` in
Stella.
