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

A setup band replaces the ordinary line-A bitmap update for that band. The
renderer therefore preserves the row already due on the *other* hardware
player, advances that lane's cached bitmap state for the following band, and
publishes the preserved row at cycle 0 of setup line A. This avoids duplicated
or dropped glyph rows while one player is repositioned. The `STY GRPx` / `TXA`
prefix deliberately consumes the same five cycles as the calibrated packed
position prefix, so fixing the vertical handoff does not move RESP/HMOVE.

Same-lane reuse also reserves the earlier attribute-write line, not merely the
RESP/HMOVE setup and eight bitmap bands. P0 lane reuse therefore requires a
15-Y separation and P1 requires 12; otherwise the scheduler selects the other
lane or omits the lower-priority sprite for that frame. This prevents a new
sprite's `COLUPx`, `NUSIZx`, or `REFPx` write from recoloring the last physical
scanline of the previous sprite.

The VBLANK scheduler is deliberately out-of-line from the visible renderer.
During lane allocation, `event_order[]` first doubles as a compact list of only
the sprites already accepted this frame, so a candidate never scans six stale or
not-yet-visited `lane_for[]` slots. With six logical sprites this bounds conflict
checks to at most 0+1+2+3+4+5 = 15. Accepted setup records are then ordered by a
fixed 12-comparator six-input sorting network; its cost does not depend on the
vertical permutation. A sentinel event keeps end-of-list handling out of the
visible timing path.

Horizontal reuse uses a renderer-local packed RESP/HMP table calibrated for this
profile's own beam phase: `RESP0`/`RESP1` are strobed on setup line A and `HMOVE`
is the first instruction on setup line B. The table was derived by exercising all
176 safe coarse/fine controls in Stella 7.0 and covers every public X=0..159; it
is intentionally not the table from the legacy multisprite raster, whose HMOVE
phase is different. The regression suite includes ordinary Y/XY sweeps, every
logical sprite moving independently in both Y directions, and randomized
per-frame mutation of all six Y values while requiring a stable 262-line NTSC
frame. It also verifies fair 2-of-N arbitration for 3-, 4-, 5-, and 6-way
pileups. `make stella-enhanced-multisprite-test` additionally grades real Stella
pixels at the X edges, swaps logical sprites between both hardware lanes, checks
equal-Y alignment, verifies exact eight-row glyph/color integrity at setup-handoff
boundaries that previously failed interactively, and verifies top reach.

The implementation deliberately lives beside, rather than replacing,
`renderers/multisprite/`. The faithful modern renderer remains the compatibility
and timing oracle.
