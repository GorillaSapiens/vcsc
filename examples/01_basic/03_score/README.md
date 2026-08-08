```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Score

`01_basic/03_score` displays a centered white six-digit score on a medium-blue
Atari VCS background. It starts at `123456` and increments once every 20 NTSC
frames.

The example instantiates the reusable lifecycle component:

```vcsc
instantiate "six_glyph_component.c26" as score
```

That creates independent `score_score`, pointer, row, and delayed-glyph state
plus the required `score_init()`, `score_vblank()`, `score_draw()`, and
`score_overscan()` lifecycle operations. The application remains responsible
for frame scheduling and update policy.

The persistent score is ordinary VCSC packed decimal:

```vcsc
score_score := 123456;
```

`score_score++` emits a decimal-mode three-byte `ADC` chain and wraps after
`999999`.

## Frame composition

The application uses `frame_ntsc.c26` for scheduler-owned VSYNC, VBLANK, and
overscan deadlines. Component callbacks run inside those budgets and do not
own VBLANK, WSYNC, or the RIOT timer.

The visible region is accounted explicitly:

```vcsc
vcs_ntsc_wait_component_scanlines(91);
score_draw();                  // exactly 11 scanlines
vcs_ntsc_wait_scanlines(90);
```

The asymmetric blank-line counts preserve the predecessor cartridge's absolute
raster position while still totaling exactly 192 visible scanlines. The
component-aware wait consumes the blank gap and returns at the same measured
entry phase as the first component after VBLANK. Using ordinary
`vcs_ntsc_wait_scanlines(91)` here leaves the compiler's loop bookkeeping in the
visible line; `RESP0`/`RESP1` then occur 32 cycles late and one digit wraps around
the screen. Adding only `vcs_ntsc_component_handoff()` shifts the players but
also spills the frame to 263 lines. Regression tests lock both the calibrated
entry tail and stable 262-line timing. The reviewed Stella 7.0 capture is kept
as `test/fixtures/vcs_examples/03_six_digit_score/reference_stella_7.0.png`.

## Why assembly remains

The component's eight-row 48-pixel player pipeline is cycle-counted. It
preloads digit 1 immediately before `WSYNC`; the remaining GRP writes complete
at cycles `8, 16, 44, 47, 50, 53`. Horizontal positioning and `HMOVE` are
re-established at every draw entry so
the component remains independent of preceding visible work. The timed region
uses documented 6502 instructions and no nested call or stack-pointer trick.

Because both players use vertical delay, the component flushes `GRP0`, `GRP1`,
and `GRP0` again before drawing and repeats the flush before disabling
`VDELP0`/`VDELP1`.

## Fonts

The example selects the shared Default decimal font:

```vcsc
include "fonts/default_decimal.c26"
```

Fonts live under `libraries/vcs/fonts/`. Source rows are visual binary written
top-to-bottom; the font module reverses each glyph for the row-7-through-row-0
renderer traversal. The page-contained table avoids indexed-load page-crossing
cycle penalties.

Build after building the toolchain:

```sh
make
```

The result is `score.bin`, an exact 2048-byte unbanked cartridge linked with the `vcs_2k.c26` profile and mapped at `$F800-$FFFF`.
