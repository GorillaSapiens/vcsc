```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# FA2 diagnostic

`fa2_diagnostic.c26` is a self-checking seven-bank 28K FA2 cartridge. It displays
lowercase `pass` on a green background when all checks succeed and uppercase
`FAIL` on a dark-red background otherwise. A centered `FA2` line identifies the
mapper.

The diagnostic occupies all 256 bytes of FA2 cartridge RAM, verifies BSS/DATA
startup initialization, writes sentinels across the device, then executes the
complete 7x7 ordered source/destination call matrix. The seven diagonal calls
are ordinary same-bank JSRs; the other 42 matrix legs use the descriptor ABI.
FA2 descriptors are the selector-hotspot low bytes `$F5-$FB`, and
`libraries/vcs/FA2/bankcall.s26` selects/restores banks with indexed stores
through `$1F00`. Cartridge RAM must survive all 49 matrix calls. The public ABI
is documented in [`../../../BANKSWITCHING.md`](../../../BANKSWITCHING.md).

VCSC's native FA2 profiles are clean 24K (six-bank) and 28K (seven-bank) ROM
images. Harmony's optional `$1FF4` flash save/load service and the 29K/32K
Harmony wrapper formats are compatibility concerns, not part of the core VCSC
FA2 language/runtime contract.

Build with `make`; `make play` launches Stella with `-bs FA2`.
