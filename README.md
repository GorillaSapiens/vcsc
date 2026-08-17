```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCSC Toolchain

`vcsc` is a deliberately small C-like compiler and complete development
toolchain for the Atari 2600/VCS. It targets the 6507 processor, the TIA/RIOT
memory model, and tiny cartridge programs rather than general-purpose 6502
systems.

VCSC began as an Atari-focused specialization of the broader
[N project](https://github.com/GorillaSapiens/n), but this repository is a
standalone toolchain. It does not preserve the parent project's source,
object, runtime, or ABI compatibility.

The public command is `vcsc`. It coordinates the compiler, assembler, linker,
runtime library, and target support files needed to turn VCSC source into an
Atari 2600 cartridge image. Separate low-level tools remain available for
people who want to inspect or control individual stages.

Canonical file suffixes are:

- `.c26` — VCSC source
- `.s26` — VCSC assembler source
- `.o26` — relocatable object
- `.l26` — object library/archive
- `.bin` — linked cartridge image

The object and archive formats are VCSC-specific. Renamed artifacts from the
parent toolchain are rejected rather than accepted by accident.

## What is included

The repository contains:

- a C-like compiler designed around fixed-width data and constrained hardware;
- a 6502/6507 assembler;
- a whole-program linker with VCS memory-layout support;
- an object-library archiver;
- a high-level build driver;
- a matching simulator used by the regression suite, including cfg-driven
  F8/F6/F4, Superchip, and CBS FA/RAM Plus cartridge execution;
- `vcsc-disas`, a byte-exact Atari cartridge disassembler that emits `.s26`
  source and performs conservative mapper/video/controller analysis;
- a small runtime library;
- Atari 2600 bindings, reusable display and audio support, and maintained
  renderer implementations;
- editable example cartridges and an automated test suite.

The normal build flow is:

```text
.c26 source -> compiler -> .s26 assembly -> assembler -> .o26 objects
            -> linker + runtime/support libraries -> .bin cartridge
```

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
make linux         # build a self-contained native Linux tar.gz with examples
make windows       # cross-build a self-contained 64-bit Windows zip with examples
make stella-bank-test STELLA=stella  # authoritative F8/F6/F4 mapper matrix
make stella-player-color-192-test STELLA=stella  # player-color-192 visible playfield raster
make stella-all-five-player-color-192-test STELLA=stella  # all-five + per-row player colors
make stella-all-five-player-color-181-test STELLA=stella  # 181 gameplay + score above/below
make docs          # Doxygen output under doxygen/
make clean
```

## Quick start

Build the blank-screen example through the high-level driver:

```sh
./driver/vcsc -I libraries/vcs \
  examples/01_basic/01_blank_screen/blank_screen.c26 \
  -o blank_screen.bin
```

The result is a 4096-byte unbanked VCS cartridge image suitable for Stella or
compatible hardware and emulators. A successful link also produces debugger
and layout information beside the cartridge image; see the linker documentation
for those outputs and their naming controls.

Most users should begin with the high-level driver and the examples. The
individual stage tools are useful when debugging generated assembly, creating
reusable object libraries, or integrating separately assembled code.

To reverse-engineer an existing cartridge while preserving it byte for byte:

```sh
./disassembler/vcsc-disas game.bin
./assembler/vcsc-as --hex=game.hex game.s26
```

See [`disassembler/README.md`](disassembler/README.md) for mapper inference,
overlapping-code handling, hardware-register symbolization, and the standalone
corpus round-trip verifier.

## Toolchain components

- [`driver/`](driver/) — the `vcsc` front end that coordinates compilation,
  assembly, and linking.
- [`compiler/`](compiler/) — the VCSC language implementation and generated-code
  model.
- [`assembler/`](assembler/) — 6502/6507 assembly, object generation, and opcode
  configuration.
- [`linker/`](linker/) — whole-program selection, memory placement, stack sizing,
  cartridge output, and debugger metadata.
- [`archiver/`](archiver/) — creation and maintenance of `.l26` object libraries.
- [`simulator/`](simulator/) — the execution engine used by automated tests.
- [`disassembler/`](disassembler/) — `vcsc-disas`, which turns cartridge `.bin`
  images back into byte-exact VCSC `.s26` source with conservative Atari-specific
  analysis.
- [`libraries/runtime/`](libraries/runtime/) — startup and runtime support linked
  into cartridge programs as needed.
- [`libraries/vcs/`](libraries/vcs/) — Atari 2600 hardware definitions and
  reusable target-side support.

Each directory has its own README describing its command-line interface,
formats, implementation contracts, and specialized features.

## Language and execution model

The language is intentionally smaller and more explicit than C. Its design is
shaped by the Atari 2600 rather than by hosted-computer conventions:

- fixed-width integer and packed-decimal types;
- static, non-reentrant function activations;
- no direct or mutual recursion;
- directly named call targets rather than function pointers;
- explicit hardware references, memory regions, and inline assembly;
- whole-program memory overlay and hardware-stack sizing;
- predictable integration with cycle-counted assembly components.

VCSC is well suited to initialization, game-state updates, controller handling,
score logic, VBLANK and overscan work, and orchestration of display components.
Cycle-critical visible-scanline code remains separately assembled where exact
instruction timing matters.

See [`compiler/README.md`](compiler/README.md) for the language reference and
[`compiler/ABI.txt`](compiler/ABI.txt) for the calling and data-layout contract.

