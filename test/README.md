# Test harness notes

`test/test.pl` is the single test runner for this tree.

It runs two kinds of files:

- `.n` source tests ... compiler-only checks by default, or full end-to-end `n65c -> n65asm -> n65ld -> n65sim` when the header requests link/sim behavior
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
./test.pl operator_overloading_rejected_test.n
./test.pl exactops_rejected_test.n e2e_call_argument_order_verify.n
./test.pl .
```

The runner does not stop at the first failure. It prints per-test progress and summarizes all failures at the end.

## Header-driven behavior

The harness reads leading comment lines from each test file.

### `.n` tests

Most `.n` tests use the first header line to describe the compile command, for example:

```n
// n65c -I .
```

Useful expectations include:

- `expectasm:` / `expectasmordered:` / `forbidasm:` ... search the emitted assembly
- `expecterr:` / `forbiderr:` ... search compiler stderr
- `expectfail` ... compilation should fail
- `expectexit:` ... run the full e2e pipeline and require a simulator exit code
- `archive:` / `archivegroup:` / `object:` ... extra link inputs for e2e cases
- `linkcfg:` / `simcfg:` / `simargs:` ... linker and simulator extras
- `phase: compile|e2e|any` ... force how the runner classifies the test

A plain `.n` file with only compile-side expectations is treated as a compile-only test. A `.n` file with link/sim expectations is treated as an e2e test.

E2E tests without a `linkcfg:` directive use `test/generic_6502.cfg`, an
explicit test-only layout matching the retained generic simulator fixtures.
Production `n65ld` has no implicit layout, and production `n65cc` defaults to
the bundled VCS 4K script instead.

`unicode_identifier_mangle.test` is a focused stage test for UTF-8 identifiers. It verifies lexer-level malformed UTF-8 rejection, readable `?uXXXX?` symbol escaping in generated assembly, assembler/linker acceptance, and simulator execution.

### `.test` files

Generic tests use an explicit runner command:

```text
# runner: n65asm --illegals --hex=@TMP@/rich.hex @TEST_ROOT@/assembler_rich_opcode_smoke.s
# expectstdout: wrote
# expectexit: 0
```

Useful placeholders in `runner:` and related directives:

- `@REPO@` ... repository root
- `@TEST_ROOT@` ... `test/` directory
- `@FILE@` ... current test file
- `@FILEDIR@` ... directory containing the current test file
- `@TMP@` ... per-test temporary work directory
- `@NLIB@` ... default `libraries/nlib/nlib.a65`
- `@NLIB_INC@` ... default `libraries/nlib/` include directory
- `@GENERIC_LINK_CFG@` ... explicit test-only generic 6502 linker layout

Useful generic expectations include:

- `expectstdout:` / `expectstdoutordered:` / `forbidstdout:`
- `expectstderr:` / `expectstderrordered:` / `forbidstderr:`
- `expectstdoutexact:` / `expectstderrexact:`
- `expectfile:` / `forbidfile:`
- `expectexit:`

## Assembler fixture sources

`assembler/tests/` contains assembler source fixtures that exercise `n65asm` directly rather than the N compiler. They are part of the normal harness through `test/assembler_fixture_suite.test`.  Some fixtures are intentionally invalid and
verify assembler diagnostics.

- `driver_version_format.test` verifies that `n65cc -V` aligns tool-name colons and prints the resolved executable path for each tool.
