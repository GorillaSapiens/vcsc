```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Static standard-kernel test

`05_static_kernel_test` is the first complete cartridge built from the
normalized no-bankswitch, no-Superchip standard kernel. It is deliberately not
a game yet. A fixed Breakout-style inspection scene exercises the asymmetric
32x12 playfield, both players, both missiles, the ball, and the six-digit score
without any changing state.

The application supplies the immutable 48-byte playfield in cartridge ROM and
includes the source-level standard-kernel state contract. The cycle-counted
normalized kernel remains a companion assembly input. This makes placement, opcode, and scanline checks deterministic before task
20e adds a VCSC overscan/vblank gameplay hook.

Build after building the toolchain:

```sh
make
```

The result is `static_kernel_test.bin`, an exact 4096-byte unbanked NTSC
cartridge, plus `static_kernel_test.map`.


## Verified profile

The linked cartridge deliberately fixes the timing-sensitive regions:

- normalized kernel code: `$F300..$F5FF`;
- 88-byte decimal score table: `$F600..$F657`;
- immutable playfield base: `$F154`, inside the required `$54..$D0` low-byte
  window;
- hidden assembly stack allowance: two bytes beyond the ordinary call graph.

Stella 7.0's developer overlay reports `262 / 60.0Hz => NTSC*`, and the rendered
frame shows the fixed `123456` score with the asymmetric playfield and object
state. The star is Stella's normal noncanonical-timing marker for this retained
kernel profile; the line count and refresh rate are stable.
