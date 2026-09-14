```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Heart score

This 4K example instantiates `heart_score_component.c26` as a fixed-footprint
0..11 health meter with half-heart steps. Eleven eight-pixel hearts are centered across the screen at
a 12-pixel pitch. Smaller values are exact left-justified prefixes, so changing
health never moves an already-visible heart.

The example advances in half-heart steps from zero through eleven hearts every
30 frames and then wraps to zero. The component consumes seven visible scanlines. Its twelve
prepatched renderer variants execute directly from ROM; the component itself
uses only eight bytes of RIOT RAM, including public score, half-state, and color bytes.
A zero-full-heart half state is a single P0 left-half sprite. Later half states
use the next P0/P1 copy while leaving every full-heart position unchanged; no
Ball or missile graphics are consumed.
