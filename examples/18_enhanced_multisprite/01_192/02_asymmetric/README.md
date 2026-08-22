```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Interactive enhanced multisprite + full asymmetric playfield diagnostic

Build with `make`, then `make play`. Game Select cycles logical sprites 0..5;
the left joystick moves the selected sprite in X/Y and Reset restores the scene.
The controls are the same shared controls used by the maintained multisprite
examples.

The initial scene deliberately demonstrates two-player arbitration: sprites
0/1/2 share a vertical band and rotate through fair 2-of-3 coverage, sprites
3/4 overlap lower down, and sprite 5 is isolated so a hardware player must be
reused later in the frame.

This WIP profile draws a full 40-bit non-reflected asymmetric playfield.  Each
logical two-scanline band has independent const/ROM left PF0/PF1/PF2 and right
PF0/PF1/PF2 data, with `CTRLPF := 0`.  PF0 is part of the raster from the start;
this is not the earlier PF1/PF2-only experiment.  Both physical lines of the
special position bands now perform the required PF0 left/right transition too.

For visual diagnosis the playfield is now organized as **12 rows of 16 scanlines**
(eight logical two-scanline bands per row), rather than six 32-scanline rows.  The
40-bit pattern is a family of one-bit diagonals separated by exactly five blank
playfield bits.  Each successive 16-line row shifts the pattern by one bit, so a
stale byte, wrong half, or mistimed PF rewrite stands out immediately.

The current diagnostic is again a conventional **4K** cartridge.  It uses a
small example-specific startup because this fixture explicitly initializes all
writable state and therefore does not need the generic DATA/copy/constructor
startup machinery.  The linked image currently uses about 3.7 KiB of ROM and
115 bytes of RIOT RAM; no bankswitching or Superchip RAM is required.

Horizontal positioning covers public X=0..159 on both hardware players with the
current measured twelve-phase RESP lattice
`23,28,33,37,42,47,50,53,58,63,68,73`.  Public Y is 0..95.  Events whose normal
setup would begin in or above the first visible band are pre-positioned during
VBLANK, so sprites can reach the very top without spending an impossible setup
scanline in visible time.

The automated timing regression now hammers the complete X=0..159 / Y=0..95
range, including the historical action-Y=95 top-edge failure and two simultaneous
Y=95 sprites, at a stable 262-line NTSC frame.  Remaining WIP is quality/capability
work rather than a known frame-length defect: finish Stella pixel certification
of every X position, migrate the middle X range to the intended final eleven-slot
lattice, then restore the richer two-sprite pair-feasibility scheduler.
