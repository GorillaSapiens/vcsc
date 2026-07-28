```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# `player_color_192` examples

This group demonstrates the official-opcode
`renderers/player_color_192/player_color_192.c26` lifecycle component.

The renderer owns all 192 visible lines as twelve playfield rows of sixteen
scanlines each. It draws P0, P1, and Ball with independent page-contained
per-row player-color tables. Missiles and an integrated score are intentionally
absent. Horizontal positioning occurs during VBLANK; the component owns no
VSYNC, VBLANK, RIOT timer, score, or font state. Because it consumes the entire
visible field, it cannot be composed with the 11-line score component.

The corrected raster uses four fixed playfield-write phases for every visible
line and returns at the line-232 boundary so the frame scheduler can blank the
next scanline before any partial output appears.

| Layout | Examples |
|---|---|
| [`01_full`](01_full/) | Full-height static, horizontal-motion, and two-axis-motion cartridges |

For the exact RAM, table, and beam-timing contract, see
[`libraries/vcs/renderers/player_color_192/README.md`](../../libraries/vcs/renderers/player_color_192/README.md).
