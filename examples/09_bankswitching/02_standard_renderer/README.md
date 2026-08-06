```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Banked standard all-five renderer

This is the single public banked-renderer diagnostic. It composes the maintained
standard P0/P1/M0/M1/Ball renderer object with the generic F8 C26 cartridge
profile; there is no F8-specific renderer or renderer-specific linker cfg.

All renderer code, the playfield, sprite graphics, score table, and other
beam-critical ROM remain in startup `bank0`. The strong
`vcs_standard_overscan_hook()` and real game logic live in `bank1`. The renderer
calls that hook only after asserting `VBLANK`; the generated cross-bank JSR
restores bank0 before the next frame begins.

The test suite privately compiles this exact source against F6 and F4, compares
all three banked rasters with an unbanked 4K reference, and builds an F8SC variant
whose three non-critical hook bytes live in shared Superchip RAM. The public
Makefile intentionally emits only `f8.bin` to avoid duplicating diagnostics.
