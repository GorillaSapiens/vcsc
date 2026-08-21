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

Horizontal sprite positioning is still under active calibration.  Fine HMP
metadata is generated per event.  The coarse path now has a real page-contained
11-entry landing block: each phase step is three ROM bytes / five CPU cycles,
P0 occupies base+$00..$1e, and P1 base+$40..$5e.  VBLANK stores the absolute
landing low byte in `position_packed`; bit 6 identifies P1, and adjacent
`event_stage` holds the common high byte, making the pair ready for an indirect
JMP.  The raster still uses the fixed RESP fallback at this checkpoint; entering
that vector and calibrating all 11 phases across public X=0..159 remain WIP.
