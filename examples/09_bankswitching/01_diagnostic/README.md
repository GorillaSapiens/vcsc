```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# F8/F6/F4 transition diagnostic suite

`bankswitching_diagnostic.c26` is the editable wrapper around the installed
`bankswitching_diagnostic_suite.c26` parameterized cartridge source.  Each build chooses a mapper bank count, a logical source bank,
and one direct-JMP destination:

```sh
../../../driver/vcsc -I ../../../libraries/vcs \
  -DMAPPER_BANKS=8 -DSOURCE_BANK=3 -DJUMP_DEST=6 \
  -T ../../../libraries/vcs/vcs_32k_f4.cfg \
  -Map f4_source3_to6.map bankswitching_diagnostic.c26 \
  -o f4_source3_to6.bin
```

Before the final direct jump, the selected source bank calls and returns from a
target in every bank.  The BANK0 target makes an additional BANK1 call, so each
build also exercises a nested cross-bank return path.  Every transition writes
a unique signature to RIOT RAM,
checks the hardware stack pointer before and after the call, and displays one
status frame.  The final direct JMP is deliberately one-way: the destination
writes its signature and jumps to the BANK0 finish path without pretending that
a cross-bank JMP has call/return semantics.

A green background with a widened **P** sprite is PASS.  A dark red background
with an **X** sprite is FAIL.  The transition frames use different background
colors, and the final frame is stable for Stella snapshots.

`make` builds every source bank with JMP destination BANK0.  `make full` builds
all ordered source/destination pairs: 4 F8, 16 F6, and 64 F4 cartridges.  The
project's simulator regression executes the same full matrix, while the
separate `make stella-bank-test` certification target runs it in the independent
emulator with every forced physical startup bank and developer-mode randomized
startup banks.  Set `STELLA=/path/to/stella` when Stella is not in `PATH`; the
headless harness also requires Xvfb and `xkbcomp`; the helper programs are Perl and require no Python installation or Python modules.
