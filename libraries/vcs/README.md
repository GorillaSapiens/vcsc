# Atari 2600 / VCS support files

This directory contains starter target files for the Atari 2600 / VCS.

Files:

- `vcs.n` ... VCS machine definition with types, memory regions, and hardware includes
- `tia.n` ... TIA hardware register bindings
- `riot.n` ... RIOT I/O and timer register bindings plus RIOT RAM region names
- `vcs_4k.cfg` ... linker configuration for a conventional unbanked 4K cartridge
- `sound_ntsc.n` ... NTSC TIA audio-control, note-frequency, volume, and frame-timing aliases
- `../../examples/01_solid_color/solid_color.n` ... first complete 4K cartridge example
- `../../examples/02_ode_to_joy/ode_to_joy.n` ... frame-driven music example using a ROM score table
- `batari-basic/` ... vendored upstream batari Basic kernel source tree (standard, multisprite) with provenance and license notes

Typical use:

```n
include "vcs.n"

int16_t main(void) {
   VBLANK := 0x02;
   COLUBK := 0x00;
   return 0;
}
```

Compile with an include path that can see this directory, for example:

```sh
n65c -I libraries/vcs source.n
```

Build a raw 4K cartridge directly with the driver:

```sh
n65cc -I libraries/vcs source.n -o game.bin
```

A `.bin` output name asks the linker for a contiguous flat binary; this VCS
layout produces exactly 4096 bytes mapped at `$F000-$FFFF`.

Notes:

- `vcs.n` is the easiest entry point for a VCS target. It defines the machine types and memory regions, then includes `tia.n` and `riot.n`.
- `tia.n` and `riot.n` can also be included separately if you already have your own base machine definition.
- `vcs_4k.cfg` assumes a standard 4K cartridge mapped at `$F000-$FFFF` with vectors at `$FFFA-$FFFF`.
- `n65cc` discovers this file in the source tree or installed `share/vcs` directory and uses it by default. Pass `-T` only to select a different cartridge layout.
- The 128 physical RIOT RAM bytes are not double-counted. `vcs_4k.cfg` declares the full `$80-$FF` block and asks `n65ld` to reserve the top bytes dynamically from the whole-program source call graph before placing ordinary storage. The page-1 addresses `$0180-$01FF` are mirrors of `$80-$FF`, not separate RAM.
- Current stack sizing accounts for JSR return addresses and compiler-generated `fp` preservation. Inline `PHA`/`PHP`/`JSR` and stack use hidden in separately assembled routines remain future accounting work.
- `batari-basic/` is reference/source material imported from upstream batari Basic and is not automatically wired into the `n65c`/`n65ld` flow.
- The VCS hardware mirrors TIA and RIOT addresses heavily. The bindings use the conventional canonical addresses.
