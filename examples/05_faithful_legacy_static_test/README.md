```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Provisional legacy static baseline

This is the provisional baseline port that should have preceded the derived
gameplay kernels. The pristine upstream Atari 2600 BASIC 1.9 oracle has since
shown that the current VCSC template still differs in selected-profile RAM
aliasing and stable frame period, so this example must not yet be treated as a
gold standard. It instantiates the retained legacy standard kernel's simplest
useful profile under the template prefix `legacy`:

- P0, P1, and Ball;
- per-row P0/P1 colors;
- the integrated six-digit score;
- original monolithic frame ownership;
- original unofficial `DCP`, `LAX`, `SBX`, and `ASR` instructions;
- original instruction ordering and scanline schedule.

The deliberately asymmetric playfield makes stale-byte and row-transition
errors visible. This reference is intentionally not split into lifecycle
components: one `legacy_drawscreen()` call owns the complete retained-source
audit frame. The external gold ROM and known-gap regression are under
`test/oracles/pristine_basic_v1.9_playercolors/`.

Build with `make` and run `faithful_legacy_static_test.bin` in Stella.
