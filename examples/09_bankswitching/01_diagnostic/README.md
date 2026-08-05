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
  -DVCS_NO_DEFAULT_ROM -DMAPPER_BANKS=8 \
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
hardware-stack state in RIOT RAM. The Superchip builds own the complete 128-byte RAM as mixed BSS and DATA.
They verify reset-time clearing/copying through the write window, both alias
directions, and persistence through the whole matrix. After displaying a result
they poison the entire contract boundary; simulator and Stella certification
reset the CPU without externally clearing RAM and require a second PASS, proving
that startup reinitializes allocated objects on every reset.

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

The first six are the complete mapper diagnostics. `poisoned.bin` is an F8SC
build with `POISONED_RESULT` defined; it still runs the matrix and Superchip
lifecycle but deliberately settles on the FAIL frame so the expected white F on
dark red can be inspected. Folding this check into the existing reference keeps
the public diagnostic set at seven cartridges.
`make ordinary`, `make superchip`, and `make poisoned` build the three subsets.
The normal regression runs the six mapper diagnostics through the cfg-driven
simulator from every physical startup bank. SC runs use hostile initial RAM and
a one-shot reset before the final stop. Stella runs all six with forced and
randomized startup banks, presses console Reset before snapshotting SC results,
and separately grades the reset-tested poisoned FAIL image.
