```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Faithful legacy static baseline

This cartridge instantiates the retained Atari 2600 BASIC 1.9 standard-kernel
profile under the template prefix `legacy`:

- P0, P1, and Ball;
- per-row P0/P1 colors;
- the integrated six-digit score;
- original monolithic frame ownership;
- original unofficial `DCP`, `LAX`, `SBX`, and `ASR` instructions;
- stock selected-profile RAM aliases and branch-cycle behavior.

The retained kernel spells its timing-critical branch requirements directly as
`.same` or `.cross`. The linker is therefore responsible for finding a valid
page phase; this example does not pin the loop to a magic ROM low byte.

The deliberately asymmetric playfield makes stale-byte and row-transition
errors visible. The cartridge uses the shared `color_ntsc.c26` aliases instead
of unexplained TIA color bytes, and its two player glyphs are written as
left-to-right visual `0b..XXXX..` rows. The playfield is RAM-backed because
the stock kernel depends on zero-page-indexed reads; putting it in ROM changes
both addressing and timing.

The disabled missile height/Y fields must be initialized before the player-color
pointers because each pair overlays the corresponding two-byte pointer. P0's
color latch likewise aliases the disabled M0 X byte.

One `legacy_drawscreen()` call owns the complete 20,064-cycle, 264-raw-line
frame. This remains a monolithic compatibility baseline, not a composable
lifecycle component.

The regression compares all 1,230 visible TIA events and 42 stable frames
against both the separately linked retained-source audit and the independently
built pristine upstream BASIC 1.9 ROM under
`test/oracles/pristine_basic_v1.9_playercolors/`.

Build with `make` and run `faithful_legacy_static_test.bin` in Stella.
