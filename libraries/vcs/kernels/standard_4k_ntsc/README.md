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

The mechanically normalized assembly is not present yet. Task 20c adds that
source without changing the contract below; task 20d first assembles and times
it.

## Selected configuration

The profile includes the retained two-line standard visible kernel, standard
overscan/positioning routine, and default 8x8 decimal score graphics. VCSC owns
reset, vectors, DATA/BSS initialization, and application logic.

The following retained options are absent and are outside this contract:

- vertical reflection;
- multisprite;
- status bar or six-lives mini-kernels;
- banking, 2K layout, Superchip, DPC+, or PXE;
- interlace;
- custom kernel macros or mini-kernels;
- player-color tables, playfield-color/height tables, paddle reading, screen
  shake, score fading, playfield-in-score, debug displays, and alternate fonts.

No optional application hook is enabled in the minimal profile. Task 20e may add
one stack-safe void vblank/overscan hook after the static cartridge is stable.

## Source-level inclusion

Applications include the machine definition and then this module:

```vcsc
include "vcs.vcsc"
include "kernels/standard_4k_ntsc/standard_4k_ntsc.vcsc"
```

Build with the matching linker configuration and illegal-opcode table:

```sh
vcsc -I libraries/vcs -Wa,--illegals \
  -T libraries/vcs/kernels/standard_4k_ntsc/vcs_standard_4k_ntsc.cfg \
  game.vcsc -o game.bin
```

The module exports one entry point:

```vcsc
extern void vcs_standard_kernel_drawscreen(void);
```

It accepts no parameters and returns no value. The application communicates
through module-owned state. No separately maintained fixed RIOT address map is
part of this interface.

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
return with decimal mode clear. The first cartridge must produce a stable
262-scanline non-interlaced NTSC frame; task 20d verifies the exact phase lengths
rather than treating comments in the retained source as proof.

## State ownership and RAM cost

`standard_4k_ntsc.vcsc` declares all state used by this selected configuration.
The compiler and linker place it normally in RIOT RAM.

| State group | Bytes | Contract |
| --- | ---: | --- |
| Five horizontal positions | 5 | One contiguous array; indexed P0, P1, M0, M1, ball order |
| Y/height and sprite-pointer state | 14 | Persistent application-visible object state |
| Packed six-digit score | 3 | `bcd24_t`, least-significant digit pair first |
| Score-pointer/transient workspace | 12 | One contiguous block; offsets 0..5 and 6..11 are coupled |
| Score color | 1 | Persistent application-visible state |
| Default asymmetric playfield | 48 | Twelve rows by four bytes, contiguous |
| Playfield position | 1 | Kernel-owned row countdown state |
| Internal transient scratch | 2 | Ordinary module RAM; not hardware-stack storage |
| **Module total** | **86** | Enforced by `vcs_standard_kernel_contract.test` |

The stock VCSC runtime currently uses 16 more RIOT bytes. With the ordinary
`main -> drawscreen` source call depth, the matching linker configuration
reserves four call-graph bytes plus two hidden-kernel bytes. Runtime, module,
and minimum stack reservation therefore consume 108 of the 128 physical bytes,
leaving 20 bytes for application objects, compiler-generated return/local
storage, inline-expansion storage, and any initializer-specific stack allowance.
This is a budget, not a promise that every future option will fit.

## Demonstrable placement constraints

Most state has no fixed address. Only these constraints are contractual:

- `vcs_standard_object_x[5]` is contiguous because the positioning loop indexes
  all five objects from one base.
- `vcs_standard_pointer_workspace[12]` is contiguous because the score kernel
  treats its six pointer bytes and six transient bytes as one offset-addressed
  block.
- `vcs_standard_playfield[48]` is contiguous for absolute-indexed playfield
  reads.
- Each active P0/P1 sprite table must stay within one 256-byte page for every
  row the kernel may read; a page-crossing indirect load changes scanline timing.
- The 88-byte default score table must occupy one page. Its ten glyphs plus the
  retained blank glyph therefore cannot cross a page boundary.
- Two cycle-critical code regions retain page-alignment guards from the source.
  Task 20c must preserve those guards with `.align 256`; no absolute ROM address
  is required.

There is no fixed `$80`-based variable map. The old addresses were an artifact
of the generated source environment, not an interface requirement for an
included VCSC module.

## Register, flag, and hardware-register clobbers

The draw call clobbers A, X, Y, and N/V/Z/C. Decimal mode must be clear on entry
and exit. The module owns TIA graphics, motion, playfield, sync, and blanking
registers and RIOT `INTIM`/`TIM64T` while the call is active. Applications must
not expect those register values to survive.

Persistent module state is available again after return. The six transient
workspace bytes and two internal scratch bytes are undefined after every draw.
The kernel temporarily decrements object Y values while drawing but restores the
persistent values before return.

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

The source contract itself emits no code and no initialized data. The selected
configuration requires an 88-byte default score table. Exact kernel code size is
not guessed here; task 20d records it from the first linked map.

All listed optional features are rejected by this profile, so no speculative
RAM or ROM deltas are contractual. A feature may be added only as a later
profile revision with measured linked ROM bytes, module-owned RAM changes,
stack changes, and a timing regression. This prevents “free” conditional
features from silently consuming the last few RIOT bytes.

## Retained-source boundary for task 20c

The next conversion slice may draw only from these retained inputs:

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
