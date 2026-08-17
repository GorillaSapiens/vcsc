```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# 0FA0 / Fotomania diagnostic

This 8K cartridge certifies the Brazilian Fotomania 0FA0 mapper. It has two 4K
physical ROM banks and powers up in physical/file bank 1. Bank selection is
mask-decoded rather than tied to two exact addresses:

```text
(A & $16E0) == $06A0  -> physical bank 0
(A & $16E0) == $06C0  -> physical bank 1
```

VCSC uses `$0FA0` and `$0FC0` as the canonical selector aliases. A11, A8 and
A4-A0 are don't-care alias bits, so addresses such as `$07A7` and `$0ECF`
select the same banks. Because these selectors live below the cartridge
`$1000-$1FFF` ROM window and overlay console devices, generated bank transitions
use the state-preserving NMOS absolute NOP read rather than a store. Explicit
program reads or writes to selector aliases still perform the underlying console
access while also changing the selected ROM bank.

The self-test starts from the hardware startup bank, calls into physical bank 0,
calls back into physical bank 1, and returns through both generated restoration
paths. The focused simulator regression also begins from the wrong physical bank
to prove the replicated reset bridge recovers to bank 1, and separately exercises
read/write alias switching.

A large green `pass` with `0FA0` underneath means the mapper behaved as expected;
red `FAIL` indicates a mismatch. VCSC writes the `0FA0` mapper signature at
`$FFF8-$FFFB` in the final physical/file bank. The diagnostic also carries a
non-taken `BIT $0FC0` path matching Stella's established 0FA0 detector, while the
Makefile forces the exact mapper for deterministic playback:

```sh
make play
```
