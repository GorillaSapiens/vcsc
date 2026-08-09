```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Widely spaced score

`01_basic/06_wide_score` displays six decimal glyphs across an 88-pixel span.
The 8-pixel glyph origins are fixed at visible X coordinates `36`, `52`, `68`,
`84`, `100`, and `116`; each neighboring pair therefore has an 8-pixel gap.
The centered score remains a separate component and example.

The cartridge starts at packed-BCD value `123456` and increments every 20 NTSC
frames. It instantiates:

```vcsc
instantiate "six_glyph_wide_component.c26" as score
```

The application owns frame scheduling. The component consumes exactly eleven
visible scanlines, so this example places 91 blank lines above it and 90 below
it for a stable 262-line frame.

`NUSIZ0=NUSIZ1=$06` creates three medium-spaced copies of each player. The
component uses the compact delayed-player pipeline: glyph one is staged before
each row boundary; glyphs two through six write at row cycles `0, 8, 36, 39,
42`; and cycle `45` commits the delayed latch. No glyph rows are cached in RAM.

The component owns 18 RIOT-RAM bytes: the three-byte packed-BCD score, twelve
pointer bytes, one row counter, one delayed glyph byte, and one mutable color
byte. In this exact 2K example the linked program uses 1,120 ROM bytes and 44
total RAM bytes, including
scheduler and application state. The regression map and raster oracle lock the
authoritative numbers; update this README with them if the implementation
changes.

Build after building the toolchain:

```sh
make
```

The result is an exact 2048-byte unbanked cartridge.
