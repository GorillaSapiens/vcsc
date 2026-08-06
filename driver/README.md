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
- `-c` to stop after producing `.o26`
- `-S` to stop after producing assembly
- `-I`, `-L`, and `-l` in the usual GCC style
- `-T`, `-Map`, `-Sym`, `-List`, and `-Cfg` passthrough for the linker
- `--no-map`, `--no-sym`, `--no-list`, and `--no-cfg` sidecar suppression
- `-Wc,...`, `-Wa,...`, `-Wl,...` and `-Xcompiler`, `-Xassembler`, `-Xlinker` for stage-specific arguments
- `-fno-peephole` to disable compiler assembly peephole rewrites, and `-fpeephole` to re-enable them
- `-v` and `-###` to print the subordinate commands

When linking without `-T`, it compiles the bundled `libraries/vcs/vcs_4k.c26`
configuration profile and links through the reduced `libraries/vcs/vcs.cfg`.
An explicit `-T` suppresses that implicit profile. The driver links
`libraries/runtime/libvcsc.l26` unless `-nostdlib` is used.
Successful links also create same-stem `.map`, `.sym`, `.lst`, and DiStella
`.cfg` files by default. The naming and suppression options above are forwarded
directly to `vcsc-ld`.

## What it requires

`vcsc` is only a coordinator.
It needs the rest of the toolchain plus the default runtime archives.

When run from the built repository tree, it finds:

- `compiler/vcsc-cc1`
- `assembler/vcsc-as`
- `linker/vcsc-ld`
- `archiver/vcsc-ar` (only for path reporting via `-print-prog-name=ar`)
- `simulator/vcsc-sim` (only for path reporting via `-print-prog-name=sim`)
- `libraries/runtime/libvcsc.l26` for default linking
- `libraries/vcs/vcs.cfg` for reduced VCS linker operational policy
- `libraries/vcs/vcs_4k.c26` for the implicit unbanked cartridge topology
- the installed F8/F6/F4 and Superchip `.c26` cartridge profiles for explicit builds
- the old profile-specific cfg files only for compatibility and simulator selection

When installed, it expects this layout under the same prefix:

- `bin/vcsc`, `bin/vcsc-cc1`, `bin/vcsc-as`, `bin/vcsc-ld`, `bin/vcsc-ar`, `bin/vcsc-sim`
- `lib/libvcsc.l26`
- `include/vcsc-runtime.inc` for the assembler's implicit runtime include path; platform headers such as the VCS bindings are selected explicitly with `-I`
- `share/vcs/vcs.cfg` plus `share/vcs/vcs_4k.c26` for the default link
- `share/vcs/vcs_8k_f8.c26`, `vcs_16k_f6.c26`, `vcs_32k_f4.c26`, and their Superchip counterparts for explicit cartridge topology
- retained profile-specific cfg files for compatibility and `vcsc-sim`

So the same binary works both from the source tree and from an installed prefix without extra path flags.

## Input kinds

`vcsc` classifies inputs by suffix:

- `.c26` ... compile with `vcsc-cc1`
- `.s26` ... assemble with `vcsc-as`
- `.asm` ... assemble retained or imported assembly with `vcsc-as`
- `.o26` ... pass directly to `vcsc-ld`
- `.l26` ... pass directly to `vcsc-ld`

The old generic `.s` suffix remains a temporary driver compatibility input and
emits a warning. Maintained VCSC assembler sources and generated compiler output
use `.s26`; new code should not use `.s`.

Each `.c26` input searches its own directory first for quoted includes. `-I`
adds further compiler and assembler include paths. This lets an installed
cartridge profile include sibling machine headers without requiring callers to
repeat the profile directory explicitly.

## Examples

Build and link a program:

```sh
./driver/vcsc -I libraries/vcs examples/01_basic/01_blank_screen/blank_screen.c26 -o solid_color.bin
```

Select an installed/repository full-window profile explicitly:

```sh
./driver/vcsc -I libraries/vcs -T libraries/vcs/vcs.cfg \
  libraries/vcs/vcs_8k_f8.c26 banked.c26 -o banked-f8.bin
./driver/vcsc -I libraries/vcs -T libraries/vcs/vcs.cfg \
  libraries/vcs/vcs_16k_f6.c26 banked.c26 -o banked-f6.bin
./driver/vcsc -I libraries/vcs -T libraries/vcs/vcs.cfg \
  libraries/vcs/vcs_32k_f4.c26 banked.c26 -o banked-f4.bin
```

Compile only:

```sh
./driver/vcsc -c -I libraries/runtime demo.c26
```

Stop after assembly:

```sh
./driver/vcsc -S demo.c26
```

Link extra archives from a search directory:

```sh
./driver/vcsc crt0.o26 main.o26 -T custom.cfg -L libraries/runtime -lruntime -nostdlib -o app.hex
```

Show the exact subordinate commands without running them:

```sh
./driver/vcsc -### -I libraries/vcs examples/01_basic/01_blank_screen/blank_screen.c26 -o solid_color.bin
```

Show aligned driver/subtool versions and the exact tool paths being used:

```sh
./driver/vcsc -V
```

The `-V` output prints one line per tool, aligns the first colon after the tool name, and includes the resolved executable path before that tool's version string.

Intermediate `.s26` and `.o26` files live in a private `vcsc.XXXXXX` directory under `$TMPDIR`, or `/tmp` when `TMPDIR` is unset. The driver removes that directory on both successful completion and normal failing exits from any pipeline stage.

## Intentional non-goals

This is not a full `gcc` clone.

- It does not try to emulate every GCC switch.
- It does not provide a separate preprocessing mode.
- It does not manage every obscure language mode.

It just covers the normal compile/assemble/link flow without making you type three commands every time.
