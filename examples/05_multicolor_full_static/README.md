```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Multicolor Full Static

This is the oracle-backed static multicolor baseline restored from the verified
`bec461cf082f9e6ed58641587e7fddca37da7b10` tree.

It instantiates the retained Atari 2600 BASIC 1.9 standard player-color kernel
under the template prefix `legacy` and preserves:

- P0, P1, and Ball;
- per-row P0/P1 colors;
- the integrated six-digit score;
- the original monolithic frame schedule;
- the selected-profile RAM aliases;
- the original unofficial `DCP`, `LAX`, `SBX`, and `ASR` instructions; and
- all timing-critical `.same` and `.cross` branch contracts.

The playfield is deliberately asymmetric so stale bytes and row-transition
errors are visible. It is RAM-backed because the kernel requires zero-page
indexed loads for its exact timing. The sprite rows use readable `0b..XXXX..`
notation and the colors use `color_ntsc.c26` aliases.

This example is not certified against a self-generated golden cartridge. Its
built ROM is compared directly with the independently built pristine upstream
BASIC 1.9 ROM under `test/oracles/pristine_basic_v1.9_playercolors/`. The two
match all 1,230 visible TIA events across 42 stable 20,064-cycle, 264-raw-line
frames, including all eight P0/P1 graphics and color rows.

Build with `make`, then run `multicolor_full_static.bin` in Stella.
