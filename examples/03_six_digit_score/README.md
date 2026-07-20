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

The visible eight-row player pipeline is adapted from the retained batari Basic
standard score mini-kernel. Its TIA stores are positioned by individual CPU
cycles, so replacing that section with ordinary compiler output would make the
picture depend on optimizer accidents. The kernel also temporarily uses the
hardware stack pointer as a graphics register. It saves S first, makes no call
or push while S is borrowed, and restores it before returning. Its two `LAX`
instructions require `-Wa,--illegals`.

Glyph-pointer construction also remains compact inline assembly. The delayed
player pipeline consumes slots in order `0, 4, 3, 2, 1, 5`; generic dynamic
16-bit table indexing generated far more code for work performed outside the
visible picture. Everything else is expressed in VCSC.

VCSC currently has inline assembly but **does not have source-level inline
functions**. These helpers are ordinary VCSC functions. They have no generated
frame prologue or epilogue: a call is simply `JSR`, the body, and `RTS`.
`draw_score()` enters before S is borrowed and restores S before its `RTS`, so
the call is safe and occurs outside the cycle-counted row loop. A future true
inline-function feature could remove that `JSR`/`RTS`, but it is not being
pretended into existence for this example.

## Fonts

The font is VCSC source data rather than a separately assembled object:

- `fonts/clean.vcsc` is the active narrow 5x7-style font.
- `fonts/classic.vcsc` retains the chunkier original batari Basic CC0
  score font as an alternate. The original material comes from
  `https://github.com/batari-Basic/batari-Basic`.

Switch fonts by changing the include near the top of `six_digit_score.vcsc`:

```vcsc
include "fonts/clean.vcsc"
```

Each font defines `const uint8_t score_font[80]`. Every glyph is written one
visual binary byte per source line using `.` for a clear pixel and `X` for a set
pixel, so the sprite can be read directly in the source. The rows are listed
top-to-bottom; a small `SCORE_GLYPH` alias reverses each eight-row group because
the cycle-counted display kernel reads row 7 down through row 0.

Six complete 16-bit pointers are constructed, so a font may land anywhere in
cartridge ROM and does not need page alignment.

The frame has stable 262-line NTSC timing. Stella 7.0 was used to verify the
actual TIA output, including correct digit order, centering, blue background,
white glyphs, and visible score advancement.

Build after building the toolchain:

```sh
make
```

The result is `six_digit_score.bin`, an exact 4096-byte unbanked cartridge.
