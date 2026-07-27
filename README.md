```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCSC Toolchain

`vcsc` is a brutally pared-down C-like compiler and toolchain for the Atari
2600/VCS. It targets the 6507, the TIA/RIOT memory model, and tiny cartridge
programs rather than general-purpose 6502 systems.

VCSC began as an Atari-focused specialization of the broader
[N project](https://github.com/GorillaSapiens/n), but this repository is a
standalone toolchain. It does not preserve the parent project's source,
object, runtime, or ABI compatibility.

The public command is `vcsc`. It drives the compiler front end (`vcsc-cc1`),
assembler (`vcsc-as`), linker (`vcsc-ld`), archiver (`vcsc-ar`), and stock
runtime. `vcsc-sim` is the matching 6502 simulator used by the test suite.

Canonical file suffixes are:

- `.c26` — VCSC source
- `.s26` — VCSC assembler source
- `.o26` — relocatable object
- `.l26` — object library/archive

The object and archive formats are VCSC-specific. Renamed artifacts from the
parent toolchain are rejected rather than accepted by accident.

## Building

Build the tools without running the complete suite:

```sh
make tools
```

Run the normal complete build and test pass:

```sh
make
```

Useful top-level targets include:

```sh
make test          # complete unified test suite
make unit          # compile-only tests
make e2e           # linked/simulated and generic tests
make sieve         # quick driver smoke build
make installcheck  # staged installed-toolchain validation
make docs           # Doxygen output under doxygen/
make clean
```

## Quick start

Build the first cartridge through the high-level driver:

```sh
./driver/vcsc -I libraries/vcs \
  examples/01_blank_screen/blank_screen.c26 \
  -o solid_color.bin
```

The result is a 4096-byte unbanked VCS cartridge image. Load it in Stella or
another compatible emulator.

The same build performed one stage at a time is:

```sh
./compiler/vcsc-cc1 -quiet -I libraries/vcs \
  examples/01_blank_screen/blank_screen.c26 \
  -o solid_color.s26 \
  -dumpbase solid_color.c26 -dumpbase-ext .c26 -dumpdir ./

./assembler/vcsc-as -I libraries/runtime \
  -o solid_color.o26 solid_color.s26

./linker/vcsc-ld -T libraries/vcs/vcs_4k.cfg \
  -o solid_color.bin \
  solid_color.o26 libraries/runtime/libvcsc.l26
```

The linker prints final cartridge-ROM usage after a successful link and can
also write a detailed map with `-Map`.

## Tool overview

The command-line tools follow GCC/binutils conventions where practical:

- `vcsc` drives compile, assemble, and link stages; supports `-c`, `-S`, `-I`,
  `-L`, `-l`, `-T`, `-Map`, and stage-specific `-Wc`, `-Wa`, and `-Wl` options.
- `vcsc-cc1` compiles one `.c26` input and normally writes `.s26` assembly;
  `-fno-peephole` emits the unpeepholed compiler assembly for inspection, while
  inline assembly remains opaque in either mode.
- `vcsc-as` assembles `.s26` or retained/imported `.asm` source. Official NMOS
  6502/6507 opcodes are the default; `--illegals` deliberately enables named
  unofficial opcodes for silicon experiments such as the fingerprint example.
  Relative branches may use `.same`, `.cross`, or explicit `.flex` suffixes to
  communicate page-cycle placement requirements to the linker.
- `vcsc-ld` requires a linker script when used directly, performs whole-program
  activation and hardware-stack sizing, places page-sensitive objects, reports
  used/free ROM and RAM with the hardware-stack share, and writes Intel HEX or
  flat `.bin` output.
- `vcsc-ar` creates and updates `.l26` archives using GNU-`ar`-style operation
  strings such as `rcs`.
- `vcsc-sim` executes linked test programs and provides tracing and host-dispatch
  calls for regression tests.

See each component README for the complete command line and format contracts.

## Language and runtime model

The language is intentionally smaller and more explicit than C:

- fixed-width signed, unsigned, and packed-BCD integer types up to 32 bits;
- static, non-reentrant function activations;
- no direct or mutual recursion;
- directly named call targets rather than function pointers;
- memory-backed parameters and return objects;
- VCS-specific memory regions, hardware bindings, and inline assembly;
- link-time activation overlay and call-graph-based hardware-stack sizing.

Cycle-counted display renderers remain separately assembled code. VCSC source is
best used for setup, VBLANK/overscan game logic, state updates, score handling,
and other work outside the visible scanline schedule.

## VCS support and examples

[`libraries/vcs/`](libraries/vcs/) contains TIA/RIOT bindings, the stock 4K
linker layout, shared NTSC frame primitives, audio aliases, named NTSC colors,
score fonts, the shared six-glyph display, and two maintained NTSC renderer
profiles. The compile-time `__builtin_ntsc_rgb(r, g, b)` matcher selects the
nearest meaningful NTSC TIA byte from ordinary RGB components with no runtime
cost.
The installed `poison_debug_score` component provides a deterministic hostile
11-line score-profile predecessor for finding hidden TIA-state coupling while
the componentized renderers pass the 22i4b correctness gate.

The maintained renderer profiles are:

- `standard_4k_ntsc` — P0, P1, M0, M1, and Ball with solid TIA color groups;
- `standard_4k_ntsc_playercolors` — P0, P1, and Ball with independent per-row
  player colors and no missiles.

The user-facing examples are deliberately editable:

- [`01_blank_screen`](examples/01_blank_screen/) — minimal complete blank-screen cartridge
- [`02_ode_to_joy`](examples/02_ode_to_joy/) — frame-driven TIA music
- [`03_score`](examples/03_score/) — centered six-glyph BCD score
- [`04_fingerprint`](examples/04_fingerprint/) — unstable-`ARR` silicon fingerprint
- [`05_faithful_legacy_playercolors`](examples/05_faithful_legacy_playercolors/) — faithful Atari 2600 BASIC 1.9 player-color renderer example
- [`06_multicolor_full_static`](examples/06_multicolor_full_static/) — **pending display repair**; scoreless 192-line static multicolor P0+P1+Ball display
- [`07_multicolor_score_above_static`](examples/07_multicolor_score_above_static/) — **pending display repair**; static multicolor gameplay with score above
- [`08_multicolor_score_below`](examples/08_multicolor_score_below/) — **pending display repair**; static multicolor gameplay with score below
- [`09_multicolor_full_dynamic_x_motion`](examples/09_multicolor_full_dynamic_x_motion/) — **pending display repair**; full-height horizontal motion
- [`10_multicolor_score_above_dynamic_x_motion`](examples/10_multicolor_score_above_dynamic_x_motion/) — **pending display repair**; horizontal motion with score above
- [`11_multicolor_score_below_dynamic_x_motion`](examples/11_multicolor_score_below_dynamic_x_motion/) — **pending display repair**; horizontal motion with score below
- [`12_multicolor_full_dynamic_x_and_y_motion`](examples/12_multicolor_full_dynamic_x_and_y_motion/) — **pending display repair**; full-height two-axis motion
- [`13_multicolor_score_above_dynamic_x_and_y_motion`](examples/13_multicolor_score_above_dynamic_x_and_y_motion/) — **pending display repair**; two-axis motion with score above
- [`14_multicolor_score_below_dynamic_x_and_y_motion`](examples/14_multicolor_score_below_dynamic_x_and_y_motion/) — **pending display repair**; two-axis motion with score below

The `faithful_legacy_playercolors` template is compared with an independently
built retained-source audit using the same fixture scene. Public example 05 uses
that renderer with different playfield data, so its test checks the 264-line frame
schedule plus exact P0/P1 rows and colors rather than falsely claiming byte-for-
byte identity with the pristine scene ROM. Example 06 currently has build,
262-line frame, player, and Ball smoke coverage only; its playfield pixels are
not certified. Examples 06 through 14 must not be treated as rendering
references until their display timing is repaired and independently verified.

Example 04 intentionally needs unofficial-opcode mode:

```sh
./driver/vcsc -I libraries/vcs -Wa,--illegals \
  examples/04_fingerprint/fingerprint.c26 \
  -o fingerprint.bin
