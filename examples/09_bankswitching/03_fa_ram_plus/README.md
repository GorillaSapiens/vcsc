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
uppercase `FAIL` on a dark-red background otherwise.

The diagnostic fills the complete 256-byte FA cartridge-RAM allocation, verifies
BSS/DATA reset initialization, writes sentinels at both ends and the middle of
RAM, and then executes a nested cross-bank call chain covering all three physical
ROM banks. The generated selectors therefore exercise `$1FF8`, `$1FF9`, and
`$1FFA`, including return to the hardware power-on/startup bank 2. RAM sentinels
must survive every bank transition.

Build with `make`; `make play` launches Stella with `-bs FA`.
