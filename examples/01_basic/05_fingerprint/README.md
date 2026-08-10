```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# 6507 silicon fingerprint

`01_basic/05_fingerprint` runs four deliberately unstable unofficial
`ARR`-immediate probes, feeds each probe's accumulator result and masked `NVZC`
flags through CRC-24/OPENPGP, and displays the resulting 24-bit value as six
hexadecimal digits in the middle of the screen. The hexadecimal display uses
`six_glyph_big_wide_component.c26` with the 8x16 `fonts/big_hex.c26` font.

Two more eleven-line six-glyph components display the fixed `012345` VCSC logo:

- `six_glyph_right_component.c26` places it at the upper-right edge;
- `six_glyph_left_component.c26` places it at the lower-left edge.

The logo components first build the ordinary packed-BCD `012345` pointers, then
redirect those six pointers to the consecutive slices in `fonts/logo_font.c26`.
The three component instances own separate state and may therefore coexist in
one cartridge.

The fingerprint is computed once at startup. The processor-sensitive probes are
small inline-assembly blocks using the readable unofficial `ARR` mnemonic. The
Makefile passes `-Wa,--illegals` deliberately, and each `ARR` source line records
the exact two emitted bytes. Everything else is VCSC: CRC-24, 24-bit state,
frame composition, colors, and display control. The fingerprint bytes are copied
verbatim into the centered component's packed score storage, so hexadecimal
nibbles A through F retain their raw values.

## Visible placement

The 192-line visible field is composed exactly as follows:

```text
raw  40.. 50   right-justified upper logo       11 lines
raw  51..126   calibrated blank gap             76 lines
raw 127..145   big-wide hexadecimal fingerprint  19 lines
raw 146..220   calibrated blank gap             75 lines
raw 221..231   left-justified lower logo         11 lines
```

The upper logo's 48-pixel group occupies X=112..159. The lower logo occupies
X=0..47. The big-wide fingerprint occupies X=36..123 with 16-pixel glyph pitch.
All three components preserve the exact 262-line NTSC frame.

The reviewed Stella 7.0 capture is kept as
`test/fixtures/vcs_examples/04_fingerprint/reference_stella_7.0.png`.

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
