```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Parameterized official-opcode player-color renderer

`player_color.c26` is the official-opcode P0/P1/Ball gameplay component with
page-contained per-row P0/P1 color tables. The required `lines` instantiation
parameter selects one of the maintained cycle-proven visible profiles:

```vcsc
instantiate "renderers/player_color/player_color.c26" as game (lines:=228)
instantiate "renderers/player_color/player_color.c26" as game (lines:=192)
instantiate "renderers/player_color/player_color.c26" as game (lines:=181)
instantiate "renderers/player_color/player_color.c26" as game (lines:=170)
```

`lines` is compile-time only; it adds no runtime line-count state or branch.

## Profiles

| `lines` | Playfield | Typical composition | Component RAM |
| ---: | ---: | --- | ---: |
| 228 | 60 bytes / 15 packed rows | native PAL/SECAM full visible field | 23 bytes |
| 192 | 48 bytes / 12 rows | native NTSC full visible field | 23 bytes |
| 181 | 44 bytes / 11 rows | one independent 11-line score above or below | 24 bytes |
| 170 | 40 bytes / 10 rows | independent 11-line scores above **and** below | 24 bytes |

All playfields are page-contained and contain four bytes per packed row. The
228- and 192-line profiles position P0, P1 and Ball during VBLANK and enter the raster
without a score handoff. The 181- and 170-line profiles use the measured
score-composable entry handoff that restores P0/P1 positioning, NUSIZ, reflection
state, graphics and colors after a score component has owned the players.
Adjacent visible components must be separated with `vcs_ntsc_component_handoff()`.

The 170-line profile uses ten full 16-line playfield rows plus the inherited
five-line entry/handoff region and five terminal blank lines, returning after
exactly 170 gameplay scanlines. Thus:

```text
11 score lines + 170 gameplay lines + 11 score lines = 192 visible lines
```

P0 and P1 use eight-row graphics pointers and matching eight-entry color tables.
The Ball has independent X/Y/height state. `game_SPRITE_GLYPH(...)` stores rows
in the renderer's highest-index-to-zero traversal order.

The full-height profiles additionally support mutable player-color tables for the
animated-gallery example. Define `VCS_PLAYER_COLOR_MUTABLE_COLORS` before the
instantiation and provide mutable `game_player0_colors[8]` and
`game_player1_colors[8]` objects. The 181- and 170-line score-composable profiles
retain immutable color tables.

All profiles use only official NMOS 6502/6507 opcodes. The scheduler owns VSYNC,
VBLANK, RIOT timer deadlines, and visible-component order.

## Maintained examples

- `examples/17_video_standards/{pal,secam}/02_player_color/` instantiate the native `lines:=228` profile.
- `examples/03_player_color_192/` instantiates `lines:=192`.
- `examples/04_player_color_181/` instantiates `lines:=181` with one score.
- `examples/13_player_color_170/` instantiates `lines:=170` between an 11-line
  score above and an 11-line score below.

The separately maintained `player_color_181_unofficial` renderer remains the
stable/common-NMOS experimental twin of the 181-line score-composable profile.
