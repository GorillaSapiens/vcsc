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
digits. A second six-glyph component at the bottom displays the VCSC logo from
`fonts/logo_font.c26` by treating its six slices as the fixed score `012345`.

The fingerprint is computed once at startup. The processor-sensitive probes are
small inline-assembly blocks using the readable unofficial `ARR` mnemonic. The
Makefile passes `-Wa,--illegals` deliberately, and each `ARR` source line
documents the exact two emitted bytes. Everything else is VCSC: CRC-24, 24-bit state, frame composition, colors, and
display control. The application instantiates `six_glyph_component.c26` twice
inside `frame_ntsc.c26`; the score example uses that same component, so their
RESP/GRP timing cannot diverge. The fingerprint instance uses the shared
hexadecimal font. Its three fingerprint bytes are copied verbatim into the
component's score storage so all six hexadecimal nibbles, including A through F,
retain their raw values. The logo instance stores packed BCD `012345`, then
redirects the six generated glyph pointers to the six page-contained slices in
`logo_font`.

## Visible placement

The fingerprint follows a 91-line blank gap, so the example uses
`vcs_ntsc_wait_component_scanlines(91)` rather than the generic WSYNC loop. The
component-aware helper completes the final blank line at the calibrated phase
required by `display_draw()`. After the fingerprint's eleven scanlines, a
79-line calibrated blank gap leads to `logo_draw()` on raw scanline 221. Its
own eleven-line contract therefore occupies the final eleven lines of the
192-line visible field.

The reviewed Stella 7.0 capture, including the bottom logo, is kept as
`test/fixtures/vcs_examples/04_fingerprint/reference_stella_7.0.png`.

The two displays use separate shared font modules:

```vcsc
include "fonts/default_hex.c26"
include "fonts/logo_font.c26"
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
