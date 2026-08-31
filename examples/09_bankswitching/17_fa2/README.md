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
startup initialization, writes sentinels across the device, then executes a
nested call chain through all seven physical ROM banks and back to bank 0. This
exercises selectors `$1FF5` through `$1FFB` and the generated return trampolines
while verifying that cartridge RAM survives every transition.

VCSC's native FA2 profiles are clean 24K (six-bank) and 28K (seven-bank) ROM
images. Harmony's optional `$1FF4` flash save/load service and the 29K/32K
Harmony wrapper formats are compatibility concerns, not part of the core VCSC
FA2 language/runtime contract.

Build with `make`; `make play` launches Stella with `-bs FA2`.
