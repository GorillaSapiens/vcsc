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
suite smoke-builds all examples through eight `vcs_examples_build_*of8.test`
shards backed by `vcs_examples_build.pl`; the round-robin split lets the outer
`test.pl --jobs N` pool compile different examples concurrently without a nested
worker pool. Every ROM produced by those shards is also passed through
`vcsc-disas -> vcsc-as` and must reconstruct byte-for-byte, so the editable
example suite doubles as a continuously maintained disassembler corpus. Exact
ROM, map, timing, raster, palette, music, score, and motion
assertions use private cartridges under `test/fixtures/vcs_examples/`. Do not
point a golden harness back at an example; `source_tree_hygiene.pl` rejects that
coupling.

## Item-31 single-callsite analysis coverage

`inline_analysis_unit.pl` compiles the standalone optimizer-analysis module with
a tiny C harness and locks call-occurrence counting independently of the rest of
the compiler. In particular, two calls from one caller count as two call sites,
while separate callees called once each remain independent candidates. It also
checks defined/internal/source-inline baseline flags, late registration, reset,
and retention of the exact unique caller and source call-expression identity.
`inline_analysis_codegen_test.c26` exercises the same bookkeeping through the
real compiler with the debug-only `-X inlineplan` trace, covering zero, one, and
multiple ordinary direct calls plus the exported-function veto.

`inline_ref_specialization.pl` covers subsection 1's compile-side single-callsite
`ref` specialization: regular/const/writeonly refs, ordinary and zero-page
actuals, split read/write aliases, fixed members and constant array indexes,
runtime-index fallback, and the conservative inline-assembly escape veto.
`inline_ref_specialization_e2e.pl` links and simulates representative accepted
and fallback cases, proves specialized ref activation slots disappear from the
map, and verifies zero-page and split-address direct opcodes in the final image.
`inline_value_specialization.pl` covers subsection 2's readonly by-value
specialization: explicit and inferred readonly formals, literal binding, direct
caller-storage binding, compound constant-bound `if`/ternary/loop pruning,
post-pruning effective-callsite fixed points, and the conservative
write/address/alias/type-conversion fallbacks.
`inline_value_specialization_e2e.pl` links and simulates accepted and rejected
cases and proves a safe one-byte formal disappears from activation RAM while the
matched address-escaped fallback keeps its by-value copy.

`optimizer_inline_ir.pl` covers subsection 3's ordinary-function control-flow
expansion mechanism under the debug-only `-X inlineir` forcing switch. It checks
that standalone procedures/JSRs disappear, nested one-call chains expand, locals
and multi-return labels remain distinct, and inline-assembly candidates stay
separate. `optimizer_inline_ir_e2e.pl` links and simulates normal and forced forms,
including copied mutable parameters, early returns, an ordinary call nested in an
inlined body, sibling activation overlay, peak activation RAM, and reduced hardware
call-stack depth. `optimizer_inline_legality.pl` covers subsection 4's
caller-aware placement gate: hard function `page` containment, named code/result
regions, direct and source-inline-transitive `.same`/`.cross` policy, a `.flex`
non-veto, and page-contained data that remains independently placed.
`optimizer_inline_legality_e2e.pl` links and simulates the forced form, verifies
final same/cross branch policy, and carries a hard-page fixture that would exceed
256 bytes if its retained target were expanded. `align_function_error_test.c26`
locks the language-level function-alignment rejection.

`inline_profit_metrics_unit.pl` covers subsection 5's final-link metric parser and
decision rule independently of the driver: summed cartridge ROM, activation/object
RAM, hardware-stack reserve, ROM win/loss, equal-ROM stack win, and rejection of
an unexpected activation-overlay regression. `optimizer_inline_profit_e2e.pl` runs
the real driver/linker trial loop. It proves a natural `main -> middle(4) -> leaf(x)`
chain propagates its readonly constant binding, accepts both profitable inlines for
an exact eight-byte final-ROM win with unchanged object RAM and lower hardware
stack, while a legal multi-return candidate is measured larger and retained. The
profitability loop is explicitly enabled with `-finline-profit`; ordinary builds
keep the automatic parameter-specialization gains without paying for speculative
final links. `optimizer_inline_identity.pl` covers subsection 6's
identity vetoes: exported/source-inline definitions, merged declaration contracts,
inline-assembly bodies, exact callable-symbol escapes, and ABI-family assembly escapes
such as `function$parameter`. `optimizer_inline_reachability_e2e.pl` covers safe dead
internal-function removal, post-specialization constant-branch reachability, exported
and contract roots, assembly roots, runtime-global-initializer roots, and verifies that
the driver's validation pass does not let dead pruning hide assembler diagnostics.

## Peephole optimizer coverage

`peephole_unit.pl` feeds generated-assembly fragments directly to the optimizer,
requires disabled mode to preserve the candidate patterns, and requires every
canonical rewrite kind to fire in at least one positive regression.
`peephole_source_toggle.pl` compiles a private ordinary `.c26` fixture twice:
`-fno-peephole` must expose every pattern the current compiler emits, while the
default pass must remove those patterns and report their rewrite names. It includes
the timing-scoped conditional-branch/`JMP` inversion added for pure generated
procedures and checks that the driver and direct compiler produce identical disabled
output. `peephole_unit.pl` separately proves that the same inversion is refused when
inline assembly makes procedure timing opaque.
`peephole_inline_asm_codegen.pl` places optimization-shaped instruction
sequences inside source `asm` statements and requires the exact sequence to
survive unchanged with the pass both enabled and disabled.

## Common usage

Run the whole suite from `test/`:

```sh
./test.pl
```

Run independent test cases in parallel with `--jobs N`:

```sh
./test.pl --jobs 8
```

The top-level Makefile exposes the same setting as `TEST_JOBS`:

```sh
make test
```

Parallelism is at the whole-test-case level. Each E2E/generic case keeps its
own temporary directory, and results are buffered so progress and failure
reporting remain in the same deterministic source order as a serial run. Large
batch-style E2Es should be split into independently schedulable `.test` shards
rather than starting their own nested worker pools; the example smoke build and
score-composition raster matrix follow that pattern. `TEST_JOBS` defaults to 8,
so normal `make test` runs eight cases in parallel. Use
`make test TEST_JOBS=1` when a serial run is useful for debugging.

The Makefiles also write a separate tab-separated timing report. From the
repository root, plain `make test` writes `test-times.tsv`; each row records the
elapsed wall-clock seconds measured inside the worker, pass/fail status, phase,
and test name:

```text
seconds status  phase   test
0.018427        pass    compile example_test.c26
7.392115        pass    e2e     vcs_paddleball.pl
```

(The actual file uses tabs, not spaces.) Set `TEST_TIMINGS=/path/to/file.tsv` to
choose another filename. Direct runner invocations can use `--timings FILE`;
`--timings-append` appends rows without repeating the header and is used by the
Makefile to combine its compile and E2E phases into one report.

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
Tests without an explicit `timeout:` header use a 20-second per-case timeout; long-running cases can override it in their header.

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

