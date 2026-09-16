```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# 3E diagnostic

This 8K cartridge certifies classic Tigervision 3E bankswitching. As with 3F,
the lower `$1000-$17FF` 2K window is selectable and the final physical 2K ROM
bank remains fixed at `$1800-$1FFF`. Writing a ROM bank number to `$3F` selects
lower-window ROM. Writing a RAM bank number to `$3E` instead maps one of 32 1K
RAM banks: `$1000-$13FF` is its read port and `$1400-$17FF` is its write port.

The self-test executes multiple ROM banks and uses ordinary compiler-generated
`swapram` lvalue accesses to check two independent 1K RAM banks and persistence.
The application source never writes `$3E` or `$3F`; the compiler, mapper helper,
and bankcall machinery perform RAM selection and ROM restoration automatically.
The cartridge then displays a large `pass` or `FAIL` with small `3E` underneath
from the fixed final bank.

Ordinary TIA accesses use the `$40-$7F` mirror. Literal `$3E` and `$3F` are
reserved for 3E mapper control, so frame timing does not depend on an emulator
forwarding writes from the cartridge-owned low TIA page.

Stella should be forced to 3E:

```sh
make play
```
