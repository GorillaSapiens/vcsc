# n Toolchain (`n65cc`, `n65c`, `n65asm`, `n65ar`, `n65ld`, `n65sim`)

`n` is a small C-like programming language designed for simplicity, low-level clarity, and embedded use. The project focuses on human-readable syntax, a minimal type system, and ease of compiler implementation... good for teaching, systems tinkering, or writing your own language from scratch.

This repository contains the `n` language compiler (`n65c`) plus a companion 6502 assembler (`n65asm`), archiver (`n65ar`), linker (`n65ld`), simulator (`n65sim`), a GCC-like driver (`n65cc`), and support libraries.

## Tool CLI Notes

The command-line tools follow the usual GCC/binutils habits where practical:

- `n65cc` is the high-level GCC-like entry point; it drives `n65c`, `n65asm`, and `n65ld` for the normal compile/assemble/link flow
- `n65c` accepts a GCC-`cc1`-style single input file anywhere on the line, uses `-o output.s`, and accepts `-quiet`, `-dumpbase`, `-dumpbase-ext`, and `-dumpdir`
- `n65asm` takes a positional input file and uses `-o output.o65` for relocatable object output, similar to GNU `as`; it auto-loads the bundled `default.cfg` from the source tree or installed `share/cfg`, can add the bundled `illegals.cfg` with `--illegals`, supports extra opcode tables with `--opcode-cfg`, and supports `.def` aliases plus raw `opXX` tokens
- `n65ar` accepts GNU-`ar` style operation strings such as `rcs`
- `n65ld` accepts GNU-`ld` style `-o`, `-T`, and `-Map`

Examples:

High-level driver flow:

```sh
n65cc -I test test/sieve.n -o sieve.hex
n65sim sieve.hex
```

Direct stage-by-stage flow:

```sh
n65c -quiet -I test test/sieve.n -o sieve.s -dumpbase sieve.n -dumpbase-ext .n -dumpdir ./
n65asm -I libraries/nlib/ -o sieve.o65 sieve.s
n65ld -o sieve.hex sieve.o65 libraries/nlib/nlib.a65 libraries/float/float.a65
n65sim sieve.hex
```


## Installing

The tree supports staged installs and relocatable packaging. The default prefix is `/opt/n`:

```sh
make install
make install DESTDIR=/tmp/n-pkg
make uninstall
make package
```

Installed layout:

- `$(PREFIX)/bin/` ... `n65cc`, `n65c`, `n65asm`, `n65ar`, `n65ld`, `n65sim`
- `$(PREFIX)/lib/` ... default runtime archives such as `nlib.a65`, `float.a65`, and `nint.a65`
- `$(PREFIX)/include/` ... installed N and assembler include files such as `machine_6502.n` and `nlib.inc`
- `$(PREFIX)/share/cfg/` ... bundled assembler opcode tables such as `default.cfg` and `illegals.cfg`
- `$(PREFIX)/share/` ... packaged library/source extras such as `nlib/n.cfg`, `float/README.md`, and `vcs/` files

The installed `n65cc` will first use the built source-tree layout when run from the repository, and otherwise will find sibling installed tools in `bin/` plus the default runtime assets under `lib/` and `include/`. By default it links `nlib.a65`, and adds `float.a65` when transitional builtin float helpers are referenced unless `-nostdlib` is used.

## Testing

Run `make test` at the repository root to execute the unified `test/test.pl` harness across both compiler-side source tests and end-to-end `n65c -> n65asm -> n65ld -> n65sim` regression tests. Use `make unit` for compile-only cases, `make e2e` for end-to-end cases, and `make sieve` for a quick `n65cc` smoke build.

`test/test.pl` is the runner for both `.n` source tests and generic `.test` wrapper tests. It does not stop at the first failure, shows progress for every case, and prints a final summary of all failures. You can also run one file, a few files, or a whole subdirectory directly, for example:

```sh
cd test
./test.pl operator_overloading_rejected_test.n
./test.pl --compile-only exactops_rejected_test.n
./test.pl --e2e-only e2e_call_argument_order_overload_verify.n
```

See `test/README.md` for the header directives, placeholder tokens, and the generic `.test` file format.

# Additional Details

For additional details, see the README.md files in the various subdirectories.

## Licensing

Unless a subdirectory says otherwise, the toolchain sources and top-level build/test glue are licensed under GPL-3.0-or-later.
The runtime libraries in `libraries/nlib/`, `libraries/float/`, and `libraries/nint/` are licensed under BSD-2-Clause so code linked into user binaries stays permissive.
The exact license texts live in the repository root `LICENSE`/`COPYING` files and in the per-library `LICENSE` files.

## Integer style flags

Integer-like scalar types use an explicit style flag: `$integer:signed` or `$integer:unsigned`.

Examples:

```n
type char   { $size:1 $integer:signed };
type *      { $size:2 $integer:unsigned $endian:little };
type int    { $size:4 $integer:signed $endian:little };
type uint   { $size:4 $integer:unsigned $endian:little };
```

Type declarations use `$integer:signed` or `$integer:unsigned`. Expression-level shortcut casts `($signed)` / `($unsigned)` are available, with matching endian shortcuts `($big)` / `($little)` for fixed-width integers and floats.

Bitfields follow the integer style of their declared type. Use an unsigned integer type for raw packed/overlay fields, and a signed integer type when you want sign extension on bitfield reads.

## Floating-point style flags

Float types use a style-based flag: `$float:ieee754` or `$float:simple`.

Examples:

```n
type half   { $size:2 $endian:little $float:ieee754 }; // IEEE 754 binary16
type float  { $size:4 $endian:little $float:ieee754 }; // IEEE 754 binary32
type double { $size:8 $endian:little $float:ieee754 }; // IEEE 754 binary64
type f3     { $size:3 $endian:little $float:simple  }; // generic simple SExMy format
```

`$float:ieee754` supports only `$size:2`, `$size:4`, and `$size:8`.
`$float:simple` supports any positive size and always uses an `SExMy` layout where `x = round(3 * log2(size) + 2)` and `y` is the remaining fraction bits. For `$size:2`, `$size:4`, and `$size:8`, that yields the same exponent widths as IEEE 754 binary16/binary32/binary64.

Operator overloading and `$exactops` are intentionally unsupported in the VCS subset. Arithmetic, comparisons, truth tests, and increment/decrement use only the compiler built-ins.
