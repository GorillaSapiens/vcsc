```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# F0 / Dynacom Megaboy

This directory provides VCSC's automatic-call profile for the 64K F0 mapper.
F0 contains exactly sixteen 4K physical ROM banks, each mapped at
`$F000-$FFFF`.  Hardware powers up in physical/file bank 15.  Every read or
write of cartridge bus address `$1FF0` advances to the next bank modulo 16;
there is no absolute bank-select operation.

`mapper.c26` names physical banks `bank0` through `bank15`, keeps file index and
`$bankcall` descriptor equal to that physical number, and marks `bank15` as the
startup/home bank.  Ordinary automatic placement therefore prefers bank15 for
startup code while explicit `bankN` placement names the corresponding physical
bank directly.

Generated cross-bank calls use the normal three-byte inline target payload.  A
source-bank trampoline computes `(destination-source) & 15`, then performs that
many `$1FF0` reads.  On return, the destination-bank copy computes
`(source-destination) & 15` and advances back before the final RTS.  All bytes
executed after the first switch are identical across the sixteen replicated
trampolines; only the bank-local source descriptor immediate differs, and it is
consumed before switching.

Because F0 has no absolute selector, VCSC cannot repair arbitrary mapper-state
changes made by handwritten code.  Code that accesses `$1FF0` outside the
maintained bankcall mechanism owns F0 mapper state.  Reset follows the hardware
contract and starts in bank 15; `entry.s26` is intentionally empty.

The `$FFF0` CPU address aliases the `$1FF0` hotspot, so ordinary code is not
allocated in the top 288 bytes of each bank and the generated vector bridges
live below that hotspot.

