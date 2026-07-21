```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCS score fonts

This directory contains nine 8x8 score-font families converted to readable
VCSC source. Every pixel row is written on its own line using visual binary
notation: `.` is a clear pixel and `X` is a set pixel.

Each family has two modules:

- `*_decimal.vcsc` defines ten glyphs, `0` through `9`, in an 80-byte array.
- `*_hex.vcsc` defines sixteen glyphs, `0` through `9` and `A` through `F`, in a
  128-byte array.

Include exactly one font module in a translation unit. Every module defines the
common table symbol `score_font`, which is the interface expected by score kernels.

| Family | Decimal module | Hexadecimal module | Notes |
|---|---|---|---|
| Default | `default_decimal.vcsc` | `default_hex.vcsc` | Original standard score digits |
| 21st Century | `21st_century_decimal.vcsc` | `21st_century_hex.vcsc` | Thin geometric strokes |
| Alarm Clock | `alarm_clock_decimal.vcsc` | `alarm_clock_hex.vcsc` | Broken seven-segment appearance |
| Handwritten | `handwritten_decimal.vcsc` | `handwritten_hex.vcsc` | Slanted hand-drawn digits |
| Interrupted | `interrupted_decimal.vcsc` | `interrupted_hex.vcsc` | Deliberately broken strokes |
| Retroputer | `retroputer_decimal.vcsc` | `retroputer_hex.vcsc` | Squared computer-terminal style |
| Whimsey | `whimsey_decimal.vcsc` | `whimsey_hex.vcsc` | Heavy playful strokes; upstream spelling retained |
| Tiny | `tiny_decimal.vcsc` | `tiny_hex.vcsc` | Compact 3x5 forms inside an 8x8 cell |
| Hexadecimal | `hexadecimal_decimal.vcsc` | `hexadecimal_hex.vcsc` | Upstream `hex` family; its decimal digits intentionally match Default |

The decimal `0`-`9` glyphs are exact conversions of the nine retained legacy
choices. The Hexadecimal family preserves the original `A`-`F` glyphs.
The other hexadecimal modules append those same official `A`-`F` glyphs after
their family-specific decimal digits; no invented letter artwork is presented
as upstream material.

## Selecting a font

Example 03 selects the table expected by its score kernel by including one
module:

```vcsc
include "fonts/21st_century_decimal.vcsc"
```

For hexadecimal output, include the corresponding `*_hex.vcsc` module and
use that module instead. The score kernel still needs digit values in the range
`0..15`; packed BCD naturally supplies only `0..9`.

The arrays are stored in the row order consumed by the score kernel, but source
rows are written top-to-bottom. `VCS_FONT_GLYPH` performs the reversal at
compile time.

## Provenance and license

The original assembly font data is from the retained legacy BASIC support
materials and is released under CC0-1.0. The exact upstream licensing overview
is retained at `../legacy-basic-kernels/LICENSE.txt`. The conversion to VCSC
visual-binary source does not change that license.
