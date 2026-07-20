```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Six-digit score

`03_six_digit_score` displays a centered white six-digit score on a medium-blue
Atari VCS background. It starts at `123456` and increments once every 20 NTSC
frames.

The persistent score is ordinary VCSC packed decimal:

```vcsc
bcd24_t score := 123456;
```

`score++` therefore emits a decimal-mode three-byte `ADC` chain and wraps after
`999999`. VCSC also owns the frame loop, scanline waits, score cadence, TIA
setup and cleanup, and both font tables.

## Why assembly remains

The visible eight-row player pipeline is adapted from a retained legacy
standard score mini-kernel. Its TIA stores have hard per-cycle deadlines, so
that section remains explicit assembly rather than depending on compiler
instruction selection.

VCSC owns the `bcd24_t` score, frame loop, scanline waits, update cadence, TIA
setup, cleanup, and font data. During overscan, `prepare_score_pointers()` builds
six complete 16-bit pointers in normal left-to-right digit order. The visible
loop uses only documented 6502 instructions, one ordinary zero-page temporary,
and one RAM row counter. It preloads digit 1 immediately before `WSYNC`; the
remaining GRP writes complete at cycles `8, 16, 44, 47, 50, 53`.

Horizontal player positioning and `HMOVE` happen once while `VBLANK` is set;
the positions persist across frames. No undocumented opcode, stack-pointer
trick, or visible-frame HMOVE is used.

VCSC currently has inline assembly but **does not have source-level inline
functions**. These helpers are ordinary VCSC functions with no generated frame
prologue or epilogue: a call is `JSR`, the body, and `RTS`. `draw_score()` has
no nested call inside the timed loop.

## Fonts

The font is VCSC source data rather than a separately assembled object:

- `fonts/clean.vcsc` is the active narrow 5x7-style font.
- `fonts/classic.vcsc` retains the chunkier CC0 score font from the retained
  legacy source snapshot as an alternate. Its exact licensing overview is kept
  in `libraries/vcs/legacy-basic-kernels/LICENSE.txt`.

Switch fonts by changing the include near the top of `six_digit_score.vcsc`:

```vcsc
include "fonts/clean.vcsc"
```

Each font defines `const uint8_t score_font[80]`. Every glyph is written one
visual binary byte per source line using `.` for a clear pixel and `X` for a set
pixel, so the sprite can be read directly in the source. The rows are listed
top-to-bottom; a small `SCORE_GLYPH` alias reverses each eight-row group because
the cycle-counted display kernel reads row 7 down through row 0.

Each glyph pointer includes low-byte carry into the font address high byte, so a
font may land anywhere in cartridge ROM and does not need page alignment.

The frame has stable 262-line NTSC timing. Stella 7.0 was used to verify the
actual TIA output, including correct digit order, centering, blue background,
white glyphs, and visible score advancement.

Build after building the toolchain:

```sh
make
```

The result is `six_digit_score.bin`, an exact 4096-byte unbanked cartridge.
