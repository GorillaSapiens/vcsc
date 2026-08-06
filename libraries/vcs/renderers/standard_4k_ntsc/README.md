```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Standard NTSC all-five renderer contract

> **Legacy monolithic profile.** This profile remains installed as a stable
> regression and compatibility target. New applications should use the explicit
> lifecycle components documented in `renderers/COMPONENT_CONVERSION.md`; there
> is no active roadmap requirement to retire this working profile.

This directory defines the first source-integration contract for the retained
standard renderer. It is deliberately narrower than “the standard renderer” as a
whole. Its original reference cartridge is the non-reflected, unbanked 4K NTSC
configuration.  The same maintained object is now also certified as a component
of F8, F6, F4, and F8SC cartridges when the bank-local requirements below are
followed.

A deterministic source normalizer and checked-in `vcsc-as` output live beside
this contract. The normalized source assembles independently to a reviewable
`.o26` object. Linking that object into the first complete cartridge and
verifying its final placement and scanline timing remain separate integration
work.

## Selected configuration

The profile includes the retained two-line standard visible renderer, standard
overscan/positioning routine, default asymmetric playfield, and default 8x8
decimal score graphics. VCSC owns reset, vectors, DATA/BSS initialization, and
application logic.

The following retained options are absent and are outside this contract:

- vertical reflection;
- multisprite;
- status bar or six-lives mini-renderers;
- 2K layout, DPC+, PXE, banked RAM, or mapper switching during beam-critical work;
- interlace;
- custom renderer macros or mini-renderers;
- player-color tables, playfield-color/height tables, paddle reading, screen
  shake, score fading, playfield-in-score, debug displays, and alternate fonts.

The profile exposes one optional end-of-frame application boundary:
`vcs_standard_overscan_hook()`. The renderer object supplies a weak no-op fallback,
so an application pays no source-code cost unless it defines the exact
`void(void)` hook. No other optional renderer feature is enabled.

## Reproducible normalized source

The normalization artifacts are:

- `normalize.pl` — the deliberately narrow deterministic translator;
- `standard_4k_ntsc_macros.inc` — explicit `vcsc-as` ports of `SLEEP`,
  `VERTICAL_SYNC`, `CLEAN_START`, `SET_POINTER`, and `RETURN`; and
- `standard_4k_ntsc_renderer.s26` — the selected overscan, visible renderer, and
  88-byte default score table normalized into current assembler syntax.

Regenerate and verify them from the repository root with:

```sh
libraries/vcs/renderers/standard_4k_ntsc/normalize.pl
libraries/vcs/renderers/standard_4k_ntsc/normalize.pl --check
```

The normalizer reads only the retained-source boundary listed below, embeds the
SHA-256 of every input in both outputs, and fails if the selected source
relationships no longer match. A fresh generation is byte-compared with the
checked-in files by the test suite. `normalize.pl` is a source-checkout
development tool and is not installed, because the installed support bundle does
not carry all retained generator inputs; the generated `.s26` and `.inc` files are
installed.

The conversion is intentionally not a general DASM-compatibility mode. It
selects only this profile's active conditional branches, changes bare DASM
labels to procedure-local `@label:` definitions, binds retained fixed-map names
to the module symbols, converts forced `.w` addressing to `.a`/`.ax`/`.ay`,
replaces the selected profile's final `ASR`, `SBX`, and odd-delay `NOP.z` sites
with scheduled legal instructions, preserves the two retained code-page guards,
and adds an explicit page boundary before the score table. DASM's address-dependent page-tail `REPEAT` cannot use
`vcsc-as`'s pre-layout `.repeat`; the normalizer emits a guarded
`.align 256, $FA, $EA`, which produces the same zero-to-sixteen bytes of NOP
padding to low byte `$FA` without hand-expanded conditional slots.
Retained comments are copied without symbol rewriting.

The historical unofficial forms and their task-20r legal replacements are
recorded in [`UNOFFICIAL_OPCODES.md`](UNOFFICIAL_OPCODES.md). A direct source scan finds no unofficial mnemonics, every checked-in profile
recipe assembles without `--illegals`, and the linked-profile regression rejects
unofficial instruction bytes even when they are introduced with a raw `opXX`
spelling. The former empty TSV inventory was retired after the linked-byte gate
made it redundant.

The normalized source itself now assembles without unofficial mnemonics:

```sh
vcsc-as \
  -I libraries/vcs/renderers/standard_4k_ntsc \
  -o standard_4k_ntsc_renderer.o26 \
  libraries/vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_renderer.s26
