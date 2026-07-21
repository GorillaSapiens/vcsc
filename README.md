```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCSC Toolchain

`vcsc` is a brutally pared-down Atari VCS C-like compiler. The language and toolchain are intentionally specialized for the 6507, the VCS memory model, and tiny cartridge programs rather than general-purpose 6502 compatibility.

VCSC is the Atari-focused child of the broader [N project](https://github.com/GorillaSapiens/n). N remains the parent/general-purpose line; VCSC deliberately hard-specializes that compiler architecture for the Atari 2600 rather than preserving source, tool, or ABI compatibility.

The public command is `vcsc`. It drives the internal compiler front end (`vcsc-cc1`), assembler (`vcsc-as`), archiver (`vcsc-ar`), linker (`vcsc-ld`), simulator (`vcsc-sim`), and the stock VCS runtime.

## Tool CLI Notes

The command-line tools follow the usual GCC/binutils habits where practical:

- `vcsc` is the high-level GCC-like entry point; it drives `vcsc-cc1`, `vcsc-as`, and `vcsc-ld` for the normal compile/assemble/link flow
- `vcsc-cc1` accepts a GCC-`cc1`-style single input file anywhere on the line, uses `-o output.s`, and accepts `-quiet`, `-dumpbase`, `-dumpbase-ext`, and `-dumpdir`
- `vcsc-as` takes a positional input file and uses `-o output.o65` for relocatable object output, similar to GNU `as`; it auto-loads the bundled `default.cfg` from the source tree or installed `share/cfg`, can add the bundled `illegals.cfg` with `--illegals`, supports extra opcode tables with `--opcode-cfg`, and supports `.def` aliases plus raw `opXX` tokens
- `vcsc-ar` accepts GNU-`ar` style operation strings such as `rcs`
- `vcsc-ld` accepts GNU-`ld` style `-o`, `-T`, and `-Map`

Examples:

High-level driver flow:

```sh
vcsc -I libraries/vcs examples/01_solid_color/solid_color.vcsc -o solid_color.bin

# The score example selects a shared VCS font module and uses official opcodes only.
vcsc -I libraries/vcs \
  examples/03_six_digit_score/six_digit_score.vcsc -o six_digit_score.bin

# The fingerprint example intentionally enables and executes unstable ARR ($6B).
vcsc -I libraries/vcs -Wa,--illegals \
  examples/04_fingerprint/fingerprint.vcsc -o fingerprint.bin
```

Direct stage-by-stage flow:

```sh
vcsc-cc1 -quiet -I libraries/vcs examples/01_solid_color/solid_color.vcsc -o solid_color.s -dumpbase solid_color.vcsc -dumpbase-ext .vcsc -dumpdir ./
vcsc-as -I libraries/runtime/ -o solid_color.o65 solid_color.s
vcsc-ld -T libraries/vcs/vcs_4k.cfg -o solid_color.bin solid_color.o65 libraries/runtime/libvcsc.a65
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
- `$(PREFIX)/lib/` ... the default runtime archive `libvcsc.a65`
- `$(PREFIX)/include/` ... the assembler runtime include `vcsc-runtime.inc`
- `$(PREFIX)/share/cfg/` ... bundled assembler opcode tables such as `default.cfg` and `illegals.cfg`
- `$(PREFIX)/share/` ... packaged VCS bindings, 18 decimal/hex score-font modules, linker configuration, and retained legacy BASIC conversion references

The installed `vcsc` will first use the built source-tree layout when run from the repository, and otherwise will find sibling installed tools in `bin/`, runtime assets under `lib/` and `include/`, and the VCS linker script under `share/vcs/`. By default it uses `vcs_4k.cfg` and links `libvcsc.a65` unless `-nostdlib` is used. Direct `vcsc-ld` use always requires an explicit linker script.

## Testing

Run `make test` at the repository root to execute the unified `test/test.pl` harness across both compiler-side source tests and end-to-end `vcsc-cc1 -> vcsc-as -> vcsc-ld -> vcsc-sim` regression tests. Use `make unit` for compile-only cases, `make e2e` for end-to-end cases, and `make sieve` for a quick `vcsc` smoke build.

`test/test.pl` is the runner for both `.vcsc` source tests and generic `.test` wrapper tests. It does not stop at the first failure, shows progress for every case, and prints a final summary of all failures. You can also run one file, a few files, or a whole subdirectory directly, for example:

```sh
cd test
./test.pl operator_overloading_rejected_test.vcsc
./test.pl --compile-only exactops_rejected_test.vcsc
./test.pl --e2e-only e2e_call_argument_order_overload_verify.vcsc
```

See `test/README.md` for the header directives, placeholder tokens, and the generic `.test` file format.

# Additional Details

For additional details, see the README.md files in the various subdirectories.

## Licensing

