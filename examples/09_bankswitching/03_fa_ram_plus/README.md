```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# CBS FA / RAM Plus diagnostic

`fa_ram_plus_diagnostic.c26` is a self-checking 12K CBS FA/RAM Plus cartridge.
It displays lowercase `pass` on a green background when all checks succeed and
uppercase `FAIL` on a dark-red background otherwise. A centered `FA` line below
the result identifies the mapper, matching the other public bankswitch diagnostics.

The diagnostic fills the complete 256-byte FA cartridge-RAM allocation, verifies
BSS/DATA reset initialization, writes sentinels at both ends and the middle of
RAM, and then executes the complete 3x3 ordered C-call matrix among the three
physical ROM banks. Same-bank calls remain ordinary JSRs; the six cross-bank
calls use the six-byte destination-descriptor ABI documented in
[`../../../BANKSWITCHING.md`](../../../BANKSWITCHING.md), sharing one fixed
replicated call/return block and generating no per-target JSR bridge entries. FA
uses selector-low-byte descriptors `$F8`, `$F9`, and `$FA`. Each target returns a
distinct 16-bit A:X value, and RAM sentinels must survive every bank transition.

Build with `make`; the mapper profile uses the descriptor bank-call ABI directly.
`make play` launches Stella with `-bs FA`.
