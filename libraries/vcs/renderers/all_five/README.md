```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Parameterized official-opcode all-five renderer

`all_five.c26` is the official-opcode P0/P1/M0/M1/BL gameplay component.
The required `lines` instantiation parameter selects one of the maintained,
cycle-proven visible profiles:

```vcsc
instantiate "renderers/all_five/all_five.c26" as game (lines:=228)
instantiate "renderers/all_five/all_five.c26" as game (lines:=192)
instantiate "renderers/all_five/all_five.c26" as game (lines:=181)
instantiate "renderers/all_five/all_five.c26" as game (lines:=170)
```

`lines` is compile-time geometry, not a run-time scanline counter or mode switch.
The caller chooses the visible height appropriate to the video-standard or
composition contract.

## Profiles

| `lines` | Playfield | Typical composition | Component RAM |
| ---: | ---: | --- | ---: |
| 228 | 60 bytes / 15 packed rows | native PAL/SECAM full visible field | 83 bytes |
| 192 | 48 bytes / 12 packed rows | native NTSC full visible field | 71 bytes |
| 181 | 44 bytes / 11 rows | one independent 11-line score above or below | 67 bytes |
| 170 | 40 bytes / 10 rows | independent 11-line scores above **and** below | 67 bytes |

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

## Interface

Public state provides X coordinates for all five objects; Y/height state for
all five objects; P0/P1 graphics pointers and heights; independent P0/P1 NUSIZ
values; independent solid P0/P1 colors; and the playfield-row position.

The aliases `game_PLAYER0_X`, `game_PLAYER1_X`, `game_MISSILE0_X`,
`game_MISSILE1_X`, and `game_BALL_X` name the horizontal coordinates.
`game_SPRITE_GLYPH(...)` stores an eight-line player glyph in renderer order.

All profiles use only official NMOS 6502/6507 opcodes. The scheduler owns
VSYNC, VBLANK, RIOT timer deadlines and visible-component order.

## Maintained examples

- `examples/05_all_five_192/` instantiates `lines:=192`.
- `examples/06_all_five_181/` instantiates `lines:=181` with one score.
- `examples/11_all_five_170/` instantiates `lines:=170` between an 11-line
  score above and an 11-line score below.
- `examples/17_video_standards/pal/01_all_five/` and
  `examples/17_video_standards/secam/01_all_five/` instantiate `lines:=228` and
  consume the complete native 50 Hz visible field directly.

The separately maintained `all_five_unofficial` renderer remains the
experimental unofficial-opcode twin and currently supports 192-, 181-, and
170-line profiles.
