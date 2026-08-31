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
RAM, and then executes all six ordered cross-bank C-call pairs among the three physical
ROM banks. The example opts into the generic five-byte `JSR` + inline-target ABI,
so those calls share one fixed replicated call/return block and generate no
per-target JSR bridge entries. The selectors therefore exercise `$1FF8`, `$1FF9`,
and `$1FFA` in both source and destination roles, including return to the hardware
power-on/startup bank 2. Each target returns a distinct 16-bit A:X value, and RAM
sentinels must survive every bank transition.

Build with `make`; the Makefile enables `VCSC_INLINE_BANKCALL` for this diagnostic.
`make play` launches Stella with `-bs FA`.
