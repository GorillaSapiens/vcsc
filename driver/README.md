```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# driver (`vcsc`)

`vcsc` is the GCC-like public front end for the VCSC Atari 2600 toolchain.
It sits above `vcsc-cc1`, `vcsc-as`, and `vcsc-ld` and invokes them in the usual compile ... assemble ... link pipeline, much like `gcc` drives `cc1`, `as`, and `ld`.

## What it does

`vcsc` understands the most useful high-level build modes:

- compile and link by default
- `-c` to stop after producing `.o65`
- `-S` to stop after producing assembly
- `-I`, `-L`, and `-l` in the usual GCC style
- `-T` and `-Map` passthrough for the linker
- `-Wc,...`, `-Wa,...`, `-Wl,...` and `-Xcompiler`, `-Xassembler`, `-Xlinker` for stage-specific arguments
- `-v` and `-###` to print the subordinate commands

When linking, it uses the bundled `libraries/vcs/vcs_4k.cfg` unless `-T` is
supplied and links `libraries/runtime/libvcsc.a65` unless `-nostdlib` is used.

## What it requires

`vcsc` is only a coordinator.
It needs the rest of the toolchain plus the default runtime archives.

When run from the built repository tree, it finds:

- `compiler/vcsc-cc1`
- `assembler/vcsc-as`
- `linker/vcsc-ld`
- `archiver/vcsc-ar` (only for path reporting via `-print-prog-name=ar`)
- `simulator/vcsc-sim` (only for path reporting via `-print-prog-name=sim`)
- `libraries/runtime/libvcsc.a65` for default linking
- `libraries/vcs/vcs_4k.cfg` for the default unbanked VCS cartridge layout

When installed, it expects this layout under the same prefix:

- `bin/vcsc`, `bin/vcsc-cc1`, `bin/vcsc-as`, `bin/vcsc-ld`, `bin/vcsc-ar`, `bin/vcsc-sim`
- `lib/libvcsc.a65`
- `include/vcsc-runtime.inc` for the assembler's implicit runtime include path; platform headers such as the VCS bindings are selected explicitly with `-I`
- `share/vcs/vcs_4k.cfg` for the default linker layout

So the same binary works both from the source tree and from an installed prefix without extra path flags.

## Input kinds

`vcsc` classifies inputs by suffix:

- `.vcsc` ... compile with `vcsc-cc1`
- `.s` or `.asm` ... assemble with `vcsc-as`
- `.o65` ... pass directly to `vcsc-ld`
- `.a65` ... pass directly to `vcsc-ld`

## Examples

Build and link a program:

```sh
./driver/vcsc -I libraries/vcs examples/01_solid_color/solid_color.vcsc -o solid_color.bin
```

Compile only:

```sh
./driver/vcsc -c -I libraries/runtime demo.vcsc
```

Stop after assembly:

```sh
./driver/vcsc -S demo.vcsc
```

Link extra archives from a search directory:

```sh
./driver/vcsc crt0.o65 main.o65 -T custom.cfg -L libraries/runtime -lruntime -nostdlib -o app.hex
```

Show the exact subordinate commands without running them:

```sh
./driver/vcsc -### -I libraries/vcs examples/01_solid_color/solid_color.vcsc -o solid_color.bin
```

Show aligned driver/subtool versions and the exact tool paths being used:

```sh
./driver/vcsc -V
```

The `-V` output prints one line per tool, aligns the first colon after the tool name, and includes the resolved executable path before that tool's version string.

## Intentional non-goals

This is not a full `gcc` clone.

- It does not try to emulate every GCC switch.
- It does not provide a separate preprocessing mode.
- It does not manage every obscure language mode.

It just covers the normal compile/assemble/link flow without making you type three commands every time.
