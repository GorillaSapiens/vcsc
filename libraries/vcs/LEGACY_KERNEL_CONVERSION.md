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

1. normalize the retained DASM source into `vcsc-as` syntax without modifying
   the vendored upstream files;
2. define a kernel-specific RAM, hardware-stack, startup, and call ABI;
3. link that assembly kernel with VCSC game logic; and
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

A VCSC conversion must replace the generated bB inputs with an explicit kernel
configuration header, fixed RAM bindings, and VCSC game-logic entry points. It
must not pretend the retained tree can already assemble by itself.

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

The retained kernels use unofficial `DCP` 22 times, `LAX` 13 times, and `SBX`
10 times. All three are representable by the existing illegal-opcode table.
That is not a blocker, but every converted kernel build must deliberately enable
that table and must regression-test the emitted bytes.

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
| `SEG.U` | replace with explicit VCSC segment definitions or fixed-RAM declarations |
| bare filenames in `.inc` manifests | explicit, ordered `.include` directives in a generated harness |

Only five macros are defined in the retained standard/multisprite material:
`SLEEP`, `VERTICAL_SYNC`, `CLEAN_START`, `SET_POINTER`, and `RETURN`. Porting
those deliberately is safer than adding a broad DASM-compatibility mode to the
assembler.

## Real integration incompatibilities

### 1. Fixed RAM ownership

Both kernel families assume a complete, fixed RIOT RAM layout beginning at
`$80`. The standard map assigns player state at `$80`, pointers and score state
through `$A3`, user/playfield storage through the middle of RAM, auxiliaries at
`$F0-$F5`, and kernel/stack bytes at `$F6-$FF`. The multisprite map similarly
assigns nearly every byte from `$80` through `$F5` and also reserves `$F6-$FF`.

The stock VCSC runtime currently asks the linker to place a 16-byte zero-page
workspace plus globals, fixed parameters, return objects, locals, and expression
scratch into the same `$80-$FF` region. A converted kernel therefore needs an
explicit ABI profile that says which kernel bytes are:

- permanently owned by the kernel;
- available to VCSC persistent variables;
- available to VCSC pooled scratch/runtime helpers;
- overlaid only during overscan/vblank; and
- unavailable because they are hardware-stack storage.

Merely declaring `ref` aliases for the legacy kernel addresses is insufficient: the
linker must also prevent ordinary VCSC allocation from colliding with them.

### 2. Hardware-stack ownership

The kernels do more than ordinary `JSR`/`RTS`. They contain `PHA`, `PLA`, `PHP`,
`PLP`, `TSX`, and `TXS`, and the multisprite kernel deliberately manipulates the
stack pointer during cycle-critical display code. The standard RAM maps call
`$F6-$FF` stack bytes and sometimes use pushes/pulls as compact cycle delays.

The current VCSC linker sizes the top-of-RAM hardware-stack reserve from
source-level call-graph metadata and does not account for stack operations or
calls hidden in separately assembled routines. A kernel integration must add
one of these explicit contracts:

- assembly-provided call/stack metadata understood by the linker; or
- a kernel profile with a fixed stack ceiling and conservative reserved range.

No VCSC function may be entered through a normal call while a kernel has
repurposed the stack pointer unless an assembly wrapper first restores the
agreed VCSC stack state. Visible-kernel entry may need to be jump/continuation
based rather than modeled as a normal C-like function call.

### 3. Startup and frame ownership

The legacy startup clears RAM by driving the hardware stack through memory,
initializes its fixed score/playfield variables, and dispatches differently for
banked cartridges. It conflicts with the stock VCSC startup and cannot simply
be linked beside it.

A converted cartridge needs one startup owner. For the first port, use a
kernel-specific startup that initializes the legacy kernel ABI state and any VCSC data
or BSS tables explicitly. The stock startup should not be pulled in as a second
reset path.

### 4. Assembly call graph and symbol ABI

The kernels call internal assembly routines and optional hooks such as
`vblank_bB_code`; the current source-level call graph cannot see those edges.
Separately assembled hooks also do not automatically advertise VCSC parameter,
return-object, scratch, or stack requirements.

The first integration should use small, documented assembly wrappers with a
minimal contract:

- no ordinary source parameters across the boundary initially;
- no value returns initially;
- explicitly exported entry labels;
- explicitly imported VCSC hook labels;
- caller-clobbered A/X/Y;
- decimal mode clear on entry and exit; and
- stack state restored before any VCSC `JSR`.

