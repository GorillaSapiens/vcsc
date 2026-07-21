```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCS score fonts

This directory contains eight 8x8 score-font families converted to readable
VCSC source. Every pixel row is written on its own line using visual binary
notation: `.` is a clear pixel and `X` is a set pixel.

Each family has two modules:

- `*_decimal.c26` defines ten glyphs, `0` through `9`, in an 80-byte array.
- `*_hex.c26` defines sixteen glyphs, `0` through `9` and `A` through `F`, in a
  128-byte array.

Include exactly one font module in a translation unit. Every module defines the
common table symbol `score_font`, which is the interface expected by score kernels.

| Family | Decimal module | Hexadecimal module | Notes |
|---|---|---|---|
| Default | `default_decimal.c26` | `default_hex.c26` | Original standard score digits |
| 21st Century | `21st_century_decimal.c26` | `21st_century_hex.c26` | Thin geometric strokes |
| Alarm Clock | `alarm_clock_decimal.c26` | `alarm_clock_hex.c26` | Broken seven-segment appearance |
| Handwritten | `handwritten_decimal.c26` | `handwritten_hex.c26` | Slanted hand-drawn digits |
| Interrupted | `interrupted_decimal.c26` | `interrupted_hex.c26` | Deliberately broken strokes |
| Retroputer | `retroputer_decimal.c26` | `retroputer_hex.c26` | Squared computer-terminal style |
| Whimsey | `whimsey_decimal.c26` | `whimsey_hex.c26` | Heavy playful strokes; upstream spelling retained |
| Tiny | `tiny_decimal.c26` | `tiny_hex.c26` | Compact 3x5 forms inside an 8x8 cell |

## Selecting a font

Example 03 selects the table expected by its score kernel by including one
module:

```vcsc
include "fonts/default_decimal.c26"
```

For hexadecimal output, include the corresponding `*_hex.c26` module and
use digit values in the range `0..15`; packed BCD naturally supplies only
`0..9`. Example 04 selects `hexadecimal_hex.c26` to display a binary 24-bit
processor fingerprint as six hexadecimal digits.

The arrays are stored in the row order consumed by the score kernel, but source
rows are written top-to-bottom. `VCS_FONT_GLYPH` performs the reversal at
compile time.

## Provenance and license

The original assembly font data is from the retained legacy BASIC support
materials and is released under CC0-1.0. The exact upstream licensing overview
is retained at `../legacy-basic-kernels/LICENSE.txt`. The conversion to VCSC
visual-binary source does not change that license.
