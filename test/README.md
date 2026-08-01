```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Test harness notes

`test/test.pl` is the single test runner for this tree.

It runs three kinds of files:

- `.c26` source tests ... compiler-only checks by default, or full end-to-end `vcsc-cc1 -> vcsc-as -> vcsc-ld -> vcsc-sim` when the header requests link/sim behavior
- metadata-bearing `.pl` tests ... self-contained Perl drivers discovered and run directly by `test.pl`
- `.test` files ... generic non-Perl command wrappers and runner-harness fixtures driven entirely by header comments

## Editable examples versus golden fixtures

Everything under `examples/` is user-facing and deliberately editable. The
suite smoke-builds all examples through `vcs_examples_build.pl`, but exact
ROM, map, timing, raster, palette, music, score, and motion assertions use
private cartridges under `test/fixtures/vcs_examples/`. Do not point a golden
harness back at an example; `source_tree_hygiene.pl` rejects that coupling.

## Peephole optimizer coverage

`peephole_unit.pl` feeds generated-assembly fragments directly to the optimizer,
requires disabled mode to preserve the candidate patterns, and requires every
canonical rewrite kind to fire in at least one positive regression.
`peephole_source_toggle.pl` compiles a private ordinary `.c26` fixture twice:
`-fno-peephole` must expose every pattern the current compiler emits, while the
default pass must remove those patterns and report their rewrite names. It also
checks that the driver and direct compiler produce identical disabled output.
`peephole_inline_asm_codegen.pl` places optimization-shaped instruction
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

`unicode_identifier_mangle.pl` is a focused stage test for UTF-8 identifiers. It verifies lexer-level malformed UTF-8 rejection, readable `?uXXXX?` symbol escaping in generated assembly, assembler/linker acceptance, and simulator execution.

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

`discard_store_codegen_test.c26` and `discard_result_codegen_test.c26`
cover the dedicated lone-underscore discard token. It locks direct `WSYNC := _` lowering to a bare `STA`, verifies
that `_ := expression` preserves calls and other evaluation, and confirms that
longer identifiers containing underscores remain ordinary names. Companion
rejection tests require assignment-from-discard targets to be one-byte,
non-bitfield lvalues. `e2e_discard_assignment_verify.c26` verifies the bare-A
store and discarded-expression side effects in the simulator.

`assign_expr_value_codegen_test.c26`,
`assign_expr_condition_codegen_test.c26`, and
`vcs_write_only_chained_assignment_codegen_test.c26` verify that a valued
simple assignment forwards the converted right-hand value instead of reading
the destination back. The VCS case covers two- and three-target write-only TIA
chains plus a split read/write `ref`, and forbids reads from every inner
register. It also requires direct byte chains to contain neither compiler
scratch nor Y traffic. `assignment_chain_shared_scratch_codegen_test.c26`
requires a wider three-target chain to use one shared value slot and direct
symbol stores rather than nested scratch objects or pointer setup.
`e2e_assign_expr_verify.c26` also checks that narrowing happens once at the
inner target and that the narrowed value is what the outer target sees.

`integer_trivial_codegen_test.c26` and
`e2e_integer_trivial_optimizations_verify.c26` cover zero/one identities,
annihilators, positive oversized divisors, compound assignments, signed and
unsigned boundaries, and preservation of operand evaluation. The matching BCD
coverage in `bcd_good_stuff_codegen_test.c26`,
`bcd_good_stuff_static_codegen_test.c26`, and
`e2e_bcd_good_stuff_verify.c26` covers `% 2`, `% 5`, two-term decimal
shift/add/subtract multipliers, fused digit extraction/repositioning, truncation,
wraparound, compound forms, and function-call evaluation counts. Companion
rejection tests retain unsupported general constants such as multiplication by
`3`, division by `20`, and remainder by `25`.

`vcs_standard_renderer_contract.pl` enforces the source contract for
the first minimal unbanked 4K NTSC standard-renderer module. It checks the
80-byte mandatory state span, the required ROM playfield, the documented
frame/clobber/page contract, the weak end-of-frame overscan hook, its exported
call-graph edge, the four-byte supplementary assembly-stack reserve, the linker
map and generated symbols, rejection of `callstack_extra` without call-graph
sizing, clean mutable-playfield RAM exhaustion, and the 4096-byte ROM smoke
cartridge.

`vcs_standard_renderer_normalization.pl` enforces deterministic renderer-source
normalization. It regenerates the selected source beside the checked-in outputs
and requires byte identity, checks all five deliberate macro ports and the
selected DASM transformations, requires the legal `AND`/`LSR`,
`TXA`/`ADC`/`TAX`, and `BIT` replacements, assembles the resulting renderer
without unofficial-opcode mode, verifies its segment map and score table, and
assembles a smoke source that invokes every retained macro.

`vcs_standard_renderer_legal_bytes.pl` builds the complete static profile
without `--illegals`, decodes all seven linked executable segments against the
151 official NMOS 6502 opcodes, and skips only the profile's two explicitly
located lookup-table ranges. A second build injects raw `op4B #$F0`; assembly
and linking still succeed, but the linked-byte gate must reject the unofficial
instruction byte.

