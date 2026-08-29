```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# VCS score fonts

This directory contains nine conventional 8x8 score-font families, one
8x16 Big font family, one compact 4x6 printable-ASCII source font, helpers for
importing BDF fonts, generating font subsets, and packing fixed messages into
display glyphs, plus one special six-slice VCSC logo table. Every pixel row is
written on its own line using visual binary notation: `.` is a clear pixel and
`X` is a set pixel.

Each conventional 8x8 family has four modules:

- `*_decimal.c26` defines ten glyphs, `0` through `9`, in an 80-byte array.
- `*_hex.c26` defines sixteen glyphs, `0` through `9` and `A` through `F`, in a
  128-byte array.
- `*_lhex.c26` defines sixteen glyphs, `0` through `9` and `a` through `f`, in a
  128-byte array.
- `*_ascii.c26` defines all 95 printable ASCII glyphs from space (`0x20`)
  through tilde (`0x7E`) in a 760-byte array. Every glyph in one ASCII module
  has a distinct bitmap.

Include exactly one font-family module in a translation unit. Every
family module defines the common table symbol `score_font`, which is the
interface expected by display components. The special
`logo_font.c26` table uses its own `logo_font` symbol and may coexist with one
conventional family. Decimal (80-byte) and upper/lower hexadecimal (128-byte)
tables use the VCSC `page` modifier because the complete table fits in one
256-byte page.
The 760-byte ASCII tables instead use `align(256)`: the table begins at `$xx00`
but remains one contiguous multi-page object. Because every ASCII glyph is
exactly eight bytes and 256 is divisible by eight, no glyph can cross a hardware
page. This matters for cycle-sensitive `(pointer),Y` glyph reads.

| Family | Decimal module | Hexadecimal module | Notes |
|---|---|---|---|
| Default | `default_decimal.c26` | `default_hex.c26` | Original standard score digits; slashed zero |
| 21st Century | `21st_century_decimal.c26` | `21st_century_hex.c26` | Thin geometric strokes |
| Alarm Clock | `alarm_clock_decimal.c26` | `alarm_clock_hex.c26` | Broken seven-segment appearance |
| Handwritten | `handwritten_decimal.c26` | `handwritten_hex.c26` | Slanted hand-drawn digits |
| Interrupted | `interrupted_decimal.c26` | `interrupted_hex.c26` | Deliberately broken strokes |
| Retroputer | `retroputer_decimal.c26` | `retroputer_hex.c26` | Squared computer-terminal style |
| Whimsey | `whimsey_decimal.c26` | `whimsey_hex.c26` | Heavy playful strokes; upstream spelling retained |
| Tiny | `tiny_decimal.c26` | `tiny_hex.c26` | Compact 3x5 forms inside an 8x8 cell |
| Wonk | `wonk_decimal.c26` | `wonk_hex.c26` | Irregular hand-built display style |

`make_font_subsets.pl foo_ascii.c26` regenerates that ASCII source's decimal,
uppercase-hex, and lowercase-hex modules in place. Generated subsets retain the
source font's license/comments, identify their ASCII source, and use `page`
instead of `align(256)`.

`make_font_subset.pl` generates an arbitrary checked-in subset in a caller-chosen
character order and table name. It defaults to `page`, accepts `--bank` for
bank-qualified placement and `--no-page` when a page constraint is unwanted.
The bankswitching diagnostics use their local `make fonts` targets to regenerate
small mapper-name and PASS/FAIL tables from `default_ascii.c26` and
`big_ascii.c26`. Those generated `.c26` files are committed, so ordinary example
builds do not require Perl.

## Font conversion and fixed-message helpers

`bdf2c26.pl` converts a small BDF bitmap font into a VCSC font module. The BDF
cell may be at most eight pixels wide and 26 rows high. By default it emits the
printable-ASCII range (`0x20` through `0x7e`) as `score_font`; `--first`,
`--last`, and `--name` select another range or table name, and `--strict` makes
a missing requested glyph an error instead of a blank cell. For example:

```sh
./bdf2c26.pl spleen-5x8.bdf > spleen_ascii.c26
./bdf2c26.pl --first 0x30 --last 0x39 foo.bdf > foo_decimal.c26
```

`make_message_glyphs.pl` pre-renders one fixed message from any compatible C26
`VCS_FONT_GLYPH(...)` font into exactly six eight-bit output glyphs, or 48
columns. It crops blank edge columns from each non-space source glyph, inserts
one blank column between adjacent characters, and treats a literal space as one
additional blank column. The generated table is named `message_font`; input
that cannot fit in 48 columns is rejected. For example:

```sh
./make_message_glyphs.pl half_ascii.c26 "TIA COLL" > tia_message.c26
```

This helper is useful when a fixed label should use an existing score renderer
without carrying a general-purpose text renderer or the whole source font into
the cartridge. `make_pair_font.pl`, described below, is the specialized 4x6
variant that preserves two source character cells per 8x6 output glyph instead
of horizontally cropping and repacking an entire message.

## Compact 4x6 ASCII source and paired-message helper

`half_ascii.c26` contains all 95 printable ASCII characters as six-row,
four-bit cells in the 570-byte `score_font` table. Its generated
`half_decimal.c26`, `half_hex.c26`, and `half_lhex.c26` subsets provide the same
three compact numeric selections as the 8x8 families. The high bit of every
four-bit source row is intentionally blank, matching the compact shifted form
used by narrow text renderers.

`make_pair_font.pl` consumes that 4x6 source plus a printable-ASCII message and
writes a C26 table named `message_font`. It combines the message two characters
at a time into one 8x6 glyph; an odd final character is paired with a space.
For example:

```sh
./make_pair_font.pl half_ascii.c26 "HELLO WORLD" > hello_pairs.c26
```

The generated table is message-specific rather than another interchangeable
`score_font` family.

## Big 8x16 font family

The Big family uses sixteen rows per 8-pixel-wide glyph:

- `big_decimal.c26` contains `0` through `9` in a 160-byte table.
- `big_hex.c26` contains `0` through `9` and `A` through `F` in a 256-byte table.
- `big_lhex.c26` contains `0` through `9` and `a` through `f` in a 256-byte table.
- `big_ascii.c26` contains all 95 printable ASCII characters in a 1520-byte table.

The decimal and upper/lower hexadecimal glyphs are exact subsets of
`big_ascii.c26`; they are not separately redrawn versions. Every module stores source rows
top-to-bottom and uses the 16-row `VCS_FONT_GLYPH` alias to emit them
bottom-to-top for the display raster.

The three generated subsets use `page`; the decimal table fits within one
hardware page and each hexadecimal table occupies exactly one page. The ASCII
table uses `align(256)` and spans multiple pages, but each glyph is exactly
sixteen bytes and 256 is divisible by 16, so no individual glyph crosses a
page. All four modules define the common `score_font` symbol and therefore must
be included one at a time.

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

For hexadecimal output, include the corresponding `*_hex.c26` or `*_lhex.c26`
module and use digit values in the range `0..15`; packed BCD naturally supplies
only `0..9`. Example 04 selects `whimsey_hex.c26` to display a binary 24-bit
processor fingerprint as six hexadecimal digits, while two edge-justified
components redirect their pointers to `logo_font.c26`.

The arrays are stored in the row order consumed by the display code, but source
rows are written top-to-bottom. `VCS_FONT_GLYPH` performs the reversal at
compile time. ASCII digits are byte-identical to the corresponding decimal and
upper/lower hexadecimal glyphs, ASCII `A` through `F` are byte-identical to the
uppercase hexadecimal glyphs, and ASCII `a` through `f` are byte-identical to
the lowercase hexadecimal glyphs. Each ASCII family preserves the same blank
row and column margins as its generated subsets.

## License

The font data is covered under CC0-1.0 with the rest of the library tree. See
`libraries/LICENSE.txt`.
