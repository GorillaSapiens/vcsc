```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Minimal unbanked 4K NTSC standard-kernel contract

This directory defines the first source-integration contract for the retained
standard kernel. It is deliberately narrower than “the standard kernel” as a
whole. It covers one non-reflected, non-banked, non-Superchip NTSC configuration
and nothing else.

A deterministic source normalizer and checked-in `vcsc-as` output live beside
this contract. The normalized source assembles independently to a reviewable
`.o26` object. Linking that object into the first complete cartridge and
verifying its final placement and scanline timing remain separate integration
work.

## Selected configuration

The profile includes the retained two-line standard visible kernel, standard
overscan/positioning routine, default asymmetric playfield, and default 8x8
decimal score graphics. VCSC owns reset, vectors, DATA/BSS initialization, and
application logic.

The following retained options are absent and are outside this contract:

- vertical reflection;
- multisprite;
- status bar or six-lives mini-kernels;
- banking, 2K layout, Superchip, DPC+, or PXE;
- interlace;
- custom kernel macros or mini-kernels;
- player-color tables, playfield-color/height tables, paddle reading, screen
  shake, score fading, playfield-in-score, debug displays, and alternate fonts.

No optional application hook is enabled in the minimal profile. A later profile
may add one stack-safe void vblank/overscan hook after the static cartridge is
stable.

## Reproducible normalized source

The normalization artifacts are:

- `normalize.pl` — the deliberately narrow deterministic translator;
- `standard_4k_ntsc_macros.inc` — explicit `vcsc-as` ports of `SLEEP`,
  `VERTICAL_SYNC`, `CLEAN_START`, `SET_POINTER`, and `RETURN`; and
- `standard_4k_ntsc_kernel.s` — the selected overscan, visible kernel, and
  88-byte default score table normalized into current assembler syntax.

Regenerate and verify them from the repository root with:

```sh
libraries/vcs/kernels/standard_4k_ntsc/normalize.pl
libraries/vcs/kernels/standard_4k_ntsc/normalize.pl --check
```

The normalizer reads only the retained-source boundary listed below, embeds the
SHA-256 of every input in both outputs, and fails if the selected source
relationships no longer match. A fresh generation is byte-compared with the
checked-in files by the test suite. `normalize.pl` is a source-checkout
development tool and is not installed, because the installed support bundle does
not carry all retained generator inputs; the generated `.s` and `.inc` files are
installed.

The conversion is intentionally not a general DASM-compatibility mode. It
selects only this profile's active conditional branches, changes bare DASM
labels to procedure-local `@label:` definitions, binds retained fixed-map names
to the module symbols, preserves the retained `SBX`/`ASR` spellings now accepted
by `illegals.cfg`, converts forced `.w` addressing to `.a`/`.ax`/`.ay`, preserves the two
retained code-page guards, and adds an explicit page boundary before the score
table. DASM's address-dependent page-tail `REPEAT` cannot use
`vcsc-as`'s pre-layout `.repeat`; the normalizer emits sixteen conditional NOP
slots that produce the same zero-to-sixteen byte pad to low byte `$FA`.
Retained comments are copied without symbol rewriting.

The selected source must be assembled with unofficial mnemonics enabled:

```sh
vcsc-as --illegals \
  -I libraries/vcs/kernels/standard_4k_ntsc \
  -o standard_4k_ntsc_kernel.o26 \
  libraries/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s
```

That produces an unresolved relocatable kernel object by design.
`examples/05_static_kernel_test` is the first complete integration: it links the
object to module state, enforces final page placement, checks exact unofficial
opcode bytes, and has been verified by Stella 7.0 at a stable 262 lines and
60.0 Hz.

## Source-level inclusion

The application includes the machine definition, defines the playfield object,
and then includes the kernel contract. A mutable playfield uses RIOT RAM:

```vcsc
include "vcs.c26"
uint8_t vcs_standard_playfield[48];
include "kernels/standard_4k_ntsc/standard_4k_ntsc.c26"
```

A fixed playfield uses cartridge ROM:

```vcsc
include "vcs.c26"
const uint8_t vcs_standard_playfield[48] := {
   // twelve rows, four bytes per row
};
include "kernels/standard_4k_ntsc/standard_4k_ntsc.c26"
```

The object name and extent are contractual. The module aliases it as
`VCS_STANDARD_PLAYFIELD`. The kernel references that symbol directly with
absolute-indexed loads. It does **not** store or follow a runtime playfield
pointer: doing so would cost two RIOT bytes, add at least one cycle to every
playfield read, risk an additional page-cross cycle, and interfere with Y usage
inside the asymmetric visible kernel.

Build with the matching linker configuration and illegal-opcode table:

```sh
vcsc -I libraries/vcs -Wa,--illegals \
  -T libraries/vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg \
  game.c26 \
  libraries/vcs/kernels/standard_4k_ntsc/standard_4k_ntsc_kernel.s \
  -o game.bin