```

## Installing and packaging

The default prefix is `/opt/vcsc`:

```sh
make install
make install DESTDIR=/tmp/vcsc-pkg
make uninstall
make package
```

The installed layout contains:

- `$(PREFIX)/bin/` — all six command-line tools;
- `$(PREFIX)/lib/` — `libvcsc.l26`;
- `$(PREFIX)/include/` — `vcsc-runtime.inc`;
- `$(PREFIX)/share/cfg/` — assembler opcode tables;
- `$(PREFIX)/share/vcs/` — VCS bindings, fonts, renderers, linker configuration,
  and retained legacy-renderer conversion references.

The driver first recognizes the built source-tree layout. When installed, it
finds sibling tools and data relative to the common prefix. It uses the bundled
4K VCS linker script and runtime archive by default unless overridden with `-T`
or `-nostdlib`.

## Testing

`make test` runs the unified [`test/test.pl`](test/test.pl) harness. It covers
compiler-only `.c26` tests and linked/simulated or generic `.test` regressions,
continues after failures, and prints a consolidated summary.

Run selected tests directly from `test/`, for example:

```sh
cd test
./test.pl inline_function_codegen_test.c26
./test.pl --compile-only default_parameter_direct_cycle_error_test.c26
./test.pl --e2e-only vcs_standard_playercolors.test
```

See [`test/README.md`](test/README.md) for test headers, placeholders, fixture
rules, and runner behavior.

## Documentation

Documentation is organized by responsibility:

- [`compiler/README.md`](compiler/README.md) — language and generated-code model
- [`driver/README.md`](driver/README.md) — high-level build driver
- [`assembler/README.md`](assembler/README.md) — syntax, opcodes, directives, and objects
- [`linker/README.md`](linker/README.md) — scripts, placement, stack sizing, and outputs
- [`archiver/README.md`](archiver/README.md) — `.l26` archive operations and format
- [`simulator/README.md`](simulator/README.md) — execution, tracing, and host calls
- [`libraries/runtime/README.md`](libraries/runtime/README.md) — runtime archive construction and ABI
- [`libraries/vcs/README.md`](libraries/vcs/README.md) — target bindings, renderers, fonts, and examples
- [`test/README.md`](test/README.md) — unified test harness

## Licensing

Unless a subdirectory says otherwise, the toolchain sources and top-level
build/test glue are licensed under GPL-3.0-or-later. The runtime library under
`libraries/runtime/` is BSD-2-Clause so linking it does not impose the
toolchain's GPL terms on cartridge programs. Exact license texts are in the
repository root and relevant library directories.
