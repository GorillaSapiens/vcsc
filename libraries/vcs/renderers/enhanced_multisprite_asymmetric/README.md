```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Enhanced multisprite asymmetric-playfield renderer

`enhanced_multisprite.c26` is the maintained enhanced six-sprite renderer. It multiplexes both TIA players while drawing a full non-reflected 40-bit asymmetric PF0/PF1/PF2 playfield.

The required `lines` parameter supports 192 and 228 active scanlines. Those correspond to 96 and 114 two-scanline logical bands and public Y ranges 0..95 and 0..113. The 228 profile is used directly by native PAL/SECAM examples; it is not a 192-line kernel surrounded by padding.

The scheduler retains the measured setup/handoff contracts documented in `.../enhanced_asymmetric.txt`. The F8 228-line examples enter the renderer bank while VBLANK is still asserted, then perform `end_vblank()`, `draw()`, and `begin_overscan()` resident in that bank. Do not put an F8 cross-bank trampoline between `end_vblank()` and `draw()`: its entry cost pushes the first cycle-counted line past the scanline boundary and produces a 229-line visible component. Caller-owned playfield ROM is page-contained. In the 228 profile the left/right PF0 planes share one 228-byte page-contained table to avoid wasting a page boundary; the 192 compatibility profile retains its separate 96-byte PF0 tables so its tightly packed 4K NTSC diagnostic remains stable.
