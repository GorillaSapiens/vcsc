```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# DPC diagnostic

This cartridge is a visible PASS/FAIL test for Atari DPC cartridges.  DPC is
modeled as two ordinary 4K F8 program banks plus a 2K data-only display bank
and a 255-byte data-only Poly8 bank.

The diagnostic calls code in both F8 program banks using the current compact
inline-target implementation. DPC reuses the maintained
`libraries/vcs/F8/inline_bankcall.s26` trampoline because its program-bank
selector geometry is identical to F8. The target descriptor ABI is documented in
[`../../../BANKSWITCHING.md`](../../../BANKSWITCHING.md). The diagnostic also checks all 2048 display
bytes through DPC fetcher 0 with an order-sensitive checksum and wrap test, and
checks a complete 255-state RNG cycle after resetting the DPC LFSR.

`make play` forces Stella's DPC mapper.