`function_mem_region_codegen_test.c26` and
`function_mem_region_placement.pl` cover named `mem` modifiers on functions.
They lock `CODE.bank1.__vcsc_function$NAME` private layouts, exact longest-rule
linker placement, page containment, source/linker region metadata agreement,
ordinary `CODE` restoration, and the Superchip-safe `$D100+$0E00` allocatable
interval. Companion rejection tests cover conflicting declaration/definition
regions, inline placement, and explicit nonzero-bank placement of `main`.
`function_code_result_regions_codegen_test.c26` and
`function_code_result_region_placement.pl` cover the generalized function-region
contract: arbitrary names, order-independent `$ro` code plus `$rw` result
modifiers, ordinary and split result storage, separate CODE/return map entries,
and independent metadata. Companion tests reject duplicate regions, multiple
writable results, and writable storage on `void`. The
`e2e_function_*_region_abi_mismatch_fail` pairs prove that separate-object
code-region and result-region disagreements diagnose different ABI roles.

`function_multiple_code_regions_codegen_test.c26`,
`object_multiple_ro_regions_codegen_test.c26`, and their rejection companions
cover the item-21 source contract: order-insensitive function body sets, one
shared writable result region, immutable object sets, duplicate names,
non-read-only regions, mutable duplication, redeclaration mismatch, and function
pointers remaining unsupported. `replicated_rom_placement.pl` verifies F8SC
bank-local function and object binding, mixed pinned/automatic callers,
independent copy offsets and bytes, a complete `bank0 bank1 cartram` function,
one shared return object, map physical-cost accounting, and the absence of
unnecessary trampolines. `replicated_rom_missing_copy.pl` covers deterministic
object missing-copy errors, function fallback from a bank without a body, and
three-copy F6 placement. `replicated_rom_separate_objects.pl` and the
`e2e_*_replica_region_abi_mismatch_fail` pairs cover separate compilation,
order-insensitive matching, and independent function/object replica-set ABI
mismatches.

`return_local_coalesce_codegen_test.c26` covers straight-line and branched
coalescing for one- through four-byte binary and packed-BCD values, plus safe
by-value use. `return_local_coalesce_split_codegen_test.c26` locks split-address
read/write lowering and absence of a separate local symbol. The fallback test
covers different returned locals, non-variable expressions, explicit `$$`,
address and `ref` escape, type/const mismatch, default-versus-zero-page storage,
and distinct explicit regions with identical numeric addresses.
`return_local_coalescing.pl` verifies caller-visible binary and BCD results,
branched execution, ordinary zero-page and absolute named storage, split-address
runtime aliases, exact one-allocation activation sizes, preserved
`function$__return` symbols, and `RETURN COALESCING` map records.

`readonly_mem_object_codegen_test.c26` locks source-level `$ro` object emission
as `RODATA.region.__vcsc_object$NAME`; companion tests reject mutable definitions
and runtime-only initializers in read-only named regions.

`linker_banked_image_model.pl` covers the first full-window banked-image
foundation. It uses an F8 test cfg with more than sixteen MEMORY and SEGMENTS
entries, verifies dynamic cfg storage, strict unknown-property rejection,
selector-hotspot and generated-vector-corridor reservation in every bank, exact
8K output, VCSC BANK1 as physical/file chunk 0 and VCSC BANK0 as chunk 1,
F8 `$1FF8` selecting the first chunk and `$1FF9` selecting the BANK0/home chunk,
replicated bridge/vector bytes, map file offsets, and byte-for-byte preservation
of a stock `vcs_4k.cfg` fixture.

`cartridge_bank_metadata_codegen_test.c26` locks the exact versioned
compiler metadata for output-wide cartridge properties, direct and selector-
controlled banks, and separate `bank`/`mem` namespaces with the same identifier.
The companion rejection tests cover incomplete bank declarations and unmatched
generated-range offset/size pairs. `linker_c26_cartridge_topology.pl` packages a
two-chunk direct image in explicit file order, checks fill and an ordinary
absolute cross-chunk call with no trampoline section, retains F8 selector and
trampoline behavior through the transitional cfg match, merges identical
separate declarations, and rejects conflicting declarations, duplicate file
indices, and missing selector startup.

`linker_c26_mem_authority.pl` links a direct two-chunk cartridge with an empty
cfg and proves that complete C26 `mem` declarations create allocator regions and
ordinary segment routes. Deliberately mismatched bank and mem names verify
ownership comes from synthetic-range containment. Its F8SC half uses a cfg with
only legacy mapper mechanics, classifies bank ROM as switched and Superchip
aliases as shared, checks direct `$F000/$F080` accesses plus the real cross-bank
trampoline, and requires byte-identical output from the current full cfg. It also
covers cross-object declaration conflicts with both C26 locations and ambiguous
multi-owner containment. The four former `e2e_mem_region_cfg_*_mismatch` cases
now prove stale or missing cfg allocator entries are ignored in favor of C26.

`vcs_c26_cartridge_profiles.pl` certifies the installed 2K, 4K, F8, F6, F4, F8SC,
F6SC, and F4SC C26 profile files against the reduced `vcs.cfg`. It verifies
physical size and file ordering—including the 2048-byte `$F800-$FFFF`
profile—ordinary versus SC mapped spans, selector and startup metadata, shared Superchip ownership, and byte-for-byte equality with
the retained legacy cfg profiles. It also proves that the driver's implicit 4K
profile equals an explicit build, that an explicitly supplied installed profile
resolves sibling includes from its own directory, and that the generic direct
two-chunk profile uses ordinary absolute cross-chunk calls, deterministic fill,
and no selector or trampoline output.

`vcs_interactive_sprite_orientation.pl` keeps every maintained interactive
example visually aligned with the faithful legacy player-color example. It
checks the shared and direct source definitions for the required bottom-to-top
geometry convention, verifies that per-row player colors follow the same visual
rows, and ensures every discovered non-legacy interactive cartridge uses one of those
normalized definitions. The discovery check is intentionally count-free, so adding a
new interactive example automatically brings it under this regression instead of
requiring a magic source-count update. The animated sprite gallery retains its own independent
frame-table convention.

`linker_banked_reset_bridges.pl` builds structural F8, F6, and F4 cartridges,
then models NMI, RESET, and IRQ/BRK vector fetch and bridge execution from every
possible initially selected bank. It locks the common eighteen-byte
`BIT BANK0_HOTSPOT; JMP handler` table, identical BANK0-mirror vector words,
exact 8K/16K/32K image sizes, handler/`main` residency in VCSC BANK0, the
complete logical-bank/file-index/hotspot relationship for all three mappers,
F4's NMI-vector/selector overlap, and diagnostics for missing or
selector-overlapping bridge corridors.

`linker_banked_relocation_validation.pl` covers bank-aware relocation validation
and generated control-transfer bridges. It proves that same-bank code/data and
shared RAM references remain legal; that o26 retains distinct direct `JSR`,
direct `JMP`, and relaxed conditional-branch intent; and that the linker rejects
cross-bank relative and long branches, ROM loads, address constants, pointer
words, low/high-byte relocations, and indirect-`JMP` vectors. It also checks
source-bank mirror patching, deduplication, exact byte-identical eight-byte JMP
and fifteen-byte JSR entries, inline targets, map accounting, corridor
exhaustion, register-preserving nested BANK0 -> BANK1 -> BANK0 calls, LIFO bank
restoration, and balanced hardware-stack returns.

`linker_banked_jsr_callstack.pl` compiles a BANK0 -> BANK1 -> BANK0 source-level
call chain and locks the ordinary depth, weighted hardware-return depth, extra
bridge slots, two-byte-per-active-cross-bank-edge RAM reservation, generated
symbols, and source/destination bridge reporting.

