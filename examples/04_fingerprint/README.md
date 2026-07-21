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
small inline-assembly blocks using exact `op6b` opcode tokens. Everything else
is VCSC: CRC-24, 24-bit state, frame structure, glyph-pointer preparation,
colors, and display control. The visible six-glyph row pipeline remains timed
inline assembly for the same reason as example 03.

The display uses the shared hexadecimal font module:

```vcsc
include "fonts/hexadecimal_hex.vcsc"
```

A real NMOS 6507 may produce a fingerprint specific to its silicon behavior.
Emulators necessarily implement a model of unstable unofficial-opcode behavior,
so their displayed value identifies that model rather than physical silicon.
During this example's acceptance test, Stella 7.0 displayed `0A55CE`, while the
bundled CPU simulator model produced `BDBAF3`.

Build after building the toolchain:

```sh
make
```

The result is `fingerprint.bin`, an exact 4096-byte unbanked cartridge.
