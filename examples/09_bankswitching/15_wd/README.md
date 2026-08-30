```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# WD / Wickstead Design diagnostic

`wd_diagnostic.c26` is the public VCSC output diagnostic for the corrected
8192-byte Wickstead Design layout used by *Pursuit of the Pink Panther*.

It checks power-on arrangement 0, arrangement 1 (`0,1,2,3`), arrangement 3
(`7,4,2,3`), read-only selector behavior at TIA `$30-$3F`, and both ends of
the 64-byte split-address cartridge RAM window. The visible cartridge leaves a
green `PASS` / `WD` display on success and dark red `FAIL` on error.

The test deliberately uses the released-cart `LDA $39` / `JMP` selector shape:
WD does not change arrangements on the selector read immediately; the selected
arrangement becomes visible only after the hardware delay.

Build with `make`. `make play` forces Stella's `WD` mapper. The C26 profile
emits the corrected 8192-byte chunk order; the historical 8195-byte WDSW dump
remains a disassembler/input compatibility case and is not an output format.
