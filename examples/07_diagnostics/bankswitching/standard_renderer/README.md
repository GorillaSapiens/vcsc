```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Banked standard all-five renderer

This is the single public banked-renderer diagnostic. It composes the maintained
standard P0/P1/M0/M1/Ball renderer object with the generic F8 C26 cartridge
profile; there is no F8-specific renderer or renderer-specific linker cfg.

All renderer code, the playfield, sprite graphics, score table, and other
beam-critical ROM remain in startup `bank0`. The strong
`vcs_standard_overscan_hook()` and real game logic live in `bank1`. The renderer
calls that hook only after asserting `VBLANK`; the generated cross-bank JSR
restores bank0 before the next frame begins. The hook updates next-frame state
in response to the controls; it also keeps a hook counter,
epoch and signature check. A failed signature check turns the background red.

## Controls

Run `make play` to build and launch the interactive F8 diagnostic.

- **Console SELECT:** cycle P0 → P1 → M0 → M1 → Ball → P0. Release between presses;
  holding SELECT does not repeat. P0 is initially selected.
- **Left joystick:** move only the selected object. X saturates at0..159 and Y
  at0..87 (two-scanline units). Opposing directions prefer left/up. Moving one
  object leaves the other four unchanged; the diagnostic artwork is retained.
- **Right joystick left/right:** select one of the six score digits, starting at
  ones. Left selects the next larger weight; right selects the next smaller,
  wrapping at either end. Each selection advances the score hue as feedback.
- **Right joystick up/down:** add/subtract that digit's decimal weight, with
  normal carry/borrow and999999 ↔000000 wrap. Each press acts once; return fully
  to neutral to re-arm. Diagonals select before editing; left/up win opposing
  directions. Fire is unused.
- **Console RESET:** restore all five positions, the score123456, its colour and
  both selections.

All input handling and score-weight lookup run in bank1 during blanked overscan.
The renderer's visible code and graphics stay in bank0. The public F8 build uses
104/128 RIOT RAM bytes including its12-byte hardware-stack allowance.

The controller regression executes the actual public source as4K, F8, F6, F4 and
F8SC with deterministic frame-indexed input. It checks independent movement,
limits, debounce, BCD arithmetic, RESET, frame periods and bank restoration; native
released-input F8/F8SC frames are compared with the4K witness. Three non-critical
hook bytes move into shared Superchip RAM only in the private F8SC build.
`BANKED_STATIC_TEST` retains the original once-only654321/ball-X104 scene solely
for the existing exact mapper/bridge/raster regressions; it is not the public
default and their pinned assertions are unchanged. The public
Makefile intentionally emits only `f8.bin` to avoid duplicating diagnostics.
Its `play` target explicitly launches Stella with `-bs F8`; VCSC already knows
the cartridge topology, so running the diagnostic does not depend on Stella's
autodetection heuristics.