`vcs_f8_profile.pl` certifies the installed `vcs_8k_f8.c26` profile through
the reduced `vcs.cfg`. It compiles the private F8 source diagnostic, locks
BANK1-first/BANK0-last file order, `$1FF8/$1FF9` selector identities, hard and
automatic placement, cross-bank JMP and nested JSR bridges, byte-identical common
corridors, vectors, map output, and exact 8192-byte output. A small opcode model
starts from each possible initially selected file chunk and proves the reset
bridge reaches BANK0 and nested calls restore banks and hardware-stack returns
correctly. Differential coverage retains the legacy `vcs_8k_f8.cfg` only as a
compatibility oracle. `make installcheck` repeats the source build with the
staged installed C26 profile.

`vcs_f6_f4_profiles.pl` certifies the installed `vcs_16k_f6.c26` and
`vcs_32k_f4.c26` profiles through the same C26-topology implementation. It
places a nested call-chain function in every logical bank, starts execution from
every possible initially selected physical chunk, exercises every selector on
the outward and return paths, locks BANK3..BANK0 and BANK7..BANK0 file order,
reserved hotspot bytes, byte-identical trampoline/vector corridors, F4's NMI
vector/hotspot overlap, balanced stack restoration, map identities, and exact
16384/32768-byte output. Retained cfg profiles are used only for differential
and compatibility checks. `make installcheck` also builds staged diagnostics
through both installed C26 profiles.

`linker_banked_auto_placement.pl` covers deterministic roadmap-item-7 placement.
It links the same fixture twice, pins runtime and `main` to BANK0, spills an
unpinned function by capacity, keeps a call-connected function home, collapses a
forbidden ROM-data edge into a hard component, and rejects contradictory pins.
It also compiles a VCSC named `$ro` object, proves the object becomes a pinned
`RODATA.bank1` layout, proves its unpinned reader follows it to BANK1, and checks
that the resulting BANK0 `main` call creates exactly one JSR bridge. Map output
must identify components, pinned/automatic members, concrete regions, byte cost,
and incident cut weight.

`linker_banked_placement_modes.pl` covers roadmap item 29. It proves omitted
mode exactly matches explicit `optimized`, locks the stable `simple` comparison
mode, rejects invalid modes, and checks the detailed explanation trace. One
capacity fixture proves optimized component ordering reduces two JSR bridges to
one and weighted hardware-return depth from 6 to 5. A second fixture forces a
deterministic local move which reduces four JSR bridges to one without changing
explicit pins or increasing weighted depth. A third fixture proves a lower
byte-weight candidate is rejected when it would raise weighted depth from 5 to
7, and requires the explanation to name that reason. Repeated optimized links
must produce byte-identical binaries and maps.

`fp_removed.pl` independently locks that the linker still reserves exactly two
bytes per weighted hardware-return slot (never the obsolete four-byte frame-
pointer-era allowance) and never lets weighted depth fall below ordinary call
depth.

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

`discard_store_codegen_test.c26`, `discard_store_register_transparent_codegen_test.c26`,
`discard_store_chain_codegen_test.c26`, and `discard_result_codegen_test.c26` cover the dedicated lone-underscore
discard token. They lock direct `WSYNC := _` lowering to a bare `STA`, prove that
bare byte-object discard stores across global, zeropage, absolute, and automatic-local
placement emit only `STA` and therefore preserve A/X/Y/S/P, require
`WSYNC := RESP1 := RESP0 := _` to emit three ordered stores with no load,
scratch, or Y traffic, verify that `_ := expression` preserves calls and other
evaluation, and confirm that longer identifiers containing underscores remain
ordinary names. Companion rejection tests require assignment-from-discard
targets to be one-byte non-bitfield lvalues and require chained targets to be
directly addressable so every store preserves A without hidden stack traffic.
`e2e_discard_assignment_verify.c26` verifies that one incoming A value reaches
all three targets and that discarded-expression side effects remain intact.

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

`assembler_component_constraints.pl` exercises generic assembly-component
metadata: startup or named-region placement, final power-of-two alignment,
object-private routes, hidden hardware-stack bytes, map reporting, and assembly
or link rejection of malformed/conflicting records.

`vcs_standard_renderer_contract.pl` enforces the source contract for
the first minimal unbanked 4K NTSC standard-renderer module. It checks the
80-byte mandatory state span, required ROM playfield, documented
frame/clobber/page contract, weak end-of-frame overscan hook and exported call
edge, object-owned region/alignment/private-route metadata, the four-byte
`.callstackextra` reserve, map symbols, conflict diagnostics, and clean mutable-
playfield RAM exhaustion. It also proves byte identity between the new generic
4K component-owned build, the deprecated compatibility cfg, and a reconstructed
pre-item-27 cfg with metadata stripped from the renderer object.

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

`vcs_six_glyph_wide.pl` builds the separate widely spaced score profile, locks
its X=36,52,68,84,100,116 origin contract, exact cycle 0/8/31/36/42/48 GRP
schedule, packed-BCD row bytes, 262-line frame, 18-byte mutable-color component-owned RAM
layout, public 2K example accounting, and reviewed Stella 7.0 RGB oracle. The
optional `vcs_six_glyph_wide_stella.pl` regenerates the emulator snapshot and
compares decoded RGB pixels with that checked-in oracle. It also hashes the
centered component so the wide profile cannot silently alter its predecessor.

`vcs_six_glyph_component.pl` builds independent centered-score instances with
distinct values in both draw orders, a widely spaced score-only pair at raw
scanlines 70 and 180, and centered fixed/mutable-color scores immediately after
the hostile poison component. It locks the merged component's compact default,
optional mutable color byte, and `compact_font:=0` six-pointer compatibility mode.
The exact raster harness decodes all six GRP pipeline bytes on every row into 48
logical pixels, locks positioning and boundary cycles, requires the cycle-equivalent
REFP0/REFP1 reset, and retains exact 262-line frames.

`vcs_score_composition_raster.pl` is the shared implementation behind four
family-level `vcs_score_composition_raster_*.test` shards. Together they lock the
complete public composition matrix: four 181-line gameplay families, four
production score layouts plus the poison diagnostic, and both legal orders.
Across the shards they generate static and moving-game fixtures for all 40
pairings, build 80 cartridges, and run the score and gameplay physical-pixel
models on each one. They also build all 32 real public production cartridges and
lock the player-color and all-five diagonal playfield bytes and write cycles, so
final-link page placement cannot reintroduce scanline tearing. The shared
phase harness initializes SWCHA and SWCHB to released inputs; holding Reset in an
oracle would make frame-relative line numbering depend on startup/BSS clearing
cost rather than the visible scheduler. The public matrix reserves the full
object-reported hidden hardware stack; its scratch-free
console Reset path keeps the worst cartridge at 119 object bytes plus eight
hardware-stack bytes, leaving one RIOT RAM byte free.
The score oracle locks centered,
left-, right-, two-plus-two, and poison positioning/ownership schedules at raw
line 40 or 221; the gameplay oracles lock every object pixel and exact 262-line
frames. A separate score-only cartridge places centered, left, right, and
two-plus-two instances at raw lines 50, 80, 110, and 140 to prove mixed arbitrary
vertical placement. The mixed-instance score-only check runs in the first
family shard so it is still covered exactly once.

