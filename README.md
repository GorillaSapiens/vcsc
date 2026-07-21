```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCSC Toolchain

`vcsc` is a brutally pared-down Atari VCS C-like compiler. The language and toolchain are intentionally specialized for the 6507, the VCS memory model, and tiny cartridge programs rather than general-purpose 6502 compatibility.

VCSC originated as an Atari-focused specialization of the broader [N project](https://github.com/GorillaSapiens/n), but this repository is a standalone toolchain and requires no knowledge of N. VCSC deliberately targets the Atari 2600 and does not preserve parent-project source, object, runtime, or ABI compatibility.

The public command is `vcsc`. It drives the internal compiler front end (`vcsc-cc1`), assembler (`vcsc-as`), archiver (`vcsc-ar`), linker (`vcsc-ld`), simulator (`vcsc-sim`), and the stock VCS runtime.

VCSC source files use `.c26`, relocatable objects use `.o26`, and object libraries use `.l26`. The object and archive magics are VCSC-specific; artifacts from the parent toolchain are intentionally rejected rather than accepted under renamed filenames.

## Tool CLI Notes

The command-line tools follow the usual GCC/binutils habits where practical:

- `vcsc` is the high-level GCC-like entry point; it drives `vcsc-cc1`, `vcsc-as`, and `vcsc-ld` for the normal compile/assemble/link flow
- `vcsc-cc1` accepts a GCC-`cc1`-style single input file anywhere on the line, uses `-o output.s`, and accepts `-quiet`, `-dumpbase`, `-dumpbase-ext`, and `-dumpdir`
- `vcsc-as` takes a positional input file and uses `-o output.o26` for relocatable object output, similar to GNU `as`; it auto-loads the bundled `default.cfg` from the source tree or installed `share/cfg`, can add the bundled `illegals.cfg` with `--illegals`, supports extra opcode tables with `--opcode-cfg`, and supports `.def` aliases plus raw `opXX` tokens
- `vcsc-ar` accepts GNU-`ar` style operation strings such as `rcs`
- `vcsc-ld` accepts GNU-`ld` style `-o`, `-T`, and `-Map`

Examples:

High-level driver flow:

```sh
vcsc -I libraries/vcs examples/01_solid_color/solid_color.c26 -o solid_color.bin

# The score example selects a shared VCS font module and uses official opcodes only.
vcsc -I libraries/vcs \
  examples/03_six_digit_score/six_digit_score.c26 -o six_digit_score.bin

# The fingerprint example intentionally enables and executes unstable ARR ($6B).
vcsc -I libraries/vcs -Wa,--illegals \
  examples/04_fingerprint/fingerprint.c26 -o fingerprint.bin
```

Direct stage-by-stage flow:

```sh
vcsc-cc1 -quiet -I libraries/vcs examples/01_solid_color/solid_color.c26 -o solid_color.s -dumpbase solid_color.c26 -dumpbase-ext .c26 -dumpdir ./
vcsc-as -I libraries/runtime/ -o solid_color.o26 solid_color.s
vcsc-ld -T libraries/vcs/vcs_4k.cfg -o solid_color.bin solid_color.o26 libraries/runtime/libvcsc.l26
```


## Installing

The tree supports staged installs and relocatable packaging. The default prefix is `/opt/vcsc`:

```sh
make install
make install DESTDIR=/tmp/vcsc-pkg
make uninstall
make package
```

Installed layout:

- `$(PREFIX)/bin/` ... `vcsc`, `vcsc-cc1`, `vcsc-as`, `vcsc-ar`, `vcsc-ld`, `vcsc-sim`
- `$(PREFIX)/lib/` ... the default runtime archive `libvcsc.l26`
- `$(PREFIX)/include/` ... the assembler runtime include `vcsc-runtime.inc`
- `$(PREFIX)/share/cfg/` ... bundled assembler opcode tables such as `default.cfg` and `illegals.cfg`
- `$(PREFIX)/share/` ... packaged VCS bindings, 16 decimal/hex score-font modules across eight families, linker configuration, and retained legacy BASIC conversion references

The installed `vcsc` will first use the built source-tree layout when run from the repository, and otherwise will find sibling installed tools in `bin/`, runtime assets under `lib/` and `include/`, and the VCS linker script under `share/vcs/`. By default it uses `vcs_4k.cfg` and links `libvcsc.l26` unless `-nostdlib` is used. Direct `vcsc-ld` use always requires an explicit linker script.

## Testing

Run `make test` at the repository root to execute the unified `test/test.pl` harness across both compiler-side source tests and end-to-end `vcsc-cc1 -> vcsc-as -> vcsc-ld -> vcsc-sim` regression tests. Use `make unit` for compile-only cases, `make e2e` for end-to-end cases, and `make sieve` for a quick `vcsc` smoke build.

`test/test.pl` is the runner for both `.c26` source tests and generic `.test` wrapper tests. It does not stop at the first failure, shows progress for every case, and prints a final summary of all failures. You can also run one file, a few files, or a whole subdirectory directly, for example:

```sh
cd test
./test.pl inline_function_codegen_test.c26
./test.pl --compile-only default_parameter_direct_cycle_error_test.c26
./test.pl --e2e-only e2e_call_argument_order_verify.c26
```

See `test/README.md` for the header directives, placeholder tokens, and the generic `.test` file format.

## Documentation

The component documentation is organized by responsibility:

- [`compiler/README.md`](compiler/README.md) — VCSC language syntax, types, expressions, functions, storage, inline assembly, and compiler behavior
- [`driver/README.md`](driver/README.md) — high-level compile/assemble/link driver options and input handling
- [`assembler/README.md`](assembler/README.md) — assembly syntax, opcode tables, directives, and object generation
- [`linker/README.md`](linker/README.md) — linker scripts, memory placement, call-stack sizing, and output formats
- [`archiver/README.md`](archiver/README.md) — `.l26` archive operations and format
- [`simulator/README.md`](simulator/README.md) — simulator command line, tracing, and host dispatch calls
- [`libraries/vcs/README.md`](libraries/vcs/README.md) — Atari 2600 bindings, fonts, kernels, linker configuration, and examples
- [`test/README.md`](test/README.md) — test harness directives and fixture formats

## Licensing

Unless a subdirectory says otherwise, the toolchain sources and top-level build/test glue are licensed under GPL-3.0-or-later.
The runtime library in `libraries/runtime/` is licensed under BSD-2-Clause so code linked into user binaries stays permissive.
The exact license texts live in the repository root `LICENSE`/`COPYING` files and in the per-library `LICENSE` files.
