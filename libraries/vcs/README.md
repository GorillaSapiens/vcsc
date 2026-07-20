```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Atari 2600 / VCS support files

This directory contains starter target files for the Atari 2600 / VCS.

Files:

- `vcs.vcsc` ... VCS machine definition with types, memory regions, and hardware includes
- `tia.vcsc` ... TIA hardware register bindings
- `riot.vcsc` ... RIOT I/O and timer register bindings plus RIOT RAM region names
- `vcs_4k.cfg` ... linker configuration for a conventional unbanked 4K cartridge
- `sound_ntsc.vcsc` ... NTSC TIA audio-control, note-frequency, volume, and frame-timing aliases
- `../../examples/01_solid_color/solid_color.vcsc` ... first complete 4K cartridge example
- `../../examples/02_ode_to_joy/ode_to_joy.vcsc` ... frame-driven music example using a ROM score table
- `../../examples/03_six_digit_score/six_digit_score.vcsc` ... centered batari-derived six-digit `bcd24_t` score display with replaceable VCSC font data
- `batari-basic/` ... vendored upstream batari Basic kernel source tree (standard, multisprite) with provenance and license notes
- `BATARI_BASIC_CONVERSION.md` ... task-19 inventory, compatibility analysis, and staged conversion plan

Typical use:

```vcsc
include "vcs.vcsc"

int16_t main(void) {
   VBLANK := 0x02;
   COLUBK := 0x00;
   return 0;
}
```

## 24- and 32-bit binary integers

`vcs.vcsc` defines `int24_t`, `uint24_t`, `int32_t`, and `uint32_t` in addition
to the 8- and 16-bit ordinary types. The three-byte types range from
-8388608..8388607 and 0..16777215; the four-byte types range from
-2147483648..2147483647 and 0..4294967295. They support the same ordinary
integer operations, parameters, and callee-owned memory returns as the smaller
widths. Values of the same signedness widen automatically; mixed
signed/unsigned runtime operations still require an explicit cast rather than
C's usual conversions.

Literal encoding is width-based, matching the established smaller ordinary
integer types. High-bit patterns and negative two's-complement literals are
legal when they fit the destination width; a literal exceeding 32 bits is
rejected.

```vcsc
uint24_t frames := 1000000;
int24_t delta := -1;
uint32_t lifetime_frames := 0x12345678;
int32_t accumulator := -2000000000;
frames += 60;
```

## Packed-decimal score and counter types

`vcs.vcsc` defines four unsigned packed-BCD types backed directly by the 6507's
decimal-mode `ADC` and `SBC` instructions:

```vcsc
bcd8_t  lives := 3;          // 00..99, byte $03
bcd16_t timer := 1234;       // 0000..9999, bytes $34,$12
bcd24_t score := 567890;     // 000000..999999, bytes $90,$78,$56
bcd32_t total := 12345678;    // 00000000..99999999, bytes $78,$56,$34,$12

score += 125;                // compiler emits SED, ADC chain, then CLD
```

Literal values are converted numerically to packed decimal. In particular,
`bcd8_t x := 0x2a;` stores `$42`, because hexadecimal `0x2a` has numeric value
42. This makes source-base choice independent of storage representation and
prevents the common binary-byte/BCD-digit mix-up.

BCD values support copy/assignment, addition, subtraction,
increment/decrement, comparisons, truth tests, and switch cases. Arithmetic
wraps at the decimal width. Runtime mixing with ordinary binary integers is
rejected, as are multiply/divide/remainder, bitwise operations, shifts, unary
minus, and BCD bitfields. `bcd24_t` is especially useful for six-digit scores, while `bcd32_t` provides eight decimal digits. Both may be stored, passed, and returned through the callee-owned memory-return ABI.

Compile with an include path that can see this directory, for example:

```sh
vcsc-cc1 -I libraries/vcs source.vcsc
```

Build a raw 4K cartridge directly with the driver:

```sh
vcsc -I libraries/vcs source.vcsc -o game.bin
```

A `.bin` output name asks the linker for a contiguous flat binary; this VCS
layout produces exactly 4096 bytes mapped at `$F000-$FFFF`.

Notes:

- `vcs.vcsc` is the easiest entry point for a VCS target. It defines the machine types and memory regions, then includes `tia.vcsc` and `riot.vcsc`.
- Compiled BCD arithmetic scopes decimal mode to the actual `ADC`/`SBC` chain and executes `CLD` afterward. Inline assembly that executes `SED` remains responsible for clearing decimal mode itself.
- `tia.vcsc` and `riot.vcsc` can also be included separately if you already have your own base machine definition.
- `vcs_4k.cfg` assumes a standard 4K cartridge mapped at `$F000-$FFFF` with vectors at `$FFFA-$FFFF`.
- `vcsc` discovers this file in the source tree or installed `share/vcs` directory and uses it by default. Pass `-T` only to select a different cartridge layout.
- The 128 physical RIOT RAM bytes are not double-counted. `vcs_4k.cfg` declares the full `$80-$FF` block and asks `vcsc-ld` to reserve the top bytes dynamically from the whole-program source call graph before placing ordinary storage. The page-1 addresses `$0180-$01FF` are mirrors of `$80-$FF`, not separate RAM.
- Current stack sizing accounts for JSR return addresses only; ordinary generated calls push no compiler state. Inline `PHA`/`PHP`/`JSR` and stack use hidden in separately assembled routines remain future accounting work.
- `batari-basic/` is reference/source material imported from upstream batari Basic and is not automatically wired into the `vcsc-cc1`/`vcsc-ld` flow. See `BATARI_BASIC_CONVERSION.md` for the fixed-RAM, stack, assembler, linker, and staged-port inventory.
- The VCS hardware mirrors TIA and RIOT addresses heavily. The bindings use the conventional canonical addresses.