`vcs_three_plus_three_score.pl` builds the fixed left/right three-plus-three
score component with hostile incoming P0/P1 state and independently colored
packed-BCD fields. Its 6502 oracle locks the simultaneous `098 -> 099 -> 100`
and `998 -> 999 -> 000` carry transitions, exact row-by-row TIA write cycles,
one HMOVE, and the scheduler calibration of 264 raw harness intervals to a
262-line Stella frame. A reviewed Stella 7.0 RGB reference locks the visible
`123`/`456` raster at glyph origins X=20,36,52 and X=100,116,132. The default
regression decodes that reference and verifies all six glyphs pixel-for-pixel
against the decimal font, so a mixed-copy P1 latch artifact cannot be blessed
by a screenshot hash alone. `make stella-three-plus-three-score-test
STELLA=/path/to/stella` independently rebuilds the fixture, snapshots it in
headless Stella, and requires the live raster to match the reviewed reference.
The test also builds the public 2K `08_dual_score` example and locks its
1545-byte ROM / 45-byte total-RAM accounting; top-level `installcheck`
independently compiles that example through the staged installed toolchain.

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
left- and right-justified cartridges through the edge-triggered
right-joystick control oracle, including immediate action, held-input suppression,
neutral re-arming, direction-roll suppression, and hue changes, and drives right fire in a
two-plus-two cartridge to prove visible field selection, independent motion and
packed-BCD changes for both fields, and the right field's full X=144 endpoint.

The left/right score components also lock compact page-contained-font storage:
left keeps five full pointers plus one byte offset (one byte saved), while right
keeps four full pointers plus two byte offsets (two bytes saved). Both expose
`compact_font:=0` for the fingerprint's deliberate full-pointer redirection to
`logo_font`; ordinary score instances use the compact default.


`vcs_font_contracts.pl` audits all eight printable-ASCII font families. It
requires 95 distinct glyph bitmaps per family, exact digit and A-F agreement
with the corresponding decimal and hexadecimal source modules, preservation of
each family's blank row/column cell contract, the compact three-line CC0
headers, the complete tree-wide `libraries/LICENSE.txt`, and byte-identical logo glyph
pixels.

`vcs_six_glyph_wide_stella.pl` is the independent Stella 7.0 guard for the
standalone wide-score visible tail. It compares raw RGB pixels against the
reviewed reference image, specifically catching an overscan VBLANK assertion
that moves into the last visible scanline. The six-glyph phase harnesses retain
the historical cycle-3 component-entry contract; optimizer-induced phase shifts
must be fixed in the timing helper rather than blessed by changing the oracle.

The wide component defaults to a row-counter-free compact layout: digit 2 is one
biased page-contained-font byte offset plus five full pointers. Its deliberately
page-crossing absolute-indexed digit-2 fetch remains five cycles, so the exact
88x8 write schedule is unchanged while two RIOT-RAM bytes are recovered. Instantiating
with `compact_font:=0` restores the historical six full pointers plus row byte for
callers that redirect every glyph to arbitrary ROM addresses; the raster oracle checks
both layouts.


`vcs_fingerprint.pl` builds the private fingerprint cartridge, verifies the
CRC and unstable-ARR probe contract, checks the Big-hex and logo font tables in
ROM, and locks three six-glyph entries: right-justified at raw scanline 40,
centered at 131, and left-justified at 221. Both edge components use fixed
packed BCD `012345` with their pointers redirected to the six VCSC-logo slices.
The harness locks the separate RESP/HMOVE phases and late GRP-write windows while
the complete cartridge retains its 262-line frame period.

`vcs_multicolor_examples.pl` builds the four public interactive renderer
cartridges: faithful legacy, scoreless 192-line, 181-line score-above, and
181-line score-below. Its 6502 harness presents idle/pressed console inputs and
checks one-unit P0/P1/Ball motion, held-SELECT suppression, complete X/Y endpoint
clamps, immediate one-shot right-joystick presses, held-input suppression,
neutral re-arming, direction-roll suppression, selected-digit score-color cycling,
decimal `10^n` score changes, exact normal frame periods, and reset-vector state
restoration. It also requires the faithful demo to opt into the same human
left-to-right packed-BCD digit order used by the eleven-line score components.
The legacy and
192-line initial scenes retain their separate exact sprite/raster checks.

`vcs_player_color_181.pl` and `vcs_player_color_192.pl` require every gameplay
GRP0 and GRP1 handoff, including zero GRP1 transfers, to occur during horizontal
blanking. The 192-line test also pins the official direct-countdown implementation:
no `game_object_masks` storage or unofficial opcodes, 23 total renderer RAM bytes,
exact 152-cycle visible pairs, top-clipped Ball output, and a four-pair Ball crossing
the first 16-line row boundary. Its `full-direct` display timing profile allows the
accepted row-transition left-playfield phases 9/16 while retaining 40/47 on the
right and checking all 160 visible pixels independently. The 181-line player-color
composition oracle retains steady diagonal-playfield writes at 18/25/48/55, pins
nonterminal row endings at 18/25/45/48, the first following P1 half at
17/24/48/55, and the terminal row ending at 18/25/48/55. The reflected
row-ending writes are deliberately kept out of the left-half display window;
the earlier 38/41 schedule produced visible playfield corruption in Stella even
though the byte-only reconstruction was self-consistent. Its object oracle also
pins the corrected Ball row-boundary transfer through its motion trace and rejects
both failure modes in the Ball
positioning sequence: an immediate `HMCLR`
that interrupts the first HMOVE, and a later HMOVE reached while `HMBL` is still
nonzero. `vcs_player_extreme_right.pl` builds both heights with alternating $AA/$55
checkerboard players at X=159; that pattern exposes the one-bit row swap that solid
glyphs hide at the extreme right edge.

`vcs_player_color_192_animation.pl` builds the public animated-sprite gallery,
checks 29 attributed four-frame source sets plus the source's sole three-frame
set driven by an independent packed modulo-3 counter, pins the exact original
960-byte one-bit occupancy, requires source sprite 16 to remain blank while
rejecting any runtime selection of it, verifies the local CC BY-NC-SA 4.0
license and attribution, and checks four aligned 256-byte graphics pages plus
final zero padding. It also pins the 480-byte packed source-row color conversion:
each source row retains its dominant nontransparent PICO-8 palette index with
deterministic tie breaks and maps through a sixteen-entry nearest-NTSC-TIA
palette. Its emulator oracle drives all 15 complete 125-frame traversals plus
Select and pause controls. The oracle locks X=16 entry, one-pixel-per-frame
motion through X=140, wrap through every pair, exact player pixels, exact
converted source-row colors, graphics-pointer selection across all four hard
pages, mutable eight-byte RAM color tables, and 262-line frame periods.

