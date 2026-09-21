```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Parameterized official-opcode gameplay renderer

`all_five.c26` is the compile-time selector for the consolidated official-opcode
gameplay renderer. `lines` selects the visible schedule. `missiles` defaults to
`1`, and `player_colors` defaults to `0`, so existing instantiations retain the
P0/P1/M0/M1/BL all-five specialization unchanged.

The compatibility form and its explicit equivalent are:

```vcsc
instantiate "renderers/all_five/all_five.c26" as game (lines:=192)
instantiate "renderers/all_five/all_five.c26" as game (lines:=192, missiles:=1, player_colors:=0)
```

The P0/P1/BL per-row-color specialization is selected with
`missiles:=0, player_colors:=1`. It is maintained in this same source; there is
no separate official `player_color` renderer implementation.
The maintained line selections are:

```vcsc
instantiate "renderers/all_five/all_five.c26" as game (lines:=228)
instantiate "renderers/all_five/all_five.c26" as game (lines:=192)
instantiate "renderers/all_five/all_five.c26" as game (lines:=181)
instantiate "renderers/all_five/all_five.c26" as game (lines:=170)
```

`lines` is compile-time geometry, not a run-time scanline counter or mode switch.
The caller chooses the visible height appropriate to the video-standard or
composition contract.

## All-five compatibility profiles

| `lines` | Playfield | Typical composition | Component RAM |
| ---: | ---: | --- | ---: |
| 228 | 60 bytes / 15 packed rows | native PAL/SECAM full visible field | 83 bytes |
| 192 | 48 bytes / 12 packed rows | native NTSC full visible field | 71 bytes |
| 181 | 44 bytes / 11 rows | one independent 11-line score above or below | 67 bytes |
| 170 | 40 bytes / 10 rows | independent 11-line scores above **and** below | 67 bytes |

The player-color specialization keeps the same visible heights and playfield
geometries but exposes P0/P1/Ball with eight-entry per-row player-color tables.
Its component RAM contracts are 23 bytes for 228/192 and 24 bytes for 181/170.
Full-height profiles support mutable color tables when
`VCS_PLAYER_COLOR_MUTABLE_COLORS` is defined; score-composable profiles retain
immutable color tables.

The playfield uses four bytes per packed row. The 192-line profile is twelve
uniform 16-line rows. The 228-line profile keeps the same proven two-scanline
object pipeline: its first packed row contributes four visible scanlines and
fourteen subsequent rows contribute 16 each (`4 + 14*16 = 228`). Public object
Y coordinates are therefore two-scanline positions `0..113` in the 228-line
profile. The mask builder absorbs the shortened first row at compile time; the
visible raster remains a continuous 228-line component with no synthetic border
or padding scanlines.

The 181- and 170-line profiles use the score-composable entry handoff that
restores P0/P1 positioning, NUSIZ and colors after a score component has owned
the players. Adjacent visible components must be separated with
`vcs_ntsc_component_handoff()`.

The 170-line profile uses ten full 16-line playfield rows plus the inherited
five-line score handoff/entry region and five terminal blank lines, returning
after exactly 170 gameplay scanlines. Thus:

```text
11 score lines + 170 gameplay lines + 11 score lines = 192 visible lines
```

P0 and P1 have independent solid colors for the complete gameplay field. The
two per-row slots that the player-color renderer uses for color changes instead
update M1 and M0. P1 graphics and both missile enables are pipelined across
scanline boundaries and committed in horizontal blanking.

## All-five compatibility interface

Public state provides X coordinates for all five objects; Y/height state for
all five objects; P0/P1 graphics pointers and heights; independent P0/P1 NUSIZ
values; independent solid P0/P1 colors; and the playfield-row position.

The aliases `game_PLAYER0_X`, `game_PLAYER1_X`, `game_MISSILE0_X`,
`game_MISSILE1_X`, and `game_BALL_X` name the horizontal coordinates.
`game_SPRITE_GLYPH(...)` stores an eight-line player glyph in renderer order.

All profiles use only official NMOS 6502/6507 opcodes. The scheduler owns
VSYNC, VBLANK, RIOT timer deadlines and visible-component order.

## Maintained examples

- `examples/04_renderers/all_five/no_score/` instantiates `lines:=192`.
- `examples/04_renderers/all_five/score_{above,below}/` contains the centered,
  left, right, two-plus-two, three-plus-three, and poison `lines:=181`
  compositions.
- `examples/04_renderers/all_five/score_above_and_below/` instantiates
  `lines:=170` between an 11-line score above and an 11-line score below.
- `examples/05_video_standards/all_five/pal/` and
  `examples/05_video_standards/all_five/secam/` instantiate `lines:=228` and
  consume the complete native 50 Hz visible field directly.

The separately maintained `all_five_unofficial` renderer remains the
experimental unofficial-opcode twin and supports the same 228-, 192-, 181-,
and 170-line profiles.
