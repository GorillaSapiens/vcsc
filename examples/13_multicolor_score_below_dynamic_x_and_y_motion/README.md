```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Multicolor Score Below Dynamic X and Y Motion

This example demonstrates the official multicolor P0+P1+Ball kernel as a
181-line gameplay with an 11-line score below it. It uses asynchronous horizontal and vertical P0, P1, and Ball motion.

P0 and P1 each have eight independently colored bitmap rows. The Ball and an
asymmetric playfield make positioning and component boundaries easy to see.
Missiles are intentionally absent from this kernel family.

Build with `make`, then run `multicolor_score_below_dynamic_x_and_y_motion.bin` in Stella.
