```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# PAL50 228-line multisprite example

Runs `multisprite (lines:=228)` across the complete 228-line visible field: P0 plus five logical sprites multiplexed through P1, with eight retained playfield rows. The full-height profile exposes P0 Y `0..113` and multiplexed P1 Y `0..110`. `make play` explicitly selects Stella `PAL` format.
