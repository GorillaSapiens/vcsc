```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Enhanced multisprite asymmetric-playfield renderer

`enhanced_multisprite.c26` is the experimental 192-visible-line six-sprite
renderer that multiplexes both TIA players while also drawing a full 40-bit
asymmetric playfield.  It is intentionally a sibling of the maintained
player-only `enhanced_multisprite` renderer while the raster is being proven.

The playfield is non-reflected (`CTRLPF` REF=0 in the public example) and is
supplied entirely from caller-owned const/ROM tables.  Every logical band has
independent left and right PF0/PF1/PF2 data.  Ordinary visible lines issue the
six required writes in left PF0/PF1/PF2 then right PF0/PF1/PF2 order.
Position/setup bands preserve the same full-PF contract; in particular, both
physical scanlines of a position band now restore left PF0 and rewrite right
PF0 instead of inheriting the prior scanline's PF0 state.

During VBLANK the six logical eight-row sprite intervals are greedily assigned
to P0 and P1.  Non-overlapping logical sprites may reuse a hardware player later
in the frame.  Two overlapping sprites can occupy P0 and P1 simultaneously;
when more than two contend, rotating priority provides fair 2-of-N coverage.
The scheduler and branch-free graphics-state transition machinery are inherited
from the enhanced-multisprite work and remain intentionally outside the
beam-critical raster where possible.

Horizontal metadata is split deliberately: `event_code` carries logical sprite
id plus the full HMP fine-motion nibble.  The renderer now contains the actual
11-entry coarse-RESP landing geometry as one page-contained, 128-byte-aligned
code object.  Each delay cell is exactly three ROM bytes and five CPU cycles
(`NOP` + zero-page `BIT`).  P0 entries occupy base+$00..$1e and P1 entries
base+$40..$5e.  VBLANK converts each raw 0..10 coarse slot to the absolute low
byte of its landing and stores that byte in `position_packed`; bit 6 of the low
byte is therefore the hardware-lane tag, tested with `BIT/BVS`.  `event_stage`
holds the common page byte, so `position_packed:event_stage` is already a
zero-page indirect-JMP vector.  The visible raster still uses the fixed RESP
fallback at this checkpoint; wiring `JMP (position_packed)` into the position
line and replacing the temporary landing RTSes with the calibrated phase paths
remain WIP, so public X=0..159 is not yet certified.

The raster aggressively moves work into the end of the preceding physical
scanline when useful.  The current P1 position path, for example, commits the
continuing P0 bitmap row in the tail of position line A so position line B can
spend those cycles on the missing PF0 transitions without exceeding one NTSC
scanline.

Current checkpoint accounting for the public asymmetric example is
3710/4090 ROM bytes and 117/128 RAM bytes.  A trial dedicated 256-byte-aligned
trampoline page was rejected because the alignment fragmented the 4K link.  The
replacement landing object uses only 128-byte alignment, is 96 bytes long, and
links cleanly; in the current build it lands at `$F780`, with P1 beginning at
`$F7C0`.  The next task is to enter this ready-made vector from the position
scanline, replace the temporary RTS landings with real RESP phase paths, then
Stella-calibrate all 11 phases on both hardware lanes while preserving all six
playfield writes and stable 262-line output.
