```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Player-color 192-line gameplay component

`player_color_192.c26` is the official-opcode, scoreless full-height P0/P1/Ball
profile with independent per-row P0 and P1 color tables. Instantiate it after
`vcs.c26` and drive its four lifecycle functions from `frame_ntsc.c26`.

The application supplies a page-contained `INSTANCE_playfield[48]`, two
page-contained eight-byte player-color tables, and page-contained player
graphics. Color tables are immutable by default. An application that defines the
object-like alias `VCS_PLAYER_COLOR_192_MUTABLE_COLORS` before instantiation may
instead supply mutable `INSTANCE_player0_colors[8]` and
`INSTANCE_player1_colors[8]` RAM objects. It must initialize or update them
outside `draw()` and leave them unchanged throughout the visible region. In
that mutable-color mode, the steady two-line path holds each pending P0 color in
workspace until GRP1 transfers the matching VDELP0 bitmap. This prevents a
newly installed row color from leading its delayed graphics by one scanline.

The component owns exactly 192 visible lines:
twelve playfield rows of sixteen scanlines each. It cannot be combined with an
eleven-line score inside the standard visible field.

RAM contract: 13 public bytes, 56 private bytes, 69 bytes total. The component
contains one page-contained 16-byte fine-motion table. Missiles are unavailable.
It owns no score/font, VSYNC, VBLANK, or RIOT timer state and uses only official
NMOS 6502 opcodes. Its VBLANK mask builder flattens the two single-use helper
wrappers; only the shared `set_range` body remains an assembly subroutine. The
object therefore declares `.callstackextra 0`: that remaining hidden JSR is
explicitly audited and never requires more hardware-stack bytes than the ordinary
source-call reserve already needs.

P0, P1, and Ball are positioned entirely during VBLANK. The first P1/Ball half
and the left half of playfield row zero are staged while output is blanked, so
visible drawing starts directly at line 40 in the same two-line pipeline used
for every later row. Row transitions use cycle-matched paths so the four
playfield writes stay aligned instead of drifting downward. P1 graphics are
staged in private workspace and committed through GRP1 during horizontal
blanking; that commit also transfers the delayed P0 and Ball graphics before
the beam reaches the visible right edge. The terminal path
finishes row twelve, then uses WSYNC to consume the remainder of visible line
231. draw() therefore returns at the line-232 boundary, where the frame scheduler
asserts VBLANK at physical beam cycle five. Display-state cleanup and the private
playfield-position restore occur afterward in overscan, so they cannot expose a
partially drawn extra scanline at the bottom of Stella's display. Public Y
coordinates are then restored.

The regression tests use the 6502/TIA write trace as the oracle. They verify the
ordinary immutable-table profile and the animated example's mutable-table
profile, including page containment and updates outside visible drawing. They
also verify all 192 visible lines against the source playfield bytes at the exact safe write
phases, exact 262-line frames, VBLANK-only horizontal positioning, P0/P1 glyph
order and colors, Ball activity in both the normal and terminal bands, and the
absence of missile activity. Nonzero GRP1 handoffs are required to occur in
horizontal blanking, preventing a new sprite row from appearing in the final
pixels of the preceding scanline. Example 06 is also reviewed in Stella 7.0.
Historical PNG fixtures are not treated as authoritative because several are
captured from broken rasters.