Once that works, richer wrappers can be added deliberately rather than assuming
that an arbitrary assembly label is a normal VCSC function.

### 5. Linker/cartridge model

The current production linker profile is an unbanked 4K image. The legacy
headers and footers also describe 2K, 8K, 16K, 32K, and 64K layouts, logical
origins, hotspots, cross-bank return trampolines, and optional Superchip RAM.
Those require real bank-aware placement and image-writing support. They are not
mere assembler syntax.

The initial target must therefore be:

- NTSC;
- unbanked 4K;
- no Superchip;
- no DPC+/PXE;
- no alternate font dependency;
- one selected standard-kernel configuration.

Bankswitching, Superchip windows, and multisprite should remain later milestones.

## Language-level fit

VCSC is already suitable for overscan/vblank game logic, state updates, BCD
scores, ROM tables, and hardware-register access. It is not intended to replace
the cycle-counted display loop. The clean split is:

- VCSC source owns game state and non-cycle-critical logic;
- separately assembled kernel code owns scanline timing and TIA writes;
- fixed `ref` declarations expose the agreed kernel state to VCSC;
- wrappers transfer control only at safe frame boundaries.

The packed `bcd24_t` and `bcd32_t` types are a particularly good fit for the
kernel score paths, but their storage must be bound to the kernel's fixed score
bytes rather than separately allocated.

## Incremental conversion plan

### Phase 1 — define the ABI profile

1. Choose one minimal standard-kernel configuration and enumerate its live RAM
   bytes after conditional assembly.
2. Add linker/profile support that reserves fixed RAM ranges and places the VCSC
   runtime workspace only in explicitly approved bytes.
3. Define a fixed hardware-stack ceiling/reserve for the kernel profile and a
   way to account for separately assembled call/stack usage.
4. Define kernel-owned startup and frame-boundary entry labels.

This is the next implementation step. Without it, a syntactically converted
kernel could assemble and still corrupt itself immediately.

### Phase 2 — reproducible source normalization

1. Keep retained source semantics unchanged and preserve its exact `LICENSE.txt`; place adapted code in a separate VCSC kernel directory.
2. Add a conversion script or clearly separated adapted copy under a new VCSC
   kernel directory.
3. Port the five macros and translate directives/mode suffixes mechanically.
4. Generate the missing configuration aliases and a minimal replacement for the
   bB-generated application fragments.
5. Assemble with `vcsc-as --illegals` and preserve listings/maps for review.

### Phase 3 — minimal standard-kernel cartridge

1. Build a no-bankswitch, no-Superchip, minimal-feature 4K cartridge.
2. Drive a static background/playfield and one simple player from fixed test
   data.
3. Verify reset vectors, ROM size, RAM placement, and every forced addressing
   mode.
4. Run the simulator/Stella timing regression and confirm stable 262-line NTSC
   frames.
5. Where an upstream DASM reference image can be produced, compare bytes or
   explain every intentional difference.

### Phase 4 — connect VCSC logic

1. Expose kernel state through a dedicated VCSC interface file of fixed refs.
2. Call one void VCSC overscan/vblank hook through a stack-safe wrapper.
3. Add BCD score and sprite/playfield updates from VCSC source.
4. Prove that linker RAM reservations and assembly call metadata prevent
   collisions and stack under-allocation.

### Phase 5 — grow standard-kernel coverage

Add one option at a time: score, playfield drawing/scrolling, player colors,
lives/status bar, vertical reflection, and other conditionally assembled paths.
Each option needs a size/map/timing regression.

### Phase 6 — multisprite, then banking

Port multisprite only after the standard-kernel ABI is stable. Its stack-pointer
tricks, sprite sorting, and nearly complete RAM ownership deserve a separate
profile. Add 8K+ bankswitching and Superchip support only after both unbanked
profiles are working; DPC+/PXE remains a distinct project because the retained
snapshot intentionally lacks the required ARM blobs.

## Conclusion

The conversion is worth attempting. The assembler syntax gap is manageable and
mostly mechanical. The real work is the kernel ABI: fixed RAM, stack ownership,
startup ownership, assembly call metadata, and banked image layout. Solving
those honestly will produce a useful VCSC kernel integration. Skipping them
would produce a cartridge-shaped memory-corruption device.
