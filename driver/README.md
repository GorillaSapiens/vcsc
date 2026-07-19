# driver (`n65cc`)

`n65cc` is a small GCC-like front-end for the `n` 6502 toolchain.
It sits above `n65c`, `n65asm`, and `n65ld` and invokes them in the usual compile ... assemble ... link pipeline, much like `gcc` drives `cc1`, `as`, and `ld`.

## What it does

`n65cc` understands the most useful high-level build modes:

- compile and link by default
- `-c` to stop after producing `.o65`
- `-S` to stop after producing assembly
- `-I`, `-L`, and `-l` in the usual GCC style
- `-T` and `-Map` passthrough for the linker
- `-Wc,...`, `-Wa,...`, `-Wl,...` and `-Xcompiler`, `-Xassembler`, `-Xlinker` for stage-specific arguments
- `-v` and `-###` to print the subordinate commands

By default it links `libraries/nlib/nlib.a65` unless `-nostdlib` is used.

## What it requires

`n65cc` is only a coordinator.
It needs the rest of the toolchain plus the default runtime archives.

When run from the built repository tree, it finds:

- `compiler/n65c`
- `assembler/n65asm`
- `linker/n65ld`
- `archiver/n65ar` (only for path reporting via `-print-prog-name=ar`)
- `simulator/n65sim` (only for path reporting via `-print-prog-name=sim`)
- `libraries/nlib/nlib.a65` for default linking

When installed, it expects this layout under the same prefix:

- `bin/n65cc`, `bin/n65c`, `bin/n65asm`, `bin/n65ld`, `bin/n65ar`, `bin/n65sim`
- `lib/nlib.a65`
- `include/nlib.inc` for the assembler's implicit runtime include path; platform headers such as the VCS bindings are selected explicitly with `-I`

So the same binary works both from the source tree and from an installed prefix without extra path flags.

## Input kinds

`n65cc` classifies inputs by suffix:

- `.n` ... compile with `n65c`
- `.s` or `.asm` ... assemble with `n65asm`
- `.o65` ... pass directly to `n65ld`
- `.a65` ... pass directly to `n65ld`

## Examples

Build and link a program:

```sh
./driver/n65cc -I test test/sieve.n -o sieve.hex
```

Compile only:

```sh
./driver/n65cc -c -I libraries/nlib demo.n
```

Stop after assembly:

```sh
./driver/n65cc -S demo.n
```

Link extra archives from a search directory:

```sh
./driver/n65cc crt0.o65 main.o65 -L libraries/nlib -lnlib -nostdlib -o app.hex
```

Show the exact subordinate commands without running them:

```sh
./driver/n65cc -### -I test test/sieve.n -o sieve.hex
```

Show aligned driver/subtool versions and the exact tool paths being used:

```sh
./driver/n65cc -V
```

The `-V` output prints one line per tool, aligns the first colon after the tool name, and includes the resolved executable path before that tool's version string.

## Intentional non-goals

This is not a full `gcc` clone.

- It does not try to emulate every GCC switch.
- It does not provide a separate preprocessing mode.
- It does not manage every obscure language mode.

It just covers the normal compile/assemble/link flow without making you type three commands every time.
