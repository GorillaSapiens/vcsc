```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Official-opcode all-five 181-line component

`all_five_181.c26` is the score-composable gameplay profile for the standard
P0/P1/M0/M1/BL renderer. It is a repeatable VCSC template with the standard
component lifecycle:

```vcsc
include "vcs.c26"
include "frame_ntsc.c26"

template "renderers/all_five_181/all_five_181.c26" as game
```

The application must define a page-contained 44-byte playfield before the
template is instantiated:

```vcsc
page const uint8_t game_playfield[44] := {
   /* eleven rows, four bytes per row */
};
```

The component draws exactly 181 gameplay scanlines. A scored application is
expected to compose the independent eleven-line `six_glyph_component.c26`
above or below it:

```text
181 gameplay lines + 11 score lines = 192 visible lines
```

`main()` owns VSYNC, VBLANK, the RIOT timer deadlines, component order, and the
complete frame loop. `game_vblank()` uses bounded internal WSYNC stalls for
object positioning while the shared VBLANK deadline is running. The component
never starts or reads the RIOT timer and never writes VBLANK or VSYNC.

## Interface and resources

The instance exports public state for all five TIA objects, player graphics and
heights, vertical positions, and playfield position. Use the aliases
`game_PLAYER0_X`, `game_PLAYER1_X`, `game_MISSILE0_X`, `game_MISSILE1_X`, and
`game_BALL_X` for horizontal positions. `game_SPRITE_GLYPH(...)` stores an
8-line player glyph in the renderer's expected bottom-to-top byte order.

Machine-readable contracts publish:

- `game_VISIBLE_SCANLINES := 181`
- `game_VBLANK_MAX_CYCLES := 1800`
- `game_OVERSCAN_MAX_CYCLES := 0`
- `game_PUBLIC_RAM_BYTES := 19`
- `game_PRIVATE_RAM_BYTES := 50`
- `game_MODULE_RAM_BYTES := 69`
- `game_PLAYFIELD_BYTES := 44`
- `game_PLAYFIELD_ROWS := 11`

The implementation uses only official NMOS 6502/6507 opcodes. The visible
steady playfield writes occur at cycles 24, 31, 38, and 45; staged row-entry writes occur at 21, 28, 38, and 45 of each measured
scanline. On return from `game_draw()`, all playfield, player, missile, ball,
vertical-delay, and horizontal-motion graphics state is cleared and the
application-visible Y positions are restored.

## Proven score composition

Maintained static and asynchronous-motion fixtures exercise both legal orders:

```vcsc
score_draw();
configure_game_frame();
game_draw();
```

and:

```vcsc
configure_game_frame();
game_draw();
score_draw();
```

The score component changes P0/P1 color, copy, delay, and positioning state, so
an application drawing the score first must reapply the gameplay TIA state
between the two draw calls. Both orders consume exactly 181 + 11 visible lines
and enter overscan on line 232 of a stable 262-line frame.

The motion regression runs 360 frames in each order. All five X coordinates
move asynchronously over the complete 0..159 range, all Y coordinates survive
component-internal counter biasing, and the score region contains no playfield,
missile, or ball activity. A gameplay-only link still contains no score state or
font; adding the independent score contributes its separately measured 17 bytes
of RIOT RAM.

The standard linker configuration
`renderers/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg` supplies four bytes of
hidden call-stack allowance needed by the inline VBLANK preparation routine.
A second practical instance normally cannot fit in the VCS's 128-byte RIOT RAM;
template instantiation still prevents accidental symbol sharing and gives the
component the same lifecycle/hygiene contract as other reusable displays.

The older `standard_4k_ntsc` monolith remains installed as the predecessor
oracle until the 181-line score compositions, the separate 192-line scoreless
profile, and the matched unofficial-opcode experiment have all been proved.
