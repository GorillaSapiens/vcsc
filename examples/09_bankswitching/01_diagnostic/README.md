```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# F8/F6/F4 complete transition diagnostics

`bankswitching_diagnostic.c26` is the editable wrapper around the installed
`bankswitching_diagnostic_suite.c26` source. One build selects a mapper only:

```sh
../../../driver/vcsc -I ../../../libraries/vcs \
  -DMAPPER_BANKS=8 -T ../../../libraries/vcs/vcs.cfg \
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

The stable result display has two centered white lines. On green success the
first line is lowercase **pass** in the 8x16 Big font; on dark-red failure it is
uppercase **FAIL**. Those glyphs are copied exactly from
`libraries/vcs/fonts/big_ascii.c26` and rendered by
`six_glyph_big_wide_component.c26` as `blank/p/a/s/s/blank` or
`blank/F/A/I/L/blank`.

Directly below it, `six_glyph_component.c26` uses exact glyphs from
`libraries/vcs/fonts/default_ascii.c26` to identify the cartridge. Ordinary
images show centered `F8`, `F6`, or `F4`; Superchip images show `F8SC`, `F6SC`,
or `F4SC`. The deliberately poisoned image shows `??????` instead of claiming a
mapper identity. The combined visible block is 19 + 11 = 30 scanlines, with 81
blank visible lines above and below, so every result frame remains exactly 262
NTSC scanlines.

`make` emits exactly seven cartridges:

```text
f8.bin    f6.bin    f4.bin       poisoned.bin
f8sc.bin  f6sc.bin  f4sc.bin
```

The first six are the complete mapper diagnostics. `poisoned.bin` is an F8SC
build with `POISONED_RESULT` defined; it still runs the matrix and Superchip
lifecycle but deliberately settles on the FAIL frame so the expected white FAIL word on
dark red can be inspected. Folding this check into the existing reference keeps
the public diagnostic set at seven cartridges.
`make ordinary`, `make superchip`, and `make poisoned` build the three subsets.
The normal regression builds all six public images from C26 topology, then runs
them through the compatibility-cfg-driven simulator from every physical startup bank. SC runs use hostile initial RAM and
a one-shot reset before the final stop. Stella runs all six with forced and
randomized startup banks, presses console Reset before snapshotting SC results,
and separately grades the reset-tested poisoned FAIL image.
