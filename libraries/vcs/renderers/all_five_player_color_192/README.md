```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Official all-five renderer with player color tables

`all_five_player_color_192.c26` is a separate official-opcode full-height
renderer that combines all five ordinary TIA objects (P0, P1, M0, M1, and Ball)
with independent eight-entry P0/P1 color tables:

```vcsc
instantiate "renderers/all_five_player_color_192/all_five_player_color_192.c26" as game
```

It is deliberately a separate cycle-scheduled profile.  The existing
`all_five` and `player_color` families are not changed or conditionally widened.
This profile is fixed at 192 visible gameplay lines and does not compose with an
independent eleven-line score inside the standard 192-line visible field.

Each instance supplies page-contained immutable `game_playfield[48]`,
`game_player0_colors[8]`, and `game_player1_colors[8]` objects.  P0/P1 also have
independent graphics pointers, X/Y/height state, and NUSIZ values.  M0, M1, and
Ball retain independent X/Y/height state.  `game_SPRITE_GLYPH(...)` stores an
eight-line player glyph in renderer traversal order.

The visible raster uses a 48-byte compact BL/M1/M0 schedule plus two seven-byte
row caches.  The final object bits of each 16-line playfield row are packed into
the otherwise dead fourth schedule lane, keeping the component at **83 RIOT-RAM
bytes**: 21 public bytes plus 62 private bytes.  The maintained smoke cartridge
uses **95/128 RAM bytes** including application/compiler state and currently
uses **3140/4096 ROM bytes**, leaving 33 RAM bytes and 950 ROM bytes free.

P1 graphics writes use one fixed phase on active and inactive paths because a
`GRP1` write also transfers the delayed Ball latch.  The pair-7 P0 handoff folds
the otherwise skipped next-row `COLUP0` update into a cycle-balanced selector;
this keeps row-boundary entry at cycle zero without an extra scanline.

The public interactive example is
`examples/15_all_five_player_color_192/01_interactive/`. It cycles selection
through all five objects with Game Select and moves the selected object with the
left joystick while the two players retain visibly different eight-row color
tables. The example currently links at **97/128 RAM bytes** and **3481/4090 ROM
bytes**.

Regression coverage checks exact 262-line frames, all-five object pixels,
horizontal X=0..159 endpoint motion for every object, a complete 8-bit vertical
Y sweep, asymmetric/reflected playfield output, patterned P0/P1 colors, isolated
M0/M1/Ball output, and delayed-Ball/P1 boundary interactions.  Stella comparisons
match the established `player_color (lines:=192)` and `all_five (lines:=192)`
rasters pixel-for-pixel in their common feature sets.
