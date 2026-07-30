```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Official-opcode all-five 181-line component

`all_five_181.c26` is the score-composable P0/P1/M0/M1/BL gameplay
component. Its visible pipeline is derived from the proven
`player_color_181` renderer, with the two cycle slots formerly used for
per-row P0/P1 color loads reassigned to M1 and M0 enable updates. P0 and P1
therefore retain independent **solid colors for the complete frame**.

Instantiate it after defining a page-contained 44-byte playfield:

```vcsc
include "vcs.c26"
include "frame_ntsc.c26"

template "renderers/all_five_181/all_five_181.c26" as game

page const uint8_t game_playfield[44] := {
   /* eleven rows, four bytes per row */
};
```

The component draws exactly 181 gameplay scanlines. An application may place
an independent eleven-line six-glyph score above or below it:

```text
181 gameplay lines + 11 score lines = 192 visible lines
```

The scheduler owns VSYNC, VBLANK, timer deadlines, visible-component order,
and the complete frame loop. `game_vblank()` prepares masks and positions M0,
M1, and Ball while output is blanked. `game_draw()` restores P0/P1 positioning,
NUSIZ, and solid colors at its visible entry, so it is safe after a score
component has used the players. Adjacent visible components must be separated
with `vcs_ntsc_component_handoff()`.

## Interface and resources

The public state includes:

- X coordinates for P0, P1, M0, M1, and Ball
- Y coordinates and heights for all five objects
- P0/P1 graphics pointers and heights
- independent P0/P1 NUSIZ values
- independent solid P0/P1 colors
- the current playfield-row position

The aliases `game_PLAYER0_X`, `game_PLAYER1_X`, `game_MISSILE0_X`,
`game_MISSILE1_X`, and `game_BALL_X` name the horizontal coordinates.
`game_SPRITE_GLYPH(...)` stores an eight-line player glyph in the renderer's
bottom-to-top byte order.

Machine-readable contracts publish:

- `game_VISIBLE_SCANLINES := 181`
- `game_VBLANK_MAX_CYCLES := 1800`
- `game_OVERSCAN_MAX_CYCLES := 58`
- `game_PUBLIC_RAM_BYTES := 23`
- `game_PRIVATE_RAM_BYTES := 51`
- `game_MODULE_RAM_BYTES := 74`
- `game_WORKSPACE_BYTES := 7`
- `game_PLAYFIELD_BYTES := 44`
- `game_PLAYFIELD_ROWS := 11`

Private storage consists of seven workspace bytes, one playfield-position byte,
and 43 object-mask bytes. The implementation uses only official NMOS
6502/6507 opcodes.

## Verified behavior

Maintained static and asynchronous-motion cartridges exercise score-above and
score-below composition. Emulator tests require:

- stable 262-line NTSC frames
- all eleven playfield rows, all sixteen scanlines per row, and all 160 pixels
- visible P0, P1, M0, M1, and Ball activity
- full-range asynchronous X motion, including X=0 and X=159
- preservation of application-visible Y coordinates across the lifecycle
- no playfield, missile, or Ball leakage into the score region
- official opcodes only and the exact RAM/page/stack contract

A gameplay-only link contains no score state, score pointers, or font. The
independent score contributes only its own separately measured resources.

## Public diagnostics

[`examples/06_all_five_181/`](../../../../examples/06_all_five_181/) contains score-above and score-below interactive cartridges. SELECT cycles through all five TIA objects, the left joystick moves the selected object through its full coordinate range, and the filtered right joystick edits the independent six-digit score. The examples pack their control state into two bytes so the full composition remains comfortably inside the VCS's 128 bytes of RAM.