`vcs_all_five_170.pl`, `vcs_all_five_181.pl`, and `vcs_all_five_192.pl`
build three compile-time profiles of the single official
`renderers/all_five/all_five.c26` component. They lock the required `lines`
instantiation parameter, 23-byte public interface, 67-byte 170/181 and 71-byte
192 total RAM contracts, official-opcode policy, solid P0/P1 colors, all-five
enable activity, exact 170/181/192 visible-line contracts, and every playfield
pixel across ten, eleven, or twelve 16-line rows. The all-five timing profile also locks the steady PF1/PF2/PF2/PF1 writes
to cycles 17/24/45/52 on both alternating scanline halves and bounds every
row-transition write, so a two-cycle P1/P0 reflected-half mismatch cannot hide
behind the byte-level raster model. They also reject every late P0/P1 transfer
and every effective M0/M1 enable-state change after horizontal blanking,
covering the same extreme-right row-tearing failure for all five objects.
Dedicated Y=8,height=3 edge cartridges additionally require exactly eight Ball
scanlines across the first packed-row boundary, catching stale VDELBL transfer
at the extra transition `GRP1`. The 170-line regression also proves that reserving the remaining 22 visible
lines yields a stable 262-line frame, matching the intended score-above plus
score-below composition. The
192-line regression additionally runs a 360-frame asynchronous fixture through
the independent endpoint oracle: all five VBLANK RESP/HMxx/HMOVE transactions
must match the requested X coordinates, every object must reach X=0 and X=159,
and the clipped player, four-clock missile, and four-clock Ball spans must be
correct at both edges. They also require the C26 component to carry its
four-byte hidden helper-JSR allowance as `.callstackextra` object metadata
rather than inheriting it from a renderer cfg.

`vcs_all_five_interactive_examples.pl` exercises the public 192-, 181-, and
170-line interactive cartridges through one behavior harness; the 170-line case
requires scores on both sides of gameplay while preserving the same five-object
selection/movement and score-edit controls.

`vcs_all_five_composition.pl` builds static and asynchronous score-above and
score-below cartridges around the 181-line profile. It requires explicit
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

`vcs_all_five_181_unofficial.pl` keeps the detailed 181-line score/motion
comparison for the parameterized unofficial twin. It requires identical RAM
addresses, one reviewed zero-page unofficial NOP in the instantiated profile,
no AXS sites, the same physical modulo-76 playfield profile, pairwise
visible-trace identity for all five static and motion compositions, direct
per-pixel object-raster checks for both static score orders, and equal linked
ROM use.

`vcs_all_five_unofficial_profiles.pl` exercises the unified unofficial source at
`lines:=192`, `181`, and `170`. Every profile must have the same linked ROM use
and object-mask RAM contract as its official twin, exactly one reviewed `$04`
NOP in generated assembly, identical visible TIA traces, and stable 262-line
frames.

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

`linker_banked_archive_reporting.pl` proves that lazy `.l26` selection remains
bank-aware.  It selects only the imported BANK1 member, leaves an unused member
out of the image and reports, resolves the selected member at its logical
`$Dxxx` address in map/symbol/list outputs, and reports the generated BANK0 to
BANK1 call bridge with the archive-member origin intact.

`vcs_bankswitching_diagnostic.pl` builds one F8, one F6, and one F4 image
from `libraries/vcs/bankswitching_diagnostic_suite.c26`. The diagnostic composes
a 19-line Big-wide result word with an 11-line centered cart-type line. The test
locks both 12-byte six-pointer workspaces and the page-contained 128-byte Big and
64-byte default ASCII subset tables. Each image executes its complete ordered
source-bank to destination-bank direct-JMP matrix internally.
The normal `make test` path builds each image from C26 topology and runs it in compatibility-cfg-driven `vcsc-sim` from every
physical/file startup bank and checks RIOT-RAM signatures, exact matrix counts,
the nested cross-bank call, and hardware-stack balance. Superchip runs prefill
the shared RAM with `$A7`, validate mixed BSS/DATA startup through the write
window, execute and poison the region, perform one CPU reset while preserving
RAM, and require a second complete PASS before dumping memory. The optional
authoritative mode is:

```sh
make stella-bank-test STELLA=/path/to/stella
```

It runs the same three ordinary and three Superchip matrix images in Stella,
grades the stable green lowercase **pass** frame versus the dark-red uppercase
**FAIL** failure frame, and independently requires the exact `F8`/`F6`/`F4` or
`F8SC`/`F6SC`/`F4SC` line beneath it. The poisoned image must show `??????`.
The grader checks exact Big/default glyph geometry and white-pixel masks rather
than merely color/area,
forces every physical startup bank, and also runs one randomized developer-mode
startup trial per physical bank. For each SC run the key helper waits for the
first result, sends Stella's F2 console-reset key, waits for the second result,
and snapshots that post-reset frame. The poisoned FAIL reference is now F8SC and
uses the same reset path, avoiding another public diagnostic cartridge. The
headless runner requires Xvfb and `xkbcomp`; its snapshot-key and PNG-grading
helpers are Perl and require no Python installation or Python modules.  Failed
runs leave `.stella-bank-test/` intact for inspection.

`vcs_bankswitching_example_make.pl` copies the public diagnostic example into a
temporary directory and runs its default Makefile target. It requires exactly
seven binaries and their map files—F8, F6, F4, F8SC, F6SC, F4SC, and the
poisoned FAIL reference—rejects hidden empty-stem sidecars, and catches broken
shell command substitutions which would otherwise print misleading
`/bin/sh: ...: not found` messages while still producing cartridges.


`superchip_allocation.pl` starts every F8SC/F6SC/F4SC allocation run from a
hostile `$A7` split-memory fill and requires the map's `STARTUP INITIALIZATION`
section to list each DATA copy and BSS clear with exact read/write aliases. It
also mutates the legacy cfg read alias, write alias, size, and bank tag and
requires every stale variant to produce the same bytes as the authoritative C26
`mem cartram` declaration. Its stable overflow fixture still fills all 128
bytes and requires the linker to name the first object that does not fit.

`split_memory_static_local_codegen_test.c26` and
`superchip_static_locals.pl` cover function-scope `static cartram` storage.
They require persistent `BSS.cartram`/`DATA.cartram` layouts rather than an
activation overlay, startup-only zero/constant/runtime initialization through
the write alias, persistence across repeated calls, packed-bitfield updates,
exact physical occupancy, and execution from every physical startup bank under
F8SC, F6SC, and F4SC.

`split_memory_generic_regions.pl` proves that split-address storage is driven by
authoritative ordinary `mem` metadata rather than by the spelling `cartram` or by
the Superchip window layout. It uses unrelated regions named `banana`, `pair`,
and `orange`, with sizes of 7, 9, and 5 bytes, unaligned and widely separated
windows, and a `pair` region whose read window is above its write window. The
test checks compiler metadata, linker placement and exact occupancy, globals,
automatic locals, function-scope statics, runtime initialization, arrays,
compound operations, packed bitfields, alias-direction enforcement in the
simulator, mirrored final contents, and per-region overflow diagnostics.

`absolute_binding_memory_region_overlap.pl` proves that non-owning absolute
bindings cannot silently occupy allocator-managed storage. It checks ordinary
and split regions, read-only and write-only projections, complete array ranges,
block-scope metadata, reversed/noncontiguous windows, and the directional rule
that compares reads only with managed read windows and writes only with managed
write windows. `external_binding_holes.cfg` keeps legacy helper-buffer tests
honest by placing their deliberate external addresses outside all managed
`MEMORY` entries.

The `writeonly_*` compile tests and `e2e_writeonly_pointer_verify.c26` cover the
one-address write-side pointer qualifier. They prove pure stores, indexing,
pointer copying/comparison/arithmetic, ordinary-to-writeonly conversion, and the
unchanged two-byte representation. Focused failures reject loads, compound and
increment operations, packed-bitfield writes which require a preserving read,
`const writeonly`, non-pointer use, restricted-to-ordinary and const/writeonly
cross-conversions, and same-translation-unit signature mismatches. Separate
pointer and aggregate ABI mismatch fixtures prove the qualifier is retained in
linker-visible fingerprints; a dedicated global-expression test prevents a
file-scope writeonly value from being misclassified as an ordinary pointer.