## Atari 2600 support

[`libraries/vcs/`](libraries/vcs/) provides the target definitions and reusable
support needed by cartridge programs, including hardware bindings, linker
configuration, frame support, display resources, and maintained renderer
families. The library README is the catalog and integration guide for those
pieces.

The examples are intentionally editable demonstrations rather than frozen test
fixtures. They range from small standalone cartridges to interactive renderer
diagnostics and are organized by purpose and renderer family. See
[`examples/README.md`](examples/README.md) for the current hierarchy and build
instructions.

## Installing and packaging

The default installation prefix is `/opt/vcsc`:

```sh
make install
make install DESTDIR=/tmp/vcsc-pkg
make uninstall
make package
make linux
make windows
```

The installed tree contains the command-line tools, runtime library, assembler
configuration, Atari 2600 support files, and editable examples under
`$(PREFIX)/examples` (normally `/opt/vcsc/examples`). The installed example
Makefiles are rewritten to use the installed `bin/vcsc` and `share/vcs` tree.
The driver locates sibling tools and shared data relative to the common
installation prefix, while still supporting in-tree development builds.
`make package` includes the same installed examples in its `/opt/vcsc` image.

`make linux` builds all seven host tools with static linkage, stages the normal
support tree plus the editable examples, and writes
`vcsc.linux.YYYYMMDD_HHMMSS.tar.gz`. The archive contains a relocatable `vcsc`
directory that can be unpacked and run without installation. See
[`LINUX.md`](LINUX.md) for prerequisites, package layout, and usage.

`make windows` uses a MinGW-w64 cross toolchain to build `.exe` versions of all
host tools with static compiler runtimes, stages the normal support tree plus
the editable examples, and writes `vcsc.windows.YYYYMMDD_HHMMSS.zip`. The zip
is relocatable after unpacking and includes a `vcsc.cmd` wrapper for native
Windows use. See [`WINDOWS.md`](WINDOWS.md) for prerequisites, package layout,
and usage.

See [`driver/README.md`](driver/README.md) and
[`libraries/runtime/README.md`](libraries/runtime/README.md) for installed
search paths and runtime details.

## Testing

`make test` runs the unified [`test/test.pl`](test/test.pl) harness. The suite
covers compiler diagnostics and code generation, assembler and linker behavior,
linked-program execution, target-library integration, renderer timing, and
source-tree hygiene. Test cases run eight-at-a-time by default, and `make test`
writes per-case elapsed wall-clock times to `test-times.tsv`; override the
filename with `TEST_TIMINGS=/path/to/file.tsv` or force serial execution with
`TEST_JOBS=1`.

Run selected tests directly from `test/`, for example:

```sh
cd test
./test.pl inline_function_codegen_test.c26
./test.pl --compile-only default_parameter_direct_cycle_error_test.c26
./test.pl --e2e-only vcs_standard_playercolors.pl
```

See [`test/README.md`](test/README.md) for test metadata, fixtures, filtering,
and runner behavior.

Banked mapper certification has two layers: `make test` executes every F8/F6/F4
transition through `vcsc-sim`, while `make stella-bank-test` runs the visible
PASS/FAIL diagnostic in Stella from every forced physical startup bank and under
randomized developer startup-bank selection. CBS FA/RAM Plus has its own public
`examples/09_bankswitching/03_fa_ram_plus` PASS/FAIL cartridge and emulator-backed
self-test covering all three selectors, startup physical bank 2, and all 256 bytes
of cartridge RAM.

## Documentation

Documentation is organized by responsibility:

- [`compiler/README.md`](compiler/README.md) — language and generated-code model
- [`compiler/ABI.txt`](compiler/ABI.txt) — ABI and data-layout contract
- [`driver/README.md`](driver/README.md) — high-level build driver
- [`assembler/README.md`](assembler/README.md) — syntax, opcodes, directives, and objects
- [`linker/README.md`](linker/README.md) — scripts, placement, stack sizing, and outputs
- [`archiver/README.md`](archiver/README.md) — `.l26` archive operations and format
- [`simulator/README.md`](simulator/README.md) — execution, tracing, and host calls
- [`libraries/runtime/README.md`](libraries/runtime/README.md) — runtime archive construction
- [`libraries/vcs/README.md`](libraries/vcs/README.md) — target bindings and reusable VCS support
- [`examples/README.md`](examples/README.md) — example organization and renderer demonstrations
- [`test/README.md`](test/README.md) — unified test harness

Doxygen input is also available through `make docs`.

## Licensing

The compiler, linker, assembler, archiver, VCSC-written simulator code, driver,
tests, and repository-level build glue are licensed under GPL-3.0-or-later. The
bundled `simulator/mos6502` CPU core is third-party code by Gianluca Ghettini
and is licensed separately under the MIT License; see
`simulator/mos6502/LICENSE.txt`. Everything under `libraries/` and, by default,
`examples/` is covered under CC0-1.0 so cartridge authors may freely reuse that
material. The animated-sprite example at
`examples/03_player_color_192/02_animated_sprites/` is the sole exception and is
covered by its local CC BY-NC-SA 4.0 `LICENSE.txt`. See `COPYING`,
`simulator/mos6502/LICENSE.txt`, `libraries/LICENSE.txt`, and
`examples/LICENSE.txt` for the governing texts.
