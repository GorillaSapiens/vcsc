```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# FC bankswitching diagnostic

Builds an eight-bank Amiga Power Play FC cartridge. The self-test executes
every ordered source/destination pair among all eight banks, checks all return
values (including a 16-bit A:X return) and the total 64 target calls, then
displays PASS or FAIL. Cross-bank calls use VCSC's three-byte inline descriptor
ABI; same-bank calls remain ordinary JSRs.