```

That produces an unresolved relocatable renderer object by design.
The exact standard-renderer regression cartridges live under
`test/fixtures/vcs_examples/`; user-facing examples are only smoke-built and
may be edited without changing test harness constants.

`test/fixtures/vcs_examples/05_static_renderer/golden.c26` is the retained complete integration: it links the
object to module state, enforces final page placement, checks the legalized
cycle schedule, and has been verified by Stella 7.0 at a stable 262 lines and
60.0 Hz.

## Source-level inclusion

The application includes the machine definition, defines a fixed playfield in
cartridge ROM, and then includes the renderer contract:

```vcsc
include "vcs.c26"
const uint8_t vcs_standard_playfield[48] := {
   // twelve rows, four bytes per row
};
include "renderers/standard_4k_ntsc/standard_4k_ntsc.c26"
```

The symbol remains application-provided and directly linked, but this selected
profile no longer has enough RIOT RAM for a mutable playfield. The contract
regression deliberately verifies that a 48-byte RAM definition fails cleanly.

The object name and extent are contractual. The module aliases it as
`VCS_STANDARD_PLAYFIELD`. The renderer references that symbol directly with
absolute-indexed loads. It does **not** store or follow a runtime playfield
pointer: doing so would cost two RIOT bytes, add at least one cycle to every
playfield read, risk an additional page-cross cycle, and interfere with Y usage
inside the asymmetric visible renderer.

The renderer carries its own linker constraints, so an ordinary default 4K
build needs no renderer-specific cfg. This profile deliberately does not enable
the assembler's unofficial-opcode table:

```sh
vcsc -I libraries/vcs \
  game.c26 \
  libraries/vcs/renderers/standard_4k_ntsc/standard_4k_ntsc_renderer.s26 \
  -o game.bin
```

An explicit build may equivalently pass `-T libraries/vcs/vcs.cfg` and
`libraries/vcs/vcs_4k.c26`. The retained `vcs_standard_4k_ntsc.cfg` is only a
deprecated compatibility filename for old commands; it contains no renderer-
specific placement or stack facts.

The module declares the draw entry:

```vcsc
extern void vcs_standard_renderer_drawscreen(void);
```

The optional `vcs_standard_overscan_hook()` signature remains exactly
`void(void)`, but the contract intentionally does not predeclare it.  An
application defines the hook after including the contract; this permits a
banked definition such as `bank1 void vcs_standard_overscan_hook(void)` without
an incompatible unqualified declaration.  A strong application definition
overrides the renderer object's weak no-op. The
application communicates through the module-owned display declarations and the
application-provided playfield object; no separately maintained fixed RIOT
address map is part of this interface.

## Banked composition

`examples/09_bankswitching/02_standard_renderer/` is the consolidated public F8
diagnostic.  It links this exact renderer object with the generic F8 C26 profile.
The renderer object's `@startup` component contract pins its code and score table
to the startup bank, while the application declares its playfield and sprite art
as `bank0 page const` objects.  The only deliberate cross-bank edge is the
end-of-frame hook, defined in `bank1` and called after `VBLANK` has been asserted.
Its generated JSR trampoline restores bank0 before drawscreen returns, so the next
VSYNC and every visible access begin in the renderer bank.

Private regressions build the same source and component against F6 and F4; no
renderer-by-mapper source or cfg copies exist.  The F8SC variant keeps the
timing-critical 80-byte renderer state in RIOT RAM and places only three bytes of
non-critical hook state in shared Superchip RAM.  Superchip reads and writes are
direct split-alias accesses and never generate selector traffic.

The certified diagnostic measures a 20140-cycle, 262-scanline frame.  Its banked
profiles have the same visible-write raster digest as the unbanked 4K reference.
One hook round trip costs 37 cycles in total—25 cycles more than direct JSR/RTS—
and occurs entirely during VBLANK.  Current map-locked costs are 1940 startup-bank
bytes, 94 F8/F6/F4 bank1 bytes (123 for F8SC), 30/60/120 replicated bridge bytes
for F8/F6/F4, 95 RIOT object bytes plus a 12-byte hardware stack for ordinary
banked builds, and 93 RIOT object bytes plus three shared Superchip bytes for
F8SC.

## What the 48-byte playfield represents

The playfield is not a 48-by-8 framebuffer. It is the entire coarse main
playfield grid for this profile:

```text
48 bytes = 12 logical rows x 4 bytes per row
         = 12 rows x 32 independently controlled bits
