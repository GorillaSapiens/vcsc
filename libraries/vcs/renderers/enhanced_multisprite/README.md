```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Enhanced multisprite renderer

`enhanced_multisprite.c26` is an experimental 192-visible-line six-sprite
renderer that treats **both TIA players as multiplexing lanes**. P0 is no longer
permanently logical sprite 0.

During VBLANK the six logical eight-row sprite intervals are greedily assigned
to P0 and P1. Non-overlapping logical sprites may reuse the same hardware player
later in the frame. Two sprites whose vertical intervals overlap can occupy P0
and P1 simultaneously and therefore render without flicker. When three or more
sprites compete for the same scanlines, frame priority rotates through the six
logical sprites. Three fully overlapping sprites therefore render as `0/1`,
`1/2`, `2/0` on successive frames; in general an N-way pile-up gets fair
2-of-N coverage.

This first profile intentionally concentrates on the player multiplexer. It owns
exactly 192 visible NTSC lines as 96 two-scanline logical bands and draws six
logical 8x8 sprites; M0, M1, Ball, and the caller-supplied playfield tables are
not yet part of the raster. It accepts the same 145-byte aligned graphics layout
and public X/Y/color/NUSIZ aliases as the existing `multisprite` renderer so the
maintained interactive control code can be reused unchanged.

Public Y increases upward and is currently limited to 0..89 for every logical
sprite. Each bitmap row is held for two physical scanlines. Hardware setup itself
occupies reserved bands above a sprite. P0 is repositioned four logical bands
above its top and uses a three-band delayed activation; P1 is repositioned one
band above its top. That asymmetry is only beam scheduling: any logical sprite
may be assigned to either hardware player. Two equal-Y sprites can therefore be
positioned on successive setup bands and become active together.

The VBLANK scheduler sorts only one-byte event indices rather than moving whole
event records. This keeps sprite crossings inside the NTSC VBLANK budget; a
sentinel event also keeps end-of-list handling out of the visible timing path.
The regression suite sweeps Y and combined X/Y motion for 997 measured frames at
a stable 262 displayed scanlines and separately checks three-way fair arbitration.

The implementation deliberately lives beside, rather than replacing,
`renderers/multisprite/`. The faithful modern renderer remains the compatibility
and timing oracle.
