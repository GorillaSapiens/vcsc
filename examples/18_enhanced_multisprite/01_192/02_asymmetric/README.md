```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Interactive enhanced multisprite + asymmetric playfield diagnostic

Build with `make`, then `make play`. Game Select cycles logical sprites 0..5;
the left joystick moves the selected sprite in X/Y and Reset restores the scene.
The controls are the same shared controls used by the maintained multisprite
examples.

The initial scene deliberately demonstrates the new arbitration:

- logical sprites 0/1/2 share the same vertical band, so two are visible on each
  frame and the pair rotates `0/1`, `1/2`, `2/0`;
- logical sprites 3/4 share a lower band and should both remain solid;
- logical sprite 5 is isolated, demonstrating that a hardware player can be
  reused for another logical sprite later in the same frame.

This experimental profile adds a dynamic 32-bit asymmetric central playfield.
Each logical two-scanline band has independent left PF1/PF2 and right PF2/PF1
data. PF0, missiles, and Ball are intentionally not rendered yet. Horizontal
sprite positioning is still under active calibration in this WIP profile.
