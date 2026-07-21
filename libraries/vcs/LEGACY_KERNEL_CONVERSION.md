```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# legacy BASIC kernel conversion inventory

## Verdict

Conversion is feasible, but it is not a sensible "translate 2,000 lines of
assembly into C-like source" project. The scanline kernels are cycle-counted
6507 assembly and should remain separately assembled code. The practical goal
is to:

1. define one exact source-integration contract and module-owned state layout;
2. normalize only that configuration's retained DASM source into `vcsc-as`
   syntax without modifying the vendored files;
3. include and link the adapted assembly with VCSC game logic; and
4. add optional kernel features only after a minimal 4K standard-kernel image is
   byte- and timing-stable.

The standard kernel is a realistic first target. The multisprite kernel is also
possible, but its much heavier use of the hardware stack and fixed RAM makes it
a later target. Bankswitching and Superchip support are separate linker/runtime
projects and should not be mixed into the first conversion.

## Retained source inventory

The vendored text/source snapshot contains 29 assembler/header/include files and
5,471 lines:

| Area | Files | Lines | Purpose |
| --- | ---: | ---: | --- |
| `common/` | 12 | 1,327 | VCS symbols, macros, startup, score graphics, RAM maps, common headers and manifests |
| `standard/` | 8 | 2,587 | Standard and vertically reflected kernels, overscan, playfield drawing/scrolling, lives/status-bar helpers |
| `multisprite/` | 9 | 1,557 | Six-player multiplexing kernel, setup/sort logic, playfield helpers, normal/Superchip manifests |

The principal cycle-critical files are:

- `standard/std_kernel.asm` — 813 lines
- `standard/std_kernel_vertical_reflect.asm` — 771 lines
- `multisprite/multisprite_kernel.asm` — 1,094 lines

The `.inc` files are mostly concatenator manifests, not ordinary assembler
includes. They list generated application fragments and kernel pieces in the
required physical order.

## Inputs not present in the retained tree

The snapshot is reference material rather than a standalone legacy BASIC build.
A real upstream build supplies generated or optional files that are not here:

- `2600basic_variable_redefs.h` — generated variable aliases
- `bB.asm` — generated game/application assembly
- `bB2.asm` — generated second-bank fragment
- `banksw.asm` — generated/selected bankswitch support
- optional alternate `score_graphics.asm.*` font files

The separately documented DPC+/PXE ARM blobs are also intentionally absent, but
they are outside the standard/multisprite scope of this inventory.

A VCSC conversion must replace the generated application inputs with an
explicit included module, module-owned state declarations, and VCSC game-logic
entry points. It must not pretend the retained tree can already assemble by
itself.

## What `vcsc-as` already provides

The assembler already has most of the underlying mechanisms needed by the
kernels:

- recursive source includes;
- source macros with hygienic `@` local labels;
- conditional assembly and definedness tests;
- mutable assembler variables;
- repeat blocks;
- `.org`, `.rorg`, `.rend`, `.align`, `.res`, `.byte`, and `.word`;
- explicit addressing-mode suffixes;
- named unofficial instructions through `--illegals`;
- raw `opXX` spellings when an exact unofficial byte is required.

Across all retained kernels, unofficial `DCP` appears 22 times, `LAX` 13 times,
and `SBX` 10 times. The bundled illegal-opcode table accepts the retained
`SBX` spelling directly as an alias for `AXS`, and accepts `ASR` directly as an
alias for `ALR`. The selected minimal branch therefore preserves both original
mnemonics during normalization. Every converted kernel
build must deliberately enable the unofficial table and task 20d must
regression-test the final emitted bytes.

## Mechanical DASM-to-VCSC syntax work

Most source conversion is mechanical and should be reproducible rather than
performed as an unreviewable hand edit:

| Retained DASM form | VCSC assembler form/action |
| --- | --- |
| `include "file"` | `.include "file"` |
| `IFCONST name` / `IFNCONST name` | `.ifdef name` / `.ifndef name` |
| `IF expr`, `ELSE`, `ENDIF` | `.if expr`, `.else`, `.endif` |
| DASM equality `=` inside `IF` | VCSC equality `==` |
| `MAC name` / `ENDM` | `MACRO name ...` / `ENDM` |
| positional macro argument `{1}` | named macro parameter |
| macro-local `.name` labels/variables | hygienic `@name` labels and `.set` variables |
| `SET` | `.set` |
| `REPEAT` / `REPEND` | `.repeat` / `.endrepeat` |
| `ORG` / `RORG` | `.org` / `.rorg`, with explicit `.rend` before a new physical origin |
| `DS` | `.res` |
| `ECHO` / `ERR` | `.echo` / `.error` |
| DASM `.w` forced-wide suffix | `.a`, `.ax`, or `.ay`, selected from the operand mode |
| parenthesized expression grouping | braces, because parentheses are reserved for 6502 indirect addressing |
| `processor 6502` | remove; CPU/opcode selection is a tool option |
| `SEG.U` | remove; state is declared by the included VCSC module and referenced by symbol |
| bare filenames in `.inc` manifests | explicit, ordered `.include` directives in a generated harness |

Only five macros are defined in the retained standard/multisprite material:
`SLEEP`, `VERTICAL_SYNC`, `CLEAN_START`, `SET_POINTER`, and `RETURN`. Porting
those deliberately is safer than adding a broad DASM-compatibility mode to the
assembler.

## Real integration constraints

### 1. Module-owned RAM and genuine layout requirements

The retained headers assign a complete fixed RIOT map because the old generated
source environment had no linker-managed object storage. An included VCSC
module does not need to preserve those absolute addresses. It declares the
state used by its selected conditional configuration and lets the ordinary
compiler/linker allocator place it.

The first contract is now maintained under
`kernels/standard_4k_ntsc/`. It declares 38 mandatory RIOT bytes: 23 bytes of
application-visible object/score state and 15 bytes of private workspace. The
application separately supplies one contiguous 48-byte playfield in mutable RAM
or constant ROM under the direct-linked symbol `vcs_standard_playfield`. Only
layout relationships used by indexed or cycle-sensitive assembly remain
contractual:

- five horizontal positions in one array;
- the six score-pointer bytes immediately followed by six transient bytes;
- one contiguous application-provided 48-byte playfield with a timing-safe
  symbol low byte in `$54..$D0`;
- player graphics and the score table kept within individual 256-byte pages;
- the source's two page-alignment guards retained for cycle-critical code.

No universal `$80`-based kernel ABI is being created. Vertical-reflect,
multisprite, status-bar, banking, and Superchip configurations need separate
contracts because their live state and constraints differ.

### 2. Hidden hardware-stack use

The source call graph accounts for ordinary VCSC calls, but the minimal retained
overscan routine also calls `scorepointerset` internally. The selected linker
configuration uses `callstack_extra = $0002` to reserve that one hidden JSR
level at the top of RIOT RAM in addition to the normal call-graph and startup
allowances.

The score row pipeline temporarily copies and restores S without pushing,
pulling, calling, or returning while S is repurposed. That behavior needs no
additional physical bytes, but the converted source must preserve the save/
restore sequence exactly. Any later hook, push, pull, or assembly call must
update the contract and stack reserve before it is enabled.

### 3. Startup and frame ownership

VCSC owns reset, vectors, DATA/BSS initialization, and application startup. The
retained startup and footer are not included in the first module. Application
logic runs during overscan with `VBLANK` asserted and calls one void
`vcs_standard_kernel_drawscreen()` entry. The module then owns sync,
positioning, visible scanlines, and score drawing before asserting `VBLANK` and
returning.

The boundary requires decimal mode clear on entry and exit. A, X, Y, N/V/Z/C,
TIA graphics/motion/playfield/sync registers, and RIOT timer state are
caller-clobbered while the module is active.

### 4. Application hooks

The minimal contract enables no application-supplied hook. This keeps the first
static cartridge's call graph and timing closed. A later slice may add one void
vblank/overscan hook through a documented stack-safe wrapper after the kernel is
byte- and timing-stable.

### 5. Linker/cartridge model

The current production linker profile is an unbanked 4K image. The legacy
headers and footers also describe 2K, 8K, 16K, 32K, and 64K layouts, logical
origins, hotspots, cross-bank return trampolines, and optional Superchip RAM.
Those require real bank-aware placement and image-writing support. They are not
mere assembler syntax.

The initial target is therefore exactly:

- NTSC and stable 262-line non-interlaced output;
- unbanked 4K;
- no Superchip, DPC+, or PXE;
- the non-reflected standard kernel;
- default asymmetric playfield and default decimal score;
- no optional color/height tables, status bar, paddle path, debug path,
  mini-kernel, or application hook.

## Language-level fit

VCSC is already suitable for overscan/vblank game logic, state updates, BCD
scores, ROM tables, and hardware-register access. It is not intended to replace
the cycle-counted display loop. The clean split is:

- the included VCSC module owns game state and its source-visible declarations;
- included normalized assembly owns scanline timing and TIA writes;
- ordinary module symbols expose the agreed state to both VCSC and assembly;
- wrappers transfer control only at safe frame boundaries.

The packed `bcd24_t` and `bcd32_t` types are a particularly good fit for the
kernel score paths. The selected module owns its `bcd24_t` score object through
ordinary allocation; the normalized assembly refers to that module symbol.

## Incremental conversion plan

### Phase 1 — source-integration contract (complete)

The maintained `kernels/standard_4k_ntsc/` contract now selects one exact
configuration, declares 38 mandatory module bytes plus the application-provided
RAM-or-ROM playfield, documents frame and register ownership, records real
adjacency/page constraints, and supplies a matching linker configuration with a
two-byte hidden-stack allowance.

### Phase 2 — reproducible source normalization (complete)

`kernels/standard_4k_ntsc/normalize.pl` now reads only the selected retained
inputs and deterministically generates:

- `standard_4k_ntsc_macros.inc`, containing deliberate ports of all five macros;
- `standard_4k_ntsc_kernel.s`, containing the active overscan/visible kernel and
  exact 88-byte default score table.

Both generated files embed SHA-256 provenance for every retained input. The
normalizer selects only the documented configuration, preserves comments,
localizes retained labels, maps fixed-map names to module symbols, converts
conditionals and expressions, preserves `SBX`/`ASR` now that `illegals.cfg`
accepts them directly, converts `.w` to explicit addressing-family suffixes,
and preserves the two page guards. The
address-dependent DASM page-tail repeat is represented by sixteen layout-time
conditional NOP slots because `vcsc-as` expands `.repeat` before layout.

The regression regenerates both files byte-for-byte, rejects stale outputs,
assembles the kernel with `vcsc-as --illegals`, verifies its current o26/map,
checks the five macros separately, and proves the selected source is rejected
without unofficial mnemonics enabled. The retained source tree itself remains
untouched.

### Phase 3 — minimal standard-kernel cartridge

1. Build the no-bankswitch, no-Superchip profile with fixed test state.
2. Drive a static background/playfield, players, missiles, ball, and score.
3. Verify reset vectors, exact 4K size, ordinary RAM allocation, adjacency/page
   constraints, hidden stack reserve, and every forced addressing mode.
4. Run Stella timing regression and confirm stable 262-line NTSC frames.
5. Record exact linked ROM costs instead of guessing from source lines.

### Phase 4 — connect VCSC logic

1. Add one stack-safe void VCSC vblank/overscan hook.
2. Update module state from VCSC source.
3. Prove that stack metadata and `callstack_extra` cover the complete boundary.

### Phase 5 — grow standard-kernel coverage

Add one option at a time with a contract revision and measured RAM, ROM, stack,
and timing deltas. Vertical reflection and status-bar variants are separate
profiles rather than undocumented switches on the minimal one.

### Phase 6 — multisprite, then banking

Port multisprite only after the standard integration is stable. Its stack-
pointer tricks and nearly complete RAM ownership deserve a separate contract.
Add 8K+ bankswitching and Superchip support only after both unbanked profiles are
working; DPC+/PXE remains distinct because the retained snapshot intentionally
lacks the required ARM blobs.

## Conclusion

The conversion is worth attempting. The assembler syntax gap is manageable and
mostly mechanical. The real work is preserving each selected kernel's source-
level state relationships, stack behavior, frame ownership, and timing without
inventing a universal ABI. The first contract now makes those boundaries
explicit; the next step is changing dialect without changing behavior.
