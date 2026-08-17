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
VCSC keeps that startup image as logical `bank0` while preserving physical file
order in the emitted 16K ROM.

The self-test follows a nested physical-bank path `1 -> 0 -> 2 -> 3 -> 1` and
then returns through the generated bank-restoration trampolines. A large green `pass`
with the smaller `JANE` underneath means all four selectors, startup recovery, and the
nested cross-bank return path succeeded. Red `FAIL` means one of those checks
failed.

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