```

The module exports one entry point:

```vcsc
extern void vcs_standard_kernel_drawscreen(void);
```

It accepts no parameters and returns no value. The application communicates
through the application-visible display state and the application-provided
playfield object. No separately maintained fixed RIOT address map is part of
this interface.

## What the 48-byte playfield represents

The playfield is not a 48-by-8 framebuffer. It is the entire coarse main
playfield grid for this profile:

```text
48 bytes = 12 logical rows x 4 bytes per row
         = 12 rows x 32 independently controlled bits
```

Each logical row contains four bytes in the order needed to produce 16
asymmetric columns on the left and 16 on the right. PF0 remains unused. In the
default configuration the two-scanline kernel repeats each row for eight kernel
iterations, so one logical row is 16 scanlines high and all twelve rows occupy
192 visible scanlines. Players, missiles, ball, and the six-digit score are
separate overlays and are not stored in these 48 bytes.

## Frame ownership

The application executes while `VBLANK` is asserted and owns overscan game
logic. Calling `vcs_standard_kernel_drawscreen()` transfers frame control to the
module. The module:

1. completes the current overscan interval;
2. generates the three-line NTSC vertical-sync sequence;
3. performs horizontal positioning and score-pointer setup;
4. owns all cycle-counted visible scanlines, including the six-digit score; and
5. asserts `VBLANK` before returning to application overscan.

The call must begin with decimal mode clear. The converted wrapper must also
return with decimal mode clear. The first cartridge, `examples/05_static_kernel_test`, produces a stable
262-scanline non-interlaced NTSC frame at 60.0 Hz in Stella 7.0. The developer
status overlay is used as the final timing authority rather than treating
comments in the retained source as proof.

## State ownership and RAM cost

The contract distinguishes kernel-private workspace, application-visible state,
and optional playfield storage instead of calling all display data “kernel
RAM.”

| State group | Bytes | Ownership and storage |
| --- | ---: | --- |
| Object positions, dimensions, sprite pointers, score, and score color | 23 | Declared by the module; application owns the persistent values in RIOT RAM |
| Score-pointer/transient workspace, playfield row position, and internal scratch | 15 | Kernel-private RIOT RAM |
| Playfield | 48 | Supplied by the application; mutable RAM or constant ROM |
| **Mandatory module-declared RAM** | **38** | 23 application-visible + 15 private |
| **RAM with mutable playfield** | **86** | 38 mandatory + 48 application-selected playfield |

The reduced stock VCSC runtime uses eight RIOT bytes. With the ordinary
`main -> drawscreen` source call depth, the matching linker configuration
reserves four call-graph bytes plus two hidden-kernel bytes. Therefore:

```text
fixed ROM playfield:   128 - 38 - 8 - 6 = 76 bytes left
mutable RAM playfield: 128 - 86 - 8 - 6 = 28 bytes left
```

Those numbers are budgeting examples, not promises that every future option or
initializer will fit. A game pays the 48-byte RIOT cost only when it actually
needs to alter the playfield at runtime.

## Demonstrable placement constraints

Most state has no fixed address. Only these constraints are contractual:

- `vcs_standard_object_x[5]` is contiguous because the positioning loop indexes
  all five objects from one base.
- `vcs_standard_pointer_workspace[12]` is contiguous because the score kernel
  treats its six pointer bytes and six transient bytes as one offset-addressed
  block.
- The application-provided `vcs_standard_playfield[48]` is contiguous and is
  addressed directly, not through a pointer.
- For the default `pfwidth=4`, `pfadjust=0` path, the 48-byte playfield must not
  cross a 256-byte page, so its low byte may be anywhere in `$00..$D0`. The
  normalized kernel uses an ordinary zero-based X offset and direct
  `vcs_standard_playfield+column,x` accesses; the inherited `$54` bias is gone.
  This condition applies equally to RAM and ROM playfields.
- Each active P0/P1 sprite table must stay within one 256-byte page for every
  row the kernel may read; a page-crossing indirect load changes scanline timing.
- The 88-byte default score table must occupy one page. Its ten glyphs plus the
  retained blank glyph therefore cannot cross a page boundary.
- Two cycle-critical code regions retain page-alignment guards from the source.
  The normalized source preserves both guards with `.align 256`.
- The score-table segment has its own `.align 256`, and the linker profile
  enforces page alignment for both `KERNEL_CODE` and `KERNEL_RODATA` objects.

The source-contract regression builds both a RAM and a ROM playfield and rejects
either linked address if its 48 bytes cross a page. Until the page-containment
linker constraint is implemented, ROM fixtures use temporary `.align 256`.
There is no fixed `$80`-based variable map and no special `$54` lower bound.

## Register, flag, and hardware-register clobbers

The draw call clobbers A, X, Y, and N/V/Z/C. Decimal mode must be clear on entry
and exit. The module owns TIA graphics, motion, playfield, sync, and blanking
registers and RIOT `INTIM`/`TIM64T` while the call is active. Applications must
not expect those register values to survive.

Persistent application-visible state is available again after return. The
six transient workspace bytes, playfield row position, and two internal scratch
bytes are undefined after every draw. The kernel temporarily decrements object Y
values while drawing but restores the persistent values before return.

## Hidden hardware-stack use

A normal VCSC call to `vcs_standard_kernel_drawscreen()` is visible to the
source call graph. The retained overscan routine additionally calls
`scorepointerset`; that one nested JSR level is hidden inside assembly and needs
two more hardware-stack bytes.

`vcs_standard_4k_ntsc.cfg` therefore sets `callstack_extra = $0002`. The linker
adds that amount to its normal call-graph and initializer reserves and exposes
it as `__call_stack_extra`. The score row pipeline temporarily copies and
restores S but performs no push, pull, call, or return while S is repurposed, so
that trick requires no additional physical stack bytes in this profile.

Adding any assembly call, push, pull, hook, or stack-pointer manipulation must
update this contract and its regression before it is accepted.

## ROM and feature-cost ledger

The `.c26` source contract itself emits no code and no initialized data. A ROM
playfield costs 48 cartridge bytes instead of RIOT RAM bytes. The normalized object contains a page-padded 768-byte `KERNEL_CODE` segment
and an 88-byte `KERNEL_RODATA` score table. In the first complete cartridge they
are fixed at `$F300..$F5FF` and `$F600..$F657`; the application playfield is ROM
backed at `$F154`. These are measured map values for the selected profile.

All listed optional features are rejected by this profile, so no speculative
RAM or ROM deltas are contractual. A feature may be added only as a later
profile revision with measured linked ROM bytes, module-declared RAM changes,
stack changes, and a timing regression. This prevents “free” conditional
features from silently consuming the last few RIOT bytes.

## Retained-source boundary used by the normalizer

The deterministic normalizer draws only from these retained inputs:

- `common/macro.h` for `SLEEP`, `VERTICAL_SYNC`, `CLEAN_START`, and
  `SET_POINTER`;
- `RETURN` and the active symbol relationships from `common/2600basic.h`;
- `standard/std_kernel.asm`;
- `standard/std_overscan.asm`; and
- the default data from `common/score_graphics.asm`.

The retained startup, footer vectors, generated application fragments,
playfield helper libraries, vertical-reflect source, status-bar source,
multisprite source, and bank/Superchip manifests are excluded. The retained
source tree remains untouched; adapted files live beside this contract.

### Application sprite and projectile notes

The kernel supports P0, P1, M0, M1, and BL simultaneously. Player rows are
fetched from highest index down to zero; use `VCS_STANDARD_SPRITE_GLYPH(...)`
when writing eight-row art top-to-bottom. Player graphics must remain within
one 256-byte page because a page-crossing indirect load changes visible-kernel
timing. The standard profile page-aligns RODATA, and the static example keeps
its two eight-byte player tables first in that segment. Missile width comes
from the upper NUSIZ bits, while player copy/size comes from the lower bits.
