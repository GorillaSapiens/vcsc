# Atari 2600 / VCS support files

This directory contains starter target files for the Atari 2600 / VCS.

Files:

- `vcs.n` ... VCS machine definition with types, memory regions, and hardware includes
- `tia.n` ... TIA hardware register bindings
- `riot.n` ... RIOT I/O and timer register bindings plus RIOT RAM region names
- `vcs_4k.cfg` ... linker configuration for a conventional unbanked 4K cartridge
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

And link with:

```sh
n65ld -C libraries/vcs/vcs_4k.cfg ...
```

Notes:

- `vcs.n` is the easiest entry point for a VCS target. It defines the machine types and memory regions, then includes `tia.n` and `riot.n`.
- `tia.n` and `riot.n` can also be included separately if you already have your own base machine definition.
- `vcs_4k.cfg` assumes a standard 4K cartridge mapped at `$F000-$FFFF` with vectors at `$FFFA-$FFFF`.
- The 128 physical RIOT RAM bytes are not double-counted: `$80-$DF` are currently available to the linker, while `$E0-$FF` are reserved for the downward-growing 6502 hardware stack. The page-1 addresses `$0180-$01FF` are mirrors of `$80-$FF`, not separate RAM.
- `batari-basic/` is reference/source material imported from upstream batari Basic and is not automatically wired into the `n65c`/`n65ld` flow.
- The VCS hardware mirrors TIA and RIOT addresses heavily. The bindings use the conventional canonical addresses.