`vcs_standard_renderer_legal_schedule.pl` executes the complete static-renderer
cartridge and locks the legal packed-mask schedule across 46 steady-state
scanlines, including the alternate ball phase at each playfield-row transition.
It also checks the five exact final-row bytes precomputed during VBLANK, covering
all former `DCP` families even when the static scene exits before the P0/M0 half.

`vcs_six_glyph_component.pl` builds independent centered-score instances with
distinct values in both draw orders, a widely spaced score-only pair at raw
scanlines 70 and 180, and a centered score immediately after the hostile poison
component. The exact raster harness decodes all six GRP pipeline bytes on every
row into 48 logical pixels, locks positioning and boundary cycles, requires the
cycle-equivalent REFP0/REFP1 reset, and retains exact 262-line frames.

`vcs_score_composition_raster.pl` locks the complete public composition
matrix: four 181-line gameplay families, four production score layouts plus the
poison diagnostic, and both legal orders. It generates static and moving-game
fixtures for all 40 pairings, builds 80 cartridges, and runs the score and
gameplay physical-pixel models on each one. It also builds all 32 real public production cartridges and locks the
player-color and all-five diagonal playfield bytes and write cycles, so final-link
page placement cannot reintroduce scanline tearing.
The score oracle locks centered,
left-, right-, two-plus-two, and poison positioning/ownership schedules at raw
line 40 or 221; the gameplay oracles lock every object pixel and exact 262-line
frames. A separate score-only cartridge places centered, left, right, and
two-plus-two instances at raw lines 50, 80, 110, and 140 to prove mixed arbitrary
vertical placement.

`vcs_two_plus_two_score.pl` builds two independent left/right two-plus-two
score instances with distinct packed-BCD values, colors, and X positions. The
top pair remains fixed at raw line 40; the bottom pair enters at raw line 221
and moves only through its own instance position variables. An independent
6502/TIA oracle checks the calibrated RESP/HMP/HMOVE transactions, spaced 3x8
glyph bytes doubled into exact 12-pixel digits with a two-pixel gap, per-player colors, final-copy
latching and cleanup, deliberately hostile reflection/VDEL/graphics and
missile/Ball motion input, all four motion endpoints, and exact 262-line frames.

`vcs_public_score_controls.pl` inventories all 16 public left/right six-digit
examples and all eight public two-plus-two examples. It runs representative
left- and right-justified cartridges through the established filtered
right-joystick control oracle, including hue changes, and drives right fire in a
two-plus-two cartridge to prove visible field selection, independent motion and
packed-BCD changes for both fields, and the right field's full X=144 endpoint.

`vcs_fingerprint.pl` builds the private fingerprint cartridge, verifies the
CRC and unstable-ARR probe contract, checks the Whimsey and logo font tables in
ROM, and locks three six-glyph entries: right-justified at raw scanline 40,
centered at 131, and left-justified at 221. Both edge components use fixed
packed BCD `012345` with their pointers redirected to the six VCSC-logo slices.
The harness locks the separate RESP/HMOVE phases and late GRP-write windows while
the complete cartridge retains its 262-line frame period.

`vcs_multicolor_examples.pl` builds the four public interactive renderer
cartridges: faithful legacy, scoreless 192-line, 181-line score-above, and
181-line score-below. Its 6502 harness presents idle/pressed console inputs and
checks one-unit P0/P1/Ball motion, held-SELECT suppression, complete X/Y endpoint
clamps, twentieth-frame right-joystick sampling, two-consecutive-sample filtering,
held-input repetition at the sample cadence, selected-digit score-color cycling,
decimal `10^n` score changes, exact normal frame periods, and reset-vector state
restoration. It also requires the faithful demo to opt into the same human
left-to-right packed-BCD digit order used by the eleven-line score components.
The legacy and
192-line initial scenes retain their separate exact sprite/raster checks.