`e2e_directional_address_projection_verify.c26` and the `directional_*`
compile tests cover unary `&<` and `&>`. The execution fixture uses unrelated
`banana`, `pair`, and `orange` regions with same-direction, reversed, and
noncontiguous read/write windows. It checks exact pointer values for global and
runtime projections, arrays, members, absolute split/read-only/write-only
bindings, same-address objects, one-time subscript evaluation, and compositional
`&<*p`/`&>*p`. Focused failures enforce adjacent operator spelling, reject a
missing selected address, bitfields, capability recovery to ordinary pointers,
reads through writeonly pointers, and writes through const pointers.

`e2e_directional_ref_verify.c26`,
`e2e_directional_ref_separate_verify.c26`, and the `directional_ref_*` compile
tests cover the one-address directional reference contracts. They verify that
`ref const T` selects a readable alias, `ref writeonly T` selects a writable
alias, and ordinary `ref T` accepts only one identical read/write address. The
fixtures cover ordinary and const objects, whole arrays, elements, structures,
members, generic reversed and noncontiguous split regions, one-sided and split
absolute bindings, direct and inline calls, legal read/write-to-restricted
forwarding, and every forbidden capability conversion or operation. Member and
bitfield failures lock subobject propagation and hidden-read rejection; plain
address failures prevent a restricted ref from recovering a read/write pointer.
`e2e_abi_const_ref_mismatch_fail.c26` locks separate-object ABI disagreement,
while `directional_ref_cross_bank.pl` proves exact address selection and the
ordinary F8 cross-bank JSR trampoline. `const_object_assignment_error_test.c26`
locks the underlying const-object write prohibition used by read-only refs.

`call_selective_staging.pl` proves direct calls do not reserve a whole argument
list in caller scratch. Call-free lists use one reusable slot sized for the
largest argument; when a later argument calls a function, only earlier values
which must survive that call remain staged. It also checks that callee parameter
writes occur at the earliest safe point without changing left-to-right argument
evaluation.

`superchip_parameters.pl` exercises split-address value parameters under F8SC,
F6SC, and F4SC from every physical startup bank. It covers ordinary and BCD
values from one through four bytes, selective left-to-right caller staging with
nested calls, callee mutation, inline parameters, cross-bank calls, exact
activation occupancy, both aliases, and deterministic overflow. The mapper-independent
`split_memory_value_parameters.pl` separately compiles callers and callees using
`banana`, `pair`, and `orange`, verifies reversed and noncontiguous alias layouts,
and requires ABI mismatch diagnostics when parameter regions disagree.

`superchip_function_returns.pl` exercises split-address function return objects
under F8SC, F6SC, and F4SC from every physical startup bank. It covers one-
through four-byte ordinary and packed-BCD results, explicit `$$` reads and
writes, compound updates, bare returns, same-bank and cross-bank calls, exact
physical overlay accounting, both aliases, and deterministic overflow. The
mapper-independent `split_memory_function_returns.pl` separately compiles
callers and definitions using `banana`, `pair`, and `orange`, including reversed
and noncontiguous windows plus a split-address pointer return, and requires
result-region ABI mismatch diagnostics.
The compile-only split-return tests additionally lock absolute import/export,
write-alias lowering, generalized writable-result `void` rejection, and
same-translation-unit declaration conflicts.

`linker_startup_main_generic.pl` uses arbitrary logical bank names PEAR/BANANA
and MEMORY names `pear_code`/`orange_code`. It makes ordinary CODE default to the
non-startup bank, proves unqualified `main` is nevertheless pinned to the unique
`startup=yes` bank, and verifies an explicit non-startup qualifier is rejected
using only configured names.

`source_tree_hygiene.pl` rejects stranded test/support files, assembler
fixtures absent from the fixture suite, byte-identical duplicate test assets,
displaced core README files, and broken relative Markdown links.

`vcsc_branding.pl` also enforces the developer-record quarantine:
`.../context.txt`, `.../bankswitching.txt`, `.../instruction.txt`, and their
explanatory README occupy that internal role, while the obsolete predecessor
directory, deletion ledgers, top-level notes, and software-stack snapshot must
remain absent. The same test also requires exactly one `bankswitching.txt` in
the repository, at `.../bankswitching.txt`. `source_tree_hygiene.pl` locks the
bankswitching plan's descending logical-bank convention, lowest-address-first
file order, early per-bank reset work, completed byte-identical direct-`JMP` and JSR-to-indirect-JMP
trampoline table with weighted call-stack accounting, `main`-in-BANK0
constrained automatic placement, `$x100` Superchip ROM boundary, and the
required automatic Superchip-variable allocation roadmap item.

The hygiene test also locks the completed F8/F6/F4 simulator and Stella
certification, including the public diagnostic suite, forced and randomized
startup-bank modes, known RAM signatures, exact 262-line result frames, white
PASS/FAIL glyphs, and the poisoned FAIL reference. It keeps the future
requirement that the same Stella framework certify Superchip read/write aliases
and persistence when the SC profiles land.

`assembler_relocatable_zp_relaxation.pl` assembles and links an ordinary
non-banked object containing ROM, true ZEROPAGE, and ordinary BSS symbols. It
requires bare `lda glyph,x` and `lda glyph+1` references to retain three-byte
absolute-family encodings after final placement, verifies that a `BSS` segment
address-size contract enables safe two-byte relaxation, verifies that a more
specific `absolute` contract overrides the family contract, and keeps both a
true ZEROPAGE label and an absolute byte constant in their legal two-byte forms.

`vcs_default_storage_addrsize_codegen_test.c26` requires the Atari VCS memory
model to emit zero-page contracts for ordinary DATA and BSS. Its generic 6502
counterpart requires no such contracts when the default writable region starts
at `$0200`, preventing target-independent zero-page assumptions.

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


`vcs_frame_ntsc_scheduler.pl` uses a deliberately calibrated pseudo-TIA frame
period. The CPU-only harness observes **264 raw WSYNC intervals** for cartridges
that Stella 7.0 reports as **262 scanlines / 60.0 Hz**. This two-line calibration
is intentional: removing the two blanked end-of-overscan closeout WSYNCs makes
Stella report 260 / 60.5 Hz even though older simplified harnesses called their
262 raw intervals "262 lines." The default scheduler and renderer tests therefore
pin raw 264 while user-facing frame claims remain the Stella-authoritative 262.


`vcs_frame_50hz_scheduler.pl` independently locks the shared PAL/SECAM scheduler
at 3 VSYNC + 45 VBLANK + 228 visible + 36 overscan scanlines. The calibrated
RIOT loads are TIM64T 52/41; the CPU harness observes 314 raw frame intervals
for Stella's 312-line 50 Hz frame, preserving the same two closeout boundaries
as the maintained NTSC scheduler. It exercises production, exact-boundary, and
both overrun paths for both public front ends. `vcs_frame_50hz_stella.pl` is the
optional independent Stella 7.0 smoke test; run `make stella-50hz-test
STELLA=/path/to/stella`. It forces PAL and SECAM formats and requires a stable
320x274 50 Hz snapshot viewport.

