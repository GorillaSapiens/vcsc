```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# All-five colour sections with a score (NTSC)

Instantiate `renderers/all_five_sections_181/all_five_sections_181.c26` as `game`.
Compose its **181 lines** with an independent **11-line** six-glyph score, using
`vcs_ntsc_component_handoff()` between draws. Either ordering is supported.

The same `sectionN_lines`, `sectionN_colupf` and `sectionN_colubk` interface as the
[192-line profile](../all_five_sections_192/README.md) configures up to eight
sections. Even heights must total **176**, not 181: the remaining five lines are
fixed positioning/setup and a blank tail. Boundaries are relative to gameplay
row zero, after the positioning setup. Defaults give one 176-line section.
Provide page-contained `game_playfield[44]` (eleven four-byte rows) and immutable,
page-contained graphics. All five objects keep continuous state across seams.

`player0_color` and `player1_color` are compile-time solid colours, defaulting to
`0x0e` and `0xc8`. The draw entry restores both after the score uses the players.
Object controls use X=0..159 and Y=0..87, like existing 181-line examples. Heights
are last-row indexes; player height 7 selects eight graphics rows. Always pair
`game_vblank()` with `game_overscan()` to restore application heights.

Renderer state uses 89 RAM bytes, excluding compiler scratch, score and controls.
The supplied full-control examples use **8K F8 ROMs and 128/128 RAM bytes**; no
additional RAM is available without changing the example's state allocation.
They bank preparation and controls outside visible drawing. For that arrangement
set `banked_vblank:=1` and supply `game_prepare_playfield[4]` in the preparation
bank, an exact mirror of the first four `game_playfield` bytes. With the default
`banked_vblank:=0`, no mirror or bankswitching is required by the component.
Uppercase profile parameters are internal implementation constants, not settings;
overrides are rejected by `game_init()`.

The component owns neither a score/font, frame timing, VBLANK nor RIOT timers.
PAL/SECAM, odd colour boundaries and per-row player colour tables are not supported.

Build and run the examples in
[`score_above`](../../../../examples/04_renderers/all_five_sections/score_above/)
or [`score_below`](../../../../examples/04_renderers/all_five_sections/score_below/)
with `make` and `make play`.

Regression coverage lives in `test/vcs_all_five_sections_score.pl` and
`test/vcs_all_five_sections_score_raster.pl`. Private fixtures lock score pixels,
all-five geometry, controls, lifecycle timing, and full F8 raster placement.
Four-palette moving composites require every object to straddle all seven seams
of the fine layout in both score orders. Independent A/B row checks require
eight intentional graphics rows, each drawn on two scanlines.
