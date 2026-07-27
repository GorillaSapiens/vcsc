```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Multicolor Score Above Static

This example demonstrates the official multicolor P0+P1+Ball kernel as a
181-line gameplay with an 11-line score above it. It uses fixed P0, P1, and Ball positions.

P0 and P1 each have eight independently colored bitmap rows. The Ball and an
asymmetric playfield make positioning and component boundaries easy to see.
Missiles are intentionally absent from this kernel family.

Build with `make`, then run `multicolor_score_above_static.bin` in Stella.
