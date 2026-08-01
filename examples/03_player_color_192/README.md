```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# `player_color_192` example

This group demonstrates the official-opcode
`renderers/player_color_192/player_color_192.c26` lifecycle component.

The renderer owns all 192 visible lines as twelve playfield rows of sixteen
scanlines each. It draws P0, P1, and Ball with independent page-contained
per-row player-color tables. M0, M1, and an integrated score are intentionally
absent. Horizontal positioning occurs during VBLANK; the component owns no
VSYNC, VBLANK, RIOT timer, score, or font state. Because it consumes the entire
visible field, it cannot be composed with the 11-line score component.

| No. | Example | Purpose |
|---:|---|---|
| 01 | [`interactive`](01_interactive/) | Select P0, P1, or Ball and move it one pixel or logical scanline at a time through the renderer's complete range |
| 02 | [`animated_sprites`](02_animated_sprites/) | Move all 30 four-frame source animations across the screen in 15 pairs, rotating each RAM row-color table to follow vertical motion inside the source cell |

For the exact RAM, table, and beam-timing contract, see
[`libraries/vcs/renderers/player_color_192/README.md`](../../libraries/vcs/renderers/player_color_192/README.md).
