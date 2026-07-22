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
setup and cleanup, and the selected shared font table.

## Why assembly remains

The visible eight-row player pipeline is adapted from a retained legacy
standard score mini-kernel. Its TIA stores have hard per-cycle deadlines, so
that section remains explicit assembly rather than depending on compiler
instruction selection.

VCSC owns the `bcd24_t` score, frame loop, scanline waits, update cadence, TIA
setup, cleanup, and font data. During overscan, `prepare_score_pointers()` builds
six complete 16-bit pointers in normal left-to-right digit order. The shared `six_glyph_display.c26` module owns both the exact horizontal
positioning sequence and the visible row loop, preventing timing drift between
examples. It uses only documented 6502 instructions, one ordinary zero-page
temporary, and one RAM row counter. It preloads digit 1 immediately before `WSYNC`; the
remaining GRP writes complete at cycles `8, 16, 44, 47, 50, 53`.

Horizontal player positioning and `HMOVE` happen once while `VBLANK` is set;
the positions persist across frames. No undocumented opcode, stack-pointer
trick, or visible-frame HMOVE is used.

Because both player graphics use vertical delay, the display module clears
`GRP0`, `GRP1`, and `GRP0` again before drawing and repeats the same three-write
flush before disabling `VDELP0`/`VDELP1`. The extra `GRP0` write clears the
otherwise stale delayed latch that could duplicate the first score row after a
value update.

These helpers remain ordinary VCSC functions: each call is `JSR`, the body, and
`RTS`; parameters and named locals use fixed symbols rather than a per-call
frame. Source-level inline functions are available, but this example keeps the
shared setup and draw entry points callable and concentrates all cycle-critical
work inside explicit assembly.
`six_glyph_draw()` has no nested call inside the timed loop.

## Fonts

Score fonts are shared VCS support modules under `libraries/vcs/fonts/`, not
private example data. Example 03 deliberately selects the Default decimal font:

```vcsc
include "fonts/default_decimal.c26"
```

The library contains eight families, each with a decimal `0-9` module and a
hexadecimal `0-9A-F` module. See `libraries/vcs/fonts/README.md` for the full
catalog, symbols, provenance, and selection instructions.

Every glyph is written one visual binary byte per source line using `.` for a
clear pixel and `X` for a set pixel. Rows are listed top-to-bottom; a small
compile-time alias reverses each eight-row group because this score kernel reads
row 7 down through row 0.

Each glyph pointer includes low-byte carry into the font address high byte, but
the visible kernel still requires all 80 font bytes to remain within one page;
an indexed page crossing adds a cycle. The stock 4K profile page-aligns RODATA,
and the font include deliberately precedes every other constant table.

The frame has stable 262-line NTSC timing. Stella 7.0 was used to verify the
actual TIA output, including correct digit order, centering, blue background,
white glyphs, and visible score advancement.

Build after building the toolchain:

```sh
make
```

The result is `six_digit_score.bin`, an exact 4096-byte unbanked cartridge.
