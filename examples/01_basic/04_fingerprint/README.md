```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# 6507 silicon fingerprint

`01_basic/04_fingerprint` runs four deliberately unstable unofficial `ARR`-immediate
probes, feeds each probe's accumulator result and masked `NVZC` flags through
CRC-24/OPENPGP, and displays the resulting 24-bit value as six hexadecimal
digits.

The fingerprint is computed once at startup. The processor-sensitive probes are
small inline-assembly blocks using the readable unofficial `ARR` mnemonic. The
Makefile passes `-Wa,--illegals` deliberately, and each `ARR` source line
documents the exact two emitted bytes. Everything else is VCSC: CRC-24, 24-bit state, frame composition, colors, and
display control. The application instantiates `six_glyph_component.c26` with the
shared hexadecimal font and runs it inside `frame_ntsc.c26`; the score example uses the
same component, so their RESP/GRP timing cannot diverge. The fingerprint bytes
are copied verbatim into the component's three-byte score storage so all six
hexadecimal nibbles, including A through F, retain their raw values.

## Visible placement

The display follows a 91-line blank gap, so the example uses
`vcs_ntsc_wait_component_scanlines(91)` rather than the generic WSYNC loop. The
component-aware helper completes the final blank line at the calibrated phase
required by `display_draw()`. The generic helper leaves loop bookkeeping in the
visible line, moving both player reset strobes and wrapping the rightmost
hexadecimal digit around to the opposite side of the screen. The reviewed
Stella 7.0 capture is kept as
`test/fixtures/vcs_examples/04_fingerprint/reference_stella_7.0.png`.

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
