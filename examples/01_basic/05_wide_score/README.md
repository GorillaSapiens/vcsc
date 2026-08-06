```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Widely spaced score

`01_basic/05_wide_score` displays six decimal glyphs across an 88-pixel span.
The 8-pixel glyph origins are fixed at visible X coordinates `36`, `52`, `68`,
`84`, `100`, and `116`; each neighboring pair therefore has an 8-pixel gap.
The centered score remains a separate component and example.

The cartridge starts at packed-BCD value `123456` and increments every 20 NTSC
frames. It instantiates:

```vcsc
template "six_glyph_wide_component.c26" as score
```

The application owns frame scheduling. The component consumes exactly eleven
visible scanlines, so this example places 91 blank lines above it and 90 below
it for a stable 262-line frame.

The row schedule does not use player vertical delay. `NUSIZ0=NUSIZ1=$06`
creates three medium-spaced copies of each player, and each row writes
`GRP0/GRP1` at cycles `0, 8, 31, 36, 42, 48`. Those writes occur between
successive copies. Glyphs five and six are prepared into two 8-byte row caches
during VBLANK so their visible loads remain fixed three-cycle accesses.

The component owns 31 RIOT-RAM bytes: the three-byte packed-BCD score, twelve
pointer bytes, and sixteen cached row bytes. In this exact 2K example the linked
program uses 1,366 ROM bytes and 57 total RAM bytes, including scheduler and
application state. The regression map and raster oracle lock the authoritative
numbers; update this README with them if the implementation changes.

Build after building the toolchain:

```sh
make
```

The result is an exact 2048-byte unbanked cartridge.