```

Each logical row contains four bytes in the order needed to produce 16
asymmetric columns on the left and 16 on the right. PF0 remains unused. In the
default configuration the two-scanline renderer repeats each row for eight renderer
iterations, so one logical row is 16 scanlines high and all twelve rows occupy
192 visible scanlines. Players, missiles, ball, and the six-digit score are
separate overlays and are not stored in these 48 bytes.

## Frame ownership

The application executes while `VBLANK` is asserted and owns overscan game
logic. Calling `vcs_standard_renderer_drawscreen()` transfers frame control to the
module. The module:

1. completes the current overscan interval;
2. generates the three-line NTSC vertical-sync sequence;
3. performs horizontal positioning and score-pointer setup;
4. owns all cycle-counted visible scanlines, including the six-digit score;
5. restores every persistent object Y value and the hardware stack pointer;
6. asserts `VBLANK`, calls `vcs_standard_overscan_hook()`, and then returns.

The hook therefore sees ordinary persistent module state, not the biased or
decremented counters used inside the visible renderer. Changes made by the hook
apply to the **next** frame. The overscan timer is already running, so the hook
must finish within the available overscan budget and must not write `VSYNC`,
`VBLANK`, `WSYNC`, `TIM64T`, or `INTIM`, recursively call drawscreen, or leave
decimal mode set. It may update module-owned display values, read inputs, and
write application-owned audio/state. Ordinary VCSC calls made by the hook are
covered by the exported call-graph edge.

The draw call and hook must enter and return with decimal mode clear. The retained static fixture
`test/fixtures/vcs_examples/05_static_renderer/golden.c26` produces a stable
262-scanline non-interlaced NTSC frame at 60.0 Hz in Stella 7.0. The developer
status overlay is used as the final timing authority rather than treating
comments in the retained source as proof.

`test/fixtures/vcs_examples/05_static_renderer` carries a checked Stella 7.0 PNG plus exact
object/playfield bounding boxes. `test/fixtures/vcs_examples/06_object_motion` is the moving
position diagnostic: a visible ruler playfield remains fixed while all five
objects traverse the complete public X=0..159 range at different integer
speeds and starting phases. Its regression locks the frame-relative object rows
**and** each RESP cycle and HMxx fine-motion value for 320 frames, and requires
every object to reach both endpoints. Merely confirming that the RAM X variables
changed is explicitly not considered a horizontal-rendering test.

## State ownership and RAM cost

The contract distinguishes renderer-private workspace, application-visible state,
and optional playfield storage instead of calling all display data “renderer
RAM.”

| State group | Bytes | Ownership and storage |
| --- | ---: | --- |
| Object positions, dimensions, sprite pointers, score, and score color | 23 | Declared by the module; application owns the persistent values in RIOT RAM |
| Score-pointer/transient workspace, playfield row position, and packed object masks | 57 | Renderer-private RIOT RAM |
| Playfield | 48 | Supplied by the application; constant ROM in this timing profile |
| **Mandatory module-declared RAM** | **80** | 23 application-visible + 57 private |

The reduced stock VCSC runtime uses eight RIOT bytes. The renderer object exports
the assembly call edge `drawscreen -> overscan_hook`, so the no-op profile's
`main -> drawscreen -> hook` depth reserves six call-graph bytes. Four
supplementary bytes cover the deeper internal mask-preparation chain. Therefore:

```text
fixed ROM playfield: 128 - 80 - 8 - 10 = 30 bytes left
```

The legal ball/missile schedule spends 44 bytes on packed vertical masks. A
48-byte mutable playfield therefore no longer fits this 128-byte RIOT-RAM
profile; applications requiring runtime playfield mutation need a different
renderer/RAM tradeoff rather than a link that only works by accident.

## Demonstrable placement constraints

Most state has no fixed address. Only these constraints are contractual:

- `vcs_standard_object_x[5]` is contiguous because the positioning loop indexes
  all five objects from one base.
- `vcs_standard_pointer_workspace[12]` is contiguous because the score renderer
  treats its six pointer bytes and six transient bytes as one offset-addressed
  block.
- The application-provided `vcs_standard_playfield[48]` is contiguous and is
  addressed directly, not through a pointer.
- For the default `pfwidth=4`, `pfadjust=0` path, the 48-byte playfield must not
  cross a 256-byte page, so its low byte may be anywhere in `$00..$D0`. The
  normalized renderer uses an ordinary zero-based X offset and direct
  `vcs_standard_playfield+column,x` accesses; the inherited `$54` bias is gone.
  This profile applies the condition to its required ROM playfield.
- Each active P0/P1 sprite table must stay within one 256-byte page for every
  row the renderer may read; a page-crossing indirect load changes scanline timing.
- The 88-byte default score table must occupy one page. Its ten glyphs plus the
  retained blank glyph therefore cannot cross a page boundary.
- Two cycle-critical code regions retain page-alignment guards from the source.
  The normalized source preserves both internal guards with `.align 256`.
- The object declares `.segmentregion ..., startup`, `.segmentalign ..., 256`,
  and `.segmentprivate ...` for `RENDERER_CODE` and `RENDERER_RODATA`. Those
  object records place both layouts in the cartridge's startup read-only region,
  align their final bases to pages, and keep the route private to this component.
  No cartridge or renderer cfg repeats those facts.

The source-contract regression builds a ROM playfield, rejects page crossing,
and also proves that the formerly supported mutable 48-byte playfield now fails
cleanly for lack of RIOT RAM. ROM fixtures use the VCSC `page` modifier, so no
companion assembly or manual page offset is required.
There is no fixed `$80`-based variable map and no special `$54` lower bound.

## Register, flag, and hardware-register clobbers

The draw call clobbers A, X, Y, and N/V/Z/C. Decimal mode must be clear on entry
and exit. The module owns TIA graphics, motion, playfield, sync, and blanking
registers and RIOT `INTIM`/`TIM64T` while the call is active. Applications must
not expect those register values to survive.

Persistent application-visible state is available again after return. The
six transient workspace bytes, playfield row position, and packed object-mask
workspace are undefined after every draw. The renderer temporarily decrements object Y
values while drawing but restores the persistent values before return.

## Hidden hardware-stack use

A normal VCSC call to `vcs_standard_renderer_drawscreen()` is visible to the
source call graph. The normalized object additionally exports a symbol-backed
`drawscreen -> vcs_standard_overscan_hook` edge. That edge makes both hardware-
stack sizing and function-activation overlay aware of the assembly-initiated
VCSC call, including any ordinary helpers called by a strong hook definition.

The packed object-mask builder still reaches an internal prepare/range chain
that is deeper than the longest source-visible path. With the hook edge already
adding one call-graph level, the normalized object declares `.callstackextra 4`;
the no-op cartridge still reserves ten physical stack bytes in total. The
linker combines that object-owned supplement with the generic `vcs.cfg`
`callstack=callgraph` policy and exposes it as `__call_stack_extra`. The score
row pipeline temporarily copies and restores S
but performs no push, pull, call, or return while S is repurposed, and the hook
is called only after S has been restored.

Adding any other assembly call, push, pull, hook, or stack-pointer manipulation
must update this contract and its regression before it is accepted.

## ROM and feature-cost ledger

The `.c26` source contract itself emits no code and no initialized data. A ROM
playfield costs 48 cartridge bytes instead of RIOT RAM bytes. The normalized
object contains a page-padded 768-byte `RENDERER_CODE` segment and an 88-byte
`RENDERER_RODATA` score table. In the current contract smoke cartridge they are
placed at `$F200..$F4FF` and `$F500..$F557`; the application playfield is ROM
backed at `$F100`. These are measured map values, not fixed addresses. The
contractual facts are startup-region ownership, page alignment, and page-safe
indexed ranges.

The overscan hook adds no module RAM. Its no-op fallback is one `RTS`; the call
site occupies three bytes inside the already page-padded renderer region. A strong
hook contributes its own linked code and activation storage. All other listed
optional features remain rejected, so no speculative RAM or ROM deltas are
contractual. A feature may be added only as a later profile revision with
measured linked ROM bytes, module-declared RAM changes, stack changes, and a
timing regression.

## Retained-source boundary used by the normalizer

The deterministic normalizer draws only from these retained inputs:

- `common/macro.h` for `SLEEP`, `VERTICAL_SYNC`, `CLEAN_START`, and
  `SET_POINTER`;
- `RETURN` and the active symbol relationships from `common/2600basic.h`;
- `standard/std_renderer.asm`;
- `standard/std_overscan.asm`; and
- the default data from `common/score_graphics.asm`.

The retained startup, footer vectors, generated application fragments,
playfield helper libraries, vertical-reflect source, status-bar source,
multisprite source, and bank/Superchip manifests are excluded. The retained
source tree remains untouched; adapted files live beside this contract.

### Application sprite and projectile notes

The renderer supports P0, P1, M0, M1, and BL simultaneously. Player rows are
fetched from highest index down to zero; use `VCS_STANDARD_SPRITE_GLYPH(...)`
when writing eight-row art top-to-bottom. Player graphics must remain within
one 256-byte page because a page-crossing indirect load changes visible-renderer
timing. The static example marks both player tables `page`, allowing the linker
to place each table wherever it fits without broad RODATA alignment. Missile width comes
from the upper NUSIZ bits, while player copy/size comes from the lower bits.
