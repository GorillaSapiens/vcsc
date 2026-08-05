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

`function_mem_region_codegen_test.c26` and
`function_mem_region_placement.pl` cover named `mem` modifiers on functions.
They lock `CODE.bank1.__vcsc_function$NAME` private layouts, exact longest-rule
linker placement, page containment, source/linker region metadata agreement,
ordinary `CODE` restoration, and the Superchip-safe `$D100+$0E00` allocatable
interval. Companion rejection tests cover conflicting declaration/definition
regions, inline placement, and explicit nonzero-bank placement of `main`.
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

`vcs_f8_profile.pl` certifies the installed `libraries/vcs/vcs_8k_f8.cfg`
profile.  It compiles the private F8 source diagnostic, locks BANK1-first/BANK0-
last file order, `$1FF8/$1FF9` selector identities, hard and automatic placement,
cross-bank JMP and nested JSR bridges, byte-identical common corridors, vectors,
map output, and exact 8192-byte output.  A small opcode model starts from each
possible initially selected file chunk and proves the reset bridge reaches
BANK0 and nested calls restore banks and hardware-stack returns correctly.
`make installcheck` repeats the source build with the staged installed profile.

`vcs_f6_f4_profiles.pl` certifies the installed `vcs_16k_f6.cfg` and
`vcs_32k_f4.cfg` profiles through the same linker implementation.  It places a
nested call-chain function in every logical bank, starts execution from every
possible initially selected physical chunk, exercises every selector on the
outward and return paths, locks BANK3..BANK0 and BANK7..BANK0 file order,
reserved hotspot bytes, byte-identical trampoline/vector corridors, F4's NMI
vector/hotspot overlap, balanced stack restoration, map identities, and exact
16384/32768-byte output.  `make installcheck` also builds staged diagnostics
through both installed profiles.

`linker_banked_auto_placement.pl` covers deterministic roadmap-item-7 placement.
It links the same fixture twice, pins runtime and `main` to BANK0, spills an
unpinned function by capacity, keeps a call-connected function home, collapses a
forbidden ROM-data edge into a hard component, and rejects contradictory pins.
It also compiles a VCSC named `$ro` object, proves the object becomes a pinned
`RODATA.bank1` layout, proves its unpinned reader follows it to BANK1, and checks
that the resulting BANK0 `main` call creates exactly one JSR bridge. Map output
must identify components, pinned/automatic members, concrete regions, byte cost,
and incident cut weight.

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

`discard_store_codegen_test.c26`, `discard_store_chain_codegen_test.c26`,
and `discard_result_codegen_test.c26` cover the dedicated lone-underscore
discard token. They lock direct `WSYNC := _` lowering to a bare `STA`, require
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

`vcs_player_color_192_animation.pl` builds the public animated-sprite gallery,
checks all 30 attributed four-frame source sets, pins the exact 960-byte one-bit
occupancy extracted from PICO-8 sprites 1 through 120, and verifies four aligned
256-byte graphics pages including the final zero padding. Its emulator oracle
drives all 15 complete 160-frame left-to-right traversals plus Select and pause
controls. The oracle locks X=0 entry, one-pixel-per-frame motion, X=159 clipping,
wrap through every pair back to the first pair, exact player pixels, graphics-
pointer selection across all four hard pages, mutable eight-byte RAM color
tables, exact palette rotation by each frame's transparent top-row count,
permitted visible color values, and 262-line frame periods.

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

`linker_banked_archive_reporting.pl` proves that lazy `.l26` selection remains
bank-aware.  It selects only the imported BANK1 member, leaves an unused member
out of the image and reports, resolves the selected member at its logical
`$Dxxx` address in map/symbol/list outputs, and reports the generated BANK0 to
BANK1 call bridge with the archive-member origin intact.

`vcs_bankswitching_diagnostic.pl` builds one F8, one F6, and one F4 image
from `libraries/vcs/bankswitching_diagnostic_suite.c26`. Each image executes its
complete ordered source-bank to destination-bank direct-JMP matrix internally.
The normal `make test` path runs each image in cfg-driven `vcsc-sim` from every
physical/file startup bank and checks RIOT-RAM signatures, exact matrix counts,
the nested cross-bank call, and hardware-stack balance. The optional
authoritative mode is:

```sh
make stella-bank-test STELLA=/path/to/stella
```

It runs the same three ordinary and three Superchip matrix images in Stella,
grades the stable green **P** frame versus the dark-red **F** failure frame,
including the exact default-font P silhouette rather than just its color/area,
forces every physical startup bank, and also runs one randomized developer-mode
startup trial per physical bank.  The
headless runner requires Xvfb and `xkbcomp`; its snapshot-key and PNG-grading
helpers are Perl and require no Python installation or Python modules.  Failed
runs leave `.stella-bank-test/` intact for inspection.

`vcs_bankswitching_example_make.pl` copies the public diagnostic example into a
temporary directory and runs its default Makefile target. It requires exactly
seven binaries and their map files—F8, F6, F4, F8SC, F6SC, F4SC, and the
poisoned FAIL reference—rejects hidden empty-stem sidecars, and catches broken
shell command substitutions which would otherwise print misleading
`/bin/sh: ...: not found` messages while still producing cartridges.


`split_memory_static_local_codegen_test.c26` and
`superchip_static_locals.pl` cover function-scope `static superchip` storage.
They require persistent `BSS.superchip`/`DATA.superchip` layouts rather than an
activation overlay, startup-only zero/constant/runtime initialization through
the write alias, persistence across repeated calls, packed-bitfield updates,
exact physical occupancy, and execution from every physical startup bank under
F8SC, F6SC, and F4SC.

`split_memory_generic_regions.pl` proves that split-address storage is driven by
ordinary `mem` and cfg metadata rather than by the spelling `superchip` or by
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
write-alias lowering, `void` rejection, and same-translation-unit declaration
conflicts.

`linker_startup_main_generic.pl` uses arbitrary logical bank names PEAR/BANANA
and MEMORY names `pear_code`/`orange_code`. It makes ordinary CODE default to the
non-startup bank, proves unqualified `main` is nevertheless pinned to the unique
`startup=yes` bank, and verifies an explicit non-startup qualifier is rejected
using only configured names.

`source_tree_hygiene.pl` rejects stranded test/support files, assembler
fixtures absent from the fixture suite, byte-identical duplicate test assets,
duplicate deletion-ledger entries, any deleted path that reappears, displaced
core README files, and broken relative Markdown links.

`vcsc_branding.pl` also enforces the developer-record quarantine:
`.../context.txt`, `.../bankswitching.txt`,
`.../instruction.txt`, `.../remove.txt`, and their explanatory
README occupy that internal role, while the old `.top_secret/` directory,
obsolete top-level notes, and software-stack snapshot must remain absent. `source_tree_hygiene.pl` locks the
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

`vcs_bankswitching_diagnostic.pl` also certifies the explicit-binding F8SC/F6SC/F4SC
profiles. It checks every allocatable bank region begins at `$x100` with size
`$0E00`, rejects deliberately malformed cfgs which expose the RAM-port prefix
to ordinary ROM placement, verifies reserved 256-byte prefixes and exact image
sizes, executes each complete-matrix diagnostic from every physical startup
bank in the mapper-aware simulator, and validates the canonical `$F080-$F0FF`
read aliases plus a matrix-wide persistence count. `stella-bank-test`
independently runs the same three SC images from every forced and randomized
physical startup bank. `VCSC_STELLA_FILTER` limits execution when a focused
Stella rerun is needed.
