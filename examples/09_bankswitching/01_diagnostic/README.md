```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# F8/F6/F4 complete transition diagnostics

`bankswitching_diagnostic.c26` is the editable wrapper around the installed
`bankswitching_diagnostic_suite.c26` source. One build selects a mapper only:

```sh
../../../driver/vcsc -I ../../../libraries/vcs \
  -DMAPPER_BANKS=8 \
  -T ../../../libraries/vcs/vcs_32k_f4.cfg \
  -Map f4.map bankswitching_diagnostic.c26 -o f4.bin
```

Each cartridge internally runs the complete ordered source-bank to
destination-bank direct-JMP matrix: 4 transitions for F8, 16 for F6, and 64 for
F4. Every source bank also performs a same-bank JSR/RTS check. BANK0 adds a
nested BANK0-to-BANK1 call and return, so cross-bank call restoration and
hardware-stack balance remain covered without consuming the common trampoline
corridor with a separate JSR bridge for every ordered pair.

Every transition records and validates its source, destination, signature, and
hardware-stack state in RIOT RAM. The Superchip builds additionally check both
ends of the 128-byte RAM, read/write alias direction, and persistence through
the whole matrix.

A green background with a widened white **P** sprite is PASS. A dark-red
background with a widened white **F** sprite is FAIL. Both glyphs are copied
from `libraries/vcs/fonts/default_ascii.c26`, with row storage reversed to match
the down-counting display loop. The source uses ordinary `lda glyph,x` syntax;
the assembler must preserve absolute-X because the glyph is relocatable ROM.
`GRP0` changes only immediately after `WSYNC`, so no row is torn midway across
a scanline. TIA setup is budgeted inside VBLANK and every result frame is
exactly 262 scanlines.

`make` emits exactly seven cartridges:

```text
f8.bin    f6.bin    f4.bin       poisoned.bin
f8sc.bin  f6sc.bin  f4sc.bin
```

The first six are the complete mapper diagnostics. `poisoned.bin` is an F8
build with `POISONED_RESULT` defined; it still runs the matrix but deliberately
settles on the FAIL frame so the expected white F on dark red can be inspected.
`make ordinary`, `make superchip`, and `make poisoned` build the three subsets.
The normal regression runs the six mapper diagnostics through the cfg-driven
simulator from every physical startup bank. The Stella certification runs those
six with forced and randomized startup banks and separately grades the poisoned
FAIL image.