`vcs_player_color_181.pl` and `vcs_player_color_192.pl` require every gameplay
GRP0 and GRP1 handoff, including zero GRP1 transfers, to occur during horizontal
blanking. The 181-line oracle also rejects both failure modes in the Ball
positioning sequence: an immediate `HMCLR` that interrupts the first HMOVE, and
a later HMOVE reached while `HMBL` is still nonzero. `vcs_player_extreme_right.pl` builds both heights with alternating
$AA/$55 checkerboard players at X=159; that pattern exposes the one-bit row swap
that solid glyphs hide at the extreme right edge.

`vcs_all_five_181.pl` and `vcs_all_five_192.pl` build the official five-object
components derived from the proven player-color rasters. They lock the 23-byte
public interfaces, 74-byte and 78-byte total RAM contracts, official-opcode
policy, solid P0/P1 colors, all-five enable activity, exact 181/192 visible-line
contracts, and every playfield pixel across all eleven or twelve 16-line
rows. The all-five timing profile also locks the steady PF1/PF2/PF2/PF1 writes
to cycles 17/24/45/52 on both alternating scanline halves and bounds every
row-transition write, so a two-cycle P1/P0 reflected-half mismatch cannot hide
behind the byte-level raster model. They also reject every late P0/P1 transfer
and every effective M0/M1 enable-state change after horizontal blanking,
covering the same extreme-right row-tearing failure for all five objects. The
192-line regression additionally runs a 360-frame asynchronous fixture through
the independent endpoint oracle: all five VBLANK RESP/HMxx/HMOVE transactions
must match the requested X coordinates, every object must reach X=0 and X=159,
and the clipped player, four-clock missile, and four-clock Ball spans must be
correct at both edges.

`vcs_all_five_composition.pl` builds static and asynchronous score-above and
score-below cartridges around the 181-line component. It requires explicit
component handoff, stable 262-line frames, complete five-object activity, clean
score regions, full-range object motion, restored application Y state, no
immediate `HMCLR` after the non-player HMOVE, and zero M0/M1/Ball fine-motion
values at every later HMOVE. Its endpoint slice now verifies the observed
RESP/HMxx/HMOVE positioning transactions for P0, P1, M0, M1, and Ball in all
360 motion frames, then checks the clipped 160-pixel spans at both horizontal
endpoints for the fixture's player glyphs, four-clock missiles, and four-clock
Ball. The same harness now models GRP0/GRP1 delayed transfers, delayed Ball
latching, immediate missile enables, NUSIZ/CTRLPF widths, and physical
color-clock write timing. It compares all five object layers at every visible
pixel on the setup line and all 181 gameplay lines in both score orders.

`vcs_all_five_181_unofficial.pl` checks the separately named unofficial twin
against the corrected official schedule. It requires identical RAM addresses,
one reviewed zero-page unofficial NOP, no AXS sites, the same physical
modulo-76 playfield profile, pairwise visible-trace identity for all five static
and motion compositions, direct per-pixel object-raster checks for both static
score orders, and the measured 2090/2090-byte result.

`vcs_standard_motion.pl` builds a private copy of the object-motion cartridge
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

`vcs_standard_playercolors.pl` builds the separate no-missile P0+P1+BL
profile and private static/motion fixtures. It checks deterministic normalization,
official-opcode assembly, page and stack contracts, the exact standard frame
period, absence of missile enables, eight distinct logical-row colors for each
player, exact P0/P1/BL raster rows, and 320 frames of full-range P0/P1/BL
RESP/HMxx motion.

`vcs_standard_pairwise.pl` jumps directly into the linked standard renderer's
actual horizontal-position routine and exhausts all `5 choose 2` object pairs
at every `160 * 160` coordinate combination: 256,000 cases. The remaining
three objects stay at distinct sentinel coordinates. Every case requires one
correct RESP strobe and HMxx write per object, the correct divide-by-15
remainder, unchanged public X state, and no cross-object positioning damage.
This provides exhaustive pairwise coverage without spending 256,000 complete
television frames.

`assembler_illegal_alias_catalog.pl` checks that the retained `ASR` and `SBX`
aliases remain active while the broader historical catalog remains commented
out. It covers every DOP/TOP encoding, the unstable `$AB` spellings, both
incompatible XAS dialects, memory-addressed AXS/SAX aliases, and their required
conflict and silicon-warning comments.

