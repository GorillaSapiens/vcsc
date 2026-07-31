```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Official-opcode all-five 192-line component

`all_five_192.c26` is the full-height scoreless P0/P1/M0/M1/BL gameplay
component. Its twelve-row visible pipeline is derived from the proven
`player_color_192` renderer. The two timed slots formerly used for per-row
P0/P1 color loads now update M1 and M0, so P0 and P1 retain independent
**solid colors for the complete frame**.

Instantiate it after defining a page-contained 48-byte playfield:

```vcsc
include "vcs.c26"
include "frame_ntsc.c26"

template "renderers/all_five_192/all_five_192.c26" as game

page const uint8_t game_playfield[48] := {
   /* twelve rows, four bytes per row */
};
```

The component draws exactly 192 visible gameplay scanlines as twelve uniform
16-line rows. It is deliberately scoreless; an eleven-line score cannot also
fit inside the standard 192-line visible field.

The scheduler owns VSYNC, VBLANK, timer deadlines, and the complete frame loop.
`game_vblank()` prepares the object masks and positions all five objects while
output is blanked. `game_draw()` renders the complete visible field, and
`game_overscan()` clears gameplay state and restores the application-visible Y
coordinates.

## Interface and resources

Public state includes X coordinates for all five objects, their Y/height state,
P0/P1 graphics pointers and heights, independent P0/P1 NUSIZ values, and
independent solid P0/P1 colors.

Machine-readable contracts publish:

- `game_VISIBLE_SCANLINES := 192`
- `game_VBLANK_MAX_CYCLES := 1800`
- `game_OVERSCAN_MAX_CYCLES := 66`
- `game_PUBLIC_RAM_BYTES := 23`
- `game_PRIVATE_RAM_BYTES := 55`
- `game_MODULE_RAM_BYTES := 78`
- `game_WORKSPACE_BYTES := 6`
- `game_PLAYFIELD_BYTES := 48`
- `game_PLAYFIELD_ROWS := 12`

Private storage consists of six workspace bytes, one playfield-position byte,
and 48 object-mask bytes. The application supplies the playfield and player
graphics in ROM. The implementation uses only official NMOS 6502/6507
opcodes. P1 graphics and both missile-enable updates are pipelined across the
scanline boundary and committed during horizontal blanking, so objects at the
right edge cannot expose the next row early.

## Verified behavior

Maintained emulator tests require:

- stable 262-line NTSC frames
- all twelve playfield rows, all sixteen scanlines per row, and all 160 pixels
- identical steady reflected-playfield write phases on the alternating P1 and
  P0 scanlines (PF1/PF2/PF2/PF1 at cycles 17/24/45/52)
- visible P0, P1, M0, M1, and Ball activity
- HBLANK-only P0/P1 handoffs and effective missile-state changes, including
  right-edge positions
- correct VBLANK positioning and lifecycle restoration
- official opcodes only
- exact RAM, page-placement, and stack contracts
- successful source-tree and staged-installed builds
