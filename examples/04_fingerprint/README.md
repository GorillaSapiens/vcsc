```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# 6507 silicon fingerprint

`04_fingerprint` runs four deliberately unstable unofficial `ARR`-immediate
probes, feeds each probe's accumulator result and masked `NVZC` flags through
CRC-24/OPENPGP, and displays the resulting 24-bit value as six hexadecimal
digits.

The fingerprint is computed once at startup. The processor-sensitive probes are
small inline-assembly blocks using the readable unofficial `ARR` mnemonic. The
Makefile passes `-Wa,--illegals` deliberately, and each `ARR` source line
documents the exact two emitted bytes. Everything else is VCSC: CRC-24, 24-bit
state, frame structure, glyph-pointer preparation, colors, and display control.
The display includes the same shared `six_glyph_display.c26` positioning and
row kernel as example 03, so their RESP/GRP timing cannot diverge.

The display uses the shared hexadecimal font module:

```vcsc
include "fonts/default_hex.c26"
```

A real NMOS 6507 may produce a fingerprint specific to its silicon behavior.
Emulators necessarily implement a model of unstable unofficial-opcode behavior,
so their displayed value identifies that model rather than physical silicon.
During this example's acceptance test, Stella 7.0 displayed `8A55CE`, while the
bundled CPU simulator model produced `BDBAF3`.

Build after building the toolchain:

```sh
make
```

The result is `fingerprint.bin`, an exact 4096-byte unbanked cartridge.
