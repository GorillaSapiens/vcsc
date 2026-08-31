```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# 0840 / EconoBanking diagnostic

This 8K cartridge certifies the Atari 0840 "EconoBanking" mapper.  It has two
4K physical ROM banks.  Accesses in the decoded `$0800` family select physical
bank 0 and accesses in the `$0840` family select physical bank 1.  Those
selectors live below the cartridge `$1000-$1FFF` ROM window and overlap mirrored
console address space, so VCSC's generated selector stubs use the NMOS absolute
NOP read rather than a store.

The self-test executes the complete ordered call matrix: bank 0 calls targets
in banks 0 and 1, then bank 1 calls targets in banks 0 and 1.  Every call checks
the returned value and hardware-stack balance.  The 0-to-0 case also makes a
nested cross-bank call so return-bank restoration is exercised compositionally.
All cross-bank calls currently use the fixed pre-migration inline-target
implementation; there are no legacy per-target JSR bridges. The target ABI is
[`../../../BANKSWITCHING.md`](../../../BANKSWITCHING.md).  A large green `pass` with `0840` underneath means all
four ordered calls and the nested return succeeded; red `FAIL` means the test
detected a mismatch.

VCSC also writes its `0840` mapper signature at `$FFF8-$FFFB` in the final
physical file bank.  The repeated linker-generated `NOP $0800; JMP ...` reset
bridge is compatible with Stella's established 0840 autodetection heuristic.

## Running in Stella

The example Makefile forces the mapper so cached or ambiguous ROM properties do
not turn this ordinary 8K image into F8:

```sh
make play
# equivalent to: stella -bs 0840 econobanking_diagnostic.bin
```
