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
instantiate "renderers/all_five/all_five.c26" as game (lines:=192)
instantiate "renderers/all_five/all_five.c26" as game (lines:=181)
instantiate "renderers/all_five/all_five.c26" as game (lines:=170)
```

No run-time scanline counter or run-time profile switch is added. `lines` is a
compile-time instantiation parameter and selects the corresponding timed code
with `#if` inside the instantiated source.

## Profiles

| `lines` | Playfield | Typical composition | Component RAM |
| ---: | ---: | --- | ---: |
| 192 | 48 bytes / 12 rows | full-height, scoreless | 71 bytes |
| 181 | 44 bytes / 11 rows | one independent 11-line score above or below | 67 bytes |
| 170 | 40 bytes / 10 rows | independent 11-line scores above **and** below | 67 bytes |

All playfields are page-contained and contain four bytes per 16-line row. The
192-line profile uses the proven full-height pipeline and positions all five
objects during VBLANK. The 181- and 170-line profiles use the score-composable
entry handoff that restores P0/P1 positioning, NUSIZ and colors after a score
component has owned the players. Adjacent visible components must be separated
with `vcs_ntsc_component_handoff()`.

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

The separately maintained `all_five_unofficial` renderer is the parameterized
experimental unofficial-opcode twin and supports the same 192-, 181-, and
170-line profiles.