`assembler_opcode_override.pl` locks down opcode-config replacement semantics.
It proves that a repeated mnemonic/addressing-mode key is silently last-definition-
wins both within one file and across repeated `--opcode-cfg` options, verifies
that reversing config order reverses the winner, confirms that exact `opXX`
spellings still reach both bytes, and rejects attempts to assign a byte to an
incompatible addressing mode.

`source_tree_hygiene.pl` rejects stranded test/support files, assembler
fixtures absent from the fixture suite, byte-identical duplicate test assets,
duplicate deletion-ledger entries, any deleted path that reappears, displaced
core README files, and broken relative Markdown links.

`vcsc_branding.pl` also enforces the developer-record quarantine:
`.top_secret/context.txt`, `.top_secret/instruction.txt`, `.top_secret/remove.txt`,
and their explanatory README occupy that internal role, while the obsolete
top-level notes and software-stack snapshot must remain absent.

`runtime_workspace_split.pl` verifies that the runtime include imports no
storage unconditionally, that only the five eight-byte-baseline workspace
members remain, and that multiplication, division, and remainder do not select
additional RIOT RAM.

`fixed_scalar_runtime.pl` verifies that the inherited arbitrary-width copy,
fill, extension, comparison, bitwise, shift, multiplication, division, and
remainder members are gone; that the fixed-width shift/multiply/divide members
are present; that scalar lowering is inline where appropriate; and that objects
wider than four bytes retain a separate aggregate zeroing path.

### `.pl` tests

A runnable Perl test keeps its harness metadata in the leading comment block
after the shebang. The driver is therefore both the test implementation and its
manifest; no same-named `.test` forwarding file is needed:

```perl
#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: linker reports occupied and free RAM bytes
# expectexit: 0

use strict;
use warnings;
```

Only `.pl` files with a recognized runner header are discovered as tests. Other
Perl files remain ordinary support scripts. `source_tree_hygiene.pl` rejects a
`.test` file whose only purpose is to invoke a same-named `.pl` driver.

### `.test` files

`.test` remains appropriate for a generic non-Perl command or for a test of the
runner itself:

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
harness through `test/assembler_fixture_suite.pl`. Some fixtures are
intentionally invalid and verify assembler diagnostics.

- `driver_version_format.pl` verifies that `vcsc -V` aligns tool-name colons and prints the resolved executable path for each tool.
- `driver_temp_cleanup.pl` forces a post-compilation linker failure and verifies that the driver removes its private `vcsc.*` directory and intermediates on the failing exit path.

`linker_ram_usage.pl` links a fixture with a known activation overlay and
three-deep call graph. It requires terminal and map-file RAM accounting to
report unique object bytes, the separately identified hardware-stack reserve,
combined used bytes, and physical free bytes exactly.

`vcs_poison_debug_score.pl` builds the installed adversarial score-profile
component, checks zero instance RAM, all intended hostile TIA writes, exactly
11 WSYNC stores, the red-background sentinel, prohibited frame/timer ownership,
and stable 262-line standalone scheduling.

`vcs_visible_component_handoff.pl` locks the machine-readable draw-entry,
return, whole/partial-line, terminal-WSYNC, HMOVE-count, and successor-on-return-
line fields for all twelve maintained visible components. It cross-checks each
published HMOVE count against the actual draw body, requires the final WSYNC,
rejects scheduler/audio ownership, verifies the three-cycle bridge, requires every
production six-glyph component to clear hostile reflection in its preserved
eight-cycle setup slot, and requires the complete TIA ownership/exit-state table
in the installed conversion report.


`vcs_poison_player_color_handoff.pl` composes the poison debug score above
and below the 181-line player-color component and leaves the 192-line scoreless
component under hostile state from the previous overscan. It requires stable
262-line scheduling and the existing P0/P1/Ball register/color raster in all
three cases. The player-color 181/192 harnesses now add a full physical-scanline
object model: delayed P0/Ball transfers, immediate P1, forbidden missiles,
NUSIZ/CTRLPF widths, setup lines, every gameplay line, and terminal paths are
compared pixel by pixel. Official and unofficial 181-line score compositions
run the same model directly.

## Stella linker sidecars

`linker_stella_sidecars.pl` verifies that every successful link normally emits
same-stem `.map`, `.sym`, `.lst`, and DiStella `.cfg` files. It checks final ROM
and RAM symbols, DASM-compatible list rows, generated CODE/DATA ranges, custom
output names, per-sidecar disable switches, high-level driver passthrough, and
protection against overwriting a same-stem linker script. ROM-specific Stella
`.script` files remain user-owned and are intentionally not generated.
