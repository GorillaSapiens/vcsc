```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Two-axis sprite motion

This scoreless full-height example uses `all_five_192`. Player 0 moves
simultaneously in X and Y, bouncing around a rectangular region while P1,
M0, M1, and Ball remain visible as references. Motion is updated during
overscan after the component restores application-visible coordinates.

Build with `make` and run `xy_motion.bin` in Stella.
