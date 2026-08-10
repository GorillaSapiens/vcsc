```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# VCS score fonts

This directory contains eight conventional 8x8 score-font families, one
8x16 Big font family, and one special six-slice VCSC logo table.
Every pixel row is written on its own line using visual binary notation: `.` is
a clear pixel and `X` is a set pixel.

Each conventional 8x8 family has three modules:

- `*_decimal.c26` defines ten glyphs, `0` through `9`, in an 80-byte array.
- `*_hex.c26` defines sixteen glyphs, `0` through `9` and `A` through `F`, in a
  128-byte array.
- `*_ascii.c26` defines all 95 printable ASCII glyphs from space (`0x20`)
  through tilde (`0x7E`) in a 760-byte array. Every glyph in one ASCII module
  has a distinct bitmap.

Include exactly one font-family module in a translation unit. Every
family module defines the common table symbol `score_font`, which is the
interface expected by display components. The special
`logo_font.c26` table uses its own `logo_font` symbol and may coexist with one
conventional family. Decimal (80-byte) and hexadecimal (128-byte) tables use
the VCSC `page` modifier because the complete table fits in one 256-byte page.
The 760-byte ASCII tables instead use `align(256)`: the table begins at `$xx00`
but remains one contiguous multi-page object. Because every ASCII glyph is
exactly eight bytes and 256 is divisible by eight, no glyph can cross a hardware
page. This matters for cycle-sensitive `(pointer),Y` glyph reads.

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


## Big 8x16 font family

The Big family uses sixteen rows per 8-pixel-wide glyph:

- `big_decimal.c26` contains `0` through `9` in a 160-byte table.
- `big_hex.c26` contains `0` through `9` and `A` through `F` in a 256-byte table.
- `big_ascii.c26` contains all 95 printable ASCII characters in a 1520-byte table.

The decimal and hexadecimal glyphs are exact subsets of `big_ascii.c26`; they
are not separately redrawn versions. Every module stores source rows
top-to-bottom and uses the 16-row `VCS_FONT_GLYPH` alias to emit them
bottom-to-top for the display raster.

All three tables use `align(256)`. The decimal table fits within one hardware
page and the hexadecimal table occupies exactly one page. The ASCII table spans
multiple pages, but each glyph is exactly sixteen bytes and 256 is divisible by
16, so no individual glyph crosses a page. All three modules define the common
`score_font` symbol and therefore must be included one at a time.

The Big fonts require a 16-row display component.
`six_glyph_big_wide_component.c26` provides the six-glyph wide score profile;
the ordinary six-glyph components remain eight-row renderers.

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

## License

The font data is covered under CC0-1.0 with the rest of the library tree. See
`libraries/LICENSE.txt`.
