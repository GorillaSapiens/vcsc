```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCS score fonts

This directory contains eight 8x8 score-font families converted to readable
VCSC source, plus one special six-slice VCSC logo table. Every pixel row is written on its own line using visual binary
notation: `.` is a clear pixel and `X` is a set pixel.

Each family has three modules:

- `*_decimal.c26` defines ten glyphs, `0` through `9`, in an 80-byte array.
- `*_hex.c26` defines sixteen glyphs, `0` through `9` and `A` through `F`, in a
  128-byte array.
- `*_ascii.c26` defines all 95 printable ASCII glyphs from space (`0x20`)
  through tilde (`0x7E`) in a 760-byte array. Every glyph in one ASCII module
  has a distinct bitmap.

Include exactly one conventional family module in a translation unit. Every
family module defines the common table symbol `score_font`, which is the
interface expected by display components. The special
`logo_font.c26` table uses its own `logo_font` symbol and may coexist with one
conventional family. Each table uses the VCSC `page` declaration modifier, so the linker
places the complete table anywhere it fits within one 256-byte page. This is a timing requirement: `(score_font + digit * 8),Y`
gains a cycle on page crossing and visibly corrupts the six-glyph pipeline.

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


## VCSC logo slices

`logo_font.c26` defines six 8x8 glyph cells named `logo_font`. Glyphs `0`
through `5` are consecutive slices of one 48-pixel-wide VCSC mark rather than
ordinary digits. A six-glyph component can display the mark by using the fixed
packed-BCD value `012345` and directing its six glyph pointers to `logo_font`.
The eighth row in every cell is blank; the visible mark itself is seven pixels
tall.

## Selecting a font

Example 03 selects the table expected by its score renderer by including one
module:

```vcsc
include "fonts/default_decimal.c26"
```

For hexadecimal output, include the corresponding `*_hex.c26` module and
use digit values in the range `0..15`; packed BCD naturally supplies only
`0..9`. Example 04 selects `whimsey_hex.c26` to display a binary 24-bit
processor fingerprint as six hexadecimal digits, while two edge-justified
components redirect their pointers to `logo_font.c26`.

The arrays are stored in the row order consumed by the display code, but source
rows are written top-to-bottom. `VCS_FONT_GLYPH` performs the reversal at
compile time. ASCII digits are byte-identical to the corresponding decimal and
hexadecimal glyphs, and ASCII `A` through `F` are byte-identical to the
hexadecimal glyphs. Each ASCII family preserves the same blank row and column
margins as its decimal and hexadecimal source family.

## Provenance and license

The font data is covered under CC0-1.0. The complete CC0 text is retained in
this directory as `LICENSE.txt`.