`builtin_pal_rgb_palette_codegen_test.c26` locks every entry in the Stella PAL
reference palette. Duplicate PAL gray entries deliberately resolve to the lower
TIA byte under the shared deterministic tie rule.
`builtin_secam_rgb_palette_codegen_test.c26` locks all eight distinct SECAM
colors and their canonical `$00..$0e` even bytes;
`e2e_builtin_pal_secam_rgb_verify.c26` verifies both matchers in the simulator.

`vcs_animated_gallery_ram_accounting.pl` is the authoritative animated-gallery
RAM/ROM report. It regenerates
`test/fixtures/vcs_animated_gallery_ram_accounting/golden.json`, accounts for
every physical RIOT address `$80-$FF`, proves that current `main` activation is
**zero bytes**, records the four-byte stock startup workspace (`_vcsc_ptr0` and
`_vcsc_ptr1` only), proves both sequential `next_pair()` expansions allocate zero
expression scratch, and checks the linker's source-call edges, deepest path, and
explicit `.callstackextra` contribution. Schema 16 preserves the completed historical
optimization sequence through the official-opcode direct-countdown `player_color_192`
renderer and adds the post-closeout startup/main cleanup. The former 48-byte
`game_object_masks` schedule is absent; renderer private RAM remains 10 bytes and total
renderer RAM remains 23. The gallery is now **3377/4090 ROM bytes** and **51/128 RAM
bytes**, with **77 RAM bytes free**: 47 object bytes plus a four-byte hardware-stack
reserve. The earlier schema-15 3296-ROM / 56-RAM / 72-free result remains represented
as a historical checkpoint rather than being rewritten. The larger reset walker trades
81 ROM bytes for four fewer permanent startup bytes, while fixed VSYNC removes the last
one-byte `main` activation. The general P0/P1/Ball renderer remains retained; the
optional two-sprite-only 192/181 profiles remain closed as unnecessary by measurement.
Relative to the item-8 mask-renderer checkpoint, the direct-countdown renderer
plus the delayed-Ball and playfield-transition corrections saves 253 ROM bytes and 46 RAM bytes without removing Ball or increasing stack depth. Its
measured VBLANK marker span falls from 920 to 468 CPU cycles. Every visible two-
line pair remains 152 cycles; steady and nonterminal row-ending playfield phases
are 10/17/40/47, while the first P1 transition half uses 9/16/40/47 and the
terminal line uses 10/17/43/50. The default player-color-192 tests now exercise both public examples' playfields:
`01_interactive` verifies all 192 scanlines of its asymmetric diagonal pattern, and
`02_animated_sprites` independently verifies its full/checker/blank/checker/full
pattern against the same Stella-proven PF byte/order/phase contract. Both profiles
reject the previously accepted 15/22/51/54 boundary schedule that corrupted one
visible scanline per 16-line row. The optional
`make stella-player-color-192-test STELLA=/path/to/stella` target snapshots that
exact public example in Stella 7.0 and compares its RGB raster to a reviewed
reference PNG. The report also records the corrected delayed-Ball carry staging
across the extra row-boundary `GRP1`, plus the
accepted Ball first-row mask-boundary fix, full baseline-to-current checkpoint
history, and the unchanged 232-byte high-level `install_frames()` span. The stack
report remains explicit at source=4, hidden=0, total=4 and `.callstackextra 0`.
The separate animation emulator remains the behavioral/frame oracle.

The optional `make stella-all-five-player-color-192-test STELLA=/path/to/stella`
target cross-checks the combined all-five plus per-row-player-color profile
against both maintained 192-line golden renderers. It verifies patterned player
colors and asymmetric playfield pixels against `player_color_192`, constant-color
object pixels against `all_five_192`, and delayed-Ball/P1 overlap at cache-row
boundaries.

`phase_overlay.pl` is the generic positive/negative lifetime proof. Explicit
`__phaseworkspace$V1$...` contracts mark a smaller overscan-only object and a
larger VBLANK+draw workspace; the smaller object is deliberately declared first
and must still share the larger slot. A marked draw+overscan object, a `main`-
lifetime object, storage used by an ordinary non-template function merely named
`unrelated_draw`, and an overscan-only file-scope object with phase-use metadata
but **no** workspace-eligibility contract must remain separate. The fixture
exercises both high-level and inline-assembly object references and verifies
runtime contents in `vcsc-sim`.

`vcs_big_ascii_font.pl` validates the separate `fonts/big_ascii.c26` 8x16 table:
95 distinct printable-ASCII glyphs, sixteen-row reversal including descenders,
one contiguous 1520-byte `align(256)` object, no impossible `page` containment,
no 16-byte glyph crossing a hardware page, and byte-for-byte agreement between
the source rows and final ROM. `vcs_ascii_font_alignment.pl` performs the linked
256-byte alignment and no-crossing proof for all eight conventional 760-byte
8x8 ASCII font families.

`compiler_address_mode_policy.pl` audits the compiler implementation and rejects
forced ordinary 6502 addressing-mode suffixes in compiler-generated mnemonic
emitters. `compiler_address_mode_codegen_test.c26` is the source-level companion:
ordinary VCSC RAM accesses must be emitted unsuffixed while explicit handwritten
`asm lda.a` / `sta.a` requests remain unchanged. Split-memory execution tests
independently prove that `.segmentaddrsize ..., absolute` still prevents incorrect
zero-page relaxation.

`direct_u8_state_update_codegen_test.c26` locks exact direct assembly for ordinary
unsigned-byte constant updates, unit increment/decrement, copy-plus/minus-
constant assignment, logical-not assignment, truth/mask tests, and constant
comparisons. It forbids generic expression-scratch symbols and Y setup.
`e2e_direct_u8_state_update_verify.c26` executes the corresponding wraparound,
mask, comparison, truth, and logical-not behavior in `vcsc-sim`.

`compact_u8_table_loop_codegen_test.c26` pins the compiler path needed by the
animated gallery's high-level frame installer: conditional ROM-page selection, direct
array-to-pointer assignment, pointer-plus-byte-offset arithmetic, indexed const-table
loads, nibble masks/shifts, a register-backed two-at-a-time byte loop, and indexed
byte-array stores. It forbids expression scratch and a materialized loop-local object.
`page_pointer_compaction_codegen_test.c26` adds the hard-`page` contract: selection
installs only the page high byte and a proven bounded low-byte offset emits without
base-low materialization or impossible carry handling. `page_pointer_offset_reuse_codegen_test.c26`
pins the cross-loop proof that doubled bitmap offsets reuse the already-computed
packed-color pointer low byte with `ASL` and do not reload/recompute the source offsets.
The independent animated-gallery emulator exercises the same operations with the full
source assets.

`register_counted_loop_fallback_codegen_test.c26` is the safety counterpart: a
counted loop whose body performs a general indirect pointer store must materialize
its loop local instead of reserving X, preventing the compact path from silently
claiming a register the body can clobber. `register_counted_loop_zero_iteration_codegen_test.c26`
requires potentially empty X-backed loops to retain their entry `CPX`/`BCS` test, while
`register_counted_loop_downward_codegen_test.c26` pins nonzero downward truth/`> 0`/
`!= 0` loops to X-backed `DEX`/`BNE` lowering, including direct `WSYNC := _` hardware
discard stores with no materialized counter or compiler scratch. The execution test
`e2e_register_counted_loop_verify.c26` covers ascending loops, a nonempty downward
countdown, and the zero-initialized downward fallback, catching both register-lifetime
mistakes and accidental loss of zero-iteration semantics.

