```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Tigervision 3EX

This profile targets Stella 7.0 3EX: up to 256 physical 2K ROM banks
(512K ROM) and 256 independently selected 1K RAM banks (256K RAM).
ROM switching and compiler-managed `$swapram` use the same `$3F`/`$3E`
windows as classic 3E.

Stella stores `(RAM bank count - 1)` in ROM byte `size-6`.  With a 2K 3E-family
bank size, Stella's implementation computes RAM capacity as half a ROM bank
(1K) times that count.  VCSC therefore exposes the complete 8-bit selector
range as **256 x 1K = 256K**.

That `size-6` byte overlaps VCSC's ordinary tail-signature location and the
unused NMI vector low byte.  The linker writes Stella's RAM-count metadata
there instead of the topology signature's third byte.  Stella's 3EX detector
requires two ASCII `3EX` strings anywhere in the image.  Its detector skips
one additional byte after each match, so adjacent `3EX3EX` is *not* two hits;
VCSC writes two `3EX` markers with one separator byte into the otherwise
unused gap immediately after the vector bridge in the startup/final ROM bank.

The compiler-visible swapram region is 256K with a 1K bank size.  Accesses are
lowered through `swapram_read1`/`swapram_write1` helpers that execute from the
permanently visible final ROM bank.  Reads use `$1000-$13FF`, writes use the
split alias `$1400-$17FF`, and the selected RAM bank is written to `$3E`.

Cross-ROM-bank calls use the same descriptor model as 3E.  Selectable lower
banks use descriptors `$00-$FE`; the fixed final bank uses `$FF` as the
no-switch sentinel.  The mapper-owned trampoline is `3EX/bankcall.s26`, and
`3EX/entry.s26` is intentionally empty because the final bank is always visible
at reset.
