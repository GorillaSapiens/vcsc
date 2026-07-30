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
- a matching simulator used by the regression suite;
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
```

The installed tree contains the command-line tools, runtime library, assembler
configuration, and Atari 2600 support files. The driver locates sibling tools
and shared data relative to the common installation prefix, while still
supporting in-tree development builds.

See [`driver/README.md`](driver/README.md) and
[`libraries/runtime/README.md`](libraries/runtime/README.md) for installed
search paths and runtime details.

## Testing

`make test` runs the unified [`test/test.pl`](test/test.pl) harness. The suite
covers compiler diagnostics and code generation, assembler and linker behavior,
linked-program execution, target-library integration, renderer timing, and
source-tree hygiene.

Run selected tests directly from `test/`, for example:

```sh
cd test
./test.pl inline_function_codegen_test.c26
./test.pl --compile-only default_parameter_direct_cycle_error_test.c26
./test.pl --e2e-only vcs_standard_playercolors.pl
```

See [`test/README.md`](test/README.md) for test metadata, fixtures, filtering,
and runner behavior.

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

Unless a subdirectory says otherwise, the toolchain sources and top-level
build/test glue are licensed under GPL-3.0-or-later. The runtime library under
`libraries/runtime/` is BSD-2-Clause so linking it does not impose the
toolchain's GPL terms on cartridge programs. Exact license texts are in the
repository root and relevant library directories.
