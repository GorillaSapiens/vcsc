```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# WD / Wickstead Design diagnostic

`wd_diagnostic.c26` is the public VCSC diagnostic for the corrected 8192-byte
Wickstead Design layout used by *Pursuit of the Pink Panther*.

WD hardware has eight 1K physical chunks and eight four-segment arrangements,
but normal 6502 code is not position independent. The VCSC compiler ABI therefore
uses only the two complementary relocation-safe arrangements:

```text
bank0 = hardware state 1 = chunks 0,1,2,3
bank1 = hardware state 2 = chunks 4,5,6,7
```

The diagnostic exercises automatic descriptor-ABI C calls from bank0 to bank1
and back, including a nested return chain. It also verifies the delayed selector
latch, both ends of the always-live 64-byte split-address RAM window, and raw
simulator handling of a non-ABI WD arrangement. Power-on state 0 reaches the
replicated vector bridge, which selects state 1 before ordinary startup.

The visible cartridge uses the standard big **wide** six-glyph layout and big
font for `PASS` / `FAIL`, with a separate small six-glyph `WD` label. Ordinary
TIA I/O uses the `$40-$7F` mirror so collision/input reads cannot accidentally
select a WD arrangement.

Build with `make`. `make play` forces Stella's `WD` mapper. The historical
8195-byte WDSW preservation dump remains a disassembler/input compatibility case
and is not an output format.
