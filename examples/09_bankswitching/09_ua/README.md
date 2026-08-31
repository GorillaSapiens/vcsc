```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# UA / UASW diagnostics

This directory contains two 8K UA Limited bankswitching diagnostics. Both use two
4K physical ROM banks and power up in physical/file bank 0. The selector decoder
qualifies only A12, A9, A6 and A5, so the canonical `$0220`/`$0240` selectors
have many aliases, including the Brazilian `$02A0`/`$02C0` forms.

`ua_diagnostic.bin` implements the ordinary UA association:

```text
(A & $1260) == $0220  -> physical bank 0
(A & $1260) == $0240  -> physical bank 1
```

`uasw_diagnostic.bin` implements UASW, the same hardware decoder with the bank
association reversed:

```text
(A & $1260) == $0220  -> physical bank 1
(A & $1260) == $0240  -> physical bank 0
```

Because these selectors overlap console devices below `$1000`, VCSC-generated
bank transitions use the state-preserving NMOS absolute NOP read rather than a
store. Reads and writes made by user code to selector aliases still reach the
underlying console device while also changing the selected ROM bank.

Both self-tests execute the complete ordered call matrix: `0->0`, `0->1`,
`1->0`, and `1->1`. The same-bank legs are ordinary JSRs; the cross-bank legs
use the fixed inline-target bankcall and verify return values, restored bank,
and hardware-stack balance. One nested cross-bank call additionally checks that
independent return frames compose correctly. A large green `pass` with `UA` or
`UASW` underneath means the selected hardware profile behaved as expected; red
`FAIL` indicates a mismatch.

VCSC writes `UA\0\0` or `UASW` at `$FFF8-$FFFB` in the final physical file
bank. Current Stella can infer historical UA images from characteristic access
opcodes, but those opcodes do not distinguish UASW reliably. The Makefile
therefore forces the exact mapper for both variants:

```sh
make play-ua
make play-uasw
```
