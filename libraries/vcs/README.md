```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Atari 2600 / VCS support files

This directory contains target support files for the Atari 2600 / VCS.

Files:

- `vcs.c26` ... VCS machine definition with types, memory regions, and hardware includes
- `tia.c26` ... TIA hardware register bindings
- `riot.c26` ... RIOT I/O and timer register bindings plus RIOT RAM region names
- `vcs_4k.cfg` ... linker configuration for a conventional unbanked 4K cartridge
- `frame_ntsc.c26` ... shared NTSC phase constants, scanline waiting, and VSYNC scheduling primitives
- `sound_ntsc.c26` ... NTSC TIA audio-control, note-frequency, volume, and frame-timing aliases
- `six_glyph_display.c26` ... shared centered 48-pixel/six-glyph positioning and timed row kernel
- `kernels/standard_4k_ntsc/` ... all-five-object solid-color standard-kernel profile
- `kernels/standard_4k_ntsc_playercolors/` ... separate P0+P1+BL profile with per-logical-row player color tables
- `fonts/` ... eight shared 8x8 score-font families, each in decimal and hexadecimal VCSC variants
- `../../examples/01_solid_color/solid_color.c26` ... first complete 4K cartridge example
- `../../examples/02_ode_to_joy/ode_to_joy.c26` ... frame-driven music example using a ROM score table
- `../../examples/03_six_digit_score/six_digit_score.c26` ... centered legacy-kernel-derived six-digit `bcd24_t` score display using the shared VCS font catalog
- `../../examples/04_fingerprint/fingerprint.c26` ... CRC-24 display of four unstable 6507 `ARR` probes using the shared hexadecimal font
- `../../examples/05_static_kernel_test/static_kernel_test.c26` ... deterministic 4K bring-up cartridge for the all-five standard kernel
- `../../examples/06_object_motion_test/object_motion_test.c26` ... full-range all-five-object motion diagnostic
- `../../examples/07_playercolor_static_test/playercolor_static_test.c26` ... static P0+P1+BL per-row-color diagnostic
- `../../examples/08_playercolor_motion_test/playercolor_motion_test.c26` ... moving P0+P1+BL per-row-color diagnostic
- `legacy-basic-kernels/` ... vendored upstream legacy BASIC kernel source tree (standard, multisprite) with provenance and license notes
- `LEGACY_KERNEL_CONVERSION.md` ... retained-kernel inventory, compatibility analysis, and staged conversion plan

Typical use:

```vcsc
include "vcs.c26"
include "frame_ntsc.c26"

int16_t main(void) {
   vcs_ntsc_vsync();
   VBLANK := 0x02;
   COLUBK := 0x00;
   return 0;
}
```

## Target type definitions

`vcs.c26` supplies the stock VCS names for signed and unsigned 8-, 16-, 24-,
and 32-bit binary integers, plus `bcd8_t`, `bcd16_t`, `bcd24_t`, and
`bcd32_t` packed-decimal types. The BCD widths hold two, four, six, and eight
decimal digits and are especially useful for scores and counters.

The complete language rules for integer flags, literal conversion, arithmetic,
casts, packed BCD, parameters, and memory-backed returns belong to the compiler
and are documented in [`../../compiler/README.md`](../../compiler/README.md).
This directory documents only the names and target bindings supplied by the VCS
machine definition.

Compile with an include path that can see this directory, for example:

```sh
vcsc-cc1 -I libraries/vcs source.c26
```

Build a raw 4K cartridge directly with the driver:

```sh
vcsc -I libraries/vcs source.c26 -o game.bin
```

A `.bin` output name asks the linker for a contiguous flat binary; this VCS
layout produces exactly 4096 bytes mapped at `$F000-$FFFF`.

Notes:

- `vcs.c26` is the easiest entry point for a VCS target. It defines the machine types and memory regions, then includes `tia.c26` and `riot.c26`.
- Compiled BCD arithmetic scopes decimal mode to the actual `ADC`/`SBC` chain and executes `CLD` afterward. Inline assembly that executes `SED` remains responsible for clearing decimal mode itself.
- `tia.c26` and `riot.c26` can also be included separately if you already have your own base machine definition.
- `vcs_4k.cfg` assumes a standard 4K cartridge mapped at `$F000-$FFFF` with vectors at `$FFFA-$FFFF`.
- `vcsc` discovers this file in the source tree or installed `share/vcs` directory and uses it by default. Pass `-T` only to select a different cartridge layout.
- The 128 physical RIOT RAM bytes are not double-counted. `vcs_4k.cfg` declares the full `$80-$FF` block and asks `vcsc-ld` to reserve the top bytes dynamically from the whole-program source call graph before placing ordinary storage. The page-1 addresses `$0180-$01FF` are mirrors of `$80-$FF`, not separate RAM.
- Current stack sizing accounts automatically for source-level JSR return addresses; ordinary generated calls push no compiler state. A linker configuration may add `callstack_extra` bytes for hardware-stack use declared by an included assembly module. Both maintained standard-kernel objects export their assembly-initiated overscan-hook edge and use four supplementary bytes for the deeper internal mask-preparation chain. Arbitrary inline-assembly pushes and stack-pointer manipulation are still not inferred.
- Example 04 uses one balanced `PHP`/`PLA` pair per probe to read P and verifies that the linked map leaves the byte immediately below the call-stack reserve unused.
- `legacy-basic-kernels/` remains untouched reference/source material imported from upstream legacy BASIC. The all-five solid-color profile and the separate no-missile per-row-player-color profile are reproducibly normalized beside their contracts and exercised by complete cartridges. See `LEGACY_KERNEL_CONVERSION.md` for the staged conversion inventory.
- The VCS hardware mirrors TIA and RIOT addresses heavily. The bindings use the conventional canonical addresses.
