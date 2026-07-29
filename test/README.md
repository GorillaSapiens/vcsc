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

## Editable examples versus golden fixtures

Everything under `examples/` is user-facing and deliberately editable. The
suite smoke-builds all examples through `vcs_examples_build.test`, but exact
ROM, map, timing, raster, palette, music, score, and motion assertions use
private cartridges under `test/fixtures/vcs_examples/`. Do not point a golden
harness back at an example; `source_tree_hygiene.test` rejects that coupling.

## Peephole optimizer coverage

`peephole_unit.test` feeds generated-assembly fragments directly to the optimizer,
requires disabled mode to preserve the candidate patterns, and requires every
canonical rewrite kind to fire in at least one positive regression.
`peephole_source_toggle.test` compiles a private ordinary `.c26` fixture twice:
`-fno-peephole` must expose every pattern the current compiler emits, while the
default pass must remove those patterns and report their rewrite names. It also
checks that the driver and direct compiler produce identical disabled output.
`peephole_inline_asm_codegen.test` places optimization-shaped instruction
sequences inside source `asm` statements and requires the exact sequence to
survive unchanged with the pass both enabled and disabled.

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

`bcd_power_of_ten_codegen_test.c26` and
`e2e_bcd_power_of_ten_verify.c26` cover inline packed-BCD `*`, `/`, `%`, `*=`,
`/=`, and `%=` lowering for constant powers of ten across `bcd8_t` through
`bcd32_t`. They lock odd-nibble shifts and masks, even whole-byte moves,
constant-expression divisors, reversed multiplication, width overflow/truncation,
and the absence of general multiply/divide helpers or decimal-mode entry.
Companion rejection tests keep non-power-of-ten operands unsupported.

`vcs_standard_renderer_contract.test` enforces the source contract for
the first minimal unbanked 4K NTSC standard-renderer module. It checks the
80-byte mandatory state span, the required ROM playfield, the documented
frame/clobber/page contract, the weak end-of-frame overscan hook, its exported
call-graph edge, the four-byte supplementary assembly-stack reserve, the linker
map and generated symbols, rejection of `callstack_extra` without call-graph
sizing, clean mutable-playfield RAM exhaustion, and the 4096-byte ROM smoke
cartridge.

`vcs_standard_renderer_normalization.test` enforces deterministic renderer-source
normalization. It regenerates the selected source beside the checked-in outputs
and requires byte identity, checks all five deliberate macro ports and the
selected DASM transformations, requires the legal `AND`/`LSR`,
`TXA`/`ADC`/`TAX`, and `BIT` replacements, assembles the resulting renderer
without unofficial-opcode mode, verifies its segment map and score table, and
assembles a smoke source that invokes every retained macro.

`vcs_standard_renderer_legal_bytes.test` builds the complete static profile
without `--illegals`, decodes all seven linked executable segments against the
151 official NMOS 6502 opcodes, and skips only the profile's two explicitly
located lookup-table ranges. A second build injects raw `op4B #$F0`; assembly
and linking still succeed, but the linked-byte gate must reject the unofficial
instruction byte.

`vcs_standard_renderer_legal_schedule.test` executes the complete static-renderer
cartridge and locks the legal packed-mask schedule across 46 steady-state
scanlines, including the alternate ball phase at each playfield-row transition.
It also checks the five exact final-row bytes precomputed during VBLANK, covering
all former `DCP` families even when the static scene exits before the P0/M0 half.

`vcs_standard_motion.test` builds a private copy of the object-motion cartridge
under `test/fixtures/vcs_examples/` and runs it for 320 frames in the 6502
harness. The motion update runs only through a
strong `vcs_standard_overscan_hook`; the test proves that it overrides the weak
fallback, that the assembly edge extends stack/activation planning, and that the
fixed frame period is unchanged. It locks every object's persistent Y
coordinate, the differently phased and paced P0/P1/M0/M1/BL X sequences, both
X=0 and X=159 endpoints for every object, and seven complete object rasters at
exact frame-relative scanlines. This catches corrupt
packed masks, state lost through horizontal-position scratch reuse, and any
whole-frame vertical displacement that instruction-level cycle tests miss.

`vcs_standard_playercolors.test` builds the separate no-missile P0+P1+BL
profile and private static/motion fixtures. It checks deterministic normalization,
official-opcode assembly, page and stack contracts, the exact standard frame
period, absence of missile enables, eight distinct logical-row colors for each
player, exact P0/P1/BL raster rows, and 320 frames of full-range P0/P1/BL
RESP/HMxx motion.

`vcs_standard_pairwise.test` jumps directly into the linked standard renderer's
actual horizontal-position routine and exhausts all `5 choose 2` object pairs
at every `160 * 160` coordinate combination: 256,000 cases. The remaining
three objects stay at distinct sentinel coordinates. Every case requires one
correct RESP strobe and HMxx write per object, the correct divide-by-15
remainder, unchanged public X state, and no cross-object positioning damage.
This provides exhaustive pairwise coverage without spending 256,000 complete
television frames.

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

`source_tree_hygiene.test` rejects stranded test/support files, assembler
fixtures absent from the fixture suite, byte-identical duplicate test assets,
duplicate deletion-ledger entries, any deleted path that reappears, displaced
core README files, and broken relative Markdown links.

`vcsc_branding.test` also enforces the developer-record quarantine:
`.top_secret/context.txt`, `.top_secret/instruction.txt`, `.top_secret/remove.txt`,
and their explanatory README occupy that internal role, while the obsolete
top-level notes and software-stack snapshot must remain absent.

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
# runner: vcsc-as --illegals --hex=@TMP@/rich.hex @TEST_ROOT@/assembler_rich_opcode_smoke.s26
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

`linker_ram_usage.test` links a fixture with a known activation overlay and
three-deep call graph. It requires terminal and map-file RAM accounting to
report unique object bytes, the separately identified hardware-stack reserve,
combined used bytes, and physical free bytes exactly.

`vcs_poison_debug_score.test` builds the installed adversarial score-profile
component, checks zero instance RAM, all intended hostile TIA writes, exactly
11 WSYNC stores, the red-background sentinel, prohibited frame/timer ownership,
and stable 262-line standalone scheduling.


`vcs_poison_player_color_handoff.test` composes the poison debug score above
and below the 181-line player-color component and leaves the 192-line scoreless
component under hostile state from the previous overscan. It requires stable
262-line scheduling and the existing P0/P1/Ball register/color raster in all
three cases. It also deliberately records the remaining stop-ship gap: the
score-above path still performs gameplay positioning before the poison renderer
and has no post-score RESP/HMxx/HMOVE restoration. This is a diagnostic probe,
not the unfinished full object-pixel oracle.
