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
id plus the full HMP fine-motion nibble, while `position_packed` carries the
hardware lane in bit 7 and the coarse RESP slot in bits 0..3.  The final
11-phase coarse RESP dispatcher is still WIP.  Do not claim public X=0..159 is
certified from this renderer yet merely because the packed position table is
present.

The raster aggressively moves work into the end of the preceding physical
scanline when useful.  The current P1 position path, for example, commits the
continuing P0 bitmap row in the tail of position line A so position line B can
spend those cycles on the missing PF0 transitions without exceeding one NTSC
scanline.

Current checkpoint accounting for the public asymmetric example is
3602/4090 ROM bytes and 117/128 RAM bytes.  The next task is still to install
and Stella-calibrate the 11 fixed coarse RESP phases for both hardware lanes
while keeping all six playfield writes and stable 262-line output.
