```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Heart score

This 2K example instantiates `heart_score_component.c26` as a fixed-footprint
0..11 health meter. Eleven eight-pixel hearts are centered across the screen at
a 12-pixel pitch. Smaller values are exact left-justified prefixes, so changing
health never moves an already-visible heart.

The example advances from zero through eleven full hearts every 30 frames and
then wraps to zero. The component consumes seven visible scanlines; its setup
and self-modifying renderer execute from ordinary 128-byte RIOT RAM.
