```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# JANE diagnostic

This cartridge certifies the 16K JANE mapper used by the released Tarzan
prototype dump. Physical banks 0, 1, 2, and 3 are selected by accesses to
`$1FF0`, `$1FF1`, `$1FF8`, and `$1FF9`; hardware startup is physical bank 1.
VCSC logical bank numbers now match those physical/file bank numbers exactly,
so logical `bank1` is the startup/home bank and unqualified `main` is linked there.

The self-test executes the complete 4x4 ordered source-bank to destination-bank
call matrix: every logical/physical bank calls every bank, including itself. Same-bank
calls use ordinary `JSR`/`RTS`; all 12 cross-bank pairs use JANE's fixed inline-target
bankcall block. Every pair checks the target signature, 16-bit return value, restored
source bank, and exact hardware-stack balance. The bank0-to-bank0 case additionally
nests a bank0-to-bank1 call to prove stacked logical return PCs compose correctly.

A large green `pass` with the smaller `JANE` underneath therefore means all 16
ordered pairs, all four selectors, startup recovery, and the nested return path
succeeded. Red `FAIL` means one of those checks failed.

The Makefile enables `VCSC_INLINE_BANKCALL`, so all cross-bank C calls use the fixed
95-byte JANE block (96 bytes reserved) and allocate no per-target JSR entries.

The image also contains the non-executed byte sequence `AD F1 FF 60`
(`LDA $FFF1; RTS`) used by current Stella for JANE autodetection, in addition
to VCSC's normal `JANE` tail signature.

## Running in Stella

JANE mapper support was added in Stella 7.0. Use Stella 7.0 or newer. The
example Makefile deliberately forces the mapper instead of relying on ROM
autodetection or a cached per-ROM property:

```sh
make play
# equivalent to: stella -bs JANE jane_diagnostic.bin
```

If the same image is run as an ordinary F6 cartridge it produces a black
screen, because JANE's `$1FF0/$1FF1/$1FF8/$1FF9` selector mapping and startup
bank are different. `stella -rominfo jane_diagnostic.bin` should report
`Bankswitch Type: JANE` on a JANE-capable Stella build.
