```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Banked all-five renderer

This is the single public banked-renderer diagnostic. It instantiates the
maintained `renderers/all_five/all_five.c26` 192-line lifecycle component with
the generic F8 C26 cartridge profile; there is no mapper-specific renderer or
renderer-specific linker cfg.

`main()` and every ROM datum used by the beam-critical component live in startup
`bank0`. The application callback `banked_game_logic()` lives in `bank1` and is
called during scheduler-owned overscan while `VBLANK` is asserted. The generated
cross-bank JSR must restore bank0 before the next VSYNC. On its first call the
callback moves the Ball from X=80 to X=104 and records that it ran, so subsequent
frames prove that cross-bank application work can safely update retained renderer
state between visible fields.

The test suite privately compiles this exact source against F6 and F4, compares
all three banked rasters with an unbanked 4K reference, and builds an F8SC variant
whose three non-critical callback bytes live in shared Superchip RAM. The public
Makefile intentionally emits only `f8.bin` to avoid duplicating diagnostics.
Its `play` target explicitly launches Stella with `-bs F8`; VCSC already knows
the cartridge topology, so running the diagnostic does not depend on Stella's
autodetection heuristics.
