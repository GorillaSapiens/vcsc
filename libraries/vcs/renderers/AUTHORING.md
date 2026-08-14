```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# VCSC renderer-authoring HOWTO

This is the maintained procedure for adding a VCS gameplay renderer or visible
score/display component to VCSC. It is intentionally stricter than "make a ROM
that looks right": a maintained component must publish its ownership contract,
compose with the frame scheduler, survive application state changes, fit the
claimed RAM/ROM budget, and have timing and physical-raster evidence strong
enough that later compiler or linker changes cannot silently move the beam.

`COMPONENT_CONVERSION.md` is the inventory and measured contract record for
existing profiles. This HOWTO describes how to create another one.

## 1. Start with a new profile, not a mutation of an old one

A renderer profile is a public timing/ownership contract. Do not change an
existing profile merely because a new experiment shares most of its code.
Create a separately named component when any of these change materially:

- visible scanline count or component handoff behavior;
- gameplay objects or score geometry;
- per-row color behavior or TIA register ownership;
- official versus stable/common-NMOS unofficial opcodes;
- application-visible state;
- private RAM ownership or hidden hardware-stack requirements;
- cycle schedule, linker/page requirements, or positioning algorithm.

Parameterize one source only when the variants really share one public API and
each parameter value has its own measured timing/RAM contract. The maintained
`all_five`, `player_color`, and `multisprite` components are examples. The
combined all-five/player-color renderers remain separate profiles because their
cycle schedules and RAM contracts are different.

Never "improve" a working profile in place and then use the old regression as
proof that the new profile is equivalent. Keep the old profile as an oracle
until the new one has independent evidence.

## 2. Define the source contract before scheduling the raster

A lifecycle component normally exposes:

```c
require inline void TEMPLATE_init(void);
require inline void TEMPLATE_vblank(void);
require inline void TEMPLATE_draw(void);
require inline void TEMPLATE_overscan(void);
```

A score/display component may have empty blanking hooks, but the lifecycle and
ownership must still be explicit. For a parameterized component, reject
unsupported parameter values at compile time rather than silently selecting a
nearby schedule.

Every maintained visible component publishes a `TEMPLATE_contract` enum. At
minimum, preserve the common handoff fields defined by
`COMPONENT_CONVERSION.md`:

```text
TEMPLATE_VISIBLE_SCANLINES
TEMPLATE_DRAW_ENTRY_CYCLE
TEMPLATE_DRAW_RETURN_CYCLE
TEMPLATE_DRAW_COMPLETE_SCANLINES
TEMPLATE_DRAW_PARTIAL_ENTRY_CYCLES
TEMPLATE_DRAW_PARTIAL_EXIT_CYCLES
TEMPLATE_DRAW_TERMINAL_WSYNC
TEMPLATE_DRAW_HMOVE_COUNT
TEMPLATE_DRAW_SUCCESSOR_ON_RETURN_LINE
TEMPLATE_VBLANK_MAX_CYCLES
TEMPLATE_OVERSCAN_MAX_CYCLES
```

Also publish profile-specific counts that a test can lock: object count,
playfield dimensions, public/private/workspace RAM bytes, and any other memory
or geometry value that is part of the component contract.

The enum is not decorative documentation. Regressions should read the source
or linked map and fail if the declared values drift away from the measured
implementation.

## 3. Separate application-visible state from private workspace

Decide which bytes the application is allowed to read or write. Those are
public state and must have documented units, ranges, ordering, persistence, and
whether a lifecycle hook temporarily biases or restores them. Examples include
object X/Y positions, sprite pointers, NUSIZ values, score bytes, and mutable
colors.

Everything else is private workspace. Typical private state includes:

- row/pair counters;
- precomputed horizontal-position controls;
- vertical enable masks;
- playfield or glyph row caches;
- temporary pointers and offsets;
- saved caller state such as a borrowed hardware-stack pointer.

Do not expose private bytes merely because the first implementation stores them
in ordinary RIOT RAM. Conversely, do not count caller-owned public data as a
private RAM saving.

If public state is temporarily modified to simplify a raster, restore it before
returning from the documented lifecycle phase. Prefer preparing biased private
copies during VBLANK so application coordinates remain stable.

For score variants, define numeric ownership explicitly. State which byte owns
which visible digits, whether values are packed BCD or binary, the display order,
and which colors or positions are caller-visible. Two score fields that merely
share six glyph slots still need separate ownership contracts.

## 4. Respect frame-phase ownership

The frame scheduler owns the frame. A lifecycle renderer must not take over
scheduler responsibilities.

Visible components must not write `VSYNC`, `VBLANK`, or a RIOT frame timer.
They may use `WSYNC` internally because scanline timing is the job being done.
Blanking callbacks may also use bounded internal `WSYNC`s, but every stalled
cycle is charged against the published blanking budget. Only the scheduler waits
for or reads the frame timer, changes the frame phase, or issues the scheduler's
phase-transition WSYNC.

For the maintained NTSC lifecycle contract:

- `vcs_ntsc_end_vblank()` starts the first visible component at physical CPU
  cycle 3;
- `draw()` owns exactly its declared complete visible scanlines;
- maintained components perform their own terminal WSYNC;
- `draw()` returns at cycle 0 of the following line;
- `vcs_ntsc_component_handoff()` is the three-cycle `BIT.z CXM0P` bridge, so a
  composable successor begins at cycle 3 of that return line;
- a 192-line component normally has no visible successor on its return line.

Do not hide visible padding in `overscan()`: the scheduler can absorb it into the
blanking deadline and the renderer will still be short. Visible lines belong in
`draw()` and must be counted by a raster oracle.

### Video-standard portability

Do not put PAL/SECAM conditionals into a scheduler-neutral raster merely because
the surrounding frame is 50 Hz. A visible component is timing-portable when its
cycle schedule, visible-line count, and entry/return phase are independent of
VSYNC/VBLANK/timer ownership. Compose it under `frame_pal.c26` or
`frame_secam.c26` and supply standard-appropriate colors from the caller. If a
renderer owns complete frame geometry, keep it explicitly standard-specific.
See `../VIDEO_STANDARDS.md` for the maintained-component classification.

## 5. Publish hooks, clobbers, incoming assumptions, and exit state

For each lifecycle function document:

- TIA registers it reads, establishes, strobes, or leaves clobbered;
- TIA registers guaranteed untouched;
- required incoming TIA state, if any;
- A/X/Y and processor-flag clobbers;
- public state temporarily changed and when it is restored;
- hidden calls or hardware-stack usage;
- the exact exit state needed by a following visible component.

Do not assume a preceding score left player state convenient for gameplay. A
score may leave `NUSIZ0/1`, `VDELP0/1`, player graphics latches, reflection,
colors, or motion registers in score-specific states. A gameplay component that
needs deterministic state must establish it before the relevant TIA event.

Likewise, a score that promises not to disturb missiles/Ball must neutralize any
motion side effects before its HMOVE rather than assuming incoming HMM0/HMM1/HMBL
are zero.

Delayed TIA latches deserve explicit exit tests. With `VDELBL` enabled, writing
`ENABL` changes the delayed Ball value; a later `GRP1` write transfers that value
to the effective Ball latch. Clearing `ENABL` alone at a component tail is not a
proof that Ball is off. Flush the latch deliberately when the exit contract
requires it. The delayed P0/P1 graphics latches have analogous ordering hazards.

## 6. Treat the hardware stack as owned memory

RIOT RAM and the physical 6507 stack are the same scarce memory budget. Hidden
stack use is part of the renderer contract even when no source-language variable
names those bytes.

If inline assembly adds a hidden JSR level, declare the measured requirement
with `.callstackextra`; do not depend on the linker accidentally reserving enough
space. If a legacy profile uses TXS/PHP or other stack tricks as object-enable
storage, document the exact reserved bytes and prove the maximum depth.

A component may temporarily borrow `S` as a general register only with a strict
contract:

1. save the caller's stack pointer before borrowing it;
2. execute no push, pull, JSR, RTS, interrupt-dependent stack use, or generated
   code that may touch the stack while `S` is borrowed;
3. restore the exact caller value before returning;
4. keep the saved byte in the component's private RAM accounting;
5. test stack balance across complete frames and worst-case control paths.

The combined 181-line all-five/player-color renderer is an example: during the
visible loop `S` carries a row base while X is used for pair control, and the
caller stack pointer is restored before the inline draw returns.

## 7. Budget RAM and ROM from linked artifacts

Do not estimate cartridge cost from source size. Build a minimal fixture and use
the linker map.

Track at least:

- component public RAM;
- component private RAM;
- total component RAM;
- whole-cartridge RIOT RAM including application and runtime state;
- renderer/code ROM;
- immutable tables/fonts;
- complete linked cartridge ROM;
- free bytes in the intended 2K/4K/bankswitched profile.

A feature is not "free" because its table moved to ROM; it may save RAM and cost
more ROM. Conversely, an unrolled raster may be the right cycle trade but can be
the dominant ROM consumer. Measure after every structural timing change.

Keep budget assertions in regression tests for representative fixtures. If an
optimization intentionally changes the expected footprint, update the documented
measurement and the test together.

## 8. Make object placement and page requirements explicit

6502 timing depends on addressing mode and page crossing. Express requirements in
source/linker contracts instead of hoping the linker repeats yesterday's layout.

VCSC distinguishes two important declarations:

- `page` means the complete object must fit within one 256-byte page. A small
  `page` object is not necessarily based at `$xx00`.
- `align(256)` means the object starts on a 256-byte boundary; it may span pages.
  `align(N)` accepts only the supported power-of-two alignment values.

Do not infer page-base low byte zero from ordinary `page` containment. The exactly
256-byte contained-object case is the special case where containment itself
forces a page boundary.

Use explicit assembly addressing suffixes when timing depends on encoding:
`.z`, `.zx`, `.a`, `.ax`, `.ay`, and related supported forms. An assembler/linker
relaxation from absolute to zero page changes both ROM size and cycles; force the
mode when the raster depends on it.

Conditional branch timing must also be explicit. Use `.same` when the branch
must remain within one page and `.cross` only when the four-cycle taken case is
the required schedule. `.flex` is the default for branches whose page relation
does not matter. Review every beam-critical branch after code motion or alignment
changes.

## 9. Normalize retained legacy source reproducibly

Do not hand-edit imported legacy renderer sources merely to make them acceptable
to VCSC. Keep the retained upstream/reference material unchanged and put the
translation in a deterministic `normalize.pl` beside the maintained profile.

A normalization pipeline should:

- select only the exact retained source/profile needed;
- translate syntax and known macro conventions reproducibly;
- make unsupported/unofficial opcodes explicit rather than silently legalizing
  them;
- preserve forced addressing modes, page constraints, and timing comments;
- emit generated files with provenance comments;
- provide a `--check` mode or equivalent regression that fails if regeneration
  changes the committed output.

Native C26 lifecycle components do not need a normalization layer just because a
legacy predecessor had one. Normalize only when there is retained external or
historical source to reproduce.

## 10. Design the cycle schedule before optimizing it

For every visible scanline or repeated pair, maintain a cycle ledger containing
at least the beam-critical TIA writes. Record physical CPU cycle, register, value
source, and the control-flow assumptions that make the timing invariant.

A useful schedule answers questions such as:

```text
cycle  0  HMOVE
cycle 18  GRP1
cycle 48  PF2
cycle 55  PF1
...
cycle 76  WSYNC
```

The exact numbers are profile-specific. The requirement is that they be measured
from generated 6502 code and locked by tests, not guessed from C26 statement
order.

### Preserve internal phases, not only total cycles

Two paths can both consume 76 cycles and still draw different pixels because the
TIA writes occur at different internal phases. Moving seven cycles of cache work
from the middle of a line to its tail preserves the line total while moving PF or
GRP writes seven cycles earlier. That can tear the playfield even though the frame
length remains perfect.

When collapsing or unrolling loops, compare the complete write schedule against a
known-good trace. Preserve beam-critical phases first; recover cycles in dead
slots or blanking time rather than redistributing work casually.

### Processor flags are live timing state

Treat condition flags as data dependencies. This is wrong:

```asm
cpy.z player_height
lsr.z object_mask       ; changes C
bcs.same @inactive      ; now tests LSR, not CPY
```

Move the compare after flag-clobbering work, or otherwise preserve the intended
condition. `ADC`, `SBC`, shifts/rotates, compares, and many arithmetic operations
change flags. A flags bug can change both object visibility and branch timing.

### Balance data-dependent paths

Active/inactive object paths, cache-boundary paths, and edge-coordinate paths must
all meet their required cycle count. Do not validate only the default fixture.
Sweep coordinates through state transitions and page/coarse-position boundaries.

Player positioning is especially phase-sensitive. Register-level equivalence is
not sufficient: RESP/HMP/HMOVE transactions that look mathematically equivalent
can map several requested coordinates to one physical pixel or shift at a coarse
boundary. Use physical pixels as the final oracle.

## 11. Build layered oracles

No single test is enough. Use several layers, each responsible for something it
can actually prove.

### Source/contract tests

Lock:

- contract enum fields;
- public/private RAM counts;
- required tables and parameters;
- forbidden frame-register ownership;
- branch annotations and explicit addressing modes where required;
- normalization reproducibility for retained legacy profiles.

### CPU/event-trace tests

Use the project frame/TIA harness to prove:

- exact scanline/frame length;
- branch-path cycle invariance;
- expected TIA write ordering and phases;
- object motion through the complete supported coordinate range;
- stack balance and hook budgets.

Register-level oracles are valuable but must not freeze a known-bad recipe. If a
bug fix intentionally changes RESP/HMP transactions while preserving the physical
coordinate, update or specialize the register oracle and let the physical raster
test decide correctness.

### Stella physical-raster tests

Use Stella as the final authority for TIA-visible behavior. Compare PNG pixels or
otherwise derive physical object coordinates from screenshots. Include adversarial
fixtures, not only attractive demos:

- asymmetric/reflected playfields to expose one-cycle PF tearing;
- patterned player graphics and row colors;
- isolated M0, M1, and Ball;
- object overlap and delayed-latch stress;
- player X values on both sides of every coarse-position boundary;
- top/bottom and left/right endpoints;
- score above and below gameplay when the profile is composable;
- hostile predecessor state when a component claims deterministic setup.

A static golden screenshot cannot prove smooth motion. A motion regression must
compare successive requested coordinates and verify one physical Atari pixel per
step where that is the public coordinate contract.

## 12. Regression design is part of the feature

Add the regression before declaring the renderer maintained. Prefer focused tests
that state what they certify rather than one giant script that accidentally owns
everything.

A new renderer/score profile normally needs coverage for:

1. source contract and RAM accounting;
2. minimal build/link smoke fixture;
3. exact frame timing;
4. TIA write/cycle schedule or a suitable predecessor equivalence trace;
5. physical Stella raster;
6. full supported motion/state sweeps;
7. score/gameplay composition in every advertised order;
8. source-tree hygiene/licensing;
9. installed-toolchain rebuild;
10. neighboring established profiles, proving they remain unchanged.

If the test runner uses maintained counts (examples, interactive sources, installed
profiles), update those counts in the same change. A new example that makes a
hard-coded audit fail is not a mysterious test failure; it is missing integration
bookkeeping.

## 13. Add a public example that exercises the new capability

A maintained profile should have a small editable example under `examples/`.
Choose a fixture that makes the profile's unique feature obvious.

For an interactive gameplay renderer, prefer the project's standard control
vocabulary when ROM permits: Game Select cycles the interesting objects, the left
joystick moves the selected object, Reset restores a known scene. For a score
variant, exercise boundary values and independent fields rather than displaying
only `000000`.

An example is not acceptance evidence by itself. It must also:

- recursively build with the public example suite;
- fit the advertised cartridge and RAM profile;
- avoid unnecessary inline assembly when ordinary VCSC can express the controls;
- retain sidecars and licensing conventions used by neighboring examples;
- be rebuilt by `make installcheck` from the staged installed library, not only
  from the source tree.

If a 4K example is within a few bytes of the ceiling, document the measured
headroom. Do not claim an interactive variant is impossible merely because an
unoptimized first version ran out of ROM; first identify whether renderer code,
font/table data, or application controls own the space.

## 14. Install the profile as part of the public library

A source-tree-only renderer is unfinished. Wire the component and any required
README/data files into the same install/uninstall paths as neighboring renderer
profiles. Extend `installcheck` so a representative cartridge compiles against
the staged installed tree.

Also update the public VCS library catalog and example index. Keep internal
roadmap/context records separate from installed user documentation.

## 15. Completion checklist

Before marking a renderer or score-display roadmap item complete, require all of
the following:

- [ ] separately named profile or justified parameterized sibling;
- [ ] public API and application-visible state documented;
- [ ] private/workspace RAM measured and declared;
- [ ] frame-phase ownership and all lifecycle hooks documented;
- [ ] TIA/A/X/Y/flag clobbers and exit guarantees documented;
- [ ] hidden hardware-stack use measured, declared, and balanced;
- [ ] linker placement, `page`, alignment, addressing-mode, and branch-page
      requirements explicit;
- [ ] source normalization reproducible when legacy source is retained;
- [ ] cycle ledger measured from generated 6502 code;
- [ ] data-dependent paths cycle-balanced;
- [ ] exact frame length proven over worst-case state/motion sweeps;
- [ ] Stella physical raster proven with adversarial fixtures;
- [ ] predecessor/neighbor profiles still pass unchanged;
- [ ] public example builds inside RAM/ROM budget;
- [ ] staged installed-toolchain example builds;
- [ ] source hygiene/licensing/tests pass;
- [ ] public docs, roadmap, compact context, and history updated.

If any item is still experimental, say so and leave the roadmap item open. A
nonfunctional renderer may be useful WIP, but it is not a maintained profile.

## 16. Useful existing references

Use existing profiles as focused examples rather than copying one wholesale:

- `COMPONENT_CONVERSION.md`: current lifecycle handoff/TIA ownership matrix and
  measured profile contracts;
- `all_five/`: parameterized 192/181/170 official-opcode gameplay lifecycle;
- `player_color/`: score-composable and full-height per-row-color timing;
- `all_five_player_color_181/`: combined-object/color scheduling, stack-pointer
  borrowing, physical player-position regression, and delayed-Ball tail flush;
- `all_five_player_color_192/`: deliberately larger unrolled cycle schedule where
  ROM is traded for exact visible timing;
- `multisprite/`: branch-page annotations, hidden stack accounting, multiplexing,
  and 181/192 parameterized composition;
- `standard_4k_ntsc/`: deterministic legacy-source normalization, linker object
  placement, hidden stack, and retained monolithic compatibility contract;
- the six-glyph and two-plus-two score components in `libraries/vcs/`: compact
  font/page placement, delayed-player pipelines, mutable versus fixed caller
  state, and score-specific TIA ownership.

When the new renderer disagrees with one of these, do not cargo-cult the older
implementation. State which contract differs, prove the new schedule, and keep
both profiles separately testable.
