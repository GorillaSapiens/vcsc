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
includes the source-level standard-kernel state contract. `CTRLPF` is set to
reflected-playfield mode, as required by this asymmetric standard-kernel write
schedule. The cycle-counted normalized kernel remains a companion assembly
input. This makes placement, opcode, and scanline checks deterministic before
task 20e adds a VCSC overscan/vblank gameplay hook.

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
- immutable playfield base: page-aligned temporarily so all 48 direct indexed
  reads remain within one page;
- hidden assembly stack allowance: two bytes beyond the ordinary call graph;
- repeated visible playfield writes at CPU cycles `24, 31, 38, 45` on each
  complete kernel scanline.

Stella 7.0's developer overlay reports `262 / 60.0Hz => NTSC*`, and the rendered
frame shows the fixed `123456` score with a centered, untorn asymmetric
playfield and object state. The normalized kernel preserves the retained
cycle-balanced ten-cycle player draw/skip paths, aligns the hot loop, and keeps
the skip stubs on the same page so taken branches cannot add a conditional
page-cross cycle. The star is Stella's normal noncanonical-timing marker for
this retained kernel profile; the line count and refresh rate are stable.

## Placement and object coverage

`static_kernel_playfield.s` temporarily uses `.align 256` to keep the immutable
48-byte playfield within one page until linker page-containment metadata lands.
The kernel now uses ordinary zero-based indexing; there is no `$54` placement
rule and no source-level padding array. The scene deliberately makes every supported
display object visible: a double-width white paddle (P0), an upright white
alien (P1), separate white missiles M0 and M1, and a gold ball.
`VCS_STANDARD_SPRITE_GLYPH` accepts player art top-to-bottom and reverses
storage for the kernel's descending row index.
