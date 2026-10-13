```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# All-five colour sections (NTSC, 192 lines)

This separate solid-player-colour profile draws P0, P1, M0, M1 and the ball
continuously across **up to eight compile-time colour sections**. It does not
restart object state at a boundary. Existing renderers are unchanged.

## Configuration inside `.c26`

```c
instantiate "renderers/all_five_sections_192/all_five_sections_192.c26" as game (
   section1_lines:=30, section1_colupf:=0x2e, section1_colubk:=0x84,
   section2_lines:=162, section2_colupf:=0x46, section2_colubk:=0xc2
)
```

Each `sectionN_lines` is a height in visible scanlines, written in decimal.
Heights must be even,
nonnegative and total 192; section 1 must be nonempty. Unused sections default
to zero height. Colours are byte values (hexadecimal is supported). Invalid
configurations fail compilation or assembly. Defaults produce one 192-line section.

The compiler folds the layout into four page-contained 48-byte ROM colour feeds.
There is no runtime boundary search and no external configuration/generator tool.
The eight-section limit is this component's initial interface; the 96-section
stress probe does **not** imply 96 configurable slots here.

## Use and ownership

Include `vcs.c26` and `frame_ntsc.c26`. Supply page-contained immutable
`game_playfield[48]`: twelve 16-line rows, four bytes per row (left PF1/PF2,
right PF2/PF1). Colour boundaries are independent of those playfield rows.

Call `init()` once, then `vblank()`, `draw()`, and `overscan()` in their matching
NTSC scheduler phases. The component owns PF0/PF1/PF2, COLUPF/COLUBK, graphics,
object positioning/enables/delay/motion registers. The caller sets solid
COLUP0/COLUP1, CTRLPF and desired NUSIZ state. The ball follows COLUPF.
VSYNC, VBLANK and frame timers remain scheduler-owned.

Public state follows `all_five_player_color_192`: `PLAYER0_X`, `PLAYER1_X`,
`MISSILE0_X`, `MISSILE1_X`, `BALL_X` (0..159 colour clocks), `player0_y`,
`player1_y`, `missile0_y`, `missile1_y`, `ball_y`, object heights, sprite pointers,
and `PLAYER0_NUSIZ`/`PLAYER1_NUSIZ`. Y/height use two-scanline object rows, not
section scanlines. Graphics must be immutable and page-contained. Player heights
are last-row indices: 7 selects eight graphics rows (sixteen hardware scanlines).
They are temporarily incremented in vblank and restored in overscan. Do not change
state between preparation and drawing. Private masks and caches are not an API.

Draw enters at cycle 3, owns 192 complete lines and returns at cycle 0 after
terminal WSYNC. The cached renderer uses 83 RAM bytes, plus application state
and hardware stack. The example uses 91/128 total RAM bytes and fits a 4K ROM.
Vblank reserves the inherited 1800-cycle budget plus 24 cycles for initial colours.

Normal GRP1/M1 stores finish at cycles 3/6, colours at 13/20. Packed-pair and
row-handoff equivalents are 2/5 and 12/19. Right PF2 completes at cycle 48.
Page anchors and `.same` assertions are part of the timing contract.

The inherited P0 pipeline primes during the first two visible lines: P0 cannot
straddle a boundary at line two. The edge-layout raster test checks that seam
against the ordinary renderer without claiming otherwise.

Only NTSC 192-line operation with solid player colours is supported here.
Odd boundaries, player colour tables, score composition and PAL/SECAM are not
certified for this schedule.

## Example and tests

See `examples/04_renderers/all_five_sections/all_five_sections_192.c26`.
It has eight sections, four palettes and all five objects moving vertically.
Build/run instructions are in the example's README.

`test/vcs_all_five_sections_fine_*.test` compares the actual component against
independent ordinary golden cartridges, with every seam of the eight-section
fixture and isolated X=0/159 cases. Additional edge and four-palette cases check
exact RGB and stable register-write phases. Dense-layout testing remains a probe.
