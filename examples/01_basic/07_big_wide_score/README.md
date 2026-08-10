```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Big widely spaced score

`01_basic/07_big_wide_score` displays six decimal glyphs from the 8x16 Big
font across the same 88-pixel horizontal span as the ordinary wide score. The
glyph origins are X=`36`, `52`, `68`, `84`, `100`, and `116`, leaving one
8-pixel glyph-width of blank space between neighbors.

The example includes `fonts/big_decimal.c26` and instantiates:

```vcsc
instantiate "six_glyph_big_wide_component.c26" as score
```

Each Big glyph consumes sixteen visible scanlines rather than eight. Including
the component's positioning/setup and terminal handoff, `score_draw()` consumes
exactly **19 visible scanlines**. This example places 87 blank lines above it and
86 below it, preserving the standard exact 262-line NTSC frame.

The cartridge starts at packed-BCD value `123456` and increments every 20
frames. `big_decimal.c26` is derived directly from the matching digit glyphs in
`big_ascii.c26`; `big_hex.c26` likewise contains the matching `0`-`9` and
`A`-`F` glyphs.

Build after building the toolchain:

```sh
make
```

The result is an exact 2048-byte unbanked cartridge.
