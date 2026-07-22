```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Test harness notes

`test/test.pl` is the single test runner for this tree.

It runs two kinds of files:

- `.c26` source tests ... compiler-only checks by default, or full end-to-end `vcsc-cc1 -> vcsc-as -> vcsc-ld -> vcsc-sim` when the header requests link/sim behavior
- `.test` script-style tests ... generic command wrappers driven entirely by header comments

## Common usage

Run the whole suite from `test/`:

```sh
./test.pl
```

Run only compile-side checks:

```sh
./test.pl --compile-only
```

Run only end-to-end and generic runtime tests:

```sh
./test.pl --e2e-only
```

Run one test, a few tests, or a whole subdirectory:

```sh
./test.pl inline_function_codegen_test.c26
./test.pl default_parameter_direct_cycle_error_test.c26 e2e_call_argument_order_verify.c26
./test.pl .
```

The runner does not stop at the first failure. It prints per-test progress and summarizes all failures at the end.

## Header-driven behavior

The harness reads leading comment lines from each test file.

### `.c26` tests

Most `.c26` tests use the first header line to describe the compile command, for example:

```vcsc
// vcsc-cc1 -I .
```

Useful expectations include:

- `expectasm:` / `expectasmordered:` / `forbidasm:` ... search the emitted assembly
- `expecterr:` / `forbiderr:` ... search compiler stderr
- `expectfail` ... compilation should fail
- `expectexit:` ... run the full e2e pipeline and require a simulator exit code
- `archive:` / `archivegroup:` / `object:` ... extra link inputs for e2e cases
- `linkcfg:` / `simcfg:` / `simargs:` ... linker and simulator extras
- `phase: compile|e2e|any` ... force how the runner classifies the test

A plain `.c26` file with only compile-side expectations is treated as a compile-only test. A `.c26` file with link/sim expectations is treated as an e2e test.

E2E tests without a `linkcfg:` directive use `test/generic_6502.cfg`, an
explicit test-only layout matching the retained generic simulator fixtures.
Production `vcsc-ld` has no implicit layout, and production `vcsc` defaults to
the bundled VCS 4K script instead.

`unicode_identifier_mangle.test` is a focused stage test for UTF-8 identifiers. It verifies lexer-level malformed UTF-8 rejection, readable `?uXXXX?` symbol escaping in generated assembly, assembler/linker acceptance, and simulator execution.

`visual_binary_literal_codegen_test.c26` and
`e2e_visual_binary_literal_verify.c26` cover `.`/`X` binary-picture notation,
mixed visual/conventional digits, underscores, wider values, preprocessor use,
and runtime values. Companion rejection tests cover bad digits, malformed
underscores, and width overflow after normalization.

`vcs_standard_kernel_contract.test` enforces the source contract for
the first minimal unbanked 4K NTSC standard-kernel module. It checks the
80-byte mandatory state span, the required ROM playfield, the documented
frame/clobber/page contract, the six-byte hidden assembly-stack reserve, the
linker map and generated symbols, rejection of `callstack_extra` without
call-graph sizing, clean mutable-playfield RAM exhaustion, and the 4096-byte ROM
smoke cartridge.

`vcs_standard_kernel_normalization.test` enforces deterministic kernel-source
normalization. It regenerates the selected source beside the checked-in outputs and requires byte identity,
checks all five deliberate macro ports and the selected DASM transformations,
requires the retained `ASR` and `SBX` spellings to survive normalization,
assembles the resulting kernel to current `.o26` with `--illegals`, verifies its
segment map and score table, rejects assembly without unofficial mnemonics, and
assembles a smoke source that invokes every retained macro.

`vcs_standard_kernel_legal_schedule.test` executes the complete static-kernel
cartridge and locks the legal packed-mask schedule across 46 steady-state
scanlines, including the alternate ball phase at each playfield-row transition.
It also checks the five exact final-row bytes precomputed during VBLANK, covering
all former `DCP` families even when the static scene exits before the P0/M0 half.

`vcs_standard_motion.test` builds `examples/06_object_motion_test` and runs it
for twenty frames in the 6502 harness. It locks every object's persistent Y
coordinate, the independently phased P0/P1/M0/M1/BL X sequence, and seven
complete object rasters at exact frame-relative scanlines. This catches corrupt
packed masks, state lost through horizontal-position scratch reuse, and any
whole-frame vertical displacement that instruction-level cycle tests miss.

`assembler_illegal_alias_catalog.test` checks that the retained `ASR` and `SBX`
aliases remain active while the broader historical catalog remains commented
out. It covers every DOP/TOP encoding, the unstable `$AB` spellings, both
incompatible XAS dialects, memory-addressed AXS/SAX aliases, and their required
conflict and silicon-warning comments.

`assembler_opcode_override.test` locks down opcode-config replacement semantics.
It proves that a repeated mnemonic/addressing-mode key is silently last-definition-
wins both within one file and across repeated `--opcode-cfg` options, verifies
that reversing config order reverses the winner, confirms that exact `opXX`
spellings still reach both bytes, and rejects attempts to assign a byte to an
incompatible addressing mode.

`vcsc_branding.test` also enforces the developer-record quarantine: only
`.top_secret/context.txt`, `.top_secret/remove.txt`, and their explanatory
README may occupy that internal role, while the obsolete top-level notes and
software-stack snapshot must remain absent.

`runtime_workspace_split.test` verifies that the runtime include imports no
storage unconditionally, that only the five eight-byte-baseline workspace
members remain, and that multiplication, division, and remainder do not select
additional RIOT RAM.

`fixed_scalar_runtime.test` verifies that the inherited arbitrary-width copy,
fill, extension, comparison, bitwise, shift, multiplication, division, and
remainder members are gone; that the fixed-width shift/multiply/divide members
are present; that scalar lowering is inline where appropriate; and that objects
wider than four bytes retain a separate aggregate zeroing path.

### `.test` files

Generic tests use an explicit runner command:

```text
# runner: vcsc-as --illegals --hex=@TMP@/rich.hex @TEST_ROOT@/assembler_rich_opcode_smoke.s
# expectstdout: wrote
# expectexit: 0
```

Useful placeholders in `runner:` and related directives:

- `@REPO@` ... repository root
- `@TEST_ROOT@` ... `test/` directory
- `@FILE@` ... current test file
- `@FILEDIR@` ... directory containing the current test file
- `@TMP@` ... per-test temporary work directory
- `@RUNTIME@` ... default `libraries/runtime/libvcsc.l26`
- `@RUNTIME_INC@` ... default `libraries/runtime/` include directory
- `@GENERIC_LINK_CFG@` ... explicit test-only generic 6502 linker layout

Useful generic expectations include:

- `expectstdout:` / `expectstdoutordered:` / `forbidstdout:`
- `expectstderr:` / `expectstderrordered:` / `forbidstderr:`
- `expectstdoutexact:` / `expectstderrexact:`
- `expectfile:` / `forbidfile:`
- `expectexit:`

## Assembler fixture sources

`assembler/tests/` contains assembler source fixtures that exercise `vcsc-as`
directly rather than passing through `vcsc-cc1`. They are part of the normal
harness through `test/assembler_fixture_suite.test`. Some fixtures are
intentionally invalid and verify assembler diagnostics.

- `driver_version_format.test` verifies that `vcsc -V` aligns tool-name colons and prints the resolved executable path for each tool.
- `driver_temp_cleanup.test` forces a post-compilation linker failure and verifies that the driver removes its private `vcsc.*` directory and intermediates on the failing exit path.
