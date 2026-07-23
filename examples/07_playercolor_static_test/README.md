```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Per-row player-color static test

This cartridge exercises the separate unbanked 4K NTSC P0+P1+BL standard
kernel. Both eight-row player sprites are stationary and use a different TIA
color on every logical bitmap row. Because this is a two-scanline kernel, each
logical row normally occupies two physical scanlines. M0 and M1 are
intentionally unavailable.

Build from this directory with `make`, then run `playercolor_static_test.bin` in
Stella. The fixed ruler playfield, ball, score, and separated players make color
and vertical-timing errors obvious.