Unless a subdirectory says otherwise, the toolchain sources and top-level build/test glue are licensed under GPL-3.0-or-later.
The runtime library in `libraries/runtime/` is licensed under BSD-2-Clause so code linked into user binaries stays permissive.
The exact license texts live in the repository root `LICENSE`/`COPYING` files and in the per-library `LICENSE` files.

## Integer and packed-BCD type flags

Integer-like scalar types use an explicit style flag: `$integer:signed` or `$integer:unsigned`.

Examples:

```vcsc
type int8_t   { $size:1 $integer:signed };
type uint8_t  { $size:1 $integer:unsigned };
type int16_t  { $size:2 $integer:signed $endian:little };
type uint16_t { $size:2 $integer:unsigned $endian:little };
type int24_t  { $size:3 $integer:signed $endian:little };
type uint24_t { $size:3 $integer:unsigned $endian:little };
type int32_t  { $size:4 $integer:signed $endian:little };
type uint32_t { $size:4 $integer:unsigned $endian:little };
type bcd8_t   { $size:1 $integer:unsigned $bcd };
type bcd16_t  { $size:2 $integer:unsigned $endian:little $bcd };
type bcd24_t  { $size:3 $integer:unsigned $endian:little $bcd };
type bcd32_t  { $size:4 $integer:unsigned $endian:little $bcd };
type *        { $size:2 $integer:unsigned $endian:little };
```

Ordinary binary integer value types may occupy one through four bytes and use
`$integer:signed` or `$integer:unsigned`. The stock VCS target exposes canonical
8-, 16-, 24-, and 32-bit signed/unsigned names. It also defines unsigned
packed-decimal `bcd8_t`, `bcd16_t`, `bcd24_t`, and `bcd32_t`, holding two,
four, six, and eight decimal digits. `$bcd` is valid only on unsigned integer
declarations from one through four bytes. All multibyte values are little-endian.

## Visual binary literals

Binary literals may use `.` for a zero bit and `X` or `x` for a one bit after
the normal `0b`/`0B` prefix. The leftmost character is the most-significant
bit, so graphics and masks can be drawn directly in source code:

```vcsc
const uint8_t sprite[8] := {
   0b........,
   0b..XXX...,
   0b.X...X..,
   0b.X...X..,
   0b.X...X..,
   0b.X...X..,
   0b.X...X..,
   0b..XXX...,
};
```

Visual and conventional digits may be mixed, and underscores remain optional
separators: `0bXX.._0011` is the same value as `0b1100_0011`. The lexer
normalizes the visual spelling to ordinary `0`/`1` digits before parsing, so
constant folding, range checking, initializers, aliases, and conditional
compilation use the existing binary-integer semantics.

BCD literals are converted by numeric value, not copied as binary bytes. Thus
decimal `42`, hexadecimal `0x2a`, octal `052`, and binary `0b101010` all store
as packed BCD `$42`. `1234` stores as `$34,$12`, `567890` stores as
`$90,$78,$56`, and `12345678` stores as `$78,$56,$34,$12`. Range checking
follows decimal capacity: 0..99, 0..9999, 0..999999, and 0..99999999.

Packed-BCD values support assignment, widening/truncating BCD copies, `+`, `-`,
`+=`, `-=`, `++`, `--`, comparisons, truth tests, and `switch`. The compiler
emits tightly scoped `SED`/`CLD` around each BCD `ADC`/`SBC` chain and leaves
decimal mode clear afterward. Multiplication, division, remainder, shifts,
bitwise operations, unary minus, BCD bitfields, and runtime BCD/binary
conversions are rejected. All four BCD widths may be stored, passed as parameters,
and returned. Value-returning functions expose an exact-sized callee-owned
`function$__return` object; callers copy from that object after `jsr`, so the
ABI no longer has a register-width ceiling.

Untyped ordinary integer literals still default to `int16_t`, but a typed 24-
or 32-bit destination, operand, parameter, return, or annotation supplies the
wider context. `int24_t` ranges from -8388608 through 8388607 and `uint24_t`
from 0 through 16777215; `int32_t` ranges from -2147483648 through 2147483647
and `uint32_t` from 0 through 4294967295. As with the existing smaller types,
literal encoding is width-based: any positive or negative magnitude that fits
the destination width may be used as that width's bit pattern. Expression-level shortcut casts `($signed)` /
`($unsigned)` change signedness while preserving width and are not valid for BCD
values.

Bitfields follow the integer style of their declared type. Use an unsigned integer type for raw packed/overlay fields, and a signed integer type when you want sign extension on bitfield reads.

## Floating-point values

Floating-point types and literals are not supported. Any `$float:*` type flag or floating-point literal is a compile-time error.

Operator overloading and `$exactops` are intentionally unsupported in the VCS subset. Arithmetic, comparisons, truth tests, and increment/decrement use only the compiler built-ins.
