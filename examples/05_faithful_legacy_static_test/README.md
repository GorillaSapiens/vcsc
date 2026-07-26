```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Faithful legacy static kernel

This is the baseline port that should have preceded the derived gameplay
kernels. It instantiates the retained legacy standard kernel's simplest useful
profile under the template prefix `legacy`:

- P0, P1, and Ball;
- per-row P0/P1 colors;
- the integrated six-digit score;
- original monolithic frame ownership;
- original unofficial `DCP`, `LAX`, `SBX`, and `ASR` instructions;
- original instruction ordering and scanline schedule.

The deliberately asymmetric playfield makes stale-byte and row-transition
errors visible. This reference is intentionally not split into lifecycle
components: one `legacy_drawscreen()` call owns the complete retained frame.

Build with `make` and run `faithful_legacy_static_test.bin` in Stella.