`direct_u8_ref_array_fallback_codegen_test.c26` prevents a ref-array formal from
being mistaken for directly allocated array storage. Its source declarator retains
array shape, but the runtime object is pointer-backed, so stores must use the normal
indirect lvalue path.

`example_assembly_allowlist.pl` audits every `.c26` under `examples/`. The compact TSV
fixture pins the normalized assembly statements for each source by count and SHA-256
and classifies each use as beam-critical or a direct hardware idiom. The item-14
cleanup reduced the allowlist from 21 sources to nine and the regression now requires
**zero** `compiler-limitation` entries. Any added or changed example assembly therefore
requires an explicit policy review rather than silently becoming ordinary application
logic.

`scratch_lifetime_overlay.pl` executes a generic 6502 fixture covering sequential
expressions, mutually exclusive branches, a loop, three repeated inline
expansions, and a nested inline expression. It requires all sequential inline
uses to share activation-owner lifetime groups, requires the nested expression
to retain deeper disjoint slots, and validates the result in `vcsc-sim`.

`vcs_poison_debug_score.pl` builds the installed adversarial score-profile
component, checks zero instance RAM, all intended hostile TIA writes, exactly
11 WSYNC stores, the red-background sentinel, prohibited frame/timer ownership,
and stable 262-line standalone scheduling.

`vcs_renderer_authoring_howto.pl` keeps the maintained renderer-authoring
procedure executable as documentation policy. It requires the HOWTO to retain
profile isolation, lifecycle and visible-handoff contracts, public/private state,
scheduler ownership, TIA/clobber and delayed-latch rules, hidden-stack accounting,
RAM/ROM and linker/page constraints, reproducible normalization, cycle/flag timing
rules, layered Stella regressions, public examples, and staged installation.

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

`vcs_bankswitching_diagnostic.pl` also certifies the explicit-binding
F8SC/F6SC/F4SC profiles. It checks every allocatable bank region begins at
`$x100` with size `$0E00`, verifies the C26 profiles keep the RAM-port prefix out of ROM,
verifies exact images, map-reported startup records, hostile initial RAM, both
aliases, bank-switch persistence, poison-before-result, and reinitialization on
a reset which preserves RAM externally. `stella-bank-test` independently runs
the same SC lifecycle from every forced and randomized physical startup bank.
`VCSC_STELLA_FILTER` limits focused Stella reruns. Staged `make installcheck`
uses the installed compiler, profile, diagnostic source, and simulator options
to prove the same second-arrival reset lifecycle and a zero final failure byte.

`vcs_standard_renderer_banked.pl` composes the maintained standard all-five
renderer with 4K, F8, F6, F4, and F8SC C26 profiles.  It locks bank-local hard
page objects, component-owned startup placement, one VBLANK-only bank1 hook,
per-bank ROM and replicated bridge costs, 37-cycle cross-bank calls, RIOT and
Superchip usage, 12 hardware-stack bytes, 20140-cycle frame length, exact raster
identity, mapper restoration, and the consolidated one-cartridge public example.

## Faithful legacy multisprite baseline

`vcs_faithful_legacy_multisprite.pl` locks the first roadmap-item-28 milestone:
the minimal NTSC, unbanked, non-Superchip retained multisprite profile.  It
requires reproducible normalization, the exact `$80-$F9` 122-byte state object,
six physical hardware-stack bytes at `$FA-$FF`, zero compiler activation RAM in
the fixed diagnostic, the retained unofficial-opcode and TXS/PHP enable path,
1472 bytes of diagnostic ROM, stable 264-line frames, and a complete 391-event
visible TIA-write oracle.  The raster oracle independently pins P0 plus all five
logical P1 sprites in upright display order, their colors/reposition phases,
the explicit P0 trailing clear that prevents stale-HMOVE stripes, asymmetric
playfield, and integrated score timing.

`vcs_faithful_legacy_multisprite_stella.pl` is the independent Stella 7.0
certification for the same fixed cartridge.  Run it through
`make stella-faithful-multisprite-test STELLA=/path/to/stella`; the default e2e
suite does not require a graphical Stella installation.

`vcs_multisprite_profiles.pl` locks the modern item-28 derivative. It requires
one `renderers/multisprite/multisprite.c26` source with compile-time
`lines:=192` and `lines:=181`, rejects unsupported heights, and preserves the
retained LAX/TXS/PHP path with a four-byte hidden-stack declaration. The public
192 interactive cartridge and both 181 score orders are built and measured; a
MOS6502/TIA oracle pins exact 262-line frames, all eight P0 rows, all 40 rows of
the five multiplexed P1 glyphs, colors, reposition phases, six playfield rows,
HMOVE schedule, score placement, and exhaustive legal X/Y frame timing. The
examples must provide a 145-byte `align(256)` graphics block at `$xx00`; glyphs
begin at offset 96 so every cycle-critical indexed fetch remains page-cross free.
Every profile additionally forces logical P1/P2 into the same vertical band for
six consecutive frames and requires the displayed winner to alternate every
frame, catching accidental loss of the faithful persistent flicker-sort order.
The test also pins the 86-byte renderer RAM contract for both profiles, the packed
full-range P1 positioner, 181 late-HMOVE P0 neutralization, and current ROM/RAM
accounting.

`vcs_multisprite_stella.pl` independently grades actual Stella 7.0 pixels rather
than inferring X from RESP/HMP write cycles. Run it through
`make stella-multisprite-test STELLA=/path/to/stella`; the default e2e suite does
not require a graphical Stella installation. It locks all five multiplexed rank
phases at representative edge/interior X coordinates, natural X=159 wrap/clipping,
the P1 top edge, 181 P0 sort invariance, and the P0 Y=0 broad-stripe regression.

`fixed_large_offset_codegen_test.c26` locks the fixed-address audit past the old
8-bit-offset boundary: an automatic byte at offset 299 must use direct
`symbol + 299` addressing rather than materializing a pointer or consuming Y.

PAL/SECAM 50 Hz coverage
------------------------
`vcs_frame_50hz_scheduler.pl` locks the shared PAL/SECAM scheduler deadlines,
phase boundaries, 314-raw/312-Stella frame accounting, and diagnostics.
`vcs_frame_50hz_interactive.pl` builds both public all-five examples with
inactive RIOT controls and proves the 228-line visible composition; this avoids
the false-reset behavior produced by zero-initialized console-switch inputs.
`vcs_video_standard_portability.pl` locks the scheduler-neutral component
classification in `libraries/vcs/VIDEO_STANDARDS.md`. PAL/SECAM RGB compile
and E2E tests lock the reference palettes, while the sound compile tests lock
the 50 Hz cadence/control aliases. `vcs_frame_50hz_stella.pl` remains optional
and independently certifies the forced PAL/SECAM Stella viewport.
`vcs_video_standard_examples_stella.pl` is the optional Stella companion for the
public PAL/SECAM interactive examples and verifies their forced-format viewport.

`vcs_4ksc.pl` certifies the direct 4K Superchip profile, full 128-byte split-address RAM lifecycle, hostile-fill reset behavior, PASS/FAIL diagnostic, disassembler recognition, and exact round trip.
